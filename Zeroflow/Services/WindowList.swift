import AppKit
import ApplicationServices
import CoreGraphics

/// 切换器里的一个窗口（面板展示的最小单元）。
/// 缩略图 `thumbnail` 由 WindowThumbnailer 后台填充，不阻塞列表构建。
/// `isWindowlessApp`：无窗口但仍在运行的 app 的占位卡（id 为合成值，非真实 CGWindowID）。
struct SwitcherWindow: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let app: NSRunningApplication
    let title: String
    let appName: String
    let appIcon: NSImage?
    let bounds: CGRect
    let isMinimized: Bool
    let workspace: Int
    var thumbnail: NSImage?
    var isWindowlessApp = false
}

/// 窗口列表采集（公开 API `CGWindowListCopyWindowInfo(.optionAll)` + CGS/SLS 私有 API 幽灵判定）。
/// - 基础过滤对齐 AltTab 默认行为：layer==0、正常 app owner、bounds ≥ 2pt；
///   保留最小化/离屏窗口（正是系统 ⌘⇥ 切不到的）。
/// - 幽灵过滤：CGS 可用时用 `PhantomWindowDetector`（对齐 AltTab）精确剔除；不可用退回启发式。
/// - 排序：窗口级 MRU（最近激活在前，见 `WindowActivityTracker`），保证默认选中「上一个窗口」。
/// - Space：总是列出所有 Space 的窗口（不做空间过滤；选中其他 Space 窗口时自动切 Space）。
final class WindowList {
    static let shared = WindowList()

