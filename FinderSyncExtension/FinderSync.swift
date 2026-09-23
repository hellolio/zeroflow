import FinderSync
import AppKit
import Foundation
import os.log

private let finderSyncLog = OSLog(subsystem: "com.zeroflow.app.finderSync", category: "FinderSync")

/// 主 app 与 FinderSync 扩展跨进程共享的设置。
/// 扩展为沙盒进程、主 app 为非沙盒进程,两者都带 8NHN73Q43T.com.zeroflow.app App Group
/// 授权。不用 UserDefaults(suiteName:) 读 App Group(沙盒扩展里读不到,cfprefsd 报
/// Container: (null)),而是双方直接读写 group container 里同一份 plist 文件。
enum FinderSyncSharedDefaults {
    static let suiteName = "8NHN73Q43T.com.zeroflow.app"
    static let settingsFileName = "finder-sync-settings.plist"
    static let enabledKey = "finderNewFileEnabled"
    static let fileNameKey = "finderNewFileName"
    static let cmdEnabledKey = "finderCmdEnabled"
    static let cmdTitleKey = "finderCmdTitle"
    static let cmdCommandKey = "finderCmdCommand"
    static let appLanguageKey = "appLanguage"

    static let defaultFileName = "new file.md"
    static let defaultCmdTitle = "打开终端"

    /// 真实用户主目录。注意:沙盒进程里 FileManager.default.homeDirectoryForCurrentUser
    /// 返回的是容器目录(~/Library/Containers/.../Data),不是 /Users/用户名,直接用于
    /// directoryURLs 会导致 Finder 完全不监控任何用户路径。这里用 NSUserName() 拼出真实路径。
    static var userHome: URL {
        URL(fileURLWithPath: "/Users/\(NSUserName())", isDirectory: true)
    }

