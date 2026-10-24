import SwiftUI
import AppKit
import EventKit

/// 灵动岛面板的一条日程（主线程由 EKEvent 转换生成）
struct NotchEventItem: Identifiable, Equatable {
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
/// 无模块时显示「添加显示内容」引导。双卡片时两卡片各占一半宽，面板高由内容驱动
/// （上限 = 设置最大高）；系统资源卡拉伸到驱动卡高度、行均匀分布；日历日程列表
/// 装得下完整展开、装不下在剩余空间滚动（文字不缩放），仅固定部分也超限时才整体缩小；
/// 各模块包圆角半透明卡片背景。
struct NotchContentView: View {
    @ObservedObject var model: NotchCalendarViewModel
    /// 显示宽度：nil = 测量模式（卡片自然尺寸）；正式展示由 NotchPanel 传入面板尺寸
    var displayWidth: CGFloat? = nil
    /// 显示高度：正式展示时传入面板高
    var displayHeight: CGFloat? = nil
    /// 测量单模块尺寸时指定要渲染的模块；nil = 按设置显示
    var modulesOverride: [Module]? = nil
    /// 测量双卡片拉伸高度时指定列宽；nil = 按自然宽/拉伸规则
    var columnWidthOverride: CGFloat? = nil
    /// 测量系统资源卡拉伸高度时指定列高；nil = 按自然高
    var columnHeightOverride: CGFloat? = nil
    /// 测量日历卡日程列表的最大高度；nil = 不限制（渲染时靠面板高度约束滚动）
    var dayListMaxHeight: CGFloat? = nil
    /// 测量日历卡固定部分高度时收起日程列表（只留选中日标题）
    var collapseDayEvents = false
    /// 各卡片的自然尺寸（含卡片内边距，由 NotchPanel 测量传入，顺序对齐可见模块）
    var cardNaturals: [CGSize] = []
    /// 卡片内容等比缩放系数（≤1，由 NotchPanel 按槽位与自然尺寸计算）
    var cardScale: CGFloat = 1

    @ObservedObject private var resources = SystemResourceMonitor.shared
    @ObservedObject private var music = NowPlayingMonitor.shared

    private let accent = Color.accentColor
    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    /// 面板内容内边距（测量与尺寸决策共用）
    static let outerHPadding: CGFloat = 20
    static let outerVPadding: CGFloat = 12
    /// 卡片样式：间距 / 内边距 / 圆角（测量与尺寸决策共用）
    static let cardGap: CGFloat = 14
    static let cardPadding: CGFloat = 14
    private static let cardRadius: CGFloat = 14
    /// 日历列自然宽度（单卡片测量/展示基准）
    private static let calendarColumnWidth: CGFloat = 332
    /// 系统资源列自然宽度
    private static let resourcesColumnWidth: CGFloat = 224
    /// 正在播放列自然宽度
    private static let musicColumnWidth: CGFloat = 224

    /// 内容模块（固定顺序，最多同时显示 2 个；超出部分在设置页禁用开关）
    enum Module: CaseIterable {
        case calendar
        case resources
        case music
    }

    var body: some View {
        HStack(alignment: .top, spacing: Self.cardGap) {
            ForEach(Array(visibleModules.enumerated()), id: \.element) { index, module in
                moduleCard(module, index: index)
            }
        }
        .padding(.horizontal, Self.outerHPadding)
        .padding(.vertical, Self.outerVPadding)
        .frame(width: displayWidth, height: displayHeight, alignment: .center)
    }

    /// 面板显示的模块（固定顺序，最多 2 个）
    static var orderedVisibleModules: [Module] {
        var enabled: [Module] = []
        if SettingsStore.shared.notchShowCalendar { enabled.append(.calendar) }
        if SettingsStore.shared.notchShowResources { enabled.append(.resources) }
        if SettingsStore.shared.notchShowMusic { enabled.append(.music) }
        return Array(enabled.prefix(2))
    }

    /// 面板显示的模块数（面板尺寸决策用）
    static var visibleModuleCount: Int { orderedVisibleModules.count }

