import AppKit
import ApplicationServices
import CoreGraphics

/// Dock 悬停窗口预览：鼠标悬停在 Dock 应用图标（或最小化窗口瓦片）上，
/// 弹出该窗口集合的缩略图预览面板，点击卡片切换窗口、悬停卡片出关闭按钮。
///
/// 实现要点（结构仿 `DockClickMinimizer` / `CommandTabSwitcher`，Dock AX 探测为本模块
/// 独立拷贝，不与 DockClickMinimizer 共享实现，避免互相牵连回归）：
/// - CGEventTap `.listenOnly` 监听 mouseMoved + mouseDown，**绝不吞事件**，
///   Dock 原生行为（启动/聚焦/右键菜单/按住 App Exposé）与 DockClickMinimizer 零影响。
/// - move 回调内只做内存几何判定（缓存的 Dock 项 frame contains），零 AX 调用；
///   目标变化防抖（悬停延时）到期后才在后台做一次「AX 权威命中测试 + WindowList 枚举」，
///   放大/自动隐藏/缓存过期都由这次权威命中兜底。
/// - Dock 项缓存：AX 遍历 Dock 的 kAXWindows 树收集 AXApplicationDockItem；
///   app 项身份走 kAXURLAttribute（.app URL → bundleID），无 URL 项记录标题作为
///   「最小化窗口瓦片」候选（展示时按标题反查最小化窗口；堆栈/废纸篓通常匹配不到）。
/// - 窗口列表 = `WindowList.shared.enumerate()` 按 bundleID 过滤，与 ⌘⇥ 切换器**完全同源**
///   （含最小化与其他 Space 的窗口，不做特殊处理）；无窗口 app 不弹、无占位卡。
/// - 状态机：idle →(进入 Dock 边缘/命中图标)→ pending(延时) → visible；
///   visible 时鼠标移入面板保活（锚点冻结，图标缩放不跟随），移出 图标∪面板 宽限后隐藏。
/// - 全局隐藏：任意 mouseDown（放行原生行为）/ Space 切换 / 锁屏睡眠 / 目标 app 退出 /
///   Dock 重启 / 任意按键 / 屏幕配置变化。
/// - 快路径命中失败或缓存无效时，pending 定时器照常触发并走权威命中，因此缓存仅是
///   「相邻图标重定向」的优化项，不是正确性依赖。
final class DockHoverPreviewController {
    static let shared = DockHoverPreviewController()

    /// 开关变化通知：由 SettingsStore.dockPreviewEnabled 的 didSet 触发
    static let didChangeNotification = Notification.Name("zeroflow.dockPreviewDidChange")

    private static let dockBundleID = "com.apple.dock"
    private static let dockItemRole = "AXApplicationDockItem"
    /// 事件路径预筛：点距屏幕边缘该宽度内才可能落在 Dock 上
    private static let edgeMargin: CGFloat = 200
    /// 兜底命中测试时向上找 dock 项的父级深度上限
    private static let parentWalkDepth = 8
    /// visible 后移出 图标∪面板 的隐藏宽限（s）
    private static let hideGrace: TimeInterval = 0.2
    /// move 事件处理节流间隔（s）：几何判定足够快，但没必要每个 HID 事件都跑
    private static let moveThrottle: CFTimeInterval = 0.016

    private enum Phase { case idle, pending, visible }

    /// 展示目标：app 图标（该 app 的全部窗口）或最小化窗口瓦片（按标题反查）
    private enum HoverTarget {
        case app(NSRunningApplication, frameTL: CGRect)
        case tile(title: String, frameTL: CGRect)

        var frameTL: CGRect {
            switch self {
            case .app(_, let frameTL): return frameTL
            case .tile(_, let frameTL): return frameTL
            }
        }
    }

    /// Dock 项缓存条目（frame 为「主屏左上原点」全局坐标，与 CGEvent/AX 一致）
    private struct DockItem {
        let id: Int
        let frame: CGRect
        let app: NSRunningApplication?
        let title: String
    }

    // MARK: - 状态（lock 保护；tap 线程 / workQueue / 主线程共用）