    private static var settingsURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: suiteName)?
            .appendingPathComponent(settingsFileName)
    }

    private static func settings() -> [String: Any] {
        guard let url = settingsURL,
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else { return [:] }
        return dict
    }

    /// 每次构建菜单前重读文件，保证主 app 的开关切换即时生效
    static func isEnabled() -> Bool {
        (settings()[enabledKey] as? Bool) ?? false
    }

    static func fileName() -> String {
        let raw = settings()[fileNameKey] as? String ?? defaultFileName
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultFileName : trimmed
    }

    /// 「自定义命令」开关与配置（菜单名称/命令均为用户自定义文案，不参与本地化）
    static func cmdEnabled() -> Bool {
        (settings()[cmdEnabledKey] as? Bool) ?? false
    }

    static func cmdTitle() -> String {
        let raw = settings()[cmdTitleKey] as? String ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cmdCommand() -> String {
        let raw = settings()[cmdCommandKey] as? String ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 与 L10n.AppLanguage 对齐的语言解析（system 时跟随系统首选语言）
    static func effectiveLanguage() -> String {
        let raw = settings()[appLanguageKey] as? String ?? "system"
        if raw != "system" && !raw.isEmpty { return raw }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
        if preferred.hasPrefix("zh") { return "zh-Hans" }
        if preferred.hasPrefix("ja") { return "ja" }
        return "en"
    }
}

extension Notification.Name {
    /// 主 app 改变「访达新建文件」设置时通知扩展增删 directoryURLs
    static let zeroflowFinderNewFileDidChange = Notification.Name("zeroflow.finderNewFileDidChange")
}

/// Finder 右键菜单注入「新建空文件」。
final class FinderSync: FIFinderSync {
    override init() {
        super.init()
        updateDirectoryURLs()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(settingsDidChange(_:)),
            name: .zeroflowFinderNewFileDidChange,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    private func updateDirectoryURLs() {
        // 仅用户目录（含桌面），满足绝大多数右键场景且避免整盘监控拖慢访达；
        // 两个功能都关闭时清空，Finder 完全不监控，零开销。
        let on = FinderSyncSharedDefaults.isEnabled() || FinderSyncSharedDefaults.cmdEnabled()
        let urls: Set<URL> = on ? [FinderSyncSharedDefaults.userHome] : []
        os_log("updateDirectoryURLs enabled=%{public}@ cmd=%{public}@ dirs=%{public}@",
               log: finderSyncLog, type: .info, String(FinderSyncSharedDefaults.isEnabled()),
               String(FinderSyncSharedDefaults.cmdEnabled()), String(describing: urls))
        FIFinderSyncController.default().directoryURLs = urls
    }

    @objc private func settingsDidChange(_ note: Notification) {
        updateDirectoryURLs()
    }

    // MARK: - 菜单

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let newFileEnabled = FinderSyncSharedDefaults.isEnabled()
        let cmdEnabled = FinderSyncSharedDefaults.cmdEnabled()
        os_log("menu(for:) called newFile=%{public}@ cmd=%{public}@ kind=%d",
               log: finderSyncLog, type: .info, String(newFileEnabled), String(cmdEnabled), menuKind.rawValue)
        guard newFileEnabled || cmdEnabled else { return nil }

        let menu = NSMenu(title: "")

        if newFileEnabled, targetDirectory() != nil {
            let item = NSMenuItem(
                title: FinderSyncMenuStrings.newFileTitle,
                action: #selector(createFile(_:)),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
        }

        // 自定义命令：命令里带 {path} 才需要目标目录，纯命令任何时候都能执行
        if cmdEnabled {
            let command = FinderSyncSharedDefaults.cmdCommand()
            let needsTarget = command.contains("{path}")
            if !command.isEmpty, (!needsTarget || targetDirectory() != nil) {
                let item = NSMenuItem(
                    title: FinderSyncMenuStrings.customCommandTitle,
                    action: #selector(runCustomCommand(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                menu.addItem(item)
            }
        }

        guard !menu.items.isEmpty else { return nil }
        return menu
    }

    /// 确定创建文件/替换 {path} 的目标目录：
    /// - 右键选中的文件夹 → 该文件夹本身
    /// - 右键选中的普通文件 → 其父目录
    /// - 无选中项（右键窗口/桌面空白处）→ targetedURL 即该目录
    /// 注意：必须先查 selectedItemURLs 再查 targetedURL——右键选中的文件夹时，
    /// targetedURL 返回的是窗口当前所在目录（也是目录），先查它会把选中的
    /// 文件夹完全吞掉，导致 {path} 恒为窗口目录而非右键目标。
    private func targetDirectory() -> URL? {
        let controller = FIFinderSyncController.default()
        for url in [controller.selectedItemURLs()?.first, controller.targetedURL()].compactMap({ $0 }) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                return isDirectory.boolValue ? url : url.deletingLastPathComponent()
            }
        }
        return nil
    }

    // MARK: - 创建

    @objc private func createFile(_ sender: Any?) {
        // Finder 通过 XPC 序列化菜单项时不会保留 NSMenuItem 的 representedObject，
        // 因此不能依赖 sender 携带目录；右键目标此刻仍有效，直接重新推导。
        guard let directory = targetDirectory() else {
            os_log("createFile: targetDirectory() == nil", log: finderSyncLog, type: .error)
            return
        }
        guard let url = NewFileMaker.create(in: directory, baseName: FinderSyncSharedDefaults.fileName()) else {
            os_log("createFile: FAILED in %@", log: finderSyncLog, type: .error, directory.path)
            NSLog("FinderSync: 创建文件失败 in %@", directory.path)
            return
        }
        os_log("createFile: OK -> %@", log: finderSyncLog, type: .info, url.path)
        // 创建后在访达中选中新文件
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - 自定义命令

    @objc private func runCustomCommand(_ sender: Any?) {
        let command = FinderSyncSharedDefaults.cmdCommand()
        guard !command.isEmpty else {
            os_log("runCustomCommand: command is empty", log: finderSyncLog, type: .error)
            return
        }
        // 命令带 {path} 时才需要目标目录；Finder 通过 XPC 序列化菜单项不保留
        // representedObject，目录必须在动作里用 targetedURL/selectedItemURLs 重新推导。
        var directory: URL?
        if command.contains("{path}") {
            guard let target = targetDirectory() else {
                os_log("runCustomCommand: {path} required but targetDirectory() == nil",
                       log: finderSyncLog, type: .error)
                return
            }
            directory = target
        }
        CustomCommandRunner.submit(command, directory: directory)
    }
}

/// 把命令请求转交给主 app 执行。
/// 扩展在沙盒里，其子进程会继承沙盒（终端/pty 类命令会拿到 EPERM 直接失败），
/// 所以不在扩展里跑命令：写入 App Group 容器的请求文件并广播分布式通知，
/// 由非沙盒的主 app 代为执行（见主 app 的 Services/FinderCommandRunner.swift）。
enum CustomCommandRunner {
    // 与主 app Services/FinderCommandRunner.swift 的常量保持一致
    static let requestNotificationName = "zeroflow.finderCommand.run"
    static let mainAppBundleID = "com.zeroflow.app"

    static func submit(_ template: String, directory: URL?) {
        let command: String
        if template.contains("{path}") {
            guard let directory else { return }
            // 纯文本替换；路径含空格时的引号由用户写在模板里（默认模板已带）
            command = template.replacingOccurrences(of: "{path}", with: directory.path)
        } else {
            command = template
        }

        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: FinderSyncSharedDefaults.suiteName) else {
            os_log("submit: no group container", log: finderSyncLog, type: .error)
            return
        }
        // 文件名自带毫秒时间戳，主 app 按字典序消费即时间序
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let fileURL = containerURL.appendingPathComponent(
            String(format: "%@%013d-%@.plist", "finder-command-", stamp, UUID().uuidString))
        let payload: [String: Any] = [
            "command": command,
            "directory": directory?.path ?? "",
            "createdAt": Double(stamp),
        ]
        guard (payload as NSDictionary).write(to: fileURL, atomically: true) else {
            os_log("submit: failed to write %@", log: finderSyncLog, type: .error, fileURL.path)
            return
        }
        os_log("submit: cmd=%{public}@ file=%{public}@", log: finderSyncLog, type: .info,
               command, fileURL.lastPathComponent)

        // 沙盒进程发分布式通知不能带 userInfo，载荷走文件
        DistributedNotificationCenter.default().post(
            name: Notification.Name(requestNotificationName), object: nil)
        wakeMainAppIfNeeded()
    }

    /// 主 app 没在跑时把它拉起来；启动后会主动消化待执行的请求文件
    private static func wakeMainAppIfNeeded() {
        let isRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == mainAppBundleID
        }
        guard !isRunning else { return }
        // Bundle.main 在扩展里是 .appex，向上两级即主 app bundle
        let appURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) {
            _, error in
            if let error {
                os_log("wakeMainApp failed: %{public}@", log: finderSyncLog, type: .error,
                       String(describing: error))
            }
        }
    }
}