    /// 测量单个模块卡片的尺寸（含卡片内边距，不含面板内边距）。
    /// columnWidth 非 nil 时以该列宽测量（双卡片按拉伸宽测高）；
    /// columnHeight 非 nil 时以该列高测量（资源卡拉伸到驱动卡高度）；
    /// dayListMaxHeight / collapseDayEvents 用于日历卡的全高/固定高两档测量。
    static func measureCardSize(index: Int,
                                columnWidth: CGFloat?,
                                columnHeight: CGFloat? = nil,
                                dayListMaxHeight: CGFloat? = nil,
                                collapseDayEvents: Bool = false,
                                model: NotchCalendarViewModel) -> CGSize {
        let modules = orderedVisibleModules
        guard index < modules.count else { return .zero }
        let view = NotchContentView(model: model,
                                    modulesOverride: [modules[index]],
                                    columnWidthOverride: columnWidth,
                                    columnHeightOverride: columnHeight,
                                    dayListMaxHeight: dayListMaxHeight,
                                    collapseDayEvents: collapseDayEvents)
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return CGSize(width: max(1, host.fittingSize.width - outerHPadding * 2),
                      height: max(1, host.fittingSize.height - outerVPadding * 2))
    }

    private var visibleModules: [Module] { modulesOverride ?? Self.orderedVisibleModules }

    /// 双卡片布局：两卡片各占一半宽
    private var isDualLayout: Bool { visibleModules.count == 2 }

    /// 正式渲染且双卡片时，列从固定自然宽改为填满卡片槽
    private var stretchForRender: Bool { displayWidth != nil && isDualLayout && columnWidthOverride == nil }

    /// 测量模式（卡片自适应内容自然尺寸）
    private var isMeasuring: Bool { displayWidth == nil }

    private func renderColumnWidth(_ natural: CGFloat) -> CGFloat? {
        columnWidthOverride ?? (stretchForRender ? nil : natural)
    }

    @ViewBuilder private func moduleView(_ module: Module) -> some View {
        switch module {
        case .calendar: calendarColumn
        case .resources: resourcesColumn
        case .music: musicColumn
        }
    }

    @ViewBuilder private func moduleCard(_ module: Module, index: Int) -> some View {
        if isMeasuring {
            moduleView(module)
                .padding(Self.cardPadding)
                .background(cardBackground)
        } else {
            renderedCard(module, index: index)
        }
    }

    /// 正式渲染：卡片背景填满槽位，内容按 cardScale 等比缩放后贴顶
    /// （缩放锚点 = 顶部，留白只出现在底部），高度取卡片的渲染目标高
    /// （完整高或压缩到槽高的滚动高，由 NotchPanel.computeLayout 决定）
    private func renderedCard(_ module: Module, index: Int) -> some View {
        let natural = index < cardNaturals.count ? cardNaturals[index] : CGSize(width: 100, height: 100)
        let slot = cardSlotSize
        return moduleView(module)
            .padding(Self.cardPadding)
            .frame(width: isDualLayout ? slot.width : natural.width,
                   height: natural.height, alignment: .top)
            .scaleEffect(cardScale, anchor: .top)
            .frame(width: slot.width, height: slot.height, alignment: .top)
            .background(cardBackground)
    }

    /// 卡片槽位：双卡片各占一半宽，单卡片占满面板内容区
    private var cardSlotSize: CGSize {
        let innerW = (displayWidth ?? 0) - Self.outerHPadding * 2
        let innerH = max(1, (displayHeight ?? 0) - Self.outerVPadding * 2)
        if isDualLayout {
            return CGSize(width: max(1, (innerW - Self.cardGap) / 2), height: innerH)
        }
        return CGSize(width: max(1, innerW), height: innerH)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
            .fill(Color.primary.opacity(0.07))
            .overlay {
                RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
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
        .frame(width: renderColumnWidth(Self.calendarColumnWidth))
        .frame(maxWidth: stretchForRender ? .infinity : nil)
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

    /// 资源行拉伸条件：测量时指定列高，或正式渲染双卡片（卡片槽高由面板决定）
    private var stretchResourceRows: Bool { columnHeightOverride != nil || stretchForRender }

    private var resourcesColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            moduleHeader("cpu", L10n.tr("系统资源"))
            ForEach(enabledResourceItems, id: \.self) { item in
                resourceRow(item)
                    // 拉伸时各行平分剩余高度（标题固定顶部），行内内容垂直居中
                    .frame(maxHeight: stretchResourceRows ? .infinity : nil)
            }
        }
        .frame(width: renderColumnWidth(Self.resourcesColumnWidth))
        .frame(height: columnHeightOverride)
        .frame(maxWidth: stretchForRender ? .infinity : nil, alignment: .leading)
    }