    private let lock = NSLock()
    private var phase: Phase = .idle
    private var generation = 0
    /// 当前悬停候选（缓存项 id；缓存重建后可能错位，仅作优化信号）
    private var hoverItemID: Int?
    /// 已调度、尚未触发的 show 工作代数（防同一停留重复调度）
    private var pendingShowGen: Int?
    private var lastMousePoint = CGPoint.zero
    private var lastMoveProcessedAt = CFTimeInterval(0)
    /// Dock 项缓存
    private var dockItems: [DockItem] = []
    private var cacheInvalid = true
    private var pendingCacheRebuild: DispatchWorkItem?
    /// visible 时锚点与面板 frame（topLeft 坐标），用于「移出图标∪面板」判定
    private var currentItemTL: CGRect?
    private var panelFrameTL: CGRect?
    /// 点击卡片激活后的防重弹：指针仍停留在同一图标区域内时不再次弹出
    private var suppressKey: String?
    private var suppressRegionTL: CGRect?

    // 主线程专用
    private var currentTarget: HoverTarget?
    private var currentWindows: [SwitcherWindow] = []
    private var panel: DockPreviewPanel?
    private let model = DockPreviewViewModel()
    private var keyMonitor: Any?
    /// 应用生命周期内的缩略图缓存（主线程读写）：抓到过就一直用，
    /// 悬停时先显旧图再换新图，避免 WindowThumbnailer TTL(5s)/节流(0.8s)导致的空面板
    private var thumbnailCache: [CGWindowID: NSImage] = [:]
    private var lastCacheRefreshAt = Date.distantPast
    /// 面板 orderFront 状态镜像（主线程）：软隐藏后置 false，present 后置 true
    private var panelShown = false

    // MARK: - 基础设施

