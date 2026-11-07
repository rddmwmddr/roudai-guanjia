import Foundation
import ImageCaptureCore
import ImageIO

// MARK: - 媒体识别

enum PhoneMediaKind { case photo, video }

struct PhoneMediaItem: Identifiable {
    let id: String          // 手机上的完整路径
    let name: String
    let album: String
    let size: Int64
    let date: Date
    let kind: PhoneMediaKind
}

struct PhonePlannedItem {
    let item: PhoneMediaItem
    let dir: URL
    let fileName: String
    var url: URL { dir.appendingPathComponent(fileName) }
}

struct PhoneAlbum: Identifiable, Hashable {
    let name: String
    let count: Int
    let bytes: Int64
    var id: String { name }
}

enum PhoneMedia {
    private static let photoExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "dng", "raw", "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2", "bmp", "tif", "tiff", "avif"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "3gp", "mkv", "webm", "m4v", "avi", "hevc"]
    private static let roots: Set<String> = ["DCIM", "Pictures", "Movies"]

    static func kind(for name: String) -> PhoneMediaKind? {
        let ext = (name as NSString).pathExtension.lowercased()
        if photoExtensions.contains(ext) { return .photo }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }

    /// 能作为文件名落到 Mac 上的名字。这些名字来自手机，不能让它们跑出保存目录。
    static func isUsableName(_ name: String) -> Bool {
        !name.hasPrefix(".") && PathSafety.isSafeComponent(name)
    }

    /// 由文件所在的文件夹路径得出相册名；不在 DCIM/Pictures/Movies 下或处于隐藏目录中返回 nil。
    static func albumName(forFolders folders: [String]) -> String? {
        guard let i = folders.firstIndex(where: { roots.contains($0) }) else { return nil }
        let rest = Array(folders[(i + 1)...])
        guard rest.allSatisfy(isUsableName) else { return nil }
        return rest.isEmpty ? folders[i] : rest.joined(separator: "/")
    }

    /// 解析手机上 `stat -c '%s|%Y|%n'` 的输出。
    static func parseScan(_ output: String) -> [PhoneMediaItem] {
        var items: [PhoneMediaItem] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let size = Int64(parts[0]), let mtime = Double(parts[1]) else { continue }
            let path = String(parts[2])
            var folders = path.split(separator: "/").map(String.init)
            guard let name = folders.popLast(), isUsableName(name), let kind = kind(for: name),
                  let album = albumName(forFolders: folders) else { continue }
            items.append(PhoneMediaItem(id: path, name: name, album: album, size: size,
                                        date: Date(timeIntervalSince1970: mtime), kind: kind))
        }
        return items
    }

    private static func dateFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
    private static let plainDate = dateFormatter("yyyy:MM:dd HH:mm:ss")
    private static let zonedDate = dateFormatter("yyyy:MM:dd HH:mm:ssXXXXX")

    /// 照片的拍摄时间（只解析文件头）；带 OffsetTimeOriginal 时按拍摄地时区换算。
    static func captureDate(of url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String,
           let date = zonedDate.date(from: raw + offset) { return date }
        return plainDate.date(from: raw)
    }
}

// MARK: - 设置

enum PhoneFolderLayout: String, CaseIterable, Identifiable {
    case deviceAlbum, deviceMonth, flat
    var id: Self { self }
    var title: String {
        switch self {
        case .deviceAlbum: return "手机 / 相册"
        case .deviceMonth: return "手机 / 年-月"
        case .flat:        return "不分文件夹"
        }
    }
}