    private func resourceRow(_ item: NotchResourceItem) -> some View {
        HStack(spacing: 8) {
            Text(item.title)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            // 百分比项（CPU/内存/GPU）= 用量进度条：灰轨道=总量 100%，彩色填充=当前用量；
            // 速率项（磁盘/网络）无固定满格，保留迷你趋势图
            if isPercentItem(item) {
                ResourceProgressBar(progress: normalizedProgress(item))
                    .frame(maxWidth: .infinity)
                    .frame(height: 16)
            } else {
                ResourceSparkline(normalizedValues: normalizedHistory(item))
                    .frame(maxWidth: .infinity)
                    .frame(height: 16)
            }
            Text(resourceValue(item))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    /// 百分比项（CPU/内存/GPU）用进度条展示用量占比；磁盘/网络为速率无固定满格，走趋势图
    private func isPercentItem(_ item: NotchResourceItem) -> Bool {
        switch item {
        case .cpu, .memory, .gpu: return true
        case .disk, .network: return false
        }
    }

    /// 百分比项当前用量 0–1；nil = 暂不可用（只显示空轨道，数值列同步显示「—」）
    private func normalizedProgress(_ item: NotchResourceItem) -> Double? {
        let s = resources.sample
        switch item {
        case .cpu: return s.cpuPercent.map { min(1, max(0, $0 / 100)) }
        case .gpu: return s.gpuPercent.map { min(1, max(0, $0 / 100)) }
        case .memory:
            guard let used = s.memUsedBytes, let total = s.memTotalBytes, total > 0 else { return nil }
            return min(1, max(0, Double(used) / Double(total)))
        case .disk, .network: return nil
        }
    }

    /// 迷你趋势图数据（现仅速率项 磁盘/网络 消费）：速率项按窗口内峰值归一化（峰值下限 200KB/s 防除零全矮）
    private func normalizedHistory(_ item: NotchResourceItem) -> [Double] {
        func normalize(_ values: [Double], scale: Double) -> [Double] {
            values.map { min(1, max(0, $0 / scale)) }
        }
        let h = resources.history
        switch item {
        case .cpu: return normalize(h.cpu, scale: 100)
        case .memory: return normalize(h.memory, scale: 100)
        case .gpu: return normalize(h.gpu, scale: 100)
        case .disk:
            return normalize(h.disk, scale: max(h.disk.max() ?? 0, 200_000))
        case .network:
            return normalize(h.network, scale: max(h.network.max() ?? 0, 200_000))
        }
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
        .frame(width: renderColumnWidth(Self.musicColumnWidth))
        .frame(maxWidth: stretchForRender ? .infinity : nil, alignment: .leading)
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

    /// 选中日详情：标题 + 授权提示/日程列表。列表高度弹性——面板装得下就完整展开，
    /// 装不下就压缩到剩余空间内滚动（文字不缩放）；collapseDayEvents 仅用于测量
    /// 日历固定部分高度（收起列表，只留标题）
    @ViewBuilder private var daySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.selectedTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            if !collapseDayEvents {
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
                    // 高度不设上限：测量时由 dayListMaxHeight 兜底，渲染时靠面板高度约束
                    // 压缩到剩余空间内滚动（文字保持原大）
                    .frame(maxHeight: dayListMaxHeight)
                }
            }
        }
    }
}

/// 百分比资源项（CPU/内存/GPU）的用量进度条：灰色轨道 = 总量 100%（恒显完整宽度），
/// 彩色填充 = 当前用量（左→右），一眼区分已用/未用
private struct ResourceProgressBar: View {
    let progress: Double?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.25))
                if let progress, progress > 0 {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * min(1, max(0, progress)))
                }
            }
        }
        .frame(height: 5)
    }
}