    /// 系统性进程 owner 排除名单（layer==0 且非这些进程的常规窗口才入列）；
    /// 注意：不排除本 app（com.zeroflow.app），否则设置窗口不会出现在切换器里。
    /// FR-23 忽略名单（用户可配置 bundleID）的过滤扩展点也放在 isExcluded。
    private static let excludedBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.WindowServer",
        "com.apple.controlcenter",
        "com.apple.systemuiserver",
        "com.apple.loginwindow",
        "com.apple.Spotlight",
        "com.apple.universalAccessAuthWarn",
        "com.apple.notificationcenterui",
        "com.apple.WindowManager",
    ]

    private let lock = NSLock()
    /// MRU 应用列表，头 = 最近激活
    private var recentPids: [pid_t] = []
    private var observers: [NSObjectProtocol] = []

    init() {
        observeAppActivity()
    }

    // MARK: - MRU 维护

    private func observeAppActivity() {
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.noteActivation(of: app.processIdentifier)
            },
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.noteActivation(of: app.processIdentifier)
            },
        ]
    }

    private func noteActivation(of pid: pid_t) {
        lock.lock()
        recentPids.removeAll { $0 == pid }
        recentPids.insert(pid, at: 0)
        lock.unlock()
    }

    private func recentPidsCopy() -> [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        return recentPids
    }

    // MARK: - 枚举

    /// 枚举当前窗口列表（每个切换会话调用一次；数据本身取自信源，无需缓存）
    func enumerate() -> [SwitcherWindow] {
        guard let rawInfo = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var raws: [RawWindow] = []
        var seenIDs: Set<CGWindowID> = []
        for dict in rawInfo {
            guard let r = RawWindow.parse(dict) else { continue }
            guard r.layer == 0 else { continue }
            guard r.bounds.width >= 2, r.bounds.height >= 2 else { continue }
            guard let app = runningApp(for: r.ownerPID), !isExcluded(app) else { continue }
            // 防御性去重：CGWindowList 正常不会重复，但避免极端情况下同 id 出现多次
            guard seenIDs.insert(r.id).inserted else { continue }
            // 幽灵启发式过滤（CGS 不可用时的兜底）：每个真实窗口会被 WindowServer 伴生数个
            // 「全屏宽×约 33pt 的空标题条」、Chromium 系「~1300×90~107 伴生标题条（比值≈12~15）」，
            // 以及 64×64 等小 chrome 图标窗口（CGSHWCaptureWindowList 抓不到、不是可切换窗口）。
            // 保留条件：高度≥48 且 宽高比≤6 且（有标题 或 在屏 或 尺寸较大）。
            // （CGS 可用时走 filterPhantoms，这里仅作无 CGS 时的兜底。）
            let maxSide = max(r.bounds.width, r.bounds.height)
            guard r.bounds.height >= 48,
                  r.bounds.width / r.bounds.height <= 6,
                  (!r.name.isEmpty || r.isOnscreen || maxSide >= 400) else { continue }
            raws.append(r)
        }

        // 总是列出所有 Space 的窗口（不做事空间过滤；旧版「显示其他 Space 的窗口」开关已删除）。
        // CGS 幽灵判定（对齐 AltTab PhantomWindowDetector）：可用时精确剔除 alpha=0/orderOut:
        // Electron、微信/Teams 隐藏窗口、以及 WindowServer 伴生影子记录（Chrome/微信 的空卡）；
        // CGS 不可用时退回上面第 99 行的启发式过滤。
        if CGSWindowServer.shared.isAvailable {
            raws = Self.filterPhantoms(raws, server: CGSWindowServer.shared)
        }

        return finish(raws)
    }

    /// 用 CGS 成员列表做幽灵判定（对齐 AltTab PhantomWindowDetector.cgsVerdict）。
    /// 在「可见列表」（不含 invisible 标签）与「全量列表」上做交集/差集，配合
    /// 最小化（SLS tags 位 60）/ 隐藏 app（NSRunningApplication.isHidden）豁免。
    private static func filterPhantoms(_ raws: [RawWindow], server: CGSWindowServer) -> [RawWindow] {
        let spaces = server.allSpaceIds()
        guard !spaces.isEmpty else { return raws } // 拓扑拿不到，保守不滤（不会误删真窗口）

        var visibleSet = Set<CGWindowID>()
        var allSet = Set<CGWindowID>()
        var spacesMap: [CGWindowID: [UInt64]] = [:]
        for spaceId in spaces {
            visibleSet.formUnion(server.windowsInSpaces([spaceId], includeInvisible: false))
            let all = server.windowsInSpaces([spaceId], includeInvisible: true)
            allSet.formUnion(all)
            for wid in all { spacesMap[wid, default: []].append(spaceId) }
        }

        let tagsByWid = Dictionary(
            uniqueKeysWithValues: server.queryWindows(raws.map { $0.id }).map { ($0.wid, $0.tags) }
        )
        let visibleSpaceIds = server.visibleSpaceIds()
        let debug = ProcessInfo.processInfo.environment["ZEROFLOW_SWITCHER_DEBUG"] == "1"
        if debug {
            ZSLog("filterPhantoms: spaces=\(spaces.count) candidates=\(raws.count) allSet=\(allSet.count) visibleSet=\(visibleSet.count) visibleSpaces=\(visibleSpaceIds)")
        }

        var hiddenPids = Set<pid_t>()
        var result: [RawWindow] = []
        for r in raws {
            let minimized = ((tagsByWid[r.id] ?? 0) & (1 << 60)) != 0 // SLS tags 位 60 = minimized
            let appHidden: Bool
            if hiddenPids.contains(r.ownerPID) {
                appHidden = true
            } else if let app = NSRunningApplication(processIdentifier: r.ownerPID) {
                appHidden = app.isHidden
                if appHidden { hiddenPids.insert(r.ownerPID) }
            } else {
                appHidden = false
            }
            var isPhantom = PhantomWindowDetector.isPhantom(
                minimized: minimized,
                appHidden: appHidden,
                inVisibleList: visibleSet.contains(r.id),
                inAllList: allSet.contains(r.id),
                spaceIds: spacesMap[r.id] ?? [],
                visibleSpaceIds: visibleSpaceIds
            )
            // 兜底：被判为「其他 Space 真窗口」保留的不可见窗口，若 AX 没有标准窗口实体
            // （subrole 非 AXStandardWindow/AXDialog），仍是幽灵（如 Chrome 伴生记录 1272×498）。
            if !isPhantom, !minimized, !appHidden,
               allSet.contains(r.id), !visibleSet.contains(r.id) {
                let subrole = AXWindow.subrole(for: r.id, pid: r.ownerPID)
                if let subrole {
                    if subrole != kAXStandardWindowSubrole, subrole != kAXDialogSubrole {
                        isPhantom = true
                    }
                } else {
                    isPhantom = true
                }
            }
            if debug {
                ZSLog("  VERDICT wid=\(r.id) pid=\(r.ownerPID) size=\(Int(r.bounds.width))x\(Int(r.bounds.height)) minimized=\(minimized) appHidden=\(appHidden) inVis=\(visibleSet.contains(r.id)) inAll=\(allSet.contains(r.id)) spaceIds=\(spacesMap[r.id] ?? []) -> \(isPhantom ? "PHANTOM" : "KEEP")")
            }
            if !isPhantom { result.append(r) }
        }
        return result
    }

    /// 构建 SwitcherWindow 并按「窗口级 MRU」全局排序（对齐 AltTab 的 lastActivityTime）。
    /// 最近激活的窗口在前（index 0 = 当前窗口，index 1 = 上一个窗口，默认选中 = 1 + offset 天然正确）；
    /// 无激活记录的按 app 级 MRU（前台 app 居前）兜底，同 rank 按 wid 稳定排序。
    private func finish(_ raws: [RawWindow]) -> [SwitcherWindow] {
        var groups: [pid_t: [RawWindow]] = [:]
        var pidsInOrder: [pid_t] = []
        for r in raws {
            if groups[r.ownerPID] == nil {
                groups[r.ownerPID] = []
                pidsInOrder.append(r.ownerPID)
            }
            groups[r.ownerPID]?.append(r)
        }

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let recent = recentPidsCopy()
        var ordered: [pid_t] = []
        if let frontmostPID { ordered.append(frontmostPID) }
        for pid in recent where !ordered.contains(pid) { ordered.append(pid) }
        for pid in pidsInOrder where !ordered.contains(pid) { ordered.append(pid) }
        var rank: [pid_t: Int] = [:]
        for (i, pid) in ordered.enumerated() { rank[pid] = i }

        var result: [SwitcherWindow] = []
        for r in raws {
            guard let app = NSRunningApplication(processIdentifier: r.ownerPID),
                  let appName = app.localizedName else { continue }
            let title = r.name.isEmpty ? appName : r.name
            result.append(SwitcherWindow(
                id: r.id,
                pid: r.ownerPID,
                app: app,
                title: title,
                appName: appName,
                appIcon: app.icon,
                bounds: r.bounds,
                isMinimized: !r.isOnscreen,
                workspace: r.workspace
            ))
        }

        // 无窗口 app 占位卡：窗口全关但仍在运行的正常 app（有 Dock 图标 .regular、非排除、
        // 非本 app、当前列表无其窗口）→ 显示 app 图标占位，统一排在最后（FR-17.7）。
        if SettingsStore.shared.windowSwitcherShowWindowlessApps {
            let windowPids = Set(result.map { $0.pid })
            let selfPID = ProcessInfo.processInfo.processIdentifier
            let placeholders = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .filter { !isExcluded($0) }
                .filter { $0.processIdentifier != selfPID }
                .filter { !windowPids.contains($0.processIdentifier) }
                .map { app -> SwitcherWindow in
                    let name = app.localizedName ?? "?"
                    var w = SwitcherWindow(
                        id: UInt32(0x8000_0000) | UInt32(app.processIdentifier),
                        pid: app.processIdentifier,
                        app: app,
                        title: name,
                        appName: name,
                        appIcon: app.icon,
                        bounds: .zero,
                        isMinimized: false,
                        workspace: -1
                    )
                    w.isWindowlessApp = true
                    return w
                }
            result.append(contentsOf: placeholders)
        }

        let tracker = WindowActivityTracker.shared
        // CGWindowList 返回顺序 ≈ 全局 z 序（前置在前）；记录每个 pid 最顶层的 onscreen 窗口，
        // 作为该 pid 窗口无 MRU 记录时的兜底顺序（当前窗口一般在顶层）。
        var frontWindowByPid: [pid_t: CGWindowID] = [:]
        for r in raws where r.isOnscreen {
            if frontWindowByPid[r.ownerPID] == nil { frontWindowByPid[r.ownerPID] = r.id }
        }
        // 前台窗口强制记最新活跃：对齐 AltTab「聚焦窗口永远是最近激活」。这是确定性的 index0 = 当前窗口
        // 修复——若某窗口带着旧日期（全屏/跨 Space 下 noteFocus 曾遗漏等），日期比较会压过前台性，
        // 导致当前窗口排不到第一张卡。此处直接把它升为最新，从根上消除。
        // 当前窗口优先用 AX 聚焦窗口：CGWindowListCopyWindowInfo 的顺序不会随同 app 窗口间激活刷新
        // （实测 SLS 真 z-序已更新、CGWindowList 仍保持旧序，曾导致「最后一个激活窗口排不到第一张卡」），
        // kAXFocusedWindowAttribute 语义上就是「当前窗口」，取不到时回退 CGWindowList 顶层 onscreen 窗口。
        if let frontmostPID {
            let currentID = AXWindow.focusedWindowID(for: frontmostPID) ?? frontWindowByPid[frontmostPID]
            // 同步兜底表，让下面 sort 的 aIsFront/bIsFront tiebreak 与调试日志的 current 判定保持一致。
            if currentID != nil { frontWindowByPid[frontmostPID] = currentID }
            if let currentID {
                tracker.noteFocus(wid: currentID)
            }
        }

        result.sort { a, b in
            // 无窗口占位卡一律排在所有真实窗口之后
            if a.isWindowlessApp != b.isWindowlessApp { return !a.isWindowlessApp }
            let ta = tracker.lastActiveDate(for: a.id)
            let tb = tracker.lastActiveDate(for: b.id)
            if let ta, let tb { return ta > tb }
            if ta != nil { return true }
            if tb != nil { return false }
            let ra = rank[a.pid] ?? Int.max
            let rb = rank[b.pid] ?? Int.max
            if ra != rb { return ra < rb }
            let aIsFront = frontWindowByPid[a.pid] == a.id
            let bIsFront = frontWindowByPid[b.pid] == b.id
            if aIsFront != bIsFront { return aIsFront }
            return a.id < b.id
        }

        if ProcessInfo.processInfo.environment["ZEROFLOW_SWITCHER_DEBUG"] == "1" {
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let frontIDs = result.prefix(5).map { w in
                let hasDate = tracker.lastActiveDate(for: w.id) != nil
                let isCurrent = frontmostPID != nil && frontWindowByPid[frontmostPID!] == w.id
                return "\(w.appName)/\(String(w.id)) date=\(hasDate) current=\(isCurrent)"
            }
            ZSLog("SWITCHER-DEBUG sorted order → [\(frontIDs.joined(separator: ", "))]")
        }
        return result
    }

    // MARK: - 辅助

    private struct RawWindow {
        var id: CGWindowID
        var ownerPID: pid_t
        var name: String
        var bounds: CGRect
        var layer: Int
        var isOnscreen: Bool
        var workspace: Int

        static func parse(_ dict: [String: Any]) -> RawWindow? {
            guard let num = (dict[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? (dict[kCGWindowNumber as String] as? UInt32) else { return nil }
            let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? (dict[kCGWindowLayer as String] as? Int ?? 0)
            guard let pidValue = (dict[kCGWindowOwnerPID as String] as? NSNumber)?.intValue
                ?? (dict[kCGWindowOwnerPID as String] as? Int) else { return nil }
            let pid = pid_t(pidValue)
            guard let bounds = parseBounds(dict[kCGWindowBounds as String] as? [String: Any]) else { return nil }
            let name = dict[kCGWindowName as String] as? String ?? ""
            let isOnscreen = (dict[kCGWindowIsOnscreen as String] as? Bool) ?? false
            // kCGWindowWorkspace 常量在 macOS 26 SDK 被标记 unavailable，但返回字典里键字符串仍存在
            let workspace = (dict["kCGWindowWorkspace"] as? NSNumber)?.intValue ?? -1
            return RawWindow(id: num, ownerPID: pid, name: name, bounds: bounds,
                             layer: layer, isOnscreen: isOnscreen, workspace: workspace)
        }

        private static func parseBounds(_ dict: [String: Any]?) -> CGRect? {
            guard let dict else { return nil }
            guard let x = (dict["X"] as? NSNumber)?.doubleValue ?? (dict["X"] as? Double),
                  let y = (dict["Y"] as? NSNumber)?.doubleValue ?? (dict["Y"] as? Double),
                  let width = (dict["Width"] as? NSNumber)?.doubleValue ?? (dict["Width"] as? Double),
                  let height = (dict["Height"] as? NSNumber)?.doubleValue ?? (dict["Height"] as? Double)
            else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }

    private func runningApp(for pid: pid_t) -> NSRunningApplication? {
        NSRunningApplication(processIdentifier: pid)
    }

    private func isExcluded(_ app: NSRunningApplication) -> Bool {
        if let bundleID = app.bundleIdentifier, Self.excludedBundleIDs.contains(bundleID) {
            return true
        }
        // 无 UI 的后台守护进程不进列表
        return app.activationPolicy == .prohibited
    }
}