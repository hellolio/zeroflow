import AppKit
import ApplicationServices

/// 私有桥：remote token → AXUIElement（AltTab 同款，HIServices/AXRuntime 动态解析）。
/// 用于给 kAXWindowsAttribute 不发布的跨 Space 窗口（尤其全屏）造元素，详见 AXWindow.elementByBruteForce。
@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

/// 共享 AX 窗口匹配辅助：CGWindowID → AXUIElement。
/// 首选私有桥 `_AXUIElementGetWindow` 精确匹配；不可用时退回 AX bounds 匹配（公开 API 兜底）。
/// WindowActivator（激活）与 WindowOps（关闭/最小化/全屏）共用。
enum AXWindow {
    /// 返回 wid 对应的 AX 窗口元素；找不到返回 nil。
    static func element(for wid: CGWindowID, pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        guard let axWindows = copyElements(appElement, kAXWindowsAttribute) else { return nil }

        // 只信私有桥精确匹配 CGWindowID（@_silgen_name 编译期链接，运行时不可能缺失）。
        // 不做 bounds 模糊匹配：同 app 两个全屏窗口 bounds 完全相同，跨 Space 目标不在发布
        // 列表时会误配到当前 Space 的同尺寸窗口（实测：raise 别的窗口，目标不动，切换无效）。
        for axWindow in axWindows {
            var w: CGWindowID = 0
            if _AXUIElementGetWindow(axWindow, &w) == .success, w == wid {
                return axWindow
            }
        }
        return nil
    }

    /// 返回 app 当前聚焦窗口的 CGWindowID（kAXFocusedWindowAttribute）。
    /// 同 app 多窗口切换时用它确定「当前窗口」：CGWindowListCopyWindowInfo 的顺序不会随
    /// 窗口间激活而刷新（实测：SLS 真 z-序已变化但 CGWindowList 顺序保持旧序），用 AX 聚焦
    /// 窗口比「CGWindowList 第一个 onscreen 窗口」可靠；AX 取不到时调用方回退 CGWindowList 兜底。
    static func focusedWindowID(for pid: pid_t) -> CGWindowID? {
        let appElement = AXUIElementCreateApplication(pid)
        // 短超时：本方法会被 MRU 补记/枚举高频调用，目标 app 挂死时不能按默认超时拖死调用方
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let focused = raw as! AXUIElement
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(focused, &wid) == .success, wid != 0 else { return nil }
        return wid
    }

    /// 读取窗口的 AX subrole（对齐 AltTab WindowDiscriminator：真窗口 subrole 应为
    /// AXStandardWindow 或 AXDialog；返回 nil = 没有可匹配的 AX 窗口实体 → 视为幽灵）。
    static func subrole(for wid: CGWindowID, pid: pid_t) -> String? {
        guard let axWindow = element(for: wid, pid: pid) else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXSubroleAttribute as CFString, &raw) == .success,
              let subrole = raw as? String else { return nil }
        return subrole
    }

    // MARK: - 跨 Space 暴力枚举（AltTab 同款）

    private static let bruteForceLock = NSLock()
    /// 每个 pid 的扫描游标：(下次起始 id, 上次使用时间)。超 30s 未用则从头扫（app 重启后 id 归零，旧游标会扫进死区）。
    private static var bruteForceCursors: [pid_t: (id: UInt64, lastUsed: TimeInterval)] = [:]

    /// 为 kAXWindowsAttribute 拿不到的窗口（跨 Space 全屏常态）暴力枚举 AX 元素，找到返回元素，超预算返回 nil。
    ///
    /// 背景：macOS 14+ `kAXWindowsAttribute` 只发布当前 Space 的窗口，另一 Space（尤其全屏）的窗口
    /// 用 `AXUIElementCreateApplication(pid)` 永远拿不到元素，激活只能靠 SLP/app.activate 收敛到该
    /// app「当前」的 Space（同 app 多全屏 Space 切换错位的根因）。AX↔wid 桥单向（只有 element→wid，
    /// 没有 wid→element），唯一办法是 AltTab `windowsByBruteForce` 的枚举术：remote token 是 20 字节
    /// 结构 [pid(4) | 0(4) | magic "coco"(4) | AXUIElementID(8)]，逐 id 调 `_AXUIElementCreateWithRemoteToken`
    /// 造元素、`_AXUIElementGetWindow` 匹配 wid。
    ///
    /// - 命中 wid ≠ window root：后代元素的 `_AXUIElementGetWindow` 也返回所属窗口 wid，raise 只对
    ///   root 有效，故再读 role 确认 == kAXWindowRole。
    /// - 预算 250ms 墙钟（AltTab 同款：id 空间 UInt64 稀疏，长命 app（如 Electron）id 可能很高，以
    ///   时间而非 id 上限为界）；每 id 一次 IPC，必须后台队列调用（focusSync 在 axQueue ✓）。
    /// - 游标按 pid 续扫：预算内没扫到，下次从上次位置继续；成功后归零（窗口关闭重建后 id 可能变小）。
    static func elementByBruteForce(pid: pid_t, windowId: CGWindowID, budgetMs: Int = 250) -> AXUIElement? {
        bruteForceLock.lock()
        defer { bruteForceLock.unlock() }
        guard let token = CFDataCreateMutable(kCFAllocatorDefault, 20) else { return nil }
        CFDataSetLength(token, 20)
        guard let bytes = CFDataGetMutableBytePtr(token) else { return nil }
        memset(bytes, 0, 20)
        var pidField = pid
        memcpy(bytes, &pidField, 4)
        var magic: Int32 = 0x636f_636f // "coco"
        memcpy(bytes + 8, &magic, 4)

        let now = Date().timeIntervalSinceReferenceDate
        if let cursor = bruteForceCursors[pid], now - cursor.lastUsed > 30 {
            bruteForceCursors[pid] = (0, now)
        } else if bruteForceCursors[pid] == nil {
            bruteForceCursors[pid] = (0, now)
        }
        var id = bruteForceCursors[pid]!.id
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(budgetMs) * 1_000_000
        var found: AXUIElement?
        while DispatchTime.now().uptimeNanoseconds < deadline {
            var idField = id
            id &+= 1
            memcpy(bytes + 12, &idField, 8)
            guard let candidate = _AXUIElementCreateWithRemoteToken(token)?.takeRetainedValue() else { continue }
            var w: CGWindowID = 0
            guard _AXUIElementGetWindow(candidate, &w) == .success, w == windowId else { continue }
            // wid 命中还要确认是 window root（后代元素也返回所属窗口 wid）
            var roleRaw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(candidate, kAXRoleAttribute as CFString, &roleRaw) == .success,
                  let role = roleRaw as? String, role == kAXWindowRole else { continue }
            found = candidate
            break
        }
        bruteForceCursors[pid] = (found != nil ? 0 : id, now)
        return found
    }

    // MARK: - 辅助

    private static func copyElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw else { return nil }
        return value as? [AXUIElement]
    }

    private static func copyValue<T>(_ element: AXUIElement, _ attribute: String, as _: T.Type) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw else { return nil }
        return value as? T
    }

}
