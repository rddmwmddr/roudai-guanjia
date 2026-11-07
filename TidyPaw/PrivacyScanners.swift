import Foundation
import AppKit
import IOKit
import Darwin

// MARK: - 电池健康

struct BatteryInfo: Sendable {
    let cycleCount: Int
    let healthPercent: Int     // 满电容量 / 设计容量，和「系统设置 › 电池 › 最大容量」同一口径
    let maxCapacity: Int       // mAh
    let designCapacity: Int    // mAh
    let charge: Int            // 当前电量 %
    let charging: Bool
    let acConnected: Bool

    var condition: String {
        if healthPercent >= 80 { return "正常" }
        if healthPercent >= 60 { return "建议更换" }
        return "建议尽快更换"
    }
}

enum BatteryReading: Sendable {
    case noBattery      // 台式机
    case unreadable     // 有电池，但系统没给出健康数据
    case info(BatteryInfo)
}

enum BatteryReader {
    /// 直接读 IOKit 注册表，类型化取值，避免 ioreg 文本解析误匹配嵌套字典
    static func read() -> BatteryReading {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return .noBattery }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = propsRef?.takeRetainedValue() as? [String: Any] else { return .unreadable }

        return parse(dict).map(BatteryReading.info) ?? .unreadable
    }

    /// 较新的系统把 DesignCapacity 等键挪进了 BatteryData 子字典，两处都要找。
    static func parse(_ dict: [String: Any]) -> BatteryInfo? {
        let nested = dict["BatteryData"] as? [String: Any]
        func i(_ k: String) -> Int? {
            (dict[k] as? NSNumber)?.intValue ?? (nested?[k] as? NSNumber)?.intValue
        }
        func b(_ k: String) -> Bool { (dict[k] as? Bool) ?? ((dict[k] as? NSNumber)?.boolValue ?? false) }

        guard let design = i("DesignCapacity"), design > 0 else { return nil }

        // MaxCapacity 在 Apple 芯片上是百分比（100），在 Intel 上是 mAh，要分开理解
        let reportedMax = (dict["MaxCapacity"] as? NSNumber)?.intValue
        let maxIsMilliampHours = (reportedMax ?? 0) > 100

        // NominalChargeCapacity 才是系统「最大容量」用的那个值；AppleRawMaxCapacity 是瞬时估算，会偏低
        let fullCharge = i("NominalChargeCapacity")
            ?? i("AppleRawMaxCapacity")
            ?? (maxIsMilliampHours ? reportedMax : nil)
            ?? design

        var charge = (dict["CurrentCapacity"] as? NSNumber)?.intValue ?? 0
        if maxIsMilliampHours, let reportedMax {
            charge = Int((Double(charge) / Double(reportedMax) * 100).rounded())
        }

        let health = min(100, Int((Double(fullCharge) / Double(design) * 100).rounded()))
        return BatteryInfo(cycleCount: i("CycleCount") ?? 0, healthPercent: health,
                           maxCapacity: fullCharge, designCapacity: design,
                           charge: min(max(charge, 0), 100),
                           charging: b("IsCharging"), acConnected: b("ExternalConnected"))
    }
}

// MARK: - 进程名

/// 把进程归到它所属的 App 名下，helper 和主程序算一个 App。
/// 每次统计新建一个实例：内部缓存 App 路径 → 显示名，同一个 App 的几十个 helper 只读一次 Info.plist。
final class ProcessNames {
    private var appNames: [String: String] = [:]

    /// 能确定身份时返回名字；确定不了（进程已退出或拿不到路径）返回 nil。
    func resolve(pid: pid_t) -> String? {
        let path = Self.executablePath(pid: pid)
        if let path, let app = Self.outermostApp(in: path) { return appName(atPath: app) }
        // 不在 .app 里的进程：系统 XPC 服务有本地化名字，命令行工具和守护进程用文件名
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName, !name.isEmpty { return name }
        return path.map { ($0 as NSString).lastPathComponent }
    }

    /// 真实路径。不用 ps：它会把中文路径转义成 M-eM-^_ 这样的乱码，还要多开一个进程。
    static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)   // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// 最外层的 .app：Chrome.app/…/Chrome Helper.app/… 算 Chrome.app。
    static func outermostApp(in path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    private func appName(atPath path: String) -> String {
        if let cached = appNames[path] { return cached }
        let bundle = Bundle(path: path)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        appNames[path] = name
        return name
    }
}

// MARK: - 网络上传（谁在偷偷上传数据）

struct NetProc: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let bytesOut: Int64    // 上传
    let bytesIn: Int64     // 下载
}

