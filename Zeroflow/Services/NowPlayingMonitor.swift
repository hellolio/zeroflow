import Foundation
import AppKit

/// 「正在播放」模块的一条当前播放信息
struct NowPlayingInfo {
    let title: String
    let artist: String?
    let album: String?
    let appBundleID: String?
    let appName: String?
    let isPlaying: Bool
    let elapsed: Double?
    let duration: Double?
}

/// 灵动岛「正在播放」:轮询 MediaRemote 私有框架。
/// 读取优先进程内 MRNowPlayingRequest 类属性(macOS 15.4+ 后唯一未封的读取路径,
/// 对无自动化授权的进程开放;已实测);类不可用时降级 osascript JXA 子进程。
/// 播放控制走 MRMediaRemoteSendCommand(dlsym)。
final class NowPlayingMonitor: ObservableObject {
    static let shared = NowPlayingMonitor()

    private static let debug = ProcessInfo.processInfo.environment["ZEROFLOW_NOTCH_DEBUG"] == "1"
    /// 轮询间隔(s)
    private static let interval: TimeInterval = 2
    /// 连续多少次读不到内容后才清空展示(避免瞬时失败闪空)
    private static let staleLimit = 3

    enum Command: UInt {
        case togglePlay = 2
        case next = 4
        case previous = 5
    }

    @Published private(set) var nowPlaying: NowPlayingInfo?
    /// 播放控制是否可用(MRMediaRemoteSendCommand 符号是否找到)
    private(set) var controlsAvailable = false

    private var timer: Timer?
    private var inFlight = false
    private var staleCount = 0
    private let queue = DispatchQueue(label: "zeroflow.notch.nowplaying", qos: .utility)

    /// MRNowPlayingRequest 类;加载失败则降级子进程
    private static let requestClass: AnyObject? = {
        let bundle = Bundle(path: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        guard let bundle, bundle.load() else { return nil }
        return NSClassFromString("MRNowPlayingRequest") as AnyObject?
    }()

    private var useSubprocess: Bool

    private typealias SendCommandFn = @convention(c) (UInt, AnyObject, DispatchQueue, AnyObject?) -> Void
    private var sendCommandFn: SendCommandFn?
    private static let dummyTarget = NSObject()

    private init() {
        useSubprocess = Self.requestClass == nil
        if let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
           let sym = dlsym(handle, "MRMediaRemoteSendCommand") {
            sendCommandFn = unsafeBitCast(sym, to: SendCommandFn.self)
        }
        controlsAvailable = sendCommandFn != nil
        if Self.debug {
            ZSLog("NowPlaying: inProcess=\(!useSubprocess) sendCommand=\(controlsAvailable)")
        }
    }

    // MARK: - 生命周期

    /// 面板显示时开始轮询、隐藏时停止;任意线程可调
    func setActive(_ active: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.setActiveOnMain(active)
        }
    }

    private func setActiveOnMain(_ active: Bool) {
        if active {
            guard timer == nil else { return }
            let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
                self?.tick()
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            tick()
        } else {
            timer?.invalidate()
            timer = nil
            nowPlaying = nil
            staleCount = 0
        }
    }

    private func tick() {
        guard !inFlight else { return }
        inFlight = true
        queue.async { [weak self] in
            guard let self else { return }
            let info = self.useSubprocess ? self.readViaSubprocess() : self.readInProcess()
            DispatchQueue.main.async {
                self.inFlight = false
                guard self.timer != nil else { return }
                if let info {
                    self.nowPlaying = info
                    self.staleCount = 0
                } else if self.nowPlaying != nil {
                    self.staleCount += 1
                    if self.staleCount >= Self.staleLimit {
                        self.nowPlaying = nil
                        self.staleCount = 0
                    }
                }
            }
        }
    }

    // MARK: - 发送播放控制