/// 资源行的迷你趋势图：无坐标轴的单色渐变面积线（数据已归一化到 0–1）
private struct ResourceSparkline: View {
    let normalizedValues: [Double]

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            if normalizedValues.count >= 2, w > 0, h > 2 {
                let step = w / CGFloat(normalizedValues.count - 1)
                let points = normalizedValues.enumerated().map { pair -> CGPoint in
                    CGPoint(x: CGFloat(pair.offset) * step,
                            y: (1 - CGFloat(min(1, max(0, pair.element)))) * (h - 2) + 1)
                }
                ZStack {
                    areaPath(points: points, bottom: h)
                        .fill(LinearGradient(colors: [Color.accentColor.opacity(0.35),
                                                      Color.accentColor.opacity(0.05)],
                                             startPoint: .top, endPoint: .bottom))
                    linePath(points: points)
                        .stroke(Color.accentColor,
                                style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private func linePath(points: [CGPoint]) -> Path {
        var path = Path()
        path.addLines(points)
        return path
    }

    private func areaPath(points: [CGPoint], bottom: CGFloat) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: CGPoint(x: first.x, y: bottom))
        path.addLines(points)
        path.addLine(to: CGPoint(x: last.x, y: bottom))
        path.closeSubpath()
        return path
    }
}

/// 灵动岛面板：非激活 borderless 面板，深色 HUD 磨砂，以 iOS 风格弹簧动画从刘海
/// 「生长」展开、收起时缩回刘海（NotchSpringAnimator 驱动 frame + alpha）。
/// 悬停/点击/Esc 判定全部由 NotchHotspotController 的 listen-only tap 完成，
/// 本面板只负责内容展示（不成为 key，无键盘交互）。
final class NotchPanel: NSPanel {
    /// 单卡片时面板最小宽/高（呼吸边距下限）；最大宽高由设置页配置
    static let minWidth: CGFloat = 420
    static let minHeight: CGFloat = 120
    /// 圆角半径（≈Mac 屏幕圆角；屏幕圆角无公开 API 可查询）
    static let cornerRadius: CGFloat = 16
    /// alpha 跟随展开进度：进行到 50% 时完全显形（前期半透明，「从刘海长出」全程可见）
    static let alphaInSpan: CGFloat = 0.5
    /// alpha 跟随收缩进度：全程线性淡出，缩回刘海时恰好消失（黑底上无感收尾）
    static let alphaOutSpan: CGFloat = 1.0

    private lazy var springAnimator = NotchSpringAnimator(panel: self)

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

    /// 面板布局决策结果（present 与 refit 共用）
    private struct PanelLayout {
        let width: CGFloat
        let height: CGFloat
        let naturals: [CGSize]
        let scale: CGFloat
    }