enum NetworkScanner {
    /// 累计自进程启动以来的上传字节，按上传降序取前 N（聚合掉同名 helper 进程）
    static func topUploaders(limit: Int = 40) -> [NetProc] {
        let out = runCommand("/usr/bin/nettop", ["-P", "-x", "-t", "external", "-L", "1", "-J", "bytes_in,bytes_out"])
        guard !out.isEmpty else { return [] }
        let names = ProcessNames()

        var agg: [String: (out: Int64, inn: Int64, name: String)] = [:]
        for line in out.split(separator: "\n") {
            let cols = line.components(separatedBy: ",")
            guard cols.count >= 3 else { continue }
            let nameField = cols[0]
            guard let dot = nameField.lastIndex(of: "."),
                  let pid = Int(nameField[nameField.index(after: dot)...]) else { continue }
            let bIn = Int64(cols[1]) ?? 0
            let bOut = Int64(cols[2]) ?? 0
            if bIn == 0 && bOut == 0 { continue }
            let truncName = String(nameField[..<dot])
            let resolved = names.resolve(pid: pid_t(pid))
            // 解析出真实名的按名聚合（合并 helper）；没解析出的按 pid 区分，避免被截断同名误合并
            let key = resolved ?? "\(truncName).\(pid)"
            var e = agg[key] ?? (0, 0, resolved ?? truncName)
            e.out += bOut; e.inn += bIn
            agg[key] = e
        }
        return agg.values.map { NetProc(name: $0.name, bytesOut: $0.out, bytesIn: $0.inn) }
            .sorted { $0.bytesOut > $1.bytesOut }
            .prefix(limit).map { $0 }
    }
}

// MARK: - 开机自启 / 常驻后台（抓第三方持久化）

struct PersistItem: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let kind: String
    let path: String
}

enum PersistenceScanner {
    static func scan() -> [PersistItem] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let dirs: [(URL, String)] = [
            (home.appendingPathComponent("Library/LaunchAgents"), "用户级后台项"),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), "系统级后台项"),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), "系统级守护进程"),
        ]
        var items: [PersistItem] = []
        for (dir, kind) in dirs {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files where f.pathExtension == "plist" {
                let label = f.deletingPathExtension().lastPathComponent
                if label.hasPrefix("com.apple.") { continue }   // 只看第三方（流氓软件重灾区）
                items.append(PersistItem(name: label, kind: kind, path: f.path))
            }
        }
        return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - 磁盘后台读写（谁在后台大量扫描/读取磁盘）

struct DiskProc: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let bytesRead: Int64
    let bytesWritten: Int64
}

enum DiskIOScanner {
    /// 各进程自启动以来累计的磁盘读/写字节，按读取量降序取前 N。
    /// 读取异常大的进程往往在后台扫描整盘文件（索引、上传前打包、"全盘体检"等）。
    static func topReaders(limit: Int = 40) -> [DiskProc] {
        let pids = allPIDs()
        guard !pids.isEmpty else { return [] }
        let names = ProcessNames()

        var agg: [String: (read: Int64, write: Int64, name: String)] = [:]
        for pid in pids {
            guard pid > 0, let io = diskBytes(pid), io.read > 0 || io.write > 0 else { continue }
            let resolved = names.resolve(pid: pid)
            // 解析出真实名按名聚合（合并 helper 进程）；否则按 pid 区分
            let key = resolved ?? "PID \(pid)"
            var e = agg[key] ?? (0, 0, key)
            e.read += Int64(bitPattern: io.read)
            e.write += Int64(bitPattern: io.write)
            agg[key] = e
        }
        return agg.values.map { DiskProc(name: $0.name, bytesRead: $0.read, bytesWritten: $0.write) }
            .sorted { $0.bytesRead > $1.bytesRead }
            .prefix(limit).map { $0 }
    }

    /// 列出当前所有进程 pid（含守护进程；无 root 时对他人进程的 rusage 会被拒，自动跳过）
    static func allPIDs() -> [pid_t] {
        // proc_listallpids 返回的是进程**个数**，不是字节数
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(estimate) + 64)   // 留余量：两次调用之间可能有新进程
        let count = buffer.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return Array(buffer.prefix(min(Int(count), buffer.count)))
    }

    private static func diskBytes(_ pid: pid_t) -> (read: UInt64, write: UInt64)? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reb in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, reb)
            }
        }
        guard rc == 0 else { return nil }   // EPERM（他人进程）/ ESRCH（已退出）→ 跳过
        return (info.ri_diskio_bytesread, info.ri_diskio_byteswritten)
    }
}

// MARK: - 蓝牙设备

struct BTDevice: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let connected: Bool
    let type: String?
}

enum BluetoothScanner {
    /// powered 为 nil 表示读不到状态，不等于蓝牙已关闭。
    static func scan() -> (powered: Bool?, devices: [BTDevice]) {
        let out = runCommand("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"])
        guard let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["SPBluetoothDataType"] as? [[String: Any]],
              let root = arr.first else { return (nil, []) }

        var powered: Bool?
        if let ctrl = root["controller_properties"] as? [String: Any],
           let state = ctrl["controller_state"] as? String {
            powered = state.lowercased().hasSuffix("_on")   // attrib_on / attrib_off
        }

        var devices: [BTDevice] = []
        func parse(_ key: String, connected: Bool) {
            guard let list = root[key] as? [[String: Any]] else { return }
            for entry in list {
                for (name, props) in entry {
                    let p = props as? [String: Any]
                    devices.append(BTDevice(name: name, connected: connected,
                                            type: p?["device_minorType"] as? String))
                }
            }
        }
        parse("device_connected", connected: true)
        parse("device_not_connected", connected: false)
        return (powered, devices)
    }
}