enum PhoneDateRange: String, CaseIterable, Identifiable {
    case all, today, week, month, quarter, year
    var id: Self { self }
    var title: String {
        switch self {
        case .all:     return "全部时间"
        case .today:   return "今天"
        case .week:    return "最近 7 天"
        case .month:   return "最近 30 天"
        case .quarter: return "最近 90 天"
        case .year:    return "最近一年"
        }
    }
    var cutoff: Date? {
        let now = Date()
        switch self {
        case .all:     return nil
        case .today:   return Calendar.current.startOfDay(for: now)
        case .week:    return now.addingTimeInterval(-7 * 86_400)
        case .month:   return now.addingTimeInterval(-30 * 86_400)
        case .quarter: return now.addingTimeInterval(-90 * 86_400)
        case .year:    return now.addingTimeInterval(-365 * 86_400)
        }
    }
}

final class PhoneTransferSettings: ObservableObject {
    var onChange: (() -> Void)?
    private let defaults = UserDefaults.standard

    @Published var destPath: String { didSet { defaults.set(destPath, forKey: "phone.destPath"); onChange?() } }
    @Published var layout: PhoneFolderLayout { didSet { defaults.set(layout.rawValue, forKey: "phone.layout"); onChange?() } }
    @Published var range: PhoneDateRange { didSet { defaults.set(range.rawValue, forKey: "phone.range"); onChange?() } }
    @Published var photos: Bool { didSet { defaults.set(photos, forKey: "phone.photos"); onChange?() } }
    @Published var videos: Bool { didSet { defaults.set(videos, forKey: "phone.videos"); onChange?() } }

    init() {
        let d = UserDefaults.standard
        destPath = d.string(forKey: "phone.destPath")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/手机照片").path
        layout = PhoneFolderLayout(rawValue: d.string(forKey: "phone.layout") ?? "") ?? .deviceAlbum
        range = PhoneDateRange(rawValue: d.string(forKey: "phone.range") ?? "") ?? .all
        photos = d.object(forKey: "phone.photos") as? Bool ?? true
        videos = d.object(forKey: "phone.videos") as? Bool ?? true
    }

    var destURL: URL { URL(fileURLWithPath: destPath) }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return f
    }()

    func targetDir(for item: PhoneMediaItem, folder: String) -> URL {
        switch layout {
        case .deviceAlbum: return destURL.appendingPathComponent(folder).appendingPathComponent(item.album)
        case .deviceMonth: return destURL.appendingPathComponent(folder).appendingPathComponent(Self.monthFormatter.string(from: item.date))
        case .flat:        return destURL
        }
    }
}

// MARK: - 设备

@MainActor
final class PhoneDevice: ObservableObject, Identifiable {
    enum Backend { case adb, mtp(ICCameraDevice) }

    enum State: Equatable {
        case connecting, unauthorized, scanning, ready, transferring
        case done(String), failed(String)
    }

    let id: String
    let backend: Backend
    let serial: String

