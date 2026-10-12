import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

/// 私有单行桥：pid → ProcessSerialNumber（HIServices，Amethyst/AltTab 同款 @_silgen_name 链接），
/// `_SLPSSetFrontProcessWithOptions` 需要 PSN 入参。
@_silgen_name("GetProcessForPID")
@discardableResult
func GetProcessForPID(_ pid: pid_t, _ psn: inout ProcessSerialNumber) -> OSStatus

/// SkyLight / CGS 私有 API 桥（运行时 dlsym，与 `WindowThumbnailer` 同款模式）。
/// - 枚举：`SLSWindowQueryWindows` 批量取 typed 字段（title/bounds/level/attributes/spaceTypeMask/tags）。
/// - 成员：`CGSCopyWindowsWithOptionsAndTags`（`.invisible1/.invisible2` 区分「可见列表」与「全量列表」）。
/// - Space：`CGSCopyManagedDisplaySpaces`（各屏当前 Space）+ 逐 Space 反查窗口归属。
/// - 激活：`_SLPSSetFrontProcessWithOptions` + `SLPSPostEventRecordTo`（可选符号；跨 Space 前台切换，见 `WindowActivator`）。
/// 任一符号缺失 → `isAvailable == false`，调用方退回公开 API（CGWindowList），不崩。
/// 说明：本工程已在使用 SkyLight 私有 API（WindowThumbnailer），此处同样是 AltTab 的正式做法。
final class CGSWindowServer {
    static let shared = CGSWindowServer()

    /// SLS 批量查询返回的一个窗口的 typed 字段
    struct RawWindow {
        let wid: CGWindowID
        let pid: pid_t
        let title: String
        let bounds: CGRect
        let level: Int32
        let attributes: UInt64
        let spaceTypeMask: UInt64
        let tags: UInt64
    }

    // MARK: - dlsym 函数类型

    private typealias MainConnFn = @convention(c) () -> UInt32
    private typealias CopyWindowsFn = @convention(c) (UInt32, Int, CFArray, Int, UnsafeMutablePointer<Int>, UnsafeMutablePointer<Int>) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindowsFn = @convention(c) (UInt32, Int, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (UInt32) -> Unmanaged<CFArray>?
    private typealias QueryWindowsFn = @convention(c) (UInt32, CFArray, Int32) -> Unmanaged<CFTypeRef>?
    private typealias QueryResultFn = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    private typealias IterAdvanceFn = @convention(c) (CFTypeRef) -> Bool
    private typealias IterGetU32Fn = @convention(c) (CFTypeRef) -> UInt32
    private typealias IterGetPidFn = @convention(c) (CFTypeRef) -> pid_t
    private typealias IterGetI32Fn = @convention(c) (CFTypeRef) -> Int32
    private typealias IterGetU64Fn = @convention(c) (CFTypeRef) -> UInt64
    private typealias IterCopyTitleFn = @convention(c) (CFTypeRef) -> Unmanaged<CFString>?
    private typealias IterGetBoundsFn = @convention(c) (UnsafeRawPointer) -> CGRect
    // 跨 Space 前台激活（可选符号，缺失仅退化为 app.activate 旧行为）
    private typealias SetFrontProcessWithOptionsFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> CGError
    private typealias PostEventRecordToFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError

    private struct Bridge {
        let mainConn: MainConnFn
        let copyWindows: CopyWindowsFn
        let copySpacesForWindows: CopySpacesForWindowsFn
        let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn
        let queryWindows: QueryWindowsFn
        let queryResult: QueryResultFn
        let iterAdvance: IterAdvanceFn
        let iterGetWindowID: IterGetU32Fn
        let iterGetPID: IterGetPidFn
        let iterGetLevel: IterGetI32Fn
        let iterGetSpaceTypeMask: IterGetU64Fn
        let iterGetTags: IterGetU64Fn
        let iterGetAttributes: IterGetU64Fn
        let iterCopyTitle: IterCopyTitleFn
        let iterGetBounds: IterGetBoundsFn
        // 可选符号：缺失仅影响跨 Space 前台激活，isAvailable 仍为 true（枚举/缩略图不受影响）
        let setFrontProcessWithOptions: SetFrontProcessWithOptionsFn?
        let postEventRecordTo: PostEventRecordToFn?
    }

    private let bridge: Bridge?
    private let cid: UInt32
    var isAvailable: Bool { bridge != nil }

    private init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else {
            ZSLog("CGSWindowServer: dlopen SkyLight failed, falling back to public API")
            bridge = nil
            cid = 0
            return
        }
        // 不 dlclose：函数指针由 SkyLight 提供，系统常驻，避免卸载风险
        if let loaded = Self.loadBridge(from: handle) {
            bridge = loaded.bridge
            cid = loaded.cid
        } else {
            ZSLog("CGSWindowServer: symbols missing, falling back to public API")
            bridge = nil
            cid = 0
        }
    }

