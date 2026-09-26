import SwiftUI
import AppKit

/// 窗口缩略图卡片（⌘⇥ 切换器瓦片与 Dock 悬停预览卡片共用，保证两处 UI/动画一致）：
/// 缩略图（未就绪显示 app 图标占位）+ 标题 + app 名；悬停时左上角显示操作钮组。
/// 操作钮由调用方注入（切换器为退出/关闭/最小化/全屏四钮，Dock 预览仅关闭一钮），
/// 卡内只负责统一的定位（topLeading + padding 5）与视觉状态：
/// 悬停未选中时缩略图压暗 10%；选中（Dock 预览=悬停）时 accent 边框 + 1.06 放大动画。
struct WindowCardView<Actions: View>: View {
    let thumbnail: NSImage?
    let appIcon: NSImage?
    let title: String
    let appName: String
    /// 切换器样式：卡片整体等比压缩（缩略图 168×118 → 148×104，显示比例不变），
    /// 底部一行改为「大号 app 图标(22) + 名称(13pt)」靠左，便于切换时快速区分 app；
    /// false（Dock 预览）维持原尺寸与纯文字 app 名。
    var showsLargeAppIcon: Bool = false
    let isSelected: Bool
    let isHovered: Bool
    var onSelect: () -> Void
    @ViewBuilder var actions: () -> Actions

    /// 缩略图/文字行共用宽度；切换器样式整体等比缩小（148×104 ≈ 168×118 × 0.88，宽高比不变）
    private var contentWidth: CGFloat { showsLargeAppIcon ? 148 : 168 }
    private var thumbnailHeight: CGFloat { showsLargeAppIcon ? 104 : 118 }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(isHovered && !isSelected ? 0.10 : 0))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                } else if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 52, maxHeight: 52)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                }

                if isHovered {
                    HStack(spacing: 4) {
                        actions()
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(5)
                }
            }
            .frame(width: contentWidth, height: thumbnailHeight)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                                  lineWidth: isSelected ? 3 : 1)
            )
            .scaleEffect(isSelected ? 1.06 : 1.0)
            .animation(.easeOut(duration: 0.1), value: isSelected)

            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: contentWidth, alignment: .leading)
                .foregroundColor(.primary)
                .padding(.top, 4)
            if showsLargeAppIcon {
                HStack(spacing: 6) {
                    if let appIcon {
                        Image(nsImage: appIcon)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                    }
                    Text(appName)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: contentWidth, alignment: .leading)
            } else {
                Text(appName)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: contentWidth, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

/// 缩略图左上角的圆形操作按钮（系统红绿灯样式：直径 12pt，退出紫 / 关闭红 / 最小化黄 / 全屏绿）。
/// 悬停时仅当前按钮轻微放大（spring 动画）。
struct TileActionButton: View {
    let symbol: String
    let title: String
    let fill: Color
    var symbolColor: Color = .white
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .bold))
                .foregroundColor(symbolColor)
                .frame(width: 12, height: 12)
                .background(Circle().fill(fill))
        }
        .buttonStyle(.plain)
        .help(title)
        .scaleEffect(hovering ? 1.28 : 1.0)
        .shadow(color: .black.opacity(hovering ? 0.35 : 0), radius: hovering ? 2 : 0, y: hovering ? 1 : 0)
        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: hovering)
        .onHover { over in
            hovering = over
        }
    }
}
