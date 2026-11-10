import AppKit
import ApplicationServices
import CoreGraphics

/// Dock 快捷键弹出（自动隐藏时）：按下预设修饰键热键（默认裸 Option）并松开，
/// 让自动隐藏的 Dock 短暂弹出看清图标状态，停留结束后由 macOS 自己收起。
///
/// 弹出方式：把 Dock 进程窗口的 `AXManualHide` AX 属性临时置 false
/// （Dock 立即弹出动画），驻留 `dockPeekHoldMs` 后写回读取到的原值。
/// **不移动鼠标指针、不读写系统 autohide 设置**，Dock 的弹出/收起节奏由 macOS 管理。
///
/// 实现要点：
/// - 裸修饰键热键无法走 `GlobalHotkeyManager` 的 Carbon
///   `RegisterEventHotKey`（必须有主键），改用 listen-only CGEventTap 监听
///   flagsChanged **精确匹配**修饰键组合，且只在「按下→松开期间没有出现任何
///   其他按键/鼠标按下」时触发，保证 Option 兼作 ⌥` 切换器、打字变音等
///   正常修饰键用法时不误触发。
/// - peek 动作在后台串行队列执行：generation 防重入；驻留到点/功能关闭都走
///   同一个还原入口（写回原值，而不是一律 true，避免碰掉系统原有状态）。
/// - `ZEROFLOW_DOCKPEEK_DEBUG=1` 打印状态机与 AXManualHide 决策日志；
///   该属性不可用时会 dump Dock 窗口的 AX 属性名便于排查。
final class DockPeekManager {
    static let shared = DockPeekManager()

    /// 外部通知：由 SettingsStore.dockPeekEnabled 的 didSet 触发
    static let didChangeNotification = Notification.Name("zeroflow.dockPeekDidChange")
    /// 外部通知：由 SettingsStore.dockPeekShortcut 的 didSet 触发（tap 为懒读配置，仅用于日志/订阅者）
    static let shortcutDidChangeNotification = Notification.Name("zeroflow.dockPeekShortcutDidChange")

    /// 按下→松开的最长间隔：超过视为正常修饰键长按，不触发
    private static let maxPressDuration: TimeInterval = 2.0
    /// 驻留时长设置的下限（毫秒），钳制极端值
    private static let minHoldMs = 150
    private static let maxHoldMs = 5000
    /// Dock 窗口上控制「手动隐藏」的 AX 属性
    private static let manualHideAttribute = "AXManualHide" as CFString

    private let lock = NSLock()
    private var isRunning = false
    private var suspended = false
    private var thread: Thread?
    private weak var tapRunLoop: CFRunLoop?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let workQueue = DispatchQueue(label: "zeroflow.dock-peek", qos: .userInitiated)

    // MARK: - 热键状态机（tap 线程串行访问，无需加锁）

    /// 修饰键组合正按住（已触发过 press 判定）
    private var armed = false
    private var armedTime: CFTimeInterval = 0
    /// 按住期间出现过其他按键/鼠标事件：视为正常修饰键用法，松开不触发
    private var foreignSeen = false

    // MARK: - peek 在途（tap 线程与 workQueue 共享，经 lock）

    private var generation: UInt64 = 0
    private var inFlight = false
    /// 当前在途 peek 的还原动作（驻留超时/关闭功能时执行一次并作废）
    private var pendingRestore: (() -> Void)?