    private static func loadBridge(from handle: UnsafeMutableRawPointer) -> (cid: UInt32, bridge: Bridge)? {
        func sym<T>(_ name: String) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let mainConn: MainConnFn = sym("CGSMainConnectionID"),
              let copyWindows: CopyWindowsFn = sym("CGSCopyWindowsWithOptionsAndTags"),
              let copySpacesForWindows: CopySpacesForWindowsFn = sym("CGSCopySpacesForWindows"),
              let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn = sym("CGSCopyManagedDisplaySpaces"),
              let queryWindows: QueryWindowsFn = sym("SLSWindowQueryWindows"),
              let queryResult: QueryResultFn = sym("SLSWindowQueryResultCopyWindows"),
              let iterAdvance: IterAdvanceFn = sym("SLSWindowIteratorAdvance"),
              let iterGetWindowID: IterGetU32Fn = sym("SLSWindowIteratorGetWindowID"),
              let iterGetPID: IterGetPidFn = sym("SLSWindowIteratorGetPID"),
              let iterGetLevel: IterGetI32Fn = sym("SLSWindowIteratorGetLevel"),
              let iterGetSpaceTypeMask: IterGetU64Fn = sym("SLSWindowIteratorGetSpaceTypeMask"),
              let iterGetTags: IterGetU64Fn = sym("SLSWindowIteratorGetTags"),
              let iterGetAttributes: IterGetU64Fn = sym("SLSWindowIteratorGetAttributes"),
              let iterCopyTitle: IterCopyTitleFn = sym("SLSWindowIteratorCopyTitle"),
              let iterGetBounds: IterGetBoundsFn = sym("SLSWindowIteratorGetBounds")
        else { return nil }
        // 可选符号（双名兜底）：本机实测 `_SLPSSetFrontProcessWithOptions` 与 `SLPSPostEventRecordTo` 均可 dlsym 解析
        let setFrontProcessWithOptions: SetFrontProcessWithOptionsFn? =
            sym("_SLPSSetFrontProcessWithOptions") ?? sym("SLPSSetFrontProcessWithOptions")
        let postEventRecordTo: PostEventRecordToFn? =
            sym("SLPSPostEventRecordTo") ?? sym("_SLPSPostEventRecordTo")
        let bridge = Bridge(mainConn: mainConn, copyWindows: copyWindows, copySpacesForWindows: copySpacesForWindows,
                            copyManagedDisplaySpaces: copyManagedDisplaySpaces, queryWindows: queryWindows,
                            queryResult: queryResult, iterAdvance: iterAdvance, iterGetWindowID: iterGetWindowID,
                            iterGetPID: iterGetPID, iterGetLevel: iterGetLevel, iterGetSpaceTypeMask: iterGetSpaceTypeMask,
                            iterGetTags: iterGetTags, iterGetAttributes: iterGetAttributes,
                            iterCopyTitle: iterCopyTitle, iterGetBounds: iterGetBounds,
                            setFrontProcessWithOptions: setFrontProcessWithOptions, postEventRecordTo: postEventRecordTo)
        return (mainConn(), bridge)
    }

    // MARK: - SLS 批量枚举

    /// 对 wids 批量查询 typed 字段（一次 IPC）。
    func queryWindows(_ wids: [CGWindowID]) -> [RawWindow] {
        guard let bridge, !wids.isEmpty else { return [] }
        guard let query = bridge.queryWindows(cid, wids as CFArray, Int32(wids.count))?.takeRetainedValue(),
              let iterator = bridge.queryResult(query)?.takeRetainedValue()
        else { return [] }
        var out: [RawWindow] = []
        while bridge.iterAdvance(iterator) {
            out.append(RawWindow(
                wid: bridge.iterGetWindowID(iterator),
                pid: bridge.iterGetPID(iterator),
                title: bridge.iterCopyTitle(iterator)?.takeRetainedValue() as String? ?? "",
                bounds: bridge.iterGetBounds(Unmanaged.passUnretained(iterator).toOpaque()),
                level: bridge.iterGetLevel(iterator),
                attributes: bridge.iterGetAttributes(iterator),
                spaceTypeMask: bridge.iterGetSpaceTypeMask(iterator),
                tags: bridge.iterGetTags(iterator)
            ))
        }
        return out
    }

    // MARK: - Space 拓扑