    @Published var model: String
    @Published var alias: String {
        didSet {
            UserDefaults.standard.set(alias, forKey: "phone.alias.\(serial)")
            manager?.recomputeAll()
        }
    }
    @Published var enabled: Bool { didSet { manager?.recomputeAll() } }
    @Published var state: State = .connecting
    @Published private(set) var items: [PhoneMediaItem] = []
    @Published private(set) var albums: [PhoneAlbum] = []
    @Published var excludedAlbums: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(excludedAlbums), forKey: "phone.excluded.\(serial)")
            manager?.recomputeAll()
        }
    }

    @Published private(set) var plan: [PhonePlannedItem] = []
    @Published private(set) var planBytes: Int64 = 0
    @Published private(set) var skipped = 0

    // 传输进度
    @Published private(set) var totalCount = 0
    @Published private(set) var doneCount = 0
    @Published private(set) var failedCount = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var doneBytes: Int64 = 0
    @Published private(set) var liveBytes: Int64 = 0
    @Published private(set) var speed: Double = 0
    @Published private(set) var current = ""
    @Published var mtpTotalFiles = 0   // 手机上 MTP 能看到的全部文件数；为 0 通常是锁屏或未选「文件传输」

    var mtpFiles: [String: ICCameraFile] = [:]
    private var task: Task<Void, Never>?
    private var liveProvider: (() -> Int64)?
    private var lastSampleBytes: Int64 = 0
    /// 正在传的这批文件。App 退出时据此清掉没传完的半截文件。
    private var activeBatch: [PhonePlannedItem] = []
    private weak var manager: PhoneManager?

    init(id: String, backend: Backend, serial: String, model: String, manager: PhoneManager) {
        self.id = id
        self.backend = backend
        self.serial = serial
        self.model = model
        self.manager = manager
        alias = UserDefaults.standard.string(forKey: "phone.alias.\(serial)") ?? ""
        excludedAlbums = Set(UserDefaults.standard.stringArray(forKey: "phone.excluded.\(serial)") ?? [])
        // 无线调试连着的手机不一定是眼前这台，甚至不一定是自己的，默认不传
        enabled = !Self.isWirelessSerial(serial)
    }

    var isADB: Bool {
        if case .adb = backend { return true }
        return false
    }

    /// adb 无线连接的序列号形如 192.168.0.5:5555 或 adb-xxx._adb-tls-connect._tcp
    static func isWirelessSerial(_ serial: String) -> Bool {
        serial.contains("_adb-tls-connect") || serial.contains(":")
    }

    var isWireless: Bool { isADB && Self.isWirelessSerial(serial) }

    var channelLabel: String {
        if !isADB { return "文件传输 MTP" }
        return isWireless ? "无线调试" : "USB 调试 · 高速"
    }

    var resultMessage: String? {
        switch state {
        case .done(let message), .failed(let message): return message
        default: return nil
        }
    }

    var folderName: String {
        let raw = alias.trimmingCharacters(in: .whitespaces).isEmpty ? model : alias
        let cleaned = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return PathSafety.isSafeComponent(cleaned) ? cleaned : "手机"
    }

    var hasContent: Bool {
        switch state {
        case .ready, .transferring, .done, .failed: return !items.isEmpty
        default: return false
        }
    }

    var statusText: String {
        switch state {
        case .connecting:   return "正在连接…"
        case .unauthorized: return "等待授权"
        case .scanning:     return "正在读取相册…"
        case .ready:        return items.isEmpty ? "没有找到照片" : "\(items.count.formatted()) 个照片和视频"
        case .transferring: return "正在传输"
        case .done:         return "传输完成"
        case .failed:       return "部分文件失败"
        }
    }

    func setItems(_ new: [PhoneMediaItem]) {
        items = new.sorted { $0.date < $1.date }
        var groups: [String: (count: Int, bytes: Int64)] = [:]
        for item in items {
            groups[item.album, default: (0, 0)].count += 1
            groups[item.album, default: (0, 0)].bytes += item.size
        }
        albums = groups.map { PhoneAlbum(name: $0.key, count: $0.value.count, bytes: $0.value.bytes) }
            .sorted { a, b in
                if (a.name == "Camera") != (b.name == "Camera") { return a.name == "Camera" }
                return a.count > b.count
            }
    }

    /// 算出这台要传哪些文件。同名同大小算已传过；同名不同大小改名，不覆盖已有文件。
    func computePlan(_ settings: PhoneTransferSettings, taken: inout Set<String>, cache: inout PhoneDirCache) {
        var newPlan: [PhonePlannedItem] = []
        var bytes: Int64 = 0
        var skip = 0
        let cutoff = settings.range.cutoff
        for item in items {
            if excludedAlbums.contains(item.album) { continue }
            if item.kind == .photo && !settings.photos { continue }
            if item.kind == .video && !settings.videos { continue }
            if let cutoff, item.date < cutoff { continue }
            let dir = settings.targetDir(for: item, folder: folderName)
            let base = (item.name as NSString).deletingPathExtension
            let ext = (item.name as NSString).pathExtension
            var name = item.name
            var n = 1
            while true {
                let key = dir.appendingPathComponent(name).path.lowercased()
                if taken.contains(key) {
                    name = ext.isEmpty ? "\(base)_\(n)" : "\(base)_\(n).\(ext)"
                    n += 1
                    continue
                }
                if let size = cache.size(dir: dir, name: name) {
                    if size == item.size {   // 同名同大小：已传过
                        skip += 1
                        taken.insert(key)
                        break
                    }
                    name = ext.isEmpty ? "\(base)_\(n)" : "\(base)_\(n).\(ext)"
                    n += 1
                    continue
                }
                taken.insert(key)
                newPlan.append(PhonePlannedItem(item: item, dir: dir, fileName: name))
                bytes += item.size
                break
            }
        }
        newPlan.sort { ($0.dir.path, $0.item.date) < ($1.dir.path, $1.item.date) }
        plan = newPlan
        planBytes = bytes
        skipped = skip
    }

    // MARK: 传输

    func start() {
        guard !plan.isEmpty else { return }
        totalCount = plan.count
        totalBytes = planBytes
        doneCount = 0; failedCount = 0; doneBytes = 0; liveBytes = 0; speed = 0; lastSampleBytes = 0
        state = .transferring
        let started = Date()
        task = Task { @MainActor in
            switch backend {
            case .adb: await runADB()
            case .mtp(let camera): await runMTP(camera)
            }
            current = ""
            liveProvider = nil
            liveBytes = 0
            let seconds = Date().timeIntervalSince(started)
            var message = Task.isCancelled ? "已停止，传了 \(doneCount.formatted()) 项" : "完成 \(doneCount.formatted()) 项"
            message += " · \(formatBytes(doneBytes))"
            if seconds > 1 && doneBytes > 0 { message += " · 平均 \(formatBytes(Int64(Double(doneBytes) / seconds)))/s" }
            if failedCount > 0 { message += " · \(failedCount) 项失败" }
            state = failedCount > 0 ? .failed(message) : .done(message)
            task = nil
            manager?.deviceFinished()
        }
    }

    func stop() { task?.cancel() }

    /// App 退出时调用：等不到异步收尾了，当场停掉传输并删掉没传完的文件。
    /// 留着半截文件的话，它会顶着正常的文件名躺在文件夹里，下次传输还会被当成另一个文件。
    func abortForQuit() {
        guard state == .transferring else { return }
        task?.cancel()
        Self.removeUnfinished(activeBatch)
    }

    private static func removeUnfinished(_ batch: [PhonePlannedItem]) {
        for planned in batch {
            let size = (try? FileManager.default.attributesOfItem(atPath: planned.url.path))?[.size] as? Int64
            if size != nil, size != planned.item.size { try? FileManager.default.removeItem(at: planned.url) }
        }
    }

    /// 每 0.5 秒由 PhoneManager 调用，刷新实时进度和速度。
    func sampleProgress() {
        liveBytes = liveProvider?() ?? 0
        let now = doneBytes + liveBytes
        let instant = Double(max(0, now - lastSampleBytes)) / 0.5
        lastSampleBytes = now
        speed = speed == 0 ? instant : speed * 0.8 + instant * 0.2
    }

    private func finalize(_ planned: PhonePlannedItem) -> Bool {
        let path = planned.url.path
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 else { return false }
        if planned.item.size > 0 && size != planned.item.size {
            try? FileManager.default.removeItem(atPath: path)
            return false
        }
        let date = (planned.item.kind == .photo ? PhoneMedia.captureDate(of: planned.url) : nil) ?? planned.item.date
        try? FileManager.default.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: path)
        doneCount += 1
        doneBytes += size
        return true
    }

    private func runADB() async {
        for batch in Self.makeBatches(plan) {
            if Task.isCancelled { return }
            let dir = batch[0].dir
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            current = batch.count == 1 ? batch[0].item.name : "\(batch[0].item.name) 等 \(batch.count) 个"
            activeBatch = batch
            var args = ["-s", serial, "pull", "-a"]
            if batch.count == 1 {
                args += [batch[0].item.id, batch[0].url.path]
            } else {
                args += batch.map(\.item.id) + [dir.path]
            }
            let paths = batch.map(\.url.path)
            liveProvider = {
                paths.reduce(Int64(0)) { $0 + (((try? FileManager.default.attributesOfItem(atPath: $1))?[.size] as? Int64) ?? 0) }
            }
            _ = await PhoneADB.run(args)
            liveProvider = nil
            liveBytes = 0
            let cancelled = Task.isCancelled
            for planned in batch where !finalize(planned) {
                if cancelled {
                    try? FileManager.default.removeItem(at: planned.url)
                } else {
                    failedCount += 1
                }
            }
            activeBatch = []
        }
    }

    private func runMTP(_ camera: ICCameraDevice) async {
        for planned in plan {
            if Task.isCancelled { return }
            guard let file = mtpFiles[planned.item.id] else {
                failedCount += 1
                continue
            }
            try? FileManager.default.createDirectory(at: planned.dir, withIntermediateDirectories: true)
            current = planned.item.name
            activeBatch = [planned]
            let once = PhoneOnceBox()
            let ok: Bool = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    once.set(continuation)
                    let options: [ICDownloadOption: Any] = [
                        .downloadsDirectoryURL: planned.dir,
                        .saveAsFilename: planned.fileName,
                        .overwrite: false,
                    ]
                    let progress = file.requestDownload(options: options) { _, error in
                        once.resume(error == nil)
                    }
                    let size = planned.item.size
                    liveProvider = { Int64((progress?.fractionCompleted ?? 0) * Double(size)) }
                }
            } onCancel: {
                DispatchQueue.main.async { camera.cancelDownload() }
                once.resume(false)
            }
            liveProvider = nil
            liveBytes = 0
            activeBatch = []
            if ok && finalize(planned) { continue }
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: planned.url)
            } else {
                failedCount += 1
            }
        }
    }

    /// adb pull 一次拉多个文件：同一目标文件夹、不改名的文件合并成一批（≤100 个或 ≤1GB）。
    nonisolated static func makeBatches(_ plan: [PhonePlannedItem]) -> [[PhonePlannedItem]] {
        var batches: [[PhonePlannedItem]] = []
        var current: [PhonePlannedItem] = []
        var bytes: Int64 = 0
        func flush() {
            if !current.isEmpty { batches.append(current) }
            current = []
            bytes = 0
        }
        for planned in plan {
            if planned.fileName != planned.item.name {
                flush()
                batches.append([planned])
                continue
            }
            if let first = current.first, first.dir != planned.dir || current.count >= 100 || bytes >= 1_000_000_000 { flush() }
            current.append(planned)
            bytes += planned.item.size
        }
        flush()
        return batches
    }
}

/// 等待一次结果的盒子：下载回调和取消可能以任意顺序到达，只响应第一个。
final class PhoneOnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var finished = false
    private var pending: Bool?

    func set(_ c: CheckedContinuation<Bool, Never>) {
        lock.lock(); defer { lock.unlock() }
        if let value = pending {
            finished = true
            c.resume(returning: value)
        } else {
            continuation = c
        }
    }

    func resume(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        if let continuation {
            finished = true
            continuation.resume(returning: value)
        } else {
            pending = value
        }
    }
}

/// 一次计算内复用的目录清单，不用为每个文件单独查一次磁盘。
struct PhoneDirCache {
    private var dirs: [String: [String: Int64]] = [:]

    mutating func size(dir: URL, name: String) -> Int64? {
        let key = dir.path
        if dirs[key] == nil {
            var map: [String: Int64] = [:]
            let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for url in urls {
                map[url.lastPathComponent.lowercased()] = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
            }
            dirs[key] = map
        }
        return dirs[key]?[name.lowercased()]
    }
}
