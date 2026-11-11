import AppKit
import ApplicationServices
import CoreGraphics

/// 鼠标滚轮方向翻转：安装可修改的 CGEventTap，只拦截 scrollWheel，
/// 把「非连续滚动」鼠标事件的垂直/水平增量按开关分别取反；
/// 触控板 / 妙控鼠标的连续事件、手势事件与惯性事件一律原样放行。
///
/// 识别依据（见 PITFALLS_DEV.md DEV-046）：
/// - `scrollWheelEventIsContinuous == 0` 才是滚轮鼠标；触控板与妙控鼠标恒为 1；
/// - 手势阶段 / 惯性阶段非 0 的事件直接放行；
/// - `eventSourceUnixProcessID != 0` 表示由其他软件合成，不重复翻转。
///
/// 写字段顺序：先 DeltaAxis，再 FixedPtDelta / PointDelta。写 DeltaAxis 会让 macOS
/// 按 8x / 1x 内部重算后两者，必须在其后写回取反值，才能保住高精度滚轮的加速度。
final class MouseScrollReverser {
    static let shared = MouseScrollReverser()

    /// 外部通知：由 SettingsStore 的两个滚轮方向开关 didSet 触发
    static let didChangeNotification = Notification.Name("zeroflow.mouseScrollReverseDidChange")

    private let lock = NSLock()
    private var isRunning = false
    private var thread: Thread?
    private weak var tapRunLoop: CFRunLoop?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let debugLogging = ProcessInfo.processInfo.environment["ZEROFLOW_SCROLL_DEBUG"] == "1"
    private var lastDebugLog = CFAbsoluteTime(0)
    private var debugDropped = 0

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidChange(_:)),
            name: Self.didChangeNotification,
            object: nil
        )
    }

    // MARK: - 启停

    /// 按开关当前状态启停（启动时 / 开关变化时调用）。两个方向都关时彻底卸载 tap
    func reapply() {
        let store = SettingsStore.shared
        if store.reverseMouseScrollVertical || store.reverseMouseScrollHorizontal {
            start()
        } else {
            stop()
        }
    }

    @objc private func handleDidChange(_ notification: Notification) {
        reapply()
    }

    private func start() {
        lock.lock()
        guard !isRunning else { lock.unlock(); return }
        isRunning = true
        lock.unlock()

        let t = Thread { [weak self] in
            self?.runTapLoop()
        }
        t.name = "zeroflow.scroll-reverse"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    private func stop() {
        lock.lock()
        guard isRunning else { lock.unlock(); return }
        isRunning = false
        let runLoop = tapRunLoop
        let source = runLoopSource
        let tap = eventTap
        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        lock.unlock()

        if let source, let runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFRunLoopStop(runLoop)
        }
        if let tap { CFMachPortInvalidate(tap) }
        thread = nil
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
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            ZSLog("MouseScrollReverser: tap create failed (no accessibility permission?)")
            return
        }
        lock.lock(); eventTap = tap; lock.unlock()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        lock.lock(); runLoopSource = source; lock.unlock()
        ZSLog("MouseScrollReverser: tap installed OK")
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

    // MARK: - 事件回调

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        let reverser = Unmanaged<MouseScrollReverser>.fromOpaque(info).takeUnretainedValue()
        return reverser.handle(type: type, event: event)
    }

    private static let retryTimerCallback: @convention(c) (CFRunLoopTimer?, UnsafeMutableRawPointer?) -> Void = { _, info in
        guard let info else { return }
        let reverser = Unmanaged<MouseScrollReverser>.fromOpaque(info).takeUnretainedValue()
        reverser.retryCreateTapIfNeeded()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); let tap = eventTap; lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

        let store = SettingsStore.shared
        let reverseVertical = store.reverseMouseScrollVertical
        let reverseHorizontal = store.reverseMouseScrollHorizontal
        logDebugEvent(event, reverseVertical: reverseVertical, reverseHorizontal: reverseHorizontal)
        guard reverseVertical || reverseHorizontal else { return Unmanaged.passUnretained(event) }
        guard AccessibilityPermission.isGranted else { return Unmanaged.passUnretained(event) }

        // 触控板 / 妙控鼠标是连续滚动；手势与惯性阶段同理，全部原样放行
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0,
              event.getIntegerValueField(.scrollWheelEventScrollPhase) == 0,
              event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 else {
            return Unmanaged.passUnretained(event)
        }
        // 其他软件合成的滚动（pid 非 0）不重复翻转，避免与滚动工具叠成双重反转
        guard event.getIntegerValueField(.eventSourceUnixProcessID) == 0 else {
            return Unmanaged.passUnretained(event)
        }

        if reverseVertical {
            reverseAxis(event,
                        delta: .scrollWheelEventDeltaAxis1,
                        fixedPt: .scrollWheelEventFixedPtDeltaAxis1,
                        point: .scrollWheelEventPointDeltaAxis1)
        }
        if reverseHorizontal {
            reverseAxis(event,
                        delta: .scrollWheelEventDeltaAxis2,
                        fixedPt: .scrollWheelEventFixedPtDeltaAxis2,
                        point: .scrollWheelEventPointDeltaAxis2)
        }
        return Unmanaged.passUnretained(event)
    }

    /// 取反单个轴的滚动增量。顺序不能换：写 DeltaAxis 会让 macOS 重算 point/fixed，
    /// 之后再写回取反后的原值才能保住高精度滚轮的平滑与加速度。
    private func reverseAxis(_ event: CGEvent, delta: CGEventField, fixedPt: CGEventField, point: CGEventField) {
        let deltaValue = event.getIntegerValueField(delta)
        let fixedValue = event.getDoubleValueField(fixedPt)
        let pointValue = event.getIntegerValueField(point)
        guard deltaValue != 0 || fixedValue != 0 || pointValue != 0 else { return }
        if deltaValue != 0 { event.setIntegerValueField(delta, value: -deltaValue) }
        if fixedValue != 0 { event.setDoubleValueField(fixedPt, value: -fixedValue) }
        if pointValue != 0 { event.setIntegerValueField(point, value: -pointValue) }
    }

    /// 调试探针（ZEROFLOW_SCROLL_DEBUG=1）：限流打印设备判据与增量，真机核对鼠标/触控板
    private func logDebugEvent(_ event: CGEvent, reverseVertical: Bool, reverseHorizontal: Bool) {
        guard debugLogging else { return }
        debugDropped += 1
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastDebugLog >= 0.5 else { return }
        let dropped = debugDropped
        debugDropped = 0
        lastDebugLog = now
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
        let dy = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let dx = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        ZSLog("MouseScroll: continuous=\(continuous) phase=\(phase) momentum=\(momentum) pid=\(pid) dy=\(dy) dx=\(dx) revV=\(reverseVertical) revH=\(reverseHorizontal) dropped=\(dropped)")
    }
}