    func send(_ command: Command) {
        guard let fn = sendCommandFn else { return }
        fn(command.rawValue, Self.requestClass ?? Self.dummyTarget, DispatchQueue.main, nil)
        if Self.debug { ZSLog("NowPlaying: sent \(command)") }
        // 发送后短暂延迟重查,让 UI 及时反映状态
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.tick()
        }
    }

    // MARK: - 读取:进程内 MRNowPlayingRequest

    private func readInProcess() -> NowPlayingInfo? {
        guard let cls = Self.requestClass else { return nil }
        guard cls.responds(to: Selector(("localNowPlayingItem"))) else { return nil }
        guard let item = cls.value(forKey: "localNowPlayingItem") as? NSObject else { return nil }
        guard item.responds(to: Selector(("nowPlayingInfo"))),
              let info = item.value(forKey: "nowPlayingInfo") as? [String: Any] else { return nil }
        guard let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String, !title.isEmpty else { return nil }

        var appName: String?
        var appBundleID: String?
        if cls.responds(to: Selector(("localNowPlayingPlayerPath"))),
           let path = cls.value(forKey: "localNowPlayingPlayerPath") as? NSObject,
           path.responds(to: Selector(("client"))),
           let client = path.value(forKey: "client") as? NSObject {
            if client.responds(to: Selector(("displayName"))) {
                appName = client.value(forKey: "displayName") as? String
            }
            if client.responds(to: Selector(("bundleIdentifier"))) {
                appBundleID = client.value(forKey: "bundleIdentifier") as? String
            }
        }
        if appName == nil, let bid = appBundleID {
            appName = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bid }?.localizedName
        }

        let rate = double(info, "kMRMediaRemoteNowPlayingInfoPlaybackRate")
        let isPlaying = rate.map { $0 != 0 } ?? true
        return NowPlayingInfo(
            title: title,
            artist: string(info, "kMRMediaRemoteNowPlayingInfoArtist"),
            album: string(info, "kMRMediaRemoteNowPlayingInfoAlbum"),
            appBundleID: appBundleID,
            appName: appName,
            isPlaying: isPlaying,
            elapsed: double(info, "kMRMediaRemoteNowPlayingInfoElapsedTime"),
            duration: double(info, "kMRMediaRemoteNowPlayingInfoDuration")
        )
    }

    private func string(_ info: [String: Any], _ key: String) -> String? {
        (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private func double(_ info: [String: Any], _ key: String) -> Double? {
        (info[key] as? NSNumber)?.doubleValue
    }

    // MARK: - 读取:osascript JXA 子进程(降级路径)

    private func readViaSubprocess() -> NowPlayingInfo? {
        guard let out = Self.runJXA() else { return nil }
        let parts = out.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\u{241F}", omittingEmptySubsequences: false)
        guard parts.count >= 8, !parts[0].isEmpty, parts[0] != "NOCLASS", parts[0] != "NOITEM" else { return nil }
        let num = { (s: Substring) -> Double? in
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : Double(t)
        }
        return NowPlayingInfo(
            title: String(parts[0]),
            artist: parts[1].isEmpty ? nil : String(parts[1]),
            album: parts[2].isEmpty ? nil : String(parts[2]),
            appBundleID: parts[3].isEmpty ? nil : String(parts[3]),
            appName: parts[4].isEmpty ? nil : String(parts[4]),
            isPlaying: num(parts[7]).map { $0 != 0 } ?? true,
            elapsed: num(parts[6]),
            duration: num(parts[5])
        )
    }

    private static func runJXA() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-l", "JavaScript", "-e", jxaScript]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        // 看门狗:4s 未返回则终止,避免卡住轮询队列
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
            if p.isRunning { p.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            if debug { ZSLog("NowPlaying: osascript exit=\(p.terminationStatus)") }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static let jxaScript = """
    ObjC.import('Foundation');
    function run() {
      var b = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework');
      if (b.isNil()) return '';
      var loaded = b.load;
      var cls = $.NSClassFromString('MRNowPlayingRequest');
      if (cls.isNil()) return 'NOCLASS';
      var item = cls.localNowPlayingItem;
      if (item.isNil()) return 'NOITEM';
      var info = item.nowPlayingInfo;
      if (info.isNil()) return 'NOINFO';
      var t = info.valueForKey('kMRMediaRemoteNowPlayingInfoTitle');
      if (t.isNil() || !t.js.length) return '';
      var app = '', bid = '';
      try {
        var c = cls.localNowPlayingPlayerPath.client;
        app = c.displayName && !c.displayName.isNil() ? c.displayName.js : '';
        bid = c.bundleIdentifier && !c.bundleIdentifier.isNil() ? c.bundleIdentifier.js : '';
      } catch (e) {}
      function s(v) { return (v && !v.isNil() && typeof v.js !== 'undefined') ? String(v.js) : ''; }
      return [t.js, s(info.valueForKey('kMRMediaRemoteNowPlayingInfoArtist')), s(info.valueForKey('kMRMediaRemoteNowPlayingInfoAlbum')), bid, app, s(info.valueForKey('kMRMediaRemoteNowPlayingInfoDuration')), s(info.valueForKey('kMRMediaRemoteNowPlayingInfoElapsedTime')), s(info.valueForKey('kMRMediaRemoteNowPlayingInfoPlaybackRate'))].join('␟');
    }
    """
}
