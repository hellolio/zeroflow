import AppKit
import ApplicationServices

/// 私有单行桥：AX 窗口 → CGWindowID（AltTab 同款，需链接 ApplicationServices）
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ axUIElement: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

/// 窗口激活：还原最小化 → 激活 app → AX 置顶/设为 main。
/// 全部 AX 写操作放到专门的后台串行队列，绝不在事件 tap 回调里跑（与 Dock 模块同一原则）。
final class WindowActivator {
    static let shared = WindowActivator()

    private let axQueue = DispatchQueue(label: "zeroflow.window-activator", qos: .userInitiated)

    /// 异步聚焦窗口：先还原最小化，再 activate，再 AX 置顶。
    /// 本 app 的窗口走主线程直接操作 NSWindow —— AX 在本进程内会被 AppKit 转成
    /// `makeKeyAndOrderFront:`，后台线程调用会触发 AppKit 崩溃（SIGTRAP，见崩溃日志）。
    func focus(window: SwitcherWindow) {
        if window.pid == ProcessInfo.processInfo.processIdentifier {
            DispatchQueue.main.async { self.focusSelf(window) }
            return
        }
        axQueue.async {
            self.focusSync(window)
        }
    }

    /// 本 app 窗口：主线程 `makeKeyAndOrderFront`，完全不经过 AX。
    private func focusSelf(_ window: SwitcherWindow) {
        NSApp.activate(ignoringOtherApps: true)
        guard let nsWindow = NSApp.windows.first(where: { $0.windowNumber == Int(window.id) }) else {
            ZSLog("WindowActivator: own window wid=\(window.id) not found in NSApp.windows, activate only")
            return
        }
        if window.isMinimized {
            nsWindow.deminiaturize(nil)
        }
        nsWindow.makeKeyAndOrderFront(nil)
        // 同步补记 MRU：AX 焦点通知是异步的，快速连按 ⌘⇥ 时要保证下次枚举 index0 = 刚激活窗口
        WindowActivityTracker.shared.noteFocus(wid: window.id, source: "switcher")
        ZSLog("WindowActivator: focused own window wid=\(window.id)")
    }

    private func focusSync(_ window: SwitcherWindow) {
        let app = window.app

        // 入口即补记 MRU：AX 焦点通知是异步的，快速连按 ⌘⇥ 时要保证下次枚举 index0 = 刚激活窗口。
        // 必须在 AX 匹配之前调用——全屏窗口在另一个 Space 上时 kAXWindowsAttribute 常取不到
        // （走下方 SkyLight/activate 兜底），若补记放在成功路径末尾会被跳过，导致全屏切换后 MRU 排序不更新。
        WindowActivityTracker.shared.noteFocus(wid: window.id, source: "switcher")

        // 无窗口 app 占位卡：`app.activate` 对没有窗口的 app 通常无效（macOS 无窗口可激活）。
        // 对齐 AltTab：重新 launch 该 app（已运行会置前，多数 app 会尝试重开窗口）；失败退回 activate。
        if window.isWindowlessApp {
            if let bundleURL = app.bundleURL,
               (try? NSWorkspace.shared.launchApplication(at: bundleURL, configuration: [:])) != nil {
                ZSLog("WindowActivator: relaunched windowless app pid=\(window.pid)")
            } else {
                app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                ZSLog("WindowActivator: activated windowless app pid=\(window.pid) (launch failed)")
            }
            return
        }

        guard let axWindow = AXWindow.element(for: window.id, pid: window.pid) else {
            // kAXWindowsAttribute 取不到（跨 Space 全屏窗口的常态）：先试 AltTab 同款 remote-token 暴力
            // 枚举造出该窗口的 AX 元素（AX↔wid 桥单向，只能枚举；详见 AXWindow.elementByBruteForce），
            // 拿到元素后走与常规路径一致的「SLP → makeKey → AX main/raise」收尾——这是同 app 多全屏
            // Space 真正落到目标窗口的关键（app.activate 只会落到该 app「当前」Space；SLP 单独使用时
            // AppKit 层激活不完整，实测对全屏 Space 静默无效）。
            if let bfWindow = AXWindow.elementByBruteForce(pid: window.pid, windowId: window.id) {
                raiseViaSLP(window: window, axWindow: bfWindow, via: "remote-token element")
                return
            }
            // 暴力枚举失败（长命 app id 过高/超预算）：SLP 切 Space + app.activate 补激活兑底
            // （不带 activateAllWindows，避免把同 app 另一个全屏 Space 拉回来）。
            if CGSWindowServer.shared.setFrontProcess(windowId: window.id, pid: window.pid) {
                CGSWindowServer.shared.makeKeyWindow(pid: window.pid, windowId: window.id)
                app.activate(options: [.activateIgnoringOtherApps])
                ZSLog("WindowActivator: no AX window matched wid=\(window.id), focused via SkyLight + app activate")
                return
            }
            ZSLog("WindowActivator: no AX window matched wid=\(window.id), fallback to app activate")
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            return
        }

        // 1. 最小化窗口先还原（动画结束前不再重抓，避免迷你帧）——还原路径维持 AX + activate（已验证）
        if window.isMinimized {
            AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            ZSLog("WindowActivator: raised (unminimized) wid=\(window.id) title='\(window.title)'")
            return
        }

        // 2. 非最小化：AltTab 同款 WindowServer 级激活（FR-19.4）
        raiseViaSLP(window: window, axWindow: axWindow, via: "AX element")
    }

    /// WindowServer 级置前 + AX 收敛 key/main（FR-19.4）。
    /// 已在独立探针验证（含同 app 两个全屏 Space、目标 app 已前台/非前台、主线程/后台线程）：
    /// `_SLPSSetFrontProcessWithOptions(psn, wid, 0x200)` 无条件按 wid 切 Space（即使该 app 已是
    /// front process 也生效），随后 makeKey 事件收敛 key、AX main/raise 完成 AppKit 层激活收尾；
    /// SLP 不可用时退回 app.activate。最小化还原路径不走这里（保持 AX deminiaturize 序列）。
    private func raiseViaSLP(window: SwitcherWindow, axWindow: AXUIElement, via: String) {
        let app = window.app
        if CGSWindowServer.shared.setFrontProcess(windowId: window.id, pid: window.pid) {
            CGSWindowServer.shared.makeKeyWindow(pid: window.pid, windowId: window.id)
            AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        } else {
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        }
        ZSLog("WindowActivator: raised wid=\(window.id) title='\(window.title)' via \(via)")
    }
}