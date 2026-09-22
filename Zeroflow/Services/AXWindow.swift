import AppKit
import ApplicationServices

/// 共享 AX 窗口匹配辅助：CGWindowID → AXUIElement。
/// 首选私有桥 `_AXUIElementGetWindow` 精确匹配；不可用时退回 AX bounds 匹配（公开 API 兜底）。
/// WindowActivator（激活）与 WindowOps（关闭/最小化/全屏）共用。
enum AXWindow {
    /// 返回 wid 对应的 AX 窗口元素；找不到返回 nil。
    static func element(for wid: CGWindowID, pid: pid_t, bounds: CGRect? = nil) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        guard let axWindows = copyElements(appElement, kAXWindowsAttribute) else { return nil }

        // 首选：私有桥精确匹配 CGWindowID
        for axWindow in axWindows {
            var w: CGWindowID = 0
            if _AXUIElementGetWindow(axWindow, &w) == .success, w == wid {
                return axWindow
            }
        }

        // 兜底：以 AX position+size 与 CGWindow bounds 匹配（不依赖私有 AX 桥）
        if let bounds {
            for axWindow in axWindows where axBoundsMatch(axWindow, target: bounds) {
                return axWindow
            }
        }
        return nil
    }

    /// 返回 app 当前聚焦窗口的 CGWindowID（kAXFocusedWindowAttribute）。
    /// 同 app 多窗口切换时用它确定「当前窗口」：CGWindowListCopyWindowInfo 的顺序不会随
    /// 窗口间激活而刷新（实测：SLS 真 z-序已变化但 CGWindowList 顺序保持旧序），用 AX 聚焦
    /// 窗口比「CGWindowList 第一个 onscreen 窗口」可靠；AX 取不到时调用方回退 CGWindowList 兜底。
    static func focusedWindowID(for pid: pid_t) -> CGWindowID? {
        let appElement = AXUIElementCreateApplication(pid)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let focused = raw as! AXUIElement
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(focused, &wid) == .success, wid != 0 else { return nil }
        return wid
    }

    /// 读取窗口的 AX subrole（对齐 AltTab WindowDiscriminator：真窗口 subrole 应为
    /// AXStandardWindow 或 AXDialog；返回 nil = 没有可匹配的 AX 窗口实体 → 视为幽灵）。
    static func subrole(for wid: CGWindowID, pid: pid_t) -> String? {
        guard let axWindow = element(for: wid, pid: pid) else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXSubroleAttribute as CFString, &raw) == .success,
              let subrole = raw as? String else { return nil }
        return subrole
    }

    // MARK: - 辅助

    private static func copyElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw else { return nil }
        return value as? [AXUIElement]
    }

    private static func copyValue<T>(_ element: AXUIElement, _ attribute: String, as _: T.Type) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw else { return nil }
        return value as? T
    }

    private static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copyValue(element, attribute, as: AXValue.self) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copyValue(element, attribute, as: AXValue.self) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private static func axBoundsMatch(_ axWindow: AXUIElement, target: CGRect) -> Bool {
        guard let point = point(axWindow, kAXPositionAttribute),
              let size = size(axWindow, kAXSizeAttribute) else { return false }
        let bounds = CGRect(origin: point, size: size)
        let tolerance: CGFloat = 12
        return abs(bounds.minX - target.minX) <= tolerance
            && abs(bounds.minY - target.minY) <= tolerance
            && abs(bounds.width - target.width) <= tolerance
            && abs(bounds.height - target.height) <= tolerance
    }
}
