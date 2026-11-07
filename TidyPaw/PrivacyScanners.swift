import Foundation
import AppKit
import IOKit
import Darwin

// MARK: - 执行命令的小工具（非沙盒构建下可 spawn 系统命令）

func runCommand(_ path: String, _ args: [String], timeout: TimeInterval = 12) -> String {
    guard FileManager.default.isExecutableFile(atPath: path) else { return "" }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    // 看门狗：超时就杀掉，避免 nettop 这类流式命令永不退出把任务卡死
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now() + timeout)
    timer.setEventHandler { if p.isRunning { p.terminate() } }
    timer.resume()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    timer.cancel()
    return String(decoding: data, as: UTF8.self)
}

// MARK: - 电池健康

struct BatteryInfo: Sendable {
    let cycleCount: Int
    let healthPercent: Int     // AppleRawMaxCapacity / DesignCapacity
    let maxCapacity: Int       // mAh
    let designCapacity: Int    // mAh
    let charge: Int            // 当前电量 %
    let charging: Bool
    let acConnected: Bool

    var condition: String {
        if healthPercent >= 80 { return "正常" }
        if healthPercent >= 60 { return "建议尽快更换" }
        return "建议更换"
    }
}

enum BatteryReader {
    /// 直接读 IOKit 注册表，类型化取值，避免 ioreg 文本解析误匹配嵌套字典
    static func read() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }   // 台式机/无电池
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = propsRef?.takeRetainedValue() as? [String: Any] else { return nil }

        func i(_ k: String) -> Int? { (dict[k] as? NSNumber)?.intValue }
        func b(_ k: String) -> Bool { (dict[k] as? Bool) ?? ((dict[k] as? NSNumber)?.boolValue ?? false) }

        guard let design = i("DesignCapacity"), design > 0 else { return nil }
        let rawMax = i("AppleRawMaxCapacity") ?? design
        var charge = i("CurrentCapacity") ?? 0
        if charge > 100, rawMax > 0 { charge = Int(Double(charge) / Double(rawMax) * 100) }  // Intel 上是 mAh
        let health = min(100, Int((Double(rawMax) / Double(design) * 100).rounded()))
        return BatteryInfo(cycleCount: i("CycleCount") ?? 0, healthPercent: health,
                           maxCapacity: rawMax, designCapacity: design, charge: charge,
                           charging: b("IsCharging"), acConnected: b("ExternalConnected"))
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
        let pidPath = psPathMap()

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
            let resolved = appName(forPID: pid, path: pidPath[pid])
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

    /// pid → 可执行文件完整路径
    private static func psPathMap() -> [Int: String] {
        let out = runCommand("/bin/ps", ["-ax", "-o", "pid=,comm="])
        var map: [Int: String] = [:]
        for line in out.split(separator: "\n") {
            let t = line.drop { $0 == " " }
            guard let sp = t.firstIndex(of: " ") else { continue }
            if let pid = Int(t[..<sp]) {
                map[pid] = t[t.index(after: sp)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return map
    }

    private static func appName(forPID pid: Int, path: String?) -> String? {
        // 优先用 NSRunningApplication 取本地化应用名（中文/正确名，避免 ps 对高位字节的 M- 转义）
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)),
           let n = app.localizedName, !n.isEmpty {
            return n
        }
        guard let path else { return nil }
        // 退而求其次：路径里最深的 *.app 组件名（helper 进程也能归并到主 App）
        let parts = path.components(separatedBy: "/")
        if let appComp = parts.last(where: { $0.hasSuffix(".app") }) {
            return String(appComp.dropLast(4))
        }
        return (path as NSString).lastPathComponent   // CLI/守护进程用 basename
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
        let pathMap = psPathMap()

        var agg: [String: (read: Int64, write: Int64, name: String)] = [:]
        for pid in pids {
            guard pid > 0, let io = diskBytes(pid), io.read > 0 || io.write > 0 else { continue }
            let display = resolveName(pid: pid, path: pathMap[Int(pid)])
            // 解析出真实名按名聚合（合并 helper 进程）；否则按 pid 区分
            let key = display.resolved ?? "\(display.name)#\(pid)"
            var e = agg[key] ?? (0, 0, display.name)
            e.read += Int64(bitPattern: io.read)
            e.write += Int64(bitPattern: io.write)
            agg[key] = e
        }
        return agg.values.map { DiskProc(name: $0.name, bytesRead: $0.read, bytesWritten: $0.write) }
            .sorted { $0.bytesRead > $1.bytesRead }
            .prefix(limit).map { $0 }
    }

    /// 列出当前所有进程 pid（含守护进程；无 root 时对他人进程的 rusage 会被拒，自动跳过）
    private static func allPIDs() -> [pid_t] {
        let hint = proc_listallpids(nil, 0)
        guard hint > 0 else { return [] }
        // hint 在不同系统上可能是"个数"也可能是"字节数"，统一多留余量，按返回字节数还原个数
        var buf = [pid_t](repeating: 0, count: Int(hint) + 256)
        let bytes = proc_listallpids(&buf, Int32(buf.count * MemoryLayout<pid_t>.stride))
        guard bytes > 0 else { return [] }
        let cnt = min(Int(bytes) / MemoryLayout<pid_t>.stride, buf.count)
        return Array(buf.prefix(cnt))
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

    private static func psPathMap() -> [Int: String] {
        let out = runCommand("/bin/ps", ["-ax", "-o", "pid=,comm="])
        var map: [Int: String] = [:]
        for line in out.split(separator: "\n") {
            let t = line.drop { $0 == " " }
            guard let sp = t.firstIndex(of: " ") else { continue }
            if let pid = Int(t[..<sp]) {
                map[pid] = t[t.index(after: sp)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return map
    }

    private static func resolveName(pid: pid_t, path: String?) -> (name: String, resolved: String?) {
        if let app = NSRunningApplication(processIdentifier: pid),
           let n = app.localizedName, !n.isEmpty {
            return (n, n)
        }
        if let path {
            let parts = path.components(separatedBy: "/")
            if let appComp = parts.last(where: { $0.hasSuffix(".app") }) {
                let n = String(appComp.dropLast(4)); return (n, n)
            }
            let base = (path as NSString).lastPathComponent
            return (base, base)
        }
        return ("PID \(pid)", nil)
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
    static func scan() -> (powered: Bool, devices: [BTDevice]) {
        let out = runCommand("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"])
        guard let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["SPBluetoothDataType"] as? [[String: Any]],
              let root = arr.first else { return (false, []) }

        var powered = false
        if let ctrl = root["controller_properties"] as? [String: Any],
           let state = ctrl["controller_state"] as? String {
            powered = state.lowercased().contains("on")
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
