import Foundation
import IOKit

/// 灵动岛「系统资源」模块的显示项
enum NotchResourceItem: String, CaseIterable, Identifiable {
    case cpu
    case memory
    case disk
    case network
    case gpu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return L10n.tr("内存")
        case .disk: return L10n.tr("磁盘")
        case .network: return L10n.tr("网络")
        case .gpu: return "GPU"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .network: return "network"
        case .gpu: return "gauge.with.needle"
        }
    }

    static let allRawValues = allCases.map(\.rawValue)
}

/// 一次采样结果;nil = 该项暂不可用(UI 显示「—」)
struct NotchResourceSample {
    var cpuPercent: Double?
    var memUsedBytes: Int64?
    var memTotalBytes: Int64?
    var diskReadBps: Int64?
    var diskWriteBps: Int64?
    var netDownBps: Int64?
    var netUpBps: Int64?
    var gpuPercent: Double?
}

/// 各资源项的近期采样序列,供面板迷你趋势图(磁盘/网络)使用;
/// 百分比项存 0–100,速率项存字节/秒(视图内按窗口内峰值归一化)
struct NotchResourceHistory {
    var cpu: [Double] = []
    var memory: [Double] = []
    var gpu: [Double] = []
    var disk: [Double] = []
    var network: [Double] = []
}

/// 灵动岛「系统资源」采样:CPU(host_processor_info)/内存(host_statistics64)/
/// 网络(sysctl NET_RT_IFLIST2)/磁盘(IOKit IOBlockStorageDriver 统计)/GPU(IOAccelerator
/// PerformanceStatistics)。全部免 root、无权限要求;仅面板可见期间采样,弹出时先建基线
/// 并在 0.4s 后快速补采,让速率项(CPU/磁盘/网络)首值不等固定 2s 间隔。
final class SystemResourceMonitor: ObservableObject {
    static let shared = SystemResourceMonitor()

    private static let debug = ProcessInfo.processInfo.environment["ZEROFLOW_NOTCH_DEBUG"] == "1"
    /// 采样间隔(s)
    private static let interval: TimeInterval = 2
    /// 弹出后快速补采间隔(s)：速率项需两次采样差值,若只等固定间隔首值要 2s 才出现;
    /// 建基线后 0.4s 先补采一次,之后由固定间隔接管
    private static let warmupDelay: TimeInterval = 0.4

    @Published private(set) var sample = NotchResourceSample()
    @Published private(set) var history = NotchResourceHistory()

    /// 历史序列容量(2s 采样间隔 → 约 1 分钟窗口)
    static let historyMaxPoints = 30

    private var timer: Timer?
    private var warmupTimer: Timer?
    private var busy = false
    private let queue = DispatchQueue(label: "zeroflow.notch.resources", qos: .utility)

    // 速率计算的上一帧(tap 之外仅后台采样线程读写,主线程只发起点)
    private var lastCPUTicks: (busy: Int, idle: Int)?
    private var lastDisk: (read: UInt64, write: UInt64, at: Date)?
    private var lastNet: [UInt32: (inBytes: Int64, outBytes: Int64)] = [:]
    private var lastNetAt: Date?

    private init() {}

    // MARK: - 生命周期

