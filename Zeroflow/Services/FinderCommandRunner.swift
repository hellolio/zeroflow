import AppKit
import Foundation

/// 执行 Finder 扩展转交过来的「访达自定义命令」。
///
/// 扩展是沙盒进程，其子进程会继承沙盒（终端/pty 类命令会直接 EPERM 失败，
/// 例如 `wezterm start` 拉起的 GUI 无法为 pane 创建 pty），所以扩展不在本地执行：
/// 它把请求写进 App Group 容器的 `finder-command-*.plist` 并广播分布式通知，
/// 由**非沙盒**的主 app 代为执行，行为与用户在终端里手动运行完全一致。
final class FinderCommandRunner {
    static let shared = FinderCommandRunner()
    private init() {}

    // 与 FinderSyncExtension/FinderSync.swift 的 CustomCommandRunner 常量保持一致
    private static let requestNotificationName = "zeroflow.finderCommand.run"
    private static let filePrefix = "finder-command-"
    /// 超过该时长的请求视为陈旧丢弃（主 app 没在跑时积累的请求不补执行）
    private static let requestTTLSeconds = 30.0
    private static let groupSuite = "8NHN73Q43T.com.zeroflow.app"

    /// 主 app 启动时调用一次；注册通知 + 消化积压请求
    func start() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(requestsDidChange),
            name: Notification.Name(Self.requestNotificationName),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        processPendingRequests()
    }

    @objc private func requestsDidChange() {
        processPendingRequests()
    }

    // MARK: - 消化请求

    private func processPendingRequests() {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.groupSuite),
            let files = try? FileManager.default.contentsOfDirectory(
                at: containerURL, includingPropertiesForKeys: nil)
        else { return }

        // 文件名自带毫秒时间戳，字典序即时间序
        let requests = files
            .filter { $0.lastPathComponent.hasPrefix(Self.filePrefix) && $0.pathExtension == "plist" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for fileURL in requests {
            defer { try? FileManager.default.removeItem(at: fileURL) }
            guard let data = try? Data(contentsOf: fileURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let dict = plist as? [String: Any],
                  let command = dict["command"] as? String, !command.isEmpty else {
                ZSLog("finderCommand: unreadable request \(fileURL.lastPathComponent), dropped")
                continue
            }
            let createdAt = dict["createdAt"] as? Double ?? 0
            let age = Date().timeIntervalSince1970 * 1000 - createdAt
            guard age < Self.requestTTLSeconds * 1000 else {
                ZSLog("finderCommand: stale request \(fileURL.lastPathComponent) (\(Int(age))ms), dropped")
                continue
            }
            run(command: command)
        }
    }

    // MARK: - 执行

    private let lock = NSLock()
    // Process 在运行中被释放会崩，终止前先持有
    private var running: [Process] = []

    private func run(command: String) {
        let shell = userShell()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -l 加载登录环境（/etc/zprofile、~/.zprofile），让 PATH 含 /opt/homebrew/bin 等
        process.arguments = ["-l", "-c", command]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            ZSLog("finderCommand: failed to run \(command), error=\(error)")
            return
        }
        ZSLog("finderCommand: shell=\(shell) cmd=\(command)")

        lock.lock()
        running.append(process)
        lock.unlock()
        process.terminationHandler = { [weak self] finished in
            ZSLog("finderCommand: exited \(finished.terminationStatus)")
            guard let self else { return }
            self.lock.lock()
            self.running.removeAll { $0 === finished }
            self.lock.unlock()
        }
    }

    /// 用户默认 shell；取不到时退回 zsh（macOS 默认）
    private func userShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let value = String(cString: shell)
            if !value.isEmpty { return value }
        }
        return "/bin/zsh"
    }
}