    private let debug: Bool = ProcessInfo.processInfo.environment["ZEROFLOW_DOCKPEEK_DEBUG"] == "1"

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidChange(_:)),
            name: Self.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShortcutDidChange(_:)),
            name: Self.shortcutDidChangeNotification,
            object: nil
        )
    }

    // MARK: - 系统偏好读取

    /// 系统是否开启了 Dock 自动隐藏（「桌面与 Dock → 自动显示和隐藏 Dock」）
    static func readSystemAutohide() -> Bool {
        (CFPreferencesCopyAppValue("autohide" as CFString, "com.apple.dock" as CFString) as? Bool) ?? false
    }

    // MARK: - 启停

    /// 按开关当前状态启停（启动时 / 开关变化时调用）
    func reapply() {
        if SettingsStore.shared.dockPeekEnabled {
            start()
        } else {
            stop()
        }
    }

    /// 快捷键录制期间暂停触发识别（录制结束恢复）
    func suspend() {
        lock.lock(); suspended = true; lock.unlock()
        dlog("suspended (recording)")
    }

    func resume() {
        lock.lock(); suspended = false; lock.unlock()
        dlog("resumed")
    }

    @objc private func handleDidChange(_ notification: Notification) {
        reapply()
    }

    @objc private func handleShortcutDidChange(_ notification: Notification) {
        dlog("shortcut changed, arm state reset")
    }

    private func start() {
        lock.lock()
        guard !isRunning else { lock.unlock(); return }
        isRunning = true
        suspended = false
        lock.unlock()

        let t = Thread { [weak self] in
            self?.runTapLoop()
        }
        t.name = "zeroflow.dock-peek"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
        ZSLog("DockPeek: started")
    }

    private func stop() {
        lock.lock()
        guard isRunning else { lock.unlock(); return }
        isRunning = false
        suspended = false
        armed = false
        let stopRestore = pendingRestore
        inFlight = false
        pendingRestore = nil
        generation += 1
        let runLoop = tapRunLoop
        let source = runLoopSource
        let tap = eventTap
        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        lock.unlock()

        // 在途 peek 兜底还原（generation 已作废，纯还原，避免功能关闭时 Dock 一直弹出）
        if let stopRestore {
            workQueue.async {
                stopRestore()
                ZSLog("DockPeek: fallback restore on stop")
            }
        }
        if let source, let runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFRunLoopStop(runLoop)
        }
        if let tap { CFMachPortInvalidate(tap) }
        thread = nil
        ZSLog("DockPeek: stopped")
    }

    private func runTapLoop() {
        guard let runLoop = CFRunLoopGetCurrent() else { return }
        lock.lock(); tapRunLoop = runLoop; lock.unlock()
        installTap(in: runLoop)
        // 兜底：tap 创建失败（如权限授权晚了）时周期重试，授权后无需重启即生效
        installRetryTimer(in: runLoop)
        CFRunLoopRun()
    }

    private func installTap(in runLoop: CFRunLoop) {
        // listen-only：只旁观，不吞事件（修饰键/正常组合键行为均不受影响）
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        let maskValue = CGEventMask(mask)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: maskValue,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            ZSLog("DockPeek: tap create failed (no accessibility permission?)")
            return
        }
        lock.lock(); eventTap = tap; lock.unlock()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        lock.lock(); runLoopSource = source; lock.unlock()
        ZSLog("DockPeek: tap installed OK")
    }

    private func installRetryTimer(in runLoop: CFRunLoop) {
        var ctx = CFRunLoopTimerContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let timer = CFRunLoopTimerCreate(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + 2,
            2,
            0,
            0,
            Self.retryTimerCallback,
            &ctx
        )
        if let timer { CFRunLoopAddTimer(runLoop, timer, .commonModes) }
    }

    private func retryCreateTapIfNeeded() {
        lock.lock()
        let missing = eventTap == nil && isRunning
        let runLoop = tapRunLoop
        lock.unlock()
        if missing, let runLoop { installTap(in: runLoop) }
    }

    // MARK: - 事件回调（tap 线程）

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        let manager = Unmanaged<DockPeekManager>.fromOpaque(info).takeUnretainedValue()
        return manager.handle(type: type, event: event)
    }

    private static let retryTimerCallback: @convention(c) (CFRunLoopTimer?, UnsafeMutableRawPointer?) -> Void = { _, info in
        guard let info else { return }
        let manager = Unmanaged<DockPeekManager>.fromOpaque(info).takeUnretainedValue()
        manager.retryCreateTapIfNeeded()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); let tap = eventTap; lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        defer { dlog("event \(type.rawValue) flags=\(event.flags.rawValue) gen=\(currentGeneration())") }
        guard SettingsStore.shared.dockPeekEnabled else { return Unmanaged.passUnretained(event) }
        guard AccessibilityPermission.isGranted else { return Unmanaged.passUnretained(event) }
        lock.lock(); let suspendedNow = suspended; lock.unlock()
        guard !suspendedNow else { return Unmanaged.passUnretained(event) }

        switch type {
        case .flagsChanged:
            handleFlagsChanged(mods: Self.modifiers(of: event.flags))
        case .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown:
            markForeign()
        default:
            break
        }
        // listen-only：事件原样放行
        return Unmanaged.passUnretained(event)
    }

    /// flagsChanged 状态机：
    /// - flags 恰好等于录制组合 → 登记按下；
    /// - 按住期间 flags 出现组合之外的修饰键 → 标记外部使用（组合手势）；
    /// - 组合中任一修饰键抬起（flags 成为组合的真子集）→ 松开，未见过外部
    ///   事件且时长 ≤ maxPressDuration 才触发 peek。
    private func handleFlagsChanged(mods: CGEventFlags) {
        let target = Self.modifiers(of: Self.storedShortcutFlags())
        guard !target.isEmpty else { return }

        if mods == target {
            guard !armed else { return }
            armed = true
            armedTime = CFAbsoluteTimeGetCurrent()
            foreignSeen = false
            dlog("hotkey armed \(mods)")
            return
        }

        guard armed else { return }

        if mods.contains(target) {
            // 添加了组合之外的其他修饰键（如 Option 按住时再按 Shift）：
            // 在组成别的快捷键，本次按下作废
            foreignSeen = true
            dlog("extra modifier added while armed, foreign")
            return
        }

        // target 的真子集：组合中有一个修饰键被抬起 → 松开
        armed = false
        let elapsed = CFAbsoluteTimeGetCurrent() - armedTime
        guard !foreignSeen, elapsed <= Self.maxPressDuration else {
            dlog("released without trigger: foreign=\(foreignSeen) elapsed=\(elapsed)s")
            return
        }
        dlog("hotkey released, peeking dock")
        workQueue.async { [weak self] in
            self?.performPeek()
        }
    }

    private func markForeign() {
        guard armed else { return }
        armed = false
        foreignSeen = true
        dlog("other input during armed press, discarded")
    }

    private static func storedShortcutFlags() -> NSEvent.ModifierFlags {
        SettingsStore.shared.dockPeekShortcut.modifiers.intersection([.command, .shift, .option, .control])
    }

    private static func modifiers(of flags: CGEventFlags) -> CGEventFlags {
        flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
    }

    /// NSEvent.ModifierFlags → CGEventFlags
    private static func modifiers(of flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result = CGEventFlags()
        if flags.contains(.command) { result.insert(.maskCommand) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.control) { result.insert(.maskControl) }
        return result
    }

    // MARK: - peek 执行（workQueue 串行）

    private func performPeek() {
        guard SettingsStore.shared.dockPeekEnabled else { return }
        guard AccessibilityPermission.isGranted else { return }
        guard Self.readSystemAutohide() else {
            ZSLog("DockPeek: system autohide off, peek skipped")
            return
        }
        guard !CaptureCoordinator.shared.isActive else {
            dlog("capture active, peek skipped")
            return
        }

        let holdMs = min(max(SettingsStore.shared.dockPeekHoldMs, Self.minHoldMs), Self.maxHoldMs)
        guard let targets = beginManualHide() else {
            ZSLog("DockPeek: AXManualHide unavailable, peek skipped")
            return
        }

        lock.lock()
        generation += 1
        let gen = generation
        inFlight = true
        pendingRestore = { [weak self] in
            self?.restoreManualHide(targets)
        }
        lock.unlock()

        dlog("peek begin manual-hide hold=\(holdMs)ms gen=\(gen) targets=\(targets.count)")
        workQueue.asyncAfter(deadline: .now() + TimeInterval(holdMs) / 1000.0) { [weak self] in
            self?.runRestoreIfCurrent(generation: gen)
        }
    }

    /// 还原入口（驻留超时 / 功能关闭共用）：仅当 generation 仍是当前在途任务。
    private func runRestoreIfCurrent(generation gen: UInt64) {
        lock.lock()
        guard generation == gen else { lock.unlock(); return }
        inFlight = false
        let restore = pendingRestore
        pendingRestore = nil
        generation += 1
        lock.unlock()
        restore?()
        ZSLog("DockPeek: peek ended, dock hide timing left to macOS")
    }

    private func currentGeneration() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    // MARK: - AXManualHide

    /// 把 Dock 各窗口的 AXManualHide 置 false（Dock 弹出），返回 (窗口, 原值) 列表用于还原。
    /// 任一写入失败则回滚已写入的窗口并返回 nil（不做 peek）。
    private func beginManualHide() -> [(AXUIElement, Bool)]? {
        guard let windows = dockWindows(), !windows.isEmpty else {
            dlog("no dock windows")
            return nil
        }

        var targets: [(AXUIElement, Bool)] = []
        for window in windows {
            guard let original = copyManualHide(window) else { continue }
            targets.append((window, original))
        }
        guard !targets.isEmpty else {
            dlog("no dock window with AXManualHide attribute")
            dumpDockWindowAttributes(windows)
            return nil
        }

        var applied: [(AXUIElement, Bool)] = []
        for (window, original) in targets {
            let err = AXUIElementSetAttributeValue(window, Self.manualHideAttribute, kCFBooleanFalse)
            if err == .success {
                applied.append((window, original))
            } else {
                dlog("set AXManualHide=false failed \(err.rawValue), rolling back")
                restoreManualHide(applied)
                return nil
            }
        }
        return targets
    }

    /// 写回读取到的原值（而不是一律 true，避免碰掉系统本来就 manual=false 的状态）
    private func restoreManualHide(_ targets: [(AXUIElement, Bool)]) {
        for (window, original) in targets {
            let err = AXUIElementSetAttributeValue(
                window,
                Self.manualHideAttribute,
                original ? kCFBooleanTrue : kCFBooleanFalse
            )
            if err != .success {
                dlog("restore AXManualHide failed \(err.rawValue)")
            }
        }
    }

    private func copyManualHide(_ window: AXUIElement) -> Bool? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, Self.manualHideAttribute, &raw) == .success,
              let raw,
              CFGetTypeID(raw) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((raw as! CFBoolean))
    }

    private func dockWindows() -> [AXUIElement]? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return nil
        }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dockElement, kAXWindowsAttribute as CFString, &raw) == .success,
              let value = raw else { return nil }
        return value as? [AXUIElement]
    }

    /// 诊断：Dock 窗口的 AX 属性名列表（排查 AXManualHide 在新系统上的变化）
    private func dumpDockWindowAttributes(_ windows: [AXUIElement]) {
        guard debug else { return }
        for (i, window) in windows.enumerated() {
            var namesRaw: CFArray?
            guard AXUIElementCopyAttributeNames(window, &namesRaw) == .success,
                  let names = namesRaw as? [String] else { continue }
            dlog("dock window[\(i)] attributes: \(names.joined(separator: ", "))")
        }
    }

    private func dlog(_ message: @autoclosure () -> String) {
        guard debug else { return }
        ZSLog("DockPeek: \(message())")
    }
}
