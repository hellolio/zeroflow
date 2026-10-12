import SwiftUI
import AppKit
import EventKit
import CoreImage
import ScreenCaptureKit

/// 灵动岛面板的一条日程（主线程由 EKEvent 转换生成）
struct NotchEventItem: Identifiable {
    let id: String
    let title: String
    let timeText: String
    let color: NSColor
}

/// 月视图日历的视图模型（仅主线程读写）。面板每次弹出 reset() 回到今天。
/// 数据加载走后台查询，代数（monthGen/dayGen）作废在途结果，面板关开/快速翻月不串数据。
final class NotchCalendarViewModel: ObservableObject {
    @Published private(set) var monthAnchor: Date = Date()
    @Published private(set) var selectedDate: Date = Date()
    /// 显示月份中有日程的日期（本地时区当日零点）
    @Published private(set) var monthEventDays: Set<Date> = []
    @Published private(set) var dayEvents: [NotchEventItem] = []
    @Published private(set) var authStatus: EKAuthorizationStatus = CalendarService.shared.status

    private var monthGen = 0
    private var dayGen = 0

    /// 日历与本地化随设置语言变化（跟随系统/zh/en/ja）
    var calendar: Calendar { SettingsStore.shared.appLanguage.locale.calendar }

    var isAuthorized: Bool { authStatus == .fullAccess }

    // MARK: - 状态迁移

    func reset() {
        let now = Date()
        monthAnchor = startOfMonth(now)
        selectedDate = calendar.startOfDay(for: now)
        refreshAuth()
        if authStatus == .notDetermined {
            CalendarService.shared.requestAccess { [weak self] _ in
                guard let self else { return }
                self.refreshAuth()
                self.reloadMonth()
                self.reloadDay()
            }
        }
        reloadMonth()
        reloadDay()
    }

    func refreshAuth() {
        let status = CalendarService.shared.status
        if status != authStatus {
            authStatus = status
        }
    }