    /// 尺寸决策：
    /// - 宽：双卡片 = 设置最大宽（两卡片各占一半）；单卡片 = 内容自然宽（上下限钳制）；
    /// - 高：内容驱动（最高卡片的渲染目标高 + 面板内边距），上限钳制到设置最大高/屏幕。
    ///   日历卡日程列表装得下就完整展开；装不下压到槽高、列表在剩余空间滚动（文字不缩放）；
    ///   仅固定部分（收起日程）也超槽时才整体等比缩小兕底；
    /// - 双卡片时系统资源卡拉伸到驱动卡目标高测量（渲染时行均匀分布填满卡片）。
    private static func computeLayout(screen: NSScreen, model: NotchCalendarViewModel) -> PanelLayout {
        let maxW = min(CGFloat(SettingsStore.shared.notchMaxWidth), screen.frame.width - 40)
        let maxH = min(CGFloat(SettingsStore.shared.notchMaxHeight), screen.frame.height - 80)
        let outerH = NotchContentView.outerHPadding
        let outerV = NotchContentView.outerVPadding
        let modules = NotchContentView.orderedVisibleModules
        let slotH = max(1, maxH - outerV * 2)

        // 日历卡两档测量：全高（日程全展开，测量上限放大）/ 固定高（收起日程列表）
        func calendarHeights(index: Int, columnWidth: CGFloat?) -> (full: CGFloat, fixed: CGFloat, naturalWidth: CGFloat) {
            let full = NotchContentView.measureCardSize(index: index, columnWidth: columnWidth,
                                                        dayListMaxHeight: 2000, model: model)
            let fixed = NotchContentView.measureCardSize(index: index, columnWidth: columnWidth,
                                                         collapseDayEvents: true, model: model)
            return (full.height, fixed.height, full.width)
        }
        // 渲染目标高：日程装得下用全高；装不下压到槽高（日程滚动）；固定部分也超槽则保持固定高（缩小兕底）
        func renderTarget(full: CGFloat, fixed: CGFloat) -> CGFloat {
            fixed >= slotH ? max(1, fixed) : max(1, min(full, slotH))
        }

        if modules.count >= 2 {
            let slotW = (maxW - outerH * 2 - NotchContentView.cardGap) / 2
            let columnW = slotW - NotchContentView.cardPadding * 2
            var naturals = Array(repeating: CGSize.zero, count: modules.count)
            var targets: [CGFloat] = Array(repeating: 0, count: modules.count)
            // 先测非资源卡（日历/正在播放）目标高，面板高度由其中最高者驱动
            for (i, module) in modules.enumerated() where module != .resources {
                if module == .calendar {
                    let h = calendarHeights(index: i, columnWidth: columnW)
                    targets[i] = renderTarget(full: h.full, fixed: h.fixed)
                    naturals[i] = CGSize(width: h.naturalWidth, height: targets[i])
                } else {
                    let natural = NotchContentView.measureCardSize(index: i, columnWidth: columnW, model: model)
                    targets[i] = renderTarget(full: natural.height, fixed: natural.height)
                    naturals[i] = CGSize(width: natural.width, height: targets[i])
                }
            }
            // 资源卡拉伸到驱动卡目标高测量，渲染时与驱动卡等高
            for (i, module) in modules.enumerated() where module == .resources {
                let natural = NotchContentView.measureCardSize(index: i, columnWidth: columnW,
                                                               columnHeight: max(1, targets.max() ?? slotH),
                                                               model: model)
                targets[i] = natural.height
                naturals[i] = natural
            }
            let scale = min(1, slotH / max(1, targets.max() ?? slotH))
            let height = Self.clamp(scale * max(1, targets.max() ?? slotH) + outerV * 2,
                                    min(Self.minHeight, maxH), maxH)
            return PanelLayout(width: maxW, height: height, naturals: naturals, scale: scale)
        }
        if modules.count == 1 {
            let naturalWidth: CGFloat
            let target: CGFloat
            if modules[0] == .calendar {
                let h = calendarHeights(index: 0, columnWidth: nil)
                naturalWidth = h.naturalWidth
                target = renderTarget(full: h.full, fixed: h.fixed)
            } else {
                let natural = NotchContentView.measureCardSize(index: 0, columnWidth: nil, model: model)
                naturalWidth = natural.width
                target = renderTarget(full: natural.height, fixed: natural.height)
            }
            let scale = min(1, (maxW - outerH * 2) / max(1, naturalWidth), slotH / target)
            let width = Self.clamp(naturalWidth * scale + outerH * 2, min(Self.minWidth, maxW), maxW)
            let height = Self.clamp(target * scale + outerV * 2, min(Self.minHeight, maxH), maxH)
            return PanelLayout(width: width, height: height,
                               naturals: [CGSize(width: naturalWidth, height: target)], scale: scale)
        }
        return PanelLayout(width: Self.clamp(outerH * 2, min(Self.minWidth, maxW), maxW),
                           height: Self.clamp(outerV * 2, min(Self.minHeight, maxH), maxH),
                           naturals: [], scale: 1)
    }