    private var isRunning = false
    private var thread: Thread?
    private weak var tapRunLoop: CFRunLoop?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var workspaceObservers: [NSObjectProtocol] = []
    private let workQueue = DispatchQueue(label: "zeroflow.dock-hover-preview", qos: .userInitiated)
    private let cacheQueue = DispatchQueue(label: "zeroflow.dock-hover-cache")
    private static let debug: Bool = ProcessInfo.processInfo.environment["ZEROFLOW_DOCKPREVIEW_DEBUG"] == "1"

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidChange(_:)),
            name: Self.didChangeNotification,
            object: nil
        )
        observeHideTriggers()
    }

    // MARK: - 启停

    /// 按开关当前状态启停（启动时 / 开关变化时调用）
    func reapply() {
        if SettingsStore.shared.dockPreviewEnabled {
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

        dockLayoutMayHaveChanged()
        installKeyMonitor()

        let t = Thread { [weak self] in
            self?.runTapLoop()
        }
        t.name = "zeroflow.dock-hover-preview"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
        // 启动预热：抓一次全量窗口缩略图进缓存（允许旧图），首次悬停即有图
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, SettingsStore.shared.dockPreviewEnabled else { return }
            let windows = WindowList.shared.enumerate().filter { !$0.isWindowlessApp }
            self.refreshThumbnailCacheAsync(for: windows)
        }
        ZSLog("DockHoverPreview: started")
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

        removeKeyMonitor()
        DispatchQueue.main.async { [weak self] in
            self?.panel?.orderOut(nil)
        }
        if let source, let runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFRunLoopStop(runLoop)
        }
        if let tap { CFMachPortInvalidate(tap) }
        thread = nil
        ZSLog("DockHoverPreview: stopped")
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
        // listen-only：只旁观，不吞事件（Dock 原生行为、DockClickMinimizer 均不受影响）
        let mask = CGEventMask(
            (1 << CGEventType.mouseMoved.rawValue)
                | (1 << CGEventType.leftMouseDown.rawValue)
                | (1 << CGEventType.rightMouseDown.rawValue)
                | (1 << CGEventType.otherMouseDown.rawValue)
        )
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            ZSLog("DockHoverPreview: tap create failed (no accessibility permission?)")
            return
        }
        lock.lock(); eventTap = tap; lock.unlock()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        lock.lock(); runLoopSource = source; lock.unlock()
        ZSLog("DockHoverPreview: tap installed OK")
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
        let controller = Unmanaged<DockHoverPreviewController>.fromOpaque(info).takeUnretainedValue()
        return controller.handle(type: type, event: event)
    }

    private static let retryTimerCallback: @convention(c) (CFRunLoopTimer?, UnsafeMutableRawPointer?) -> Void = { _, info in
        guard let info else { return }
        let controller = Unmanaged<DockHoverPreviewController>.fromOpaque(info).takeUnretainedValue()
        controller.retryCreateTapIfNeeded()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); let tap = eventTap; lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard SettingsStore.shared.dockPreviewEnabled else { return Unmanaged.passUnretained(event) }
        // 未授权辅助功能时静默跳过
        guard AccessibilityPermission.isGranted else { return Unmanaged.passUnretained(event) }

        switch type {
        case .mouseMoved:
            handleMouseMoved(event.location)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            handleAnyMouseDown(at: event.location)
        default:
            break
        }
        // listen-only：事件原样放行
        return Unmanaged.passUnretained(event)
    }

    // MARK: - 状态机（tap 线程决策，workQueue/主线程执行）

    private func bumpGeneration() -> Int {
        lock.lock()
        generation += 1
        let g = generation
        lock.unlock()
        return g
    }

    private func isLive(_ g: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return g == generation && phase != .idle
    }

    private func isVisible() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return phase == .visible
    }

    private func hoverDelay() -> TimeInterval {
        let ms = SettingsStore.shared.dockPreviewHoverDelayMs
        return TimeInterval(max(50, ms)) / 1000.0
    }

    private func setHoverItem(_ id: Int) {
        lock.lock()
        hoverItemID = id
        lock.unlock()
    }

    /// 缓存命中测试（纯内存几何，零 AX 调用）
    private func cachedItem(at point: CGPoint) -> (id: Int, item: DockItem)? {
        lock.lock(); defer { lock.unlock() }
        guard !cacheInvalid else { return nil }
        // 倒序遍历（后画的在绘制层级更上层）
        for item in dockItems.reversed() where item.frame.contains(point) {
            return (item.id, item)
        }
        return nil
    }

    private func handleMouseMoved(_ point: CGPoint) {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastMoveProcessedAt < Self.moveThrottle {
            lastMousePoint = point // 记录最新点，节流不影响权威命中的取点
            lock.unlock()
            return
        }
        lastMoveProcessedAt = now
        lastMousePoint = point
        let currentPhase = phase
        let hoverID = hoverItemID
        let panelFrame = panelFrameTL
        let anchorFrame = currentItemTL
        lock.unlock()

        let hit = cachedItem(at: point)

        // 离开抑制区域即解除防重弹
        lock.lock()
        if suppressKey != nil, let region = suppressRegionTL, !region.contains(point) {
            suppressKey = nil
            suppressRegionTL = nil
        }
        lock.unlock()
        switch currentPhase {
        case .idle:
            if let entry = hit {
                if entry.id != hoverID {
                    setHoverItem(entry.id)
                    scheduleShow(after: hoverDelay())
                }
                // 同一图标内移动不重置计时
            } else if isNearDockEdge(point) {
                // 缓存未命中（无效/过期/放大中）：仍在 Dock 边缘区就挂一次延时，
                // 到期后由 AX 权威命中判定真正目标
                scheduleShowIfNone(after: hoverDelay())
            }

        case .pending:
            if let entry = hit, entry.id != hoverID {
                setHoverItem(entry.id)
                scheduleShow(after: hoverDelay()) // 换图标：重置防抖
            }
            // 其余情况：定时器继续倒数，到期权威判定

        case .visible:
            if let entry = hit, entry.id != hoverID {
                setHoverItem(entry.id)
                softHidePanel() // 换目标：旧面板立刻消失，避免残留与「扫过旧面板区域取消重弹」
                scheduleShow(after: hoverDelay()) // 相邻图标：延时后原位换内容
                return
            }
            // 面板显示中：仍在 图标∪面板 内 → 保活（锚点冻结，图标缩放不跟随）
            var inside = false
            if let anchorFrame, anchorFrame.contains(point) { inside = true }
            if let panelFrame, panelFrame.contains(point) { inside = true }
            if inside {
                bumpGeneration() // 取消已调度的隐藏
            } else {
                softHidePanel() // 移出保活区：面板立刻消失，宽限期内回来会重新走弹出流程
                scheduleHideAfterGrace()
            }
        }
    }

    private func handleAnyMouseDown(at point: CGPoint) {
        lock.lock()
        let onPanel: Bool
        if let panelFrame = panelFrameTL, phase == .visible {
            onPanel = panelFrame.contains(point)
        } else {
            onPanel = false
        }
        let active = phase != .idle || pendingShowGen != nil
        lock.unlock()
        // 点击发生在自己面板上：放行（卡片点击/关闭钮需要收到这次 mouseDown），不隐藏
        if onPanel { return }
        // 其余任意 mouseDown：面板收起，事件放行（Dock 原生行为、DockClickMinimizer 不受影响）
        if active { hidePanel(reason: "mouseDown") }
    }

    // MARK: - 调度

    private func scheduleShow(after delay: TimeInterval) {
        let g = bumpGeneration()
        lock.lock()
        pendingShowGen = g
        if phase == .idle { phase = .pending }
        lock.unlock()
        workQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.pendingShowGen == g { self.pendingShowGen = nil }
            let live = g == self.generation && (self.phase == .pending || self.phase == .visible)
            self.lock.unlock()
            guard live else { return }
            self.resolveAndShow(generation: g)
        }
    }

    /// 仅当没有任何挂起的 show 时调度（防止边缘区连续移动重复触发）
    private func scheduleShowIfNone(after delay: TimeInterval) {
        lock.lock()
        let none = pendingShowGen == nil
        lock.unlock()
        guard none else { return }
        scheduleShow(after: delay)
    }

    private func scheduleHideAfterGrace() {
        let g = bumpGeneration()
        workQueue.asyncAfter(deadline: .now() + Self.hideGrace) { [weak self] in
            guard let self, self.isLive(g) else { return }
            self.hidePanel(reason: "left icon+panel region")
        }
    }

    /// 视觉上立刻收起面板（换目标/移出时），状态保持不变以便正常重弹。
    /// 同时清掉 panelFrameTL：保活区域随之收缩，指针扫过旧面板区域不再误判保活。
    private func softHidePanel() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panelShown else { return }
            self.panel?.orderOut(nil)
            self.panelShown = false
            self.lock.lock()
            self.panelFrameTL = nil
            self.lock.unlock()
        }
    }

    private func hidePanel(reason: String) {
        lock.lock()
        phase = .idle
        hoverItemID = nil
        pendingShowGen = nil
        currentItemTL = nil
        panelFrameTL = nil
        suppressKey = nil
        suppressRegionTL = nil
        generation += 1
        let g = generation
        lock.unlock()
        if Self.debug { ZSLog("DockHoverPreview: hide (\(reason)) gen=\(g)") }
        let dismiss = { [weak self] in
            guard let self else { return }
            self.panel?.orderOut(nil)
            self.panelShown = false
            let shown = self.currentWindows
            self.currentTarget = nil
            self.currentWindows = []
            self.refreshThumbnailCacheAsync(for: shown)
        }
        if Thread.isMainThread {
            dismiss()
        } else {
            DispatchQueue.main.async(execute: dismiss)
        }
    }

    /// 静默刷新一批窗口的缩略图缓存（节流 3s），只补缓存不碰面板 UI。
    /// 用于启动预热与面板收起后，保证下次悬停立即有图（允许旧图）。
    private func refreshThumbnailCacheAsync(for windows: [SwitcherWindow]) {
        guard !windows.isEmpty else { return }
        let now = Date()
        guard now.timeIntervalSince(lastCacheRefreshAt) > 3 else { return }
        lastCacheRefreshAt = now
        WindowThumbnailer.shared.fetchThumbnails(for: windows) { [weak self] images in
            guard let self else { return }
            for (windowID, image) in images {
                self.thumbnailCache[windowID] = image
            }
        }
    }
    // MARK: - 解析与展示（workQueue → 主线程）

    /// 延时到期：AX 权威命中 → 过滤窗口 → 主线程展示。
    /// 失败（不在 Dock 项上/命中右键菜单/目标无窗口）时回到 idle；面板已开则收起。
    private func resolveAndShow(generation: Int) {
        let point: CGPoint = {
            lock.lock(); defer { lock.unlock() }
            return lastMousePoint
        }()
        let target: HoverTarget
        switch resolveTarget(at: point) {
        case .resolved(let resolved):
            target = resolved
        case .failed:
            // AX 偶发失败：用缓存身份兜底（缓存无效时 cachedItem 返回 nil，不会误弹）。
            // 注意仅在 AX 完全失败时兜底：右键菜单等「正常但非 Dock 项」不走这里，
            // 否则右键菜单悬在图标上时会弹出预览。
            if let entry = cachedItem(at: point) {
                if let app = entry.item.app {
                    target = .app(app, frameTL: entry.item.frame)
                } else if !entry.item.title.isEmpty {
                    target = .tile(title: entry.item.title, frameTL: entry.item.frame)
                } else {
                    failResolve(generation: generation, reason: "no dock item at point")
                    return
                }
            } else {
                failResolve(generation: generation, reason: "no dock item at point")
                return
            }
        case .notDockElement:
            failResolve(generation: generation, reason: "point is not a dock item")
            return
        }
        // 点击卡片激活后的防重弹：同一目标且指针仍在原图标区域内 → 不弹
        lock.lock()
        var suppressed = false
        if let region = suppressRegionTL, let key = suppressKey, region.contains(point) {
            suppressed = key == self.suppressKey(for: target)
        }
        lock.unlock()
        if suppressed {
            failResolve(generation: generation, reason: "suppressed after activate")
            return
        }
        let windows = windows(for: target)
        guard !windows.isEmpty else {
            failResolve(generation: generation, reason: "target has no windows")
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.present(windows: windows, target: target, generation: generation)
        }
    }

    /// 权威命中失败/无窗口：回到 idle；面板已开着则收起
    private func failResolve(generation: Int, reason: String) {
        lock.lock()
        let wasVisible = phase == .visible
        if generation == self.generation {
            phase = .idle
            hoverItemID = nil
            currentItemTL = nil
            panelFrameTL = nil
        }
        lock.unlock()
        if wasVisible {
            hidePanel(reason: reason)
        } else if Self.debug {
            ZSLog("DockHoverPreview: resolve failed (\(reason))")
        }
    }

    /// 目标 → 窗口列表（与 ⌘⇥ 切换器同源；无窗口 app 返回空 → 不弹）
    private func windows(for target: HoverTarget) -> [SwitcherWindow] {
        let all = WindowList.shared.enumerate()
        switch target {
        case .app(let app, _):
            let bundleID = app.bundleIdentifier
            let pid = app.processIdentifier
            return all.filter { window in
                guard !window.isWindowlessApp else { return false }
                if let bundleID { return window.app.bundleIdentifier == bundleID }
                return window.pid == pid
            }
        case .tile(let title, _):
            return all.filter { !$0.isWindowlessApp && $0.isMinimized && $0.title == title }
        }
    }

    private func makeItems(_ windows: [SwitcherWindow]) -> [DockPreviewItem] {
        windows.map { window in
            var item = DockPreviewItem(id: window.id,
                                       title: window.title.isEmpty ? window.appName : window.title,
                                       appName: window.appName,
                                       appIcon: window.appIcon,
                                       thumbnail: nil)
            // 先用持久缓存里的旧图占位（抓到过就一直有），新图抓到后在 applyThumbnails 替换
            item.thumbnail = thumbnailCache[window.id]
            return item
        }
    }

    /// 主线程：更新模型并弹出/刷新面板（复用同一面板实例，换图标仅换内容不闪烁）
    private func present(windows: [SwitcherWindow], target: HoverTarget, generation: Int) {
        lock.lock()
        guard generation == self.generation, phase == .pending || phase == .visible else {
            lock.unlock()
            return
        }
        phase = .visible
        currentItemTL = target.frameTL
        hoverItemID = nil
        lock.unlock()

        currentTarget = target
        currentWindows = windows
        model.items = makeItems(windows)

        let panel = ensurePanel()
        let placement = self.placement(for: target.frameTL)
        panel.present(anchorTL: target.frameTL,
                      placement: placement,
                      model: model,
                      onSelect: { [weak self] windowID in self?.activate(windowID: windowID) },
                      onClose: { [weak self] windowID in self?.close(windowID: windowID) })
        panelShown = true
        lock.lock()
        panelFrameTL = toTopLeftCoords(panel.frame)
        lock.unlock()
        if Self.debug {
            ZSLog("DockHoverPreview: show gen=\(generation) windows=\(windows.count) anchor=\(target.frameTL) placement=\(placement)")
        }

        WindowThumbnailer.shared.fetchThumbnails(for: windows) { [weak self] images in
            self?.applyThumbnails(images, generation: generation)
        }
    }

    private func applyThumbnails(_ images: [CGWindowID: NSImage], generation: Int) {
        lock.lock()
        let live = generation == self.generation && phase == .visible
        lock.unlock()
        guard live else { return }
        // 新图先入持久缓存：即使下次抓取失败/被节流，卡片也不会变回空占位
        for (windowID, image) in images {
            thumbnailCache[windowID] = image
        }
        for (index, item) in model.items.enumerated() {
            if let image = images[item.id] {
                model.items[index].thumbnail = image
            }
        }
    }

    /// 主线程：懒创建面板
    private func ensurePanel() -> DockPreviewPanel {
        if let panel { return panel }
        let panel = DockPreviewPanel()
        self.panel = panel
        return panel
    }
    // MARK: - 卡片动作（主线程）

    private func activate(windowID: CGWindowID) {
        guard let window = currentWindows.first(where: { $0.id == windowID }) else { return }
        let anchor = currentTarget?.frameTL
        let key = currentTarget.map { self.suppressKey(for: $0) }
        hidePanel(reason: "activate")
        if let anchor, let key {
            lock.lock()
            suppressKey = key
            suppressRegionTL = anchor
            lock.unlock()
        }
        // 复用切换器激活链：最小化先还原、跨 Space 自动切换、本 app 窗口走主线程
        WindowActivator.shared.focus(window: window)
    }

    private func suppressKey(for target: HoverTarget) -> String {
        switch target {
        case .app(let app, _):
            return "app:\(app.bundleIdentifier ?? "pid:\(app.processIdentifier)")"
        case .tile(let title, _):
            return "tile:\(title)"
        }
    }

    private func close(windowID: CGWindowID) {
        guard let window = currentWindows.first(where: { $0.id == windowID }) else { return }
        lock.lock()
        let gen = generation
        lock.unlock()
        WindowOps.perform(.close, on: window) { [weak self] in
            self?.refreshAfterClose(generation: gen)
        }
    }

    /// 关闭后刷新：重新枚举目标窗口；最后一个窗口被关掉时整个面板撤掉
    private func refreshAfterClose(generation: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.phase == .visible, let target = self.currentTarget, generation == self.generation else {
                self.lock.unlock()
                return
            }
            self.lock.unlock()
            self.workQueue.async { [weak self] in
                let windows = self?.windows(for: target) ?? []
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let alive = generation == self.generation && self.phase == .visible
                    self.lock.unlock()
                    guard alive else { return }
                    if windows.isEmpty {
                        self.hidePanel(reason: "last window closed")
                    } else {
                        self.currentWindows = windows
                        self.model.items = self.makeItems(windows)
                        WindowThumbnailer.shared.fetchThumbnails(for: windows) { [weak self] images in
                            self?.applyThumbnails(images, generation: generation)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 面板定位

    /// 依据 Dock 项缓存的分布与图标在屏上的位置判定面板朝向
    private func placement(for anchorTL: CGRect) -> DockPreviewPanel.Placement {
        let unionMaxY = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }.maxY
        let cocoa = CGRect(x: anchorTL.minX, y: unionMaxY - anchorTL.maxY,
                           width: anchorTL.width, height: anchorTL.height)
        let center = CGPoint(x: cocoa.midX, y: cocoa.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
                ?? NSScreen.screens.first(where: { $0.frame.intersects(cocoa) }) else {
            return .above
        }
        lock.lock()
        let items = dockItems
        lock.unlock()
        if items.count >= 2 {
            // 多项：图标整体沿横轴排布 → 底部 Dock（面板在上方）；沿纵轴 → 左右 Dock
            var bbox = CGRect.null
            for item in items { bbox = bbox.union(item.frame) }
            if bbox.width >= bbox.height { return .above }
            return cocoa.midX < screen.frame.midX ? .rightOf : .leftOf
        }
        // 单项兜底：取图标中心到各屏幕边的最近边
        let frame = toTopLeftCoords(screen.frame)
        let dBottom = frame.maxY - anchorTL.maxY
        let dLeft = anchorTL.minX - frame.minX
        let dRight = frame.maxX - anchorTL.maxX
        let nearest = min(dBottom, dLeft, dRight)
        if nearest == dLeft { return .rightOf }
        if nearest == dRight { return .leftOf }
        return .above
    }

    // MARK: - 键盘与全局隐藏触发

    /// visible 时任意按键（含 Esc）收起面板；事件不吞，不影响其他响应
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let self, self.isVisible() {
                self.hidePanel(reason: "keyDown \(event.keyCode)")
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// 全局隐藏触发：Space 切换 / 锁屏睡眠 / 目标 app 或 Dock 退出 / 屏幕配置变化
    private func observeHideTriggers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.hidePanel(reason: "space changed")
                self?.dockLayoutMayHaveChanged()
            },
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.hidePanel(reason: "sleep")
            },
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.hidePanel(reason: "screens sleep")
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                if app.bundleIdentifier == Self.dockBundleID {
                    self?.dockLayoutMayHaveChanged()
                }
                self?.hideIfTarget(app: app)
            },
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                self?.dockLayoutMayHaveChanged()
            },
        ]
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.hidePanel(reason: "screen config changed")
            self?.dockLayoutMayHaveChanged()
        }
    }

    /// 目标 app 退出时收起（tile 目标不跟踪 app 退出）
    private func hideIfTarget(app: NSRunningApplication) {
        guard let target = currentTarget else { return }
        switch target {
        case .app(let targetApp, _):
            if targetApp.processIdentifier == app.processIdentifier {
                hidePanel(reason: "target app quit")
            }
        case .tile:
            break
        }
    }

    // MARK: - Dock 项缓存（独立拷贝自 DockClickMinimizer 的探测逻辑，另含瓦片标题）

    /// Dock 布局变化（图标增删、切 Space、Dock 重启）时置缓存失效并防抖重建
    private func dockLayoutMayHaveChanged() {
        lock.lock()
        cacheInvalid = true
        lock.unlock()
        scheduleCacheRebuild()
    }

    /// trailing-edge 防抖：布局事件爆发时合并为一次重建
    private func scheduleCacheRebuild() {
        let work = DispatchWorkItem { [weak self] in
            self?.rebuildDockCache()
        }
        lock.lock()
        pendingCacheRebuild?.cancel()
        pendingCacheRebuild = work
        lock.unlock()
        cacheQueue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func rebuildDockCache() {
        lock.lock()
        let enabled = SettingsStore.shared.dockPreviewEnabled && isRunning
        lock.unlock()
        guard enabled else { return }

        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleID).first else { return }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        guard let windows = copyAXElements(dockElement, kAXWindowsAttribute) else { return }

        var nextID = 0
        var items: [DockItem] = []
        for window in windows {
            collectDockItems(in: window, into: &items, nextID: &nextID)
        }
        lock.lock()
        dockItems = items
        cacheInvalid = false
        lock.unlock()
        if Self.debug { ZSLog("DockHoverPreview: cache rebuilt, items=\(items.count)") }
    }

    private func collectDockItems(in element: AXUIElement, into items: inout [DockItem], nextID: inout Int) {
        if isDockItemElement(element),
           let point = axPoint(element, kAXPositionAttribute),
           let size = axSize(element, kAXSizeAttribute) {
            let app = appForDockItem(element)
            let title = copyAXValue(element, kAXTitleAttribute, as: CFString.self) as String? ?? ""
            items.append(DockItem(id: nextID, frame: CGRect(origin: point, size: size), app: app, title: title))
            nextID += 1
        }
        if let children = copyAXElements(element, kAXChildrenAttribute) {
            for child in children {
                collectDockItems(in: child, into: &items, nextID: &nextID)
            }
        }
    }

    // MARK: - AX 权威命中（独立拷贝自 DockClickMinimizer，扩展瓦片识别）

    /// 解析结果三态：notDockElement 表示 AX 正常但该点不是可识别 Dock 项（右键菜单/分隔符等），
    /// 不可用缓存兜底；failed 表示 AX 调用本身偶发失败，可用缓存身份兜底。
    private enum ResolveOutcome {
        case resolved(HoverTarget)
        case notDockElement
        case failed
    }

    /// 问系统「该点上是什么元素」，向上找最近的 Dock 项；app 项与无 URL 项（瓦片候选）都返回
    private func resolveTarget(at point: CGPoint) -> ResolveOutcome {
        let systemWide = AXUIElementCreateSystemWide()
        var raw: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &raw) == .success,
              let raw else { return .failed }
        var element = raw
        for _ in 0..<Self.parentWalkDepth {
            if isDockItemElement(element) {
                guard let pos = axPoint(element, kAXPositionAttribute),
                      let size = axSize(element, kAXSizeAttribute) else { return .failed }
                let frame = CGRect(origin: pos, size: size)
                if let app = appForDockItem(element) {
                    return .resolved(.app(app, frameTL: frame))
                }
                // 无 URL 项：最小化窗口瓦片候选（堆栈/废纸篓标题通常反查不到窗口，自然不弹）
                let title = copyAXValue(element, kAXTitleAttribute, as: CFString.self) as String? ?? ""
                guard !title.isEmpty else { return .notDockElement }
                return .resolved(.tile(title: title, frameTL: frame))
            }
            // 命中 Dock 右键菜单/菜单项：不视为图标悬停
            if isMenuElement(element) { return .notDockElement }
            guard let parent = axParent(element) else { break }
            element = parent
        }
        return .notDockElement
    }

    /// 菜单类元素：Dock 图标右键弹出的菜单/菜单项
    private func isMenuElement(_ element: AXUIElement) -> Bool {
        let role = copyAXValue(element, kAXRoleAttribute, as: CFString.self) as String?
        let subrole = copyAXValue(element, kAXSubroleAttribute, as: CFString.self) as String?
        switch role ?? subrole {
        case kAXMenuRole, kAXMenuItemRole, kAXMenuBarRole, kAXMenuBarItemRole:
            return true
        default:
            return false
        }
    }

    private func isDockItemElement(_ element: AXUIElement) -> Bool {
        if let role = copyAXValue(element, kAXRoleAttribute, as: CFString.self) as String?,
           role == Self.dockItemRole {
            return true
        }
        if let subrole = copyAXValue(element, kAXSubroleAttribute, as: CFString.self) as String?,
           subrole == Self.dockItemRole {
            return true
        }
        return false
    }

    private func axParent(_ element: AXUIElement) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &raw) == .success,
              let raw else { return nil }
        // AX 元素的父元素恒为 AXUIElement，强制桥接
        let parent: AXUIElement = raw as! AXUIElement
        return parent
    }

    /// Dock 项 → 对应运行中的应用。优先 kAXURL（.app file URL → bundleID），
    /// 无 URL 的项（Launchpad/Trash/窗口图标等）按标题兜底匹配。
    private func appForDockItem(_ element: AXUIElement) -> NSRunningApplication? {
        if let urlRaw = copyAXValue(element, kAXURLAttribute, as: NSURL.self),
           let bundle = Bundle(url: urlRaw as URL),
           let bundleID = bundle.bundleIdentifier,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app
        }
        if let title = copyAXValue(element, kAXTitleAttribute, as: CFString.self) as String? {
            return runningApp(named: title)
        }
        return nil
    }

    private func runningApp(named title: String) -> NSRunningApplication? {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return NSWorkspace.shared.runningApplications.first { app in
            let displayName = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let executableName = app.executableURL?.deletingPathExtension().lastPathComponent.lowercased()
            return displayName == normalized || executableName == normalized
        }
    }

    // MARK: - 坐标（CGEvent/AX/CGWindow 均为「主屏左上原点」的点坐标）

    private func topLeftFrame(of screen: NSScreen) -> CGRect {
        toTopLeftCoords(screen.frame)
    }

    /// Cocoa 矩形（左下原点）→ 左上原点全局坐标
    private func toTopLeftCoords(_ rect: CGRect) -> CGRect {
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        return CGRect(
            x: rect.minX,
            y: union.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func isNearDockEdge(_ point: CGPoint) -> Bool {
        for frame in NSScreen.screens.map({ topLeftFrame(of: $0) }) where frame.contains(point) {
            if point.x < frame.minX + Self.edgeMargin || point.x > frame.maxX - Self.edgeMargin { return true }
            if point.y < frame.minY + Self.edgeMargin || point.y > frame.maxY - Self.edgeMargin { return true }
            return false
        }
        return false
    }

    // MARK: - AX 辅助（与 DockClickMinimizer 同款）

    private func copyAXValue<T>(_ element: AXUIElement, _ attribute: String, as _: T.Type) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw else { return nil }
        return value as? T
    }

    private func copyAXElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw else { return nil }
        return value as? [AXUIElement]
    }

    private func axPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copyAXValue(element, attribute, as: AXValue.self) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private func axSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copyAXValue(element, attribute, as: AXValue.self) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }
}