    /// 所有 Space id（来自 CGSCopyManagedDisplaySpaces 的 Spaces[id64]）。
    func allSpaceIds() -> [UInt64] {
        guard let bridge else { return [] }
        guard let raw = bridge.copyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var ids = Set<UInt64>()
        for display in raw {
            if let spaces = display["Spaces"] as? [[String: Any]] {
                for space in spaces {
                    if let id64 = (space["id64"] as? NSNumber)?.uint64Value { ids.insert(id64) }
                }
            }
        }
        return Array(ids)
    }

    /// 当前可见 Space id（每屏一个，来自各屏的 Current Space）。
    func visibleSpaceIds() -> [UInt64] {
        guard let bridge else { return [] }
        guard let raw = bridge.copyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var ids: [UInt64] = []
        for display in raw {
            if let current = display["Current Space"] as? [String: Any],
               let id64 = (current["id64"] as? NSNumber)?.uint64Value {
                ids.append(id64)
            }
        }
        return ids
    }

    /// 指定 Space 上的窗口 id 列表。
    /// `includeInvisible=false` 排除 `.invisible1/.invisible2` 标签窗口（= 可见列表）；
    /// `includeInvisible=true` 含它们（= 全量列表）。
    func windowsInSpaces(_ spaceIds: [UInt64], includeInvisible: Bool) -> [CGWindowID] {
        guard let bridge, !spaceIds.isEmpty else { return [] }
        // 1<<0 = invisible1, 1<<2 = invisible2, 1<<1 = screenSaverLevel1000（AltTab 实测常量）
        let options = includeInvisible ? (1 << 0 | 1 << 1 | 1 << 2) : (1 << 1)
        var setTags = 0
        var clearTags = 0
        guard let array = bridge.copyWindows(cid, 0, spaceIds as CFArray, options, &setTags, &clearTags)?.takeRetainedValue() as? [CGWindowID] else { return [] }
        return array
    }

    // MARK: - 跨 Space 前台激活（SkyLight 私有 API，AltTab/Hammerspoon 同款）

    /// WindowServer 级把指定窗口带前台并自动切到其所在 Space：
    /// `GetProcessForPID` 取 PSN → `_SLPSSetFrontProcessWithOptions(psn, wid, kCPSUserGenerated=0x200)`。
    /// 同 app 多窗口各占全屏 Space 时这是唯一可靠手段（`app.activate` 只会落到该 app「当前」的 Space）。
    /// 返回 false = 符号缺失 / PSN 失败 / CGError 失败，调用方应退回 `app.activate` 旧行为。
    @discardableResult
    func setFrontProcess(windowId wid: CGWindowID, pid: pid_t) -> Bool {
        guard let bridge, let fn = bridge.setFrontProcessWithOptions else {
            ZSLog("CGSWindowServer: setFrontProcess unavailable (symbol missing)")
            return false
        }
        var psn = ProcessSerialNumber()
        guard GetProcessForPID(pid, &psn) == noErr else {
            ZSLog("CGSWindowServer: GetProcessForPID failed pid=\(pid)")
            return false
        }
        let err = fn(&psn, wid, 0x200) // kCPSUserGenerated
        if err != .success {
            ZSLog("CGSWindowServer: setFrontProcess wid=\(wid) err=\(err.rawValue)")
        }
        return err == .success
    }

    /// 把 AppKit 层 key 窗口收敛到指定窗口（Hammerspoon 事件记录配方，AltTab `makeKeyWindow` 逐字节同款）。
    /// 不发这个，部分 app 已切 Space 但键盘焦点没跟上（AltTab 注释里的 System Preferences OS bug）。
    func makeKeyWindow(pid: pid_t, windowId wid: CGWindowID) {
        guard let bridge, let post = bridge.postEventRecordTo else { return }
        var psn = ProcessSerialNumber()
        guard GetProcessForPID(pid, &psn) == noErr else { return }
        var bytes1 = [UInt8](repeating: 0, count: 0xf8)
        bytes1[0x04] = 0xF8
        bytes1[0x08] = 0x01
        bytes1[0x3a] = 0x10
        var bytes2 = [UInt8](repeating: 0, count: 0xf8)
        bytes2[0x04] = 0xF8
        bytes2[0x08] = 0x02
        bytes2[0x3a] = 0x10
        var wid32 = UInt32(wid)
        withUnsafeBytes(of: &wid32) { raw in
            for (i, byte) in raw.enumerated() {
                bytes1[0x3c + i] = byte
                bytes2[0x3c + i] = byte
            }
        }
        for i in 0x20..<0x30 {
            bytes1[i] = 0xFF
            bytes2[i] = 0xFF
        }
        bytes1.withUnsafeMutableBufferPointer { b1 in
            bytes2.withUnsafeMutableBufferPointer { b2 in
                _ = post(&psn, b1.baseAddress!)
                _ = post(&psn, b2.baseAddress!)
            }
        }
    }
}
