import SwiftUI
import AppKit

@main
struct ZeroflowMain {
    static func main() {
        let app = NSApplication.shared
        let controller = MenuBarController()
        app.delegate = controller
        // 预热 CGS/WindowServer 连接：不先建立连接时 SkyLight SLPS 调用会静默 no-op（err=0 但无效果）
        _ = CGSWindowServer.shared.isAvailable
        // 消化 Finder 扩展转交的「访达自定义命令」（见 Services/FinderCommandRunner.swift）
        FinderCommandRunner.shared.start()
        app.run()
    }
}

#Preview {
    SettingsView()
}