    /// 依据刘海热区（主屏左上原点坐标）重建内容、测尺寸、定位，并从刘海矩形「生长」展开。
    /// 面板顶边贴刘海下边缘（热区竖向范围 = 刘海竖向范围）、水平居中刘海；
    /// 每次 present 重建 contentView（模型重置到今天，同时取最新内容设置）。
    /// 尺寸决策见 computeLayout（日程异步加载完成后的高度修正走 refit）。
    func present(hotspotTL: CGRect, notchTL: CGRect, screen: NSScreen, model: NotchCalendarViewModel) {
        let layout = Self.computeLayout(screen: screen, model: model)
        contentView = makeContentView(model: model, width: layout.width, height: layout.height,
                                      cardNaturals: layout.naturals, scale: layout.scale)
        setContentSize(NSSize(width: layout.width, height: layout.height))

        let x = Self.clamp(hotspotTL.midX - layout.width / 2,
                           screen.frame.minX + 8, screen.frame.maxX - layout.width - 8)
        // 热区 TL 坐标最大 y = 刘海下边缘；转回 Cocoa 坐标作为面板顶边
        let unionMaxY = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }.maxY
        let finalFrame = NSRect(x: x, y: unionMaxY - hotspotTL.maxY - layout.height,
                                width: layout.width, height: layout.height)
        if isVisible {
            // 收起动画被打断（快速反复进出）：不重放，从当前 frame/alpha 无缝续接展开
            invalidateShadow()
        } else {
            // 起始 frame = 刘海矩形（盖住刘海，深色 HUD 与黑色刘海衔接）→ 弹簧展开 ≈ 刘海长大
            setFrame(cocoaNotchFrame(notchTL: notchTL, unionMaxY: unionMaxY), display: false)
            alphaValue = 0
            orderFront(nil)
            invalidateShadow()
        }
        springAnimator.animate(to: finalFrame, alpha: 1, fadeSpan: Self.alphaInSpan)
    }

    /// 收起：弹簧缩回刘海矩形并淡出，动画结束才 orderOut。控制器状态在 hidePanel 即时更新，
    /// 期间再 present 会从当前 frame 无缝续接展开（本方法的 orderOut 已作废，不会执行）。
    func dismiss(notchTL: CGRect) {
        let unionMaxY = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }.maxY
        springAnimator.animate(to: cocoaNotchFrame(notchTL: notchTL, unionMaxY: unionMaxY),
                               alpha: 0, fadeSpan: Self.alphaOutSpan) { [weak self] in
            self?.orderOut(nil)
        }
    }

    /// 刘海矩形（主屏左上原点坐标）→ Cocoa 坐标（面板盖在刘海正上方）
    private func cocoaNotchFrame(notchTL: CGRect, unionMaxY: CGFloat) -> NSRect {
        NSRect(x: notchTL.minX, y: unionMaxY - notchTL.maxY, width: notchTL.width, height: notchTL.height)
    }

    /// 日程加载/切换后重算布局并调整面板：顶边贴刘海不动（向下生长/收缩），同款弹簧动画。
    /// contentView 按新尺寸重建；尺寸不变时跳过。
    func refit(hotspotTL: CGRect, screen: NSScreen, model: NotchCalendarViewModel) {
        let layout = Self.computeLayout(screen: screen, model: model)
        guard abs(layout.height - frame.height) > 0.5 || abs(layout.width - frame.width) > 0.5 else { return }
        contentView = makeContentView(model: model, width: layout.width, height: layout.height,
                                      cardNaturals: layout.naturals, scale: layout.scale)
        let x = Self.clamp(hotspotTL.midX - layout.width / 2,
                           screen.frame.minX + 8, screen.frame.maxX - layout.width - 8)
        let unionMaxY = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }.maxY
        let target = NSRect(origin: NSPoint(x: x, y: unionMaxY - hotspotTL.maxY - layout.height),
                            size: NSSize(width: layout.width, height: layout.height))
        // 同款弹簧（alpha 保持当前值不变），与展开/收起手感一致
        springAnimator.animate(to: target)
        invalidateShadow()
    }

    /// 液态玻璃背景（macOS 26+）或磨砂底（旧系统）包裹内容，圆角≈屏幕圆角。
    /// 不透明度不再可调：使用系统默认外观（玻璃不染色、磨砂不降 alpha）。
    private func makeContentView(model: NotchCalendarViewModel, width: CGFloat, height: CGFloat,
                                 cardNaturals: [CGSize], scale: CGFloat) -> NSView {
        let hosting = NSHostingView(rootView: NotchContentView(model: model,
                                                               displayWidth: width,
                                                               displayHeight: height,
                                                               cardNaturals: cardNaturals,
                                                               cardScale: scale))
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

/// iOS 风格弹簧动画驱动器（驱动 NotchPanel 的窗口 frame；alpha 跟随几何进度渐显/渐隐）。
/// macOS 对窗口 frame 没有公开的弹簧动画 API（NSAnimationContext 仅支持贝塞尔曲线，
/// animator() 可动画属性的限制见 PITFALLS_DEV.md DEV-016），这里在主线程用定时器对弹簧
/// 微分方程做半隐式欧拉积分后直接 setFrame。response + dampingFraction 语义同 UIKit，
/// dampingFraction < 1 带过冲回弹。
/// alpha 不走独立曲线：独立快速淡入会让早期生长不可见（感知成「从一侧滑入」，DEV-022），
/// 改为按尺寸进度渐显/渐隐。动画进行中再次 animate：各分量以当前值/速度为起点重定向
/// （展开↔收起互相打断无缝续接），旧动画未执行的 completion 作废。
private final class NotchSpringAnimator {
    /// frame 弹簧：0.5s 响应、阻尼比 0.72（展开过程全程可见 + 明显回弹）
    static let frameResponse: TimeInterval = 0.5
    static let frameDampingFraction: CGFloat = 0.72

    private struct Spring {
        var value: CGFloat
        var velocity: CGFloat
        let target: CGFloat
        let stiffness: CGFloat
        let damping: CGFloat
        let valueEpsilon: CGFloat
        let velocityEpsilon: CGFloat

        init(value: CGFloat, velocity: CGFloat, target: CGFloat, response: TimeInterval,
             dampingFraction: CGFloat, valueEpsilon: CGFloat, velocityEpsilon: CGFloat) {
            self.value = value
            self.velocity = velocity
            self.target = target
            // k = (2π/response)²，c = 2ζ√k（response/dampingFraction 同 UIKit 语义）
            let k = pow(2 * CGFloat.pi / max(0.01, CGFloat(response)), 2)
            self.stiffness = k
            self.damping = 2 * dampingFraction * sqrt(k)
            self.valueEpsilon = valueEpsilon
            self.velocityEpsilon = velocityEpsilon
        }

        /// 半隐式欧拉一步（dt 远小于稳定域 2/ω，帧率抖动不发散）
        func stepped(dt: CGFloat) -> Spring {
            var s = self
            let force = -stiffness * (s.value - target) - damping * s.velocity
            s.velocity += force * dt
            s.value += s.velocity * dt
            return s
        }

        var settled: Bool {
            abs(value - target) < valueEpsilon && abs(velocity) < velocityEpsilon
        }
    }

    /// 分量顺序：x, y, width, height（alpha 由几何进度推导，不单独积分）
    private var springs: [Spring]?
    private var completion: (() -> Void)?
    private var timer: Timer?
    private weak var panel: NotchPanel?
    /// alpha = captured + (target − captured) × clamp(尺寸进度 / fadeSpan, 0, 1)
    private var startWidth: CGFloat = 0
    private var startHeight: CGFloat = 0
    private var targetWidth: CGFloat = 0
    private var targetHeight: CGFloat = 0
    private var capturedAlpha: CGFloat = 1
    private var targetAlpha: CGFloat = 1
    private var fadeSpan: CGFloat = 1

    init(panel: NotchPanel) {
        self.panel = panel
    }

    deinit {
        timer?.invalidate()
    }

    /// 启动/重定向动画。alpha 传 nil = 保持在途的 alpha 目标（无在途动画则保持当前 alpha）。
    /// fadeSpan：alpha 到位所需的几何进度比例（1 = 与展开同步）。必须主线程调用（setFrame）。
    func animate(to targetFrame: NSRect, alpha targetAlpha: CGFloat? = nil,
                 fadeSpan span: CGFloat = 1, completion: (() -> Void)? = nil) {
        guard let panel else { return }
        self.completion = nil // 被打断动画的收尾作废

        let inFlight = springs != nil
        let frame = panel.frame
        let previous = springs?.count == 4 ? springs : nil

        startWidth = frame.width
        startHeight = frame.height
        targetWidth = targetFrame.width
        targetHeight = targetFrame.height
        capturedAlpha = panel.alphaValue
        // refit（alpha nil）时保留在途 alpha 目标，避免展开中途淡入被冻结在半透明
        self.targetAlpha = targetAlpha ?? (inFlight ? self.targetAlpha : panel.alphaValue)
        fadeSpan = span

        func make(_ index: Int, _ initial: CGFloat, _ target: CGFloat) -> Spring {
            if let previous {
                // 打断续接：沿用该分量当前的值与速度
                return Spring(value: previous[index].value, velocity: previous[index].velocity,
                              target: target, response: Self.frameResponse,
                              dampingFraction: Self.frameDampingFraction, valueEpsilon: 0.5, velocityEpsilon: 5)
            }
            return Spring(value: initial, velocity: 0, target: target, response: Self.frameResponse,
                          dampingFraction: Self.frameDampingFraction, valueEpsilon: 0.5, velocityEpsilon: 5)
        }

        springs = [
            make(0, frame.minX, targetFrame.minX),
            make(1, frame.minY, targetFrame.minY),
            make(2, frame.width, targetFrame.width),
            make(3, frame.height, targetFrame.height),
        ]
        self.completion = completion
        startTimerIfNeeded()
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        var t: Timer?
        t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            guard let self else { t?.invalidate(); return }
            self.tick()
        }
        // .common：面板内按钮按下等事件跟踪期间动画不冻结
        RunLoop.main.add(t!, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let panel, var springs else {
            stopTimer()
            return
        }
        let dt: CGFloat = 1 / 120
        var allSettled = true
        for i in springs.indices {
            if !springs[i].settled {
                springs[i] = springs[i].stepped(dt: dt)
            }
            if springs[i].settled {
                springs[i].value = springs[i].target
                springs[i].velocity = 0
            } else {
                allSettled = false
            }
        }
        self.springs = springs
        panel.setFrame(NSRect(x: springs[0].value, y: springs[1].value,
                              width: springs[2].value, height: springs[3].value), display: true)
        panel.alphaValue = progressAlpha(width: springs[2].value, height: springs[3].value)
        if allSettled {
            stopTimer()
            let completion = self.completion
            self.completion = nil
            completion?()
        }
    }

    /// alpha 随几何进度渐显/渐隐：进度 = 当前尺寸离开本次动画起点的比例（宽优先，宽没动用高；
    /// 同参数弹簧各分量归一化进度相同，取宽即整 frame 进度），
    /// alpha = captured + (target − captured) × clamp(进度 / fadeSpan, 0, 1)。
    /// 打断时 captured = 当前 alpha、起点 = 当前尺寸，故续接无跳变。
    private func progressAlpha(width: CGFloat, height: CGFloat) -> CGFloat {
        let dw = targetWidth - startWidth
        let dh = targetHeight - startHeight
        var progress: CGFloat = 1
        if abs(dw) > 0.5 {
            progress = (width - startWidth) / dw
        } else if abs(dh) > 0.5 {
            progress = (height - startHeight) / dh
        }
        progress = min(1, max(0, progress))
        let t = min(1, progress / max(0.05, fadeSpan))
        return capturedAlpha + (targetAlpha - capturedAlpha) * t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        springs = nil
    }
}