    /// 面板显示时开启采样、隐藏时停止;任意线程可调(内部回主线程)
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
            // 快速补采:首次 tick 只建基线(速率项返回 nil,UI 显示「—」),0.4s 后补采一次
            // 即得首个速率值;面板若已隐藏(timer == nil)则补采自动作废
            let w = Timer(timeInterval: Self.warmupDelay, repeats: false) { [weak self] _ in
                guard let self, self.timer != nil else { return }
                self.tick()
            }
            RunLoop.main.add(w, forMode: .common)
            warmupTimer = w
        } else {
            timer?.invalidate()
            timer = nil
            warmupTimer?.invalidate()
            warmupTimer = nil
            // 清基线,重新显示后重新累计速率(计数器可能被系统重置);趋势历史同步清空
            lastCPUTicks = nil
            lastDisk = nil
            lastNet = [:]
            lastNetAt = nil
            history = NotchResourceHistory()
        }
    }

    private func tick() {
        guard !busy else { return }
        busy = true
        queue.async { [weak self] in
            guard let self else { return }
            let s = self.collect()
            DispatchQueue.main.async {
                self.busy = false
                guard self.timer != nil else { return }
                self.sample = s
                self.appendHistory(s)
            }
        }
    }

    // MARK: - 采样(后台线程)

    /// 追加本次采样到历史序列(主线程)。某项本次不可用时沿用上一值,保持趋势线连续
    private func appendHistory(_ s: NotchResourceSample) {
        let memPercent: Double? = {
            guard let used = s.memUsedBytes, let total = s.memTotalBytes, total > 0 else { return nil }
            return Double(used) / Double(total) * 100
        }()
        let diskBps: Double? = (s.diskReadBps == nil && s.diskWriteBps == nil)
            ? nil : Double((s.diskReadBps ?? 0) + (s.diskWriteBps ?? 0))
        let netBps: Double? = (s.netDownBps == nil && s.netUpBps == nil)
            ? nil : Double((s.netDownBps ?? 0) + (s.netUpBps ?? 0))
        history = NotchResourceHistory(
            cpu: Self.push(history.cpu, s.cpuPercent),
            memory: Self.push(history.memory, memPercent),
            gpu: Self.push(history.gpu, s.gpuPercent),
            disk: Self.push(history.disk, diskBps),
            network: Self.push(history.network, netBps)
        )
    }

    private static func push(_ array: [Double], _ value: Double?) -> [Double] {
        var array = array
        array.append(value ?? array.last ?? 0)
        if array.count > historyMaxPoints { array.removeFirst(array.count - historyMaxPoints) }
        return array
    }

    private func collect() -> NotchResourceSample {
        var s = NotchResourceSample()
        s.cpuPercent = cpuPercent()
        if let mem = memoryUsage() {
            s.memUsedBytes = mem.used
            s.memTotalBytes = mem.total
        }
        if let disk = diskRates() {
            s.diskReadBps = disk.read
            s.diskWriteBps = disk.write
        }
        if let net = netRates() {
            s.netDownBps = net.down
            s.netUpBps = net.up
        }
        s.gpuPercent = gpuPercent()
        if Self.debug {
            ZSLog("Resources: cpu=\(fmt(s.cpuPercent))% mem=\(fmtBytes(s.memUsedBytes))/\(fmtBytes(s.memTotalBytes)) disk=\(fmtBytes(s.diskReadBps))/s,\(fmtBytes(s.diskWriteBps))/s net=\(fmtBytes(s.netDownBps))/s,\(fmtBytes(s.netUpBps))/s gpu=\(fmt(s.gpuPercent))%")
        }
        return s
    }

    private func fmt(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "nil" }
    private func fmtBytes(_ v: Int64?) -> String {
        guard let v else { return "nil" }
        let bps = Double(v)
        if bps < 1024 { return "\(Int(bps))B" }
        if bps < 1_048_576 { return String(format: "%.1fKB", bps / 1024) }
        return String(format: "%.1fMB", bps / 1_048_576)
    }

    /// CPU 总占用:两次采样的 busy/idle ticks 差值;首次无基线返回 nil
    private func cpuPercent() -> Double? {
        var count: natural_t = 0
        var loads: processor_info_array_t?
        var msgCount: mach_msg_type_number_t = 0
        let port = mach_host_self()
        defer { _ = mach_port_deallocate(mach_task_self_, port) }
        guard host_processor_info(port, PROCESSOR_CPU_LOAD_INFO, &count, &loads, &msgCount) == KERN_SUCCESS,
              let loads, count > 0 else { return nil }

        var busy = 0
        var idle = 0
        for i in 0..<Int(count) {
            let base = i * Int(CPU_STATE_MAX)
            busy += Int(loads[base + Int(CPU_STATE_USER)])
                + Int(loads[base + Int(CPU_STATE_SYSTEM)])
                + Int(loads[base + Int(CPU_STATE_NICE)])
            idle += Int(loads[base + Int(CPU_STATE_IDLE)])
        }
        let stride = vm_size_t(MemoryLayout<integer_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: loads)), stride * vm_size_t(msgCount))

        guard let last = lastCPUTicks else {
            lastCPUTicks = (busy, idle)
            return nil
        }
        lastCPUTicks = (busy, idle)
        let deltaBusy = busy - last.busy
        let deltaIdle = idle - last.idle
        let total = deltaBusy + deltaIdle
        guard total > 0 else { return nil }
        return min(100, max(0, Double(deltaBusy) / Double(total) * 100))
    }

    /// 内存已用/总量,口径对齐活动监视器(App + Wired + Compressed)
    private func memoryUsage() -> (used: Int64, total: Int64)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let port = mach_host_self()
        defer { _ = mach_port_deallocate(mach_task_self_, port) }
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(port, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        let pageSize = UInt64(vm_kernel_page_size)
        let pages = { (n: natural_t) -> Int64 in Int64(UInt64(n) * pageSize) }
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        let used = pages(stats.active_count) + pages(stats.inactive_count) + pages(stats.speculative_count)
            + pages(stats.wire_count) + pages(stats.compressor_page_count)
            - pages(stats.purgeable_count) - pages(stats.external_page_count)
        return (max(0, min(used, total)), total)
    }

    /// 磁盘吞吐:IOBlockStorageDriver 注册表的读写字节计数差值
    private func diskRates() -> (read: Int64, write: Int64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0
        var found = false
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let prop = IORegistryEntryCreateCFProperty(service, Self.diskStatsKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            if let read = Self.u64(prop[Self.diskReadKey]) { totalRead += read; found = true }
            if let write = Self.u64(prop[Self.diskWriteKey]) { totalWrite += write; found = true }
        }
        guard found else { return nil }

        let now = Date()
        defer { lastDisk = (totalRead, totalWrite, now) }
        guard let last = lastDisk else { return nil }
        let elapsed = now.timeIntervalSince(last.at)
        guard elapsed > 0.1 else { return nil }
        // 计数器被重置(睡眠等)时放弃本轮
        guard totalRead >= last.read, totalWrite >= last.write else { return nil }
        let read = Double(totalRead - last.read) / elapsed
        let write = Double(totalWrite - last.write) / elapsed
        return (Int64(clamping: Int(read)), Int64(clamping: Int(write)))
    }

    /// 网络吞吐:NET_RT_IFLIST2 各非 loopback 接口的字节计数差值(逐接口防新接口突刺)
    private func netRates() -> (down: Int64, up: Int64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len: size_t = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return nil }

        var seen: [UInt32: (inBytes: Int64, outBytes: Int64)] = [:]
        buf.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let msgLen = Int(hdr.ifm_msglen)
                guard msgLen > 0, offset + msgLen <= len else { break }
                if hdr.ifm_type == RTM_IFINFO2 {
                    let msg = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if msg.ifm_data.ifi_type != UInt32(IFT_LOOP) {
                        seen[UInt32(msg.ifm_index)] = (Int64(bitPattern: msg.ifm_data.ifi_ibytes), Int64(bitPattern: msg.ifm_data.ifi_obytes))
                    }
                }
                offset += msgLen
            }
        }
        guard !seen.isEmpty else { return nil }

        let now = Date()
        defer {
            lastNet = seen
            lastNetAt = now
        }
        guard let lastAt = lastNetAt, !lastNet.isEmpty else { return nil }
        let elapsed = now.timeIntervalSince(lastAt)
        guard elapsed > 0.1 else { return nil }
        var down: Int64 = 0
        var up: Int64 = 0
        for (idx, cur) in seen {
            guard let prev = lastNet[idx] else { continue }
            let din = cur.inBytes - prev.inBytes
            let dout = cur.outBytes - prev.outBytes
            if din > 0 { down += din }
            if dout > 0 { up += dout }
        }
        return (Int64(Double(down) / elapsed), Int64(Double(up) / elapsed))
    }

    /// GPU 占用:IOAccelerator 的 PerformanceStatistics 瞬时利用率
    private func gpuPercent() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let props = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            let values = ["Device Utilization %", "GPU Activity(%)"].compactMap { key -> Double? in
                (props[key] as? Double).map { min(100, max(0, $0)) }
            }
            if let v = values.first {
                best = max(best ?? 0, v)
            }
        }
        return best
    }

    /// IOKit 计数器经 NSNumber.stringValue 转 UInt64(兼容 128 位值)
    private static func u64(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber else { return nil }
        return UInt64(number.stringValue)
    }

    /// IOBlockStorageDriver.h 的统计键(Swift 未导入这些 C 宏,直接给字符串值)
    private static let diskStatsKey = "Statistics"
    private static let diskReadKey = "Bytes (Read)"
    private static let diskWriteKey = "Bytes (Write)"

    // MARK: - 展示格式化(供视图共用)

    static func formatBps(_ v: Int64?) -> String {
        guard let v else { return "—" }
        let bps = Double(v)
        if bps < 1024 { return "\(Int(bps)) B/s" }
        if bps < 1_048_576 { return String(format: "%.1f KB/s", bps / 1024) }
        if bps < 1_073_741_824 { return String(format: "%.1f MB/s", bps / 1_048_576) }
        return String(format: "%.2f GB/s", bps / 1_073_741_824)
    }

    static func formatBytes(_ v: Int64) -> String {
        let gb = Double(v) / 1_073_741_824
        if gb >= 10 { return String(format: "%.0f GB", gb) }
        return String(format: "%.1f GB", gb)
    }
}
