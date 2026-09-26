import AppKit
import ApplicationServices

/// 窗口级最近激活时间（MRU），对齐 AltTab 的 per-window `lastActivityTime`。
/// 对每个运行中的 app 监听 `kAXFocusedWindowChangedNotification`，聚焦窗口变化时用
/// `_AXUIElementGetWindow`（WindowActivator 里已声明的私有桥）取 CGWindowID 并打时间戳。
/// app 启动/退出时增删观察者；返回辅助功能授权后（didBecomeActive）补建。
final class WindowActivityTracker {
    static let shared = WindowActivityTracker()

    private let lock = NSLock()
    private var activity: [CGWindowID: Date] = [:]
    private var observers: [NSObjectProtocol] = []
    private var axObservers: [pid_t: AXObserver] = [:]
    /// 主动补记用的串行后台队列：AX 重读聚焦窗口不堵主线程，且保序（后到的激活覆盖先到的）
    private let bumpQueue = DispatchQueue(label: "zeroflow.window-activity-bump", qos: .userInitiated)
    /// Space 切换去抖任务（仅主线程访问）：连续滑动只补记最后一次落定的 Space
    private var spaceBumpWorkItem: DispatchWorkItem?

    private init() {
        observeLifecycle()
        observeActivationAndSpaceChanges()
        if AccessibilityPermission.isGranted {
            rebuildObservers()
        }
    }

    // MARK: - 对外查询

    func lastActiveDate(for wid: CGWindowID) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return activity[wid]
    }

    /// 记录窗口最近激活时间（MRU）。AX 焦点通知是异步的，快速连按 ⌘⇥ 时可能尚未落库，
    /// 因此切换器激活成功后会同步调用本方法补记，保证下一次枚举 index0 = 刚激活的窗口。
    /// - Parameter source: 时间戳来源（ax=AX 焦点回调 / activate=app 激活补记 / space=Space 切换补记 /
    ///   switcher=切换器激活 / frontmost=枚举时前台补记），仅用于 ZEROFLOW_SWITCHER_DEBUG 日志。
    func noteFocus(wid: CGWindowID, source: String) {
        lock.lock()
        activity[wid] = Date()
        lock.unlock()
        if ProcessInfo.processInfo.environment["ZEROFLOW_SWITCHER_DEBUG"] == "1" {
            ZSLog("MRU noteFocus wid=\(wid) source=\(source)")
        }
    }

    // MARK: - 生命周期

    private func observeLifecycle() {
        let ws = NSWorkspace.shared.notificationCenter
        observers = [
            ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.addObserver(for: app.processIdentifier)
            },
            ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.removeObserver(for: app.processIdentifier)
            },
        ]
        // 用户从系统设置返回授权后补建观察者（首次启动时可能尚未授权）
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard AccessibilityPermission.isGranted else { return }
            self?.rebuildObservers()
        }
    }

    private func rebuildObservers() {
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy != .prohibited else { continue }
            addObserver(for: app.processIdentifier)
        }
    }

    private func addObserver(for pid: pid_t) {
        guard AccessibilityPermission.isGranted else { return }
        lock.lock(); let exists = axObservers[pid] != nil; lock.unlock()
        guard !exists else { return }

        let appElement = AXUIElementCreateApplication(pid)
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, info in
            guard let info else { return }
            let tracker = Unmanaged<WindowActivityTracker>.fromOpaque(info).takeUnretainedValue()
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(element, &wid) == .success {
                tracker.noteFocus(wid: wid, source: "ax")
            }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let addError = AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, context)
        guard addError == .success else {
            // 个别 app 对该通知注册失败且此后不会再有任何窗口级焦点通知（此前静默失败，排查时是盲区）
            ZSLog("WindowActivityTracker: AXObserverAddNotification failed pid=\(pid) err=\(addError.rawValue)")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        lock.lock()
        axObservers[pid] = observer
        lock.unlock()
    }

    private func removeObserver(for pid: pid_t) {
        lock.lock()
        let observer = axObservers.removeValue(forKey: pid)
        lock.unlock()
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }

    // MARK: - 激活 / Space 切换补记（对齐 AltTab「激活时重读聚焦窗口」的 workaround）

    /// kAXFocusedWindowChangedNotification 在点击激活、触摸板滑 Space、Mission Control 等
    /// 路径下可能不发（AltTab 同款缺口，见其 checkIfFocused workaround），只靠 AX 回调会让
    /// 这些路径上聚焦的窗口拿不到时间戳，排序时被带旧时间戳的窗口压住（表现为默认选中错位，
    /// 如「滑到全屏 Space 后 ⌘⇥，上一个窗口排错」）。因此监听 app 激活与 Space 切换，
    /// 主动重读前台聚焦窗口补记 MRU。
    private func observeActivationAndSpaceChanges() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.bumpFocusedWindow(of: app.processIdentifier, source: "activate")
        })
        observers.append(ws.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Space 切换的焦点落位是异步的，稍等再读；连续滑动只保留最后一次
            self.spaceBumpWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, let front = NSWorkspace.shared.frontmostApplication else { return }
                self.bumpFocusedWindow(of: front.processIdentifier, source: "space")
            }
            self.spaceBumpWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
        })
    }

    /// 后台串行队列重读 pid 当前 AX 聚焦窗口的 CGWindowID 并补记（无窗口/取不到则跳过）。
    private func bumpFocusedWindow(of pid: pid_t, source: String) {
        bumpQueue.async { [weak self] in
            guard let self, let wid = AXWindow.focusedWindowID(for: pid) else { return }
            self.noteFocus(wid: wid, source: source)
        }
    }
}