/// 右键菜单文案，按共享语言设置取词
enum FinderSyncMenuStrings {
    static var newFileTitle: String {
        switch FinderSyncSharedDefaults.effectiveLanguage() {
        case "zh-Hans": return "新建空文件"
        case "ja": return "空の新規ファイル"
        default: return "New Empty File"
        }
    }

    /// 自定义命令的菜单名称：优先用用户配置值，为空时回退到本地化默认
    static var customCommandTitle: String {
        let configured = FinderSyncSharedDefaults.cmdTitle()
        if !configured.isEmpty { return configured }
        switch FinderSyncSharedDefaults.effectiveLanguage() {
        case "zh-Hans": return FinderSyncSharedDefaults.defaultCmdTitle
        case "ja": return "ターミナルを開く"
        default: return "Open Terminal"
        }
    }
}

enum NewFileMaker {
    /// 在指定目录创建空文件，文件名按「基础名 序号.扩展名」去重
    static func create(in directory: URL, baseName: String) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        guard let url = uniqueURL(in: directory, baseName: baseName) else { return nil }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
        return url
    }

    private static func uniqueURL(in directory: URL, baseName: String) -> URL? {
        let sanitized = baseName.replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: ":", with: "")
        guard !sanitized.isEmpty else { return nil }

        let nsName = sanitized as NSString
        let ext = nsName.pathExtension
        let stem = ext.isEmpty ? sanitized : String(nsName.deletingPathExtension)

        let fileManager = FileManager.default
        var candidate = directory.appendingPathComponent(sanitized)
        var index = 1
        while fileManager.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            candidate = directory.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }
}