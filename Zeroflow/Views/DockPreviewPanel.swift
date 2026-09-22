import SwiftUI
import AppKit

/// Dock 预览卡片模型（仅主线程读写）
final class DockPreviewViewModel: ObservableObject {
    @Published var items: [DockPreviewItem] = []
}

/// 预览面板里的一张卡（对应一个真实窗口；无窗口占位卡不进入 Dock 预览）
struct DockPreviewItem: Identifiable {
    let id: CGWindowID
    let title: String
    let appName: String
    let appIcon: NSImage?
    var thumbnail: NSImage?
}

/// 单卡：缩略图（未就绪显示 app 图标占位）+ 标题；悬停右上角显示关闭钮（系统红绿灯语义）。
private struct DockPreviewCardView: View {
    let item: DockPreviewItem
    let isHovered: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    /// 系统红绿灯关闭钮的红色
    private static let trafficLightRed = Color(red: 1.0, green: 0.24, blue: 0.20)

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail = item.thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFit()
                            .padding(4)
                    } else if let icon = item.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 44, maxHeight: 44)
                    } else {
                        Image(systemName: "app.dashed")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 148, height: 96)

                if isHovered {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 13, height: 13)
                            .background(Circle().fill(Self.trafficLightRed))
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("关闭窗口"))
                    .padding(4)
                }
            }
            Text(item.title)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 6)
                .padding(.bottom, 5)
                .frame(width: 148, alignment: .leading)
                .foregroundColor(.primary)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isHovered ? Color.accentColor : Color(nsColor: .separatorColor),
                              lineWidth: isHovered ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

/// 卡片列表：横排（底部 Dock）或竖排（左右 Dock），超出可用长度时滚动。
struct DockPreviewContentView: View {
    @ObservedObject var model: DockPreviewViewModel
    let vertical: Bool
    var onSelect: (CGWindowID) -> Void
    var onClose: (CGWindowID) -> Void
    @State private var hoveredID: CGWindowID?

    private let spacing: CGFloat = 8

    var body: some View {
        Group {
            if vertical {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: spacing) { cards }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: spacing) { cards }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.94))
        )
    }

    @ViewBuilder private var cards: some View {
        ForEach(model.items) { item in
            DockPreviewCardView(
                item: item,
                isHovered: hoveredID == item.id,
                onSelect: { onSelect(item.id) },
                onClose: { onClose(item.id) }
            )
            .onHover { hovering in
                hoveredID = hovering ? item.id : nil
            }
        }
    }
}

/// Dock 预览面板：非激活 borderless 面板（配置对齐 WindowSwitcherPanel）。
/// 不成为 key（canBecomeKey=false），点击/悬停全走 SwiftUI；键盘隐藏由
/// DockHoverPreviewController 的本地 monitor 负责。每次 present 重建 contentView
/// （卡片排布方向可能随 Dock 位置变化），并按 Dock 项位置锚定（topLeft 全局坐标）。
final class DockPreviewPanel: NSPanel {
    /// 面板相对 Dock 项的位置
    enum Placement { case above, rightOf, leftOf }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.isReleasedWhenClosed = false
        self.animationBehavior = .none
        self.hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 最近一次 present 的内容与锚点（refit 复用，面板不换目标时不变）
    private var contentModel: DockPreviewViewModel?
    private var onSelect: ((CGWindowID) -> Void)?
    private var onClose: ((CGWindowID) -> Void)?
    private var anchorTL: CGRect?
    private var placement: Placement = .above

    /// 依据 Dock 项位置（左上原点全局坐标）重建内容并定位、显示。
    /// 面板弹出后位置冻结（图标放大效验抖由 controller 的保活/隐藏判定兜住，不跟随重排）。
    func present(anchorTL: CGRect,
                 placement: Placement,
                 model: DockPreviewViewModel,
                 onSelect: @escaping (CGWindowID) -> Void,
                 onClose: @escaping (CGWindowID) -> Void) {
        contentModel = model
        self.onSelect = onSelect
        self.onClose = onClose
        self.anchorTL = anchorTL
        self.placement = placement
        rebuildContentView()
        layoutAndPosition()
        orderFront(nil)
    }

    /// 关闭卡片后调用：按最新模型重算面板尺寸并重新贴回锚点，外框随之收缩不留空白。
    /// 重建 contentView 再测量——SwiftUI 对已装载视图的更新是异步提交的，
    /// 直接量旧视图可能量到旧布局；新视图持有同一 model 引用，fittingSize 即最新内容尺寸。
    func refit() {
        guard contentModel != nil else { return }
        rebuildContentView()
        layoutAndPosition()
    }

    private func rebuildContentView() {
        guard let contentModel, let onSelect, let onClose else { return }
        contentView = NSHostingView(
            rootView: DockPreviewContentView(model: contentModel,
                                             vertical: placement != .above,
                                             onSelect: onSelect,
                                             onClose: onClose)
        )
    }

    /// 按当前内容测量尺寸，并按锚点与朝向定位（present / refit 共用）。
    private func layoutAndPosition() {
        guard let anchorTL else { return }
        // AX/CGEvent 全局坐标（主屏左上原点）→ Cocoa 全局坐标（左下原点）
        let unionMaxY = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }.maxY
        let anchorCocoa = CGRect(x: anchorTL.minX, y: unionMaxY - anchorTL.maxY,
                                 width: anchorTL.width, height: anchorTL.height)
        let center = CGPoint(x: anchorCocoa.midX, y: anchorCocoa.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.first { $0.frame.intersects(anchorCocoa) }
            ?? NSScreen.main

        contentView?.layoutSubtreeIfNeeded()
        var size = contentView?.fittingSize ?? frame.size
        size = NSSize(width: max(1, ceil(size.width)), height: max(1, ceil(size.height)))
        if let screen {
            size = NSSize(width: min(size.width, screen.frame.width - 32),
                          height: min(size.height, screen.frame.height - 32))
        }
        setContentSize(size)

        if let screen {
            let origin: NSPoint
            switch placement {
            case .above:
                let x = Self.clamp(anchorCocoa.midX - size.width / 2,
                                   screen.frame.minX + 8, screen.frame.maxX - size.width - 8)
                origin = NSPoint(x: x, y: anchorCocoa.maxY + 2)
            case .rightOf:
                let y = Self.clamp(anchorCocoa.midY - size.height / 2,
                                   screen.frame.minY + 8, screen.frame.maxY - size.height - 8)
                origin = NSPoint(x: anchorCocoa.maxX + 2, y: y)
            case .leftOf:
                let y = Self.clamp(anchorCocoa.midY - size.height / 2,
                                   screen.frame.minY + 8, screen.frame.maxY - size.height - 8)
                origin = NSPoint(x: anchorCocoa.minX - 2 - size.width, y: y)
            }
            setFrameOrigin(origin)
        }
    }

    private static func clamp(_ value: CGFloat, _ minValue: CGFloat, _ maxValue: CGFloat) -> CGFloat {
        guard maxValue >= minValue else { return minValue }
        return min(max(value, minValue), maxValue)
    }
}
