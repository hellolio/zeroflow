import AppKit
import ApplicationServices

/// 缩略图卡片上的窗口操作。
enum WindowOperation: Equatable {
    case quitApp   // 退出应用
    case close     // 关闭窗口
    case minimize  // 最小化
    case maximize  // 全屏切换（AltTab 绿钮语义）
}

/// 窗口操作执行：
/// - 本 app 窗口 → 主线程直接操作 NSWindow（AX 在本进程内会被 AppKit 转成主线程操作，
///   后台线程调用会触发崩溃，与 WindowActivator 同一规避）。
/// - 其他 app → 后台串行队列走 AX。
/// 完成回调在主线程触发（调用方用它移除面板里的卡片）。
enum WindowOps {
    private static let axQueue = DispatchQueue(label: "zeroflow.window-ops", qos: .userInitiated)

    static func perform(_ op: WindowOperation, on window: SwitcherWindow, then completion: (() -> Void)? = nil) {
        if window.pid == ProcessInfo.processInfo.processIdentifier {
            DispatchQueue.main.async {
                performOnSelf(op, window)
                completion?()
            }
            return
        }
        axQueue.async {
            performAX(op, window)
            DispatchQueue.main.async { completion?() }
        }
    }

    // MARK: - 本 app 窗口

    private static func performOnSelf(_ op: WindowOperation, _ window: SwitcherWindow) {
        switch op {
        case .quitApp:
            NSApp.terminate(nil)
        case .close:
            guard let nsWindow = nsWindow(for: window) else { return }
            nsWindow.performClose(nil)
        case .minimize:
            guard let nsWindow = nsWindow(for: window) else { return }
            nsWindow.miniaturize(nil)
        case .maximize:
            guard let nsWindow = nsWindow(for: window) else { return }
            nsWindow.toggleFullScreen(nil)
        }
    }

    private static func nsWindow(for window: SwitcherWindow) -> NSWindow? {
        NSApp.windows.first { $0.windowNumber == Int(window.id) }
    }

    // MARK: - 其他 app（AX）

    private static func performAX(_ op: WindowOperation, _ window: SwitcherWindow) {
        switch op {
        case .quitApp:
            window.app.terminate()
        case .close:
            guard let axWindow = AXWindow.element(for: window.id, pid: window.pid) else { return }
            closeAXWindow(axWindow, wid: window.id)
        case .minimize:
            guard let axWindow = AXWindow.element(for: window.id, pid: window.pid) else { return }
            AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        case .maximize:
            guard let axWindow = AXWindow.element(for: window.id, pid: window.pid) else { return }
            var raw: CFTypeRef?
            let target: CFTypeRef
            if AXUIElementCopyAttributeValue(axWindow, "AXFullScreen" as CFString, &raw) == .success,
               let fullscreen = raw as? Bool, fullscreen {
                target = kCFBooleanFalse
            } else {
                target = kCFBooleanTrue
            }
            AXUIElementSetAttributeValue(axWindow, "AXFullScreen" as CFString, target) // kAXFullScreenAttribute
        }
    }

    /// 关闭窗口（对齐 AltTab Window.close：按 AX 关闭按钮 = 系统红绿灯路径，比窗口的 AXClose
    /// action 可靠——多数 app/Electron 不实现 AXClose action，会导致「卡片移除但窗口没关」）。
    private static func closeAXWindow(_ axWindow: AXUIElement, wid: CGWindowID) {
        let debug = ProcessInfo.processInfo.environment["ZEROFLOW_SWITCHER_DEBUG"] == "1"
        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, "AXCloseButton" as CFString, &raw) == .success,
           let closeButton = raw as! AXUIElement? {
            let error = AXUIElementPerformAction(closeButton, "AXPress" as CFString) // kAXPressAction
            if debug {
                ZSLog("WindowOps: close wid=\(wid) via AXCloseButton press, error=\(error.rawValue)")
            }
            return
        }
        let error = AXUIElementPerformAction(axWindow, "AXClose" as CFString) // kAXCloseAction 兜底
        if debug {
            ZSLog("WindowOps: close wid=\(wid) via AXClose action fallback, error=\(error.rawValue)")
        }
    }
}