    /// 翻月；选中日跟随到新月份同日（超出天数钳到月末）
    func moveMonth(_ delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: monthAnchor),
              let range = calendar.range(of: .day, in: .month, for: next) else { return }
        monthAnchor = startOfMonth(next)
        var comps = calendar.dateComponents([.year, .month], from: next)
        comps.day = min(calendar.component(.day, from: selectedDate), range.count)
        if let moved = calendar.date(from: comps) {
            selectedDate = calendar.startOfDay(for: moved)
        }
        reloadMonth()
        reloadDay()
    }

    func select(_ day: Date) {
        let dayStart = calendar.startOfDay(for: day)
        guard dayStart != selectedDate else { return }
        selectedDate = dayStart
        reloadDay()
    }

    // MARK: - 数据加载

    private func reloadMonth() {
        monthGen += 1
        let gen = monthGen
        guard let interval = calendar.dateInterval(of: .month, for: monthAnchor) else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let events = CalendarService.shared.events(from: interval.start, to: interval.end)
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.monthGen else { return }
                var days = Set<Date>()
                for event in events {
                    // 跨天日程在区间内的每一天都打点（EventKit 结束时间为独占的次日零点）
                    let from = max(event.startDate, interval.start)
                    let to = min(event.endDate, interval.end)
                    var day = self.calendar.startOfDay(for: from)
                    while day < to {
                        days.insert(day)
                        guard let next = self.calendar.date(byAdding: .day, value: 1, to: day) else { break }
                        day = next
                    }
                }
                self.monthEventDays = days
            }
        }
    }

    private func reloadDay() {
        dayGen += 1
        let gen = dayGen
        let dayStart = selectedDate
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let events = CalendarService.shared.events(from: dayStart, to: dayEnd)
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.dayGen else { return }
                self.dayEvents = events
                    .sorted { lhs, rhs in
                        if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                        if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
                        return lhs.title < rhs.title
                    }
                    .map { self.makeItem($0) }
            }
        }
    }

    private func makeItem(_ event: EKEvent) -> NotchEventItem {
        // macOS 上 EKCalendar.color 即 NSColor（iOS 才是 CGColor）
        let color = event.calendar?.color ?? .controlAccentColor
        let timeText: String
        if event.isAllDay {
            timeText = L10n.tr("全天")
        } else {
            // EventKit 的 endDate 为独占（次日零点），回退 1s 取真实末日
            let lastDay = event.endDate.addingTimeInterval(-1)
            if calendar.isDate(event.startDate, inSameDayAs: lastDay) {
                let end = lastDay
                if calendar.compare(event.startDate, to: end, toGranularity: .minute) == .orderedSame {
                    timeText = Self.timeFormatter.string(from: event.startDate)
                } else {
                    timeText = "\(Self.timeFormatter.string(from: event.startDate)) – \(Self.timeFormatter.string(from: end))"
                }
            } else {
                timeText = "\(Self.dayFormatter.string(from: event.startDate)) – \(Self.dayFormatter.string(from: lastDay))"
            }
        }
        let title = (event.title?.isEmpty == false) ? event.title! : L10n.tr("无标题日程")
        return NotchEventItem(
            id: "\(event.calendarItemIdentifier)-\(event.startDate.timeIntervalSince1970)",
            title: title,
            timeText: timeText,
            color: color
        )
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter
    }()

    // MARK: - 月网格

    func startOfMonth(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    /// 月网格单元格：按周首日补前置空位 + 当月日期，末尾补齐到 6 行（面板高度稳定不跳）
    func monthCells() -> [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: monthAnchor) else { return [] }
        let leading = (calendar.component(.weekday, from: interval.start) - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        var day = interval.start
        while day < interval.end {
            cells.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        while cells.count < 42 { cells.append(nil) }
        return cells
    }

    /// 按周首日重排的极短星期符号
    var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    var monthTitle: String {
        titleFormatter(template: "yMMMM").string(from: monthAnchor)
    }

    var selectedTitle: String {
        titleFormatter(template: "MMMd EEEE").string(from: selectedDate)
    }

    private func titleFormatter(template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = SettingsStore.shared.appLanguage.locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    func dayNumber(_ date: Date) -> Int {
        calendar.component(.day, from: date)
    }

    func isToday(_ date: Date) -> Bool {
        calendar.isDateInToday(date)
    }

    func isSelected(_ date: Date) -> Bool {
        date == selectedDate
    }

    func hasEvents(_ date: Date) -> Bool {
        monthEventDays.contains(date)
    }
}

/// 磨砂背景（HUD 材质；面板固定深色外观 → 灵动岛同款深色磨砂圆角）
private struct VisualEffectBackground: NSViewRepresentable {
    /// 不透明度 0...1（数值越小越透明）
    let opacity: Double

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 16
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.alphaValue = opacity
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.alphaValue = opacity
    }
}

/// 灵动岛面板内容：日历列（月历 + 当日日程）贴左，预留右侧空白区；
/// 无内容模块时显示「添加显示内容」引导。宽度 = 面板宽，日历列固定原尺寸不随宽度拉伸。
struct NotchContentView: View {
    @ObservedObject var model: NotchCalendarViewModel
    /// 模糊背景（面板背后的屏幕快照 + 高斯模糊）；nil = 未就绪，仅显示磨砂底
    var backdrop: NSImage?

    private let accent = Color.accentColor
    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    /// 日历列宽度（面板加宽前的内容宽，保持原比例）
    private static let calendarColumnWidth: CGFloat = 332

    var body: some View {
        // 单模块居中；后续多模块在 HStack 内并排、整体居中
        HStack(alignment: .top, spacing: 16) {
            if SettingsStore.shared.notchShowCalendar {
                calendarColumn
            } else {
                emptyState
            }
        }
        .padding(.vertical, 14)
        .frame(width: NotchPanel.preferredWidth, alignment: .center)
        .background(backgroundLayer)
    }

    /// 磨砂底（实时透视，不透明度设置）+ 高斯模糊快照叠加层（模糊强度设置）
    private var backgroundLayer: some View {
        ZStack {
            VisualEffectBackground(opacity: Double(SettingsStore.shared.notchPanelOpacity) / 100)
            if let backdrop {
                ZStack {
                    Image(nsImage: backdrop)
                        .resizable()
                        .interpolation(.medium)
                    Color.black.opacity(0.2)
                }
                .opacity(Double(SettingsStore.shared.notchBlurStrength) / 100)
            }
        }
    }

    private var calendarColumn: some View {
        VStack(spacing: 10) {
            header
            weekdayRow
            monthGrid
            Divider()
            daySection
        }
        .frame(width: Self.calendarColumnWidth)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text(L10n.tr("暂无显示内容"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Button(L10n.tr("添加显示内容")) {
                SettingsView.pendingTab = .notch
                NotificationCenter.default.post(name: .zeroflowOpenNotchSettings, object: nil)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 16)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(L10n.tr("今天")) {
                model.reset()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundColor(.secondary)

            Spacer()
            Text(model.monthTitle)
                .font(.system(size: 14, weight: .semibold))
            Spacer()

            HStack(spacing: 4) {
                monthNavButton("chevron.left") { model.moveMonth(-1) }
                monthNavButton("chevron.right") { model.moveMonth(1) }
            }
        }
    }

    private func monthNavButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(model.weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var monthGrid: some View {
        LazyVGrid(columns: Self.columns, spacing: 4) {
            ForEach(Array(model.monthCells().enumerated()), id: \.offset) { _, cell in
                if let date = cell {
                    dayCell(date)
                } else {
                    Color.clear.frame(height: 30)
                }
            }
        }
    }

    private func dayCell(_ date: Date) -> some View {
        let selected = model.isSelected(date)
        let today = model.isToday(date)
        return VStack(spacing: 2) {
            Text("\(model.dayNumber(date))")
                .font(.system(size: 12, weight: selected || today ? .semibold : .regular))
                .foregroundColor(selected ? .white : (today ? accent : .primary))
            Circle()
                .fill(selected ? Color.white.opacity(0.9) : accent)
                .frame(width: 3, height: 3)
                .opacity(model.hasEvents(date) ? 1 : 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background {
            if selected {
                Circle()
                    .fill(accent)
                    .frame(width: 26, height: 26)
            } else if today {
                Circle()
                    .strokeBorder(accent.opacity(0.7), lineWidth: 1)
                    .frame(width: 26, height: 26)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.select(date)
        }
    }

    @ViewBuilder private var daySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.selectedTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            if !model.isAuthorized && model.authStatus != .notDetermined {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("未获准访问日历，无法显示日程。"))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Button(L10n.tr("前往设置")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.privacy?Privacy_Calendars") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            } else if model.dayEvents.isEmpty {
                Text(L10n.tr("没有日程"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.dayEvents) { item in
                            HStack(alignment: .top, spacing: 8) {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(Color(nsColor: item.color))
                                    .frame(width: 3, height: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(2)
                                    Text(item.timeText)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(maxHeight: 240)
            }
        }
    }
}

/// 灵动岛面板：非激活 borderless 面板，深色 HUD 磨砂，从刘海正下方滑入。
/// 悬停/点击/Esc 判定全部由 NotchHotspotController 的 listen-only tap 完成，
/// 本面板只负责内容展示（不成为 key，无键盘交互）。
final class NotchPanel: NSPanel {
    static let preferredWidth: CGFloat = 560

    /// 异步模糊背景的代数：面板重开/隐藏后作废在途快照
    private var captureGen = 0

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.preferredWidth, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.isReleasedWhenClosed = false
        self.animationBehavior = .none
        self.hidesOnDeactivate = false
        // 固定深色外观：HUD 磨砂 + 白字（灵动岛风格，不随系统深浅模式变化）
        self.appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 依据刘海热区（主屏左上原点坐标）重建内容、测尺寸、定位并滑入显示。
    /// 面板顶边贴刘海下边缘（热区竖向范围 = 刘海竖向范围）、水平居中刘海；
    /// 每次 present 重建 contentView（模型重置到今天，同时取最新透明度/内容设置）。
    func present(hotspotTL: CGRect, screen: NSScreen, model: NotchCalendarViewModel) {
        contentView = NSHostingView(rootView: NotchContentView(model: model))
        contentView?.layoutSubtreeIfNeeded()
        var size = contentView?.fittingSize ?? frame.size
        size = NSSize(width: Self.preferredWidth,
                      height: max(120, min(ceil(size.height), screen.frame.height - 80)))
        setContentSize(size)

        let x = Self.clamp(hotspotTL.midX - size.width / 2,
                           screen.frame.minX + 8, screen.frame.maxX - size.width - 8)
        // 热区 TL 坐标最大 y = 刘海下边缘；转回 Cocoa 坐标作为面板顶边
        let unionMaxY = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }.maxY
        let finalOrigin = NSPoint(x: x, y: unionMaxY - hotspotTL.maxY - size.height)
        // 从刘海后方 12pt 处滑入；NSWindow 只有 frame 可动画（animator().setFrameOrigin 无效，
        // 面板会停在起始位置），必须用 animator().setFrame(_:display:)
        let startFrame = NSRect(origin: NSPoint(x: finalOrigin.x, y: finalOrigin.y + 12), size: size)
        let finalFrame = NSRect(origin: finalOrigin, size: size)
        setFrame(startFrame, display: false)
        alphaValue = 0
        orderFront(nil)
        invalidateShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(finalFrame, display: true)
            animator().alphaValue = 1
        }

        // 异步叠加高斯模糊快照背景（需屏幕录制权限；未授权/强度 0 时保持磨砂底）
        captureGen += 1
        let gen = captureGen
        let strength = SettingsStore.shared.notchBlurStrength
        if strength > 0, ScreenRecordingPermission.isGranted {
            // ScreenCapture.crop 接受「该屏内部左下原点」矩形
            let rect = CGRect(x: finalFrame.origin.x - screen.frame.origin.x,
                              y: finalFrame.origin.y - screen.frame.origin.y,
                              width: finalFrame.width, height: finalFrame.height)
            let windowNumber = self.windowNumber
            Task { [weak self] in
                guard let captured = await Self.captureBackdrop(screen: screen, rect: rect, windowNumber: windowNumber),
                      let cgImage = captured.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                let pixelScale = Double(cgImage.width) / Double(finalFrame.width)
                guard let blurred = Self.gaussianBlur(cgImage,
                                                      radiusPixels: Double(strength) * 0.5 * pixelScale) else { return }
                let image = NSImage(cgImage: blurred,
                                    size: NSSize(width: finalFrame.width, height: finalFrame.height))
                DispatchQueue.main.async {
                    guard let self, self.captureGen == gen, self.isVisible else { return }
                    self.contentView = NSHostingView(rootView: NotchContentView(model: model, backdrop: image))
                    self.invalidateShadow()
                }
            }
        }
    }

    private static var scContentCache: SCShareableContent?
    private static var scContentCacheDate = Date.distantPast

    /// 抓取面板背后的屏幕区域（整屏捕获后裁剪）；filter 排除面板自身窗口，避免自拍
    private static func captureBackdrop(screen: NSScreen, rect: CGRect, windowNumber: Int) async -> NSImage? {
        do {
            guard let (scDisplay, scWindow) = await scDisplayAndSelfWindow(screen: screen, windowNumber: windowNumber) else { return nil }
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [scWindow])
            let config = SCStreamConfiguration()
            let pixelScale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * pixelScale)
            config.height = Int(filter.contentRect.height * pixelScale)
            config.showsCursor = false
            config.captureResolution = .best
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return ScreenCapture.crop(DisplayCapture(cgImage: cgImage, pixelScale: pixelScale), on: screen, rect: rect)
        } catch {
            ZSLog("notch backdrop capture error: \(error)")
            return nil
        }
    }

    /// SCShareableContent 缓存（TTL 30s）；找不到自身窗口时返回 nil——宁可不叠加也不把面板拍进背景
    private static func scDisplayAndSelfWindow(screen: NSScreen, windowNumber: Int) async -> (SCDisplay, SCWindow)? {
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        var content = scContentCache
        if content == nil || -scContentCacheDate.timeIntervalSinceNow > 30
                || !(content!.displays.contains(where: { $0.displayID == displayID })) {
            guard let fresh = try? await SCShareableContent.current else { return nil }
            scContentCache = fresh
            scContentCacheDate = Date()
            content = fresh
        }
        guard let content,
              let scDisplay = content.displays.first(where: { $0.displayID == displayID }),
              let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(windowNumber) }) else { return nil }
        return (scDisplay, scWindow)
    }

    /// 高斯模糊（输入先 clamp 到无限延展，避免边缘透明晕边）；radiusPixels 相对输入像素
    private static func gaussianBlur(_ image: CGImage, radiusPixels: Double) -> CGImage? {
        guard radiusPixels >= 0.5 else { return image }
        let input = CIImage(cgImage: image).clampedToExtent()
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(radiusPixels, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return nil }
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        return ciContext.createCGImage(output, from: extent, format: .RGBA8,
                                       colorSpace: image.colorSpace ?? CGColorSpaceCreateDeviceRGB())
    }

    private static let ciContext = CIContext()

    private static func clamp(_ value: CGFloat, _ minValue: CGFloat, _ maxValue: CGFloat) -> CGFloat {
        guard maxValue >= minValue else { return minValue }
        return min(max(value, minValue), maxValue)
    }
}
