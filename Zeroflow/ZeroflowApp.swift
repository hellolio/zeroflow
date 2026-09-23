import SwiftUI
import AppKit

@main
struct ZeroflowMain {
    static func main() {
        let app = NSApplication.shared
        let controller = MenuBarController()
        app.delegate = controller
        // 消化 Finder 扩展转交的「访达自定义命令」（见 Services/FinderCommandRunner.swift）
        FinderCommandRunner.shared.start()
        app.run()
    }
}

#Preview {
    SettingsView()
}