import SwiftUI
import AppKit
import EventKit

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

/// 灵动岛面板内容：已启用的内容模块横排（日历 / 系统资源 / 正在播放，最多同时 2 个），
/// 无模块时显示「添加显示内容」引导。各列宽度固定，面板宽度按内容自适应。
struct NotchContentView: View {
    @ObservedObject var model: NotchCalendarViewModel
    /// 显示宽度：nil = 测量模式（自然内容宽）；正式展示由 NotchPanel 传入面板宽并整体居中
    var displayWidth: CGFloat? = nil

    @ObservedObject private var resources = SystemResourceMonitor.shared
    @ObservedObject private var music = NowPlayingMonitor.shared

    private let accent = Color.accentColor
    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    /// 日历列宽度（面板加宽前的内容宽，保持原比例）
    private static let calendarColumnWidth: CGFloat = 332
    /// 系统资源列宽
    private static let resourcesColumnWidth: CGFloat = 224
    /// 正在播放列宽
    private static let musicColumnWidth: CGFloat = 224

    /// 内容模块（固定顺序，最多同时显示 2 个；超出部分在设置页禁用开关）
    private enum Module: CaseIterable {
        case calendar
        case resources
        case music
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(visibleModules, id: \.self) { module in
                moduleView(module)
            }
        }
        .padding(.vertical, 14)
        .frame(width: displayWidth, alignment: .center)
    }

    private var visibleModules: [Module] {
        var enabled: [Module] = []
        if SettingsStore.shared.notchShowCalendar { enabled.append(.calendar) }
        if SettingsStore.shared.notchShowResources { enabled.append(.resources) }
        if SettingsStore.shared.notchShowMusic { enabled.append(.music) }
        return Array(enabled.prefix(2))
    }

    @ViewBuilder private func moduleView(_ module: Module) -> some View {
        switch module {
        case .calendar: calendarColumn
        case .resources: resourcesColumn
        case .music: musicColumn
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

    // MARK: - 系统资源模块

    private var resourcesColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            moduleHeader("cpu", L10n.tr("系统资源"))
            ForEach(enabledResourceItems, id: \.self) { item in
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer(minLength: 8)
                    Text(resourceValue(item))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .frame(width: Self.resourcesColumnWidth, alignment: .leading)
    }

    private var enabledResourceItems: [NotchResourceItem] {
        SettingsStore.shared.notchResourceItems.compactMap { NotchResourceItem(rawValue: $0) }
    }

    private func resourceValue(_ item: NotchResourceItem) -> String {
        let s = resources.sample
        switch item {
        case .cpu:
            return s.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—"
        case .memory:
            guard let used = s.memUsedBytes else { return "—" }
            guard let total = s.memTotalBytes else { return SystemResourceMonitor.formatBytes(used) }
            return "\(SystemResourceMonitor.formatBytes(used)) / \(SystemResourceMonitor.formatBytes(total))"
        case .disk:
            let text = "\(L10n.tr("读")) \(SystemResourceMonitor.formatBps(s.diskReadBps)) · \(L10n.tr("写")) \(SystemResourceMonitor.formatBps(s.diskWriteBps))"
            return (s.diskReadBps == nil && s.diskWriteBps == nil) ? "—" : text
        case .network:
            let text = "↓ \(SystemResourceMonitor.formatBps(s.netDownBps)) · ↑ \(SystemResourceMonitor.formatBps(s.netUpBps))"
            return (s.netDownBps == nil && s.netUpBps == nil) ? "—" : text
        case .gpu:
            return s.gpuPercent.map { String(format: "%.0f%%", $0) } ?? "—"
        }
    }

    // MARK: - 正在播放模块

    private var musicColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            moduleHeader("music.note", L10n.tr("正在播放"))
            if let info = music.nowPlaying {
                musicBody(info)
            } else {
                Text(L10n.tr("没有正在播放的音乐"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }
        }
        .frame(width: Self.musicColumnWidth, alignment: .leading)
    }

    private func musicBody(_ info: NowPlayingInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                appIcon(info)
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.appName ?? L10n.tr("未知应用"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(info.isPlaying ? Color.green : Color.secondary.opacity(0.5))
                            .frame(width: 5, height: 5)
                        Text(info.isPlaying ? L10n.tr("正在播放") : L10n.tr("已暂停"))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Text(info.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)

            musicSubtitle(info)

            if let progress = musicProgress(info) {
                VStack(alignment: .leading, spacing: 3) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.15))
                            Capsule().fill(Color.accentColor)
                                .frame(width: max(2, proxy.size.width * progress))
                        }
                    }
                    .frame(height: 3)
                    HStack {
                        Text(Self.timeText(info.elapsed ?? 0))
                        Spacer()
                        Text(Self.timeText(info.duration ?? 0))
                    }
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 18) {
                musicButton("backward.fill", L10n.tr("上一首"), disabled: !music.controlsAvailable) {
                    NowPlayingMonitor.shared.send(.previous)
                }
                musicButton(info.isPlaying ? "pause.fill" : "play.fill",
                            info.isPlaying ? L10n.tr("暂停") : L10n.tr("播放"),
                            disabled: !music.controlsAvailable) {
                    NowPlayingMonitor.shared.send(.togglePlay)
                }
                musicButton("forward.fill", L10n.tr("下一首"), disabled: !music.controlsAvailable) {
                    NowPlayingMonitor.shared.send(.next)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func musicSubtitle(_ info: NowPlayingInfo) -> some View {
        let parts = [info.artist, info.album].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    private func musicProgress(_ info: NowPlayingInfo) -> Double? {
        guard let duration = info.duration, duration > 0, let elapsed = info.elapsed else { return nil }
        return min(1, max(0, elapsed / duration))
    }

    private static func timeText(_ t: Double) -> String {
        let total = Int(max(0, t))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func appIcon(_ info: NowPlayingInfo) -> some View {
        Group {
            if let bid = info.appBundleID, let icon = Self.icon(forBundleID: bid) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 22, height: 22)
    }

    private static let iconCache = NSCache<NSString, NSImage>()

    private static func icon(forBundleID bid: String) -> NSImage? {
        if let cached = iconCache.object(forKey: bid as NSString) { return cached }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }),
              let icon = app.icon else { return nil }
        iconCache.setObject(icon, forKey: bid as NSString)
        return icon
    }

    private func musicButton(_ symbol: String, _ label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(disabled ? Color.secondary.opacity(0.4) : .primary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(label)
    }

    private func moduleHeader(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
        }
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
    /// 面板宽度 = 内容模块自然宽 + 左右各 44pt 呼吸边距，钳制在 [min, max]
    static let minWidth: CGFloat = 420
    static let maxWidth: CGFloat = 680
    /// 圆角半径（≈Mac 屏幕圆角；屏幕圆角无公开 API 可查询）
    static let cornerRadius: CGFloat = 16

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.minWidth, height: 200),
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
    /// 每次 present 重建 contentView（模型重置到今天，同时取最新内容设置）。
    func present(hotspotTL: CGRect, screen: NSScreen, model: NotchCalendarViewModel) {
        // 先用自然宽度测量内容，再按模块组合计算面板宽、以该宽重测高度
        let measuring = NSHostingView(rootView: NotchContentView(model: model))
        measuring.layoutSubtreeIfNeeded()
        let natural = measuring.fittingSize
        // 内容左右各留 44pt 呼吸边距（与最小宽下单日历布局的比例一致）
        let width = Self.clamp(ceil(natural.width) + 88,
                               Self.minWidth,
                               min(Self.maxWidth, screen.frame.width - 40))
        let sized = NSHostingView(rootView: NotchContentView(model: model, displayWidth: width))
        sized.layoutSubtreeIfNeeded()
        let height = max(120, min(ceil(sized.fittingSize.height), screen.frame.height - 80))
        contentView = makeContentView(model: model, width: width)
        setContentSize(NSSize(width: width, height: height))

        let x = Self.clamp(hotspotTL.midX - width / 2,
                           screen.frame.minX + 8, screen.frame.maxX - width - 8)
        // 热区 TL 坐标最大 y = 刘海下边缘；转回 Cocoa 坐标作为面板顶边
        let unionMaxY = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }.maxY
        let finalOrigin = NSPoint(x: x, y: unionMaxY - hotspotTL.maxY - height)
        // 从刘海后方 12pt 处滑入；NSWindow 只有 frame 可动画（animator().setFrameOrigin 无效，
        // 面板会停在起始位置），必须用 animator().setFrame(_:display:)
        let startFrame = NSRect(origin: NSPoint(x: finalOrigin.x, y: finalOrigin.y + 12),
                                size: NSSize(width: width, height: height))
        let finalFrame = NSRect(origin: finalOrigin, size: NSSize(width: width, height: height))
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
    }

    /// 液态玻璃背景（macOS 26+）或磨砂底（旧系统）包裹内容，圆角≈屏幕圆角。
    /// 不透明度不再可调：使用系统默认外观（玻璃不染色、磨砂不降 alpha）。
    private func makeContentView(model: NotchCalendarViewModel, width: CGFloat) -> NSView {
        let hosting = NSHostingView(rootView: NotchContentView(model: model, displayWidth: width))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.cornerRadius
            glass.style = .regular
            glass.contentView = hosting
            pinEdges(of: hosting, to: glass)
            return glass
        }
        let frost = NSVisualEffectView()
        frost.material = .hudWindow
        frost.blendingMode = .behindWindow
        frost.state = .active
        frost.wantsLayer = true
        frost.layer?.cornerRadius = Self.cornerRadius
        frost.layer?.cornerCurve = .continuous
        frost.layer?.masksToBounds = true
        frost.addSubview(hosting)
        pinEdges(of: hosting, to: frost)
        return frost
    }

    private func pinEdges(of view: NSView, to container: NSView) {
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private static func clamp(_ value: CGFloat, _ minValue: CGFloat, _ maxValue: CGFloat) -> CGFloat {
        guard maxValue >= minValue else { return minValue }
        return min(max(value, minValue), maxValue)
    }
}
