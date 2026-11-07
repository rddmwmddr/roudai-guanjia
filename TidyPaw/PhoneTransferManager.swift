import Foundation
import AppKit
import Combine
import ImageCaptureCore

/// 手机传图的总管。只在用户打开这一页时连接手机：大管家可能全天开着，
/// 一直占着 MTP 连接会让「照片」「图像捕捉」这些 App 连不上手机。离开页面时如果还在传输，等传完再断开。
@MainActor
final class PhoneManager: ObservableObject {
    let settings = PhoneTransferSettings()
    @Published private(set) var allDevices: [PhoneDevice] = []

    private let mtp = PhoneMTPWatcher()
    private var isPageVisible = false
    private var isWatching = false
    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var deviceObservers: [String: AnyCancellable] = [:]
    private var settingsObserver: AnyCancellable?
    private var pendingRescan: Set<String> = []

    init() {
        settings.onChange = { [weak self] in self?.recomputeAll() }
        settingsObserver = settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        mtp.manager = self
    }

    /// 同一台手机既开了 USB 调试又开了文件传输时，只显示更快的 adb 通道。
    var devices: [PhoneDevice] {
        let adbSerials = Set(allDevices.filter { $0.isADB && $0.state != .unauthorized }.map(\.serial))
        return allDevices.filter { device in
            device.isADB || device.state == .transferring || !adbSerials.contains(device.serial)
        }
    }

    var isTransferring: Bool { allDevices.contains { $0.state == .transferring } }
    var active: [PhoneDevice] { devices.filter { $0.enabled && $0.hasContent && $0.state != .transferring } }
    var pendingCount: Int { active.reduce(0) { $0 + $1.plan.count } }
    var pendingBytes: Int64 { active.reduce(0) { $0 + $1.planBytes } }

    var freeBytes: Int64? {
        var url = settings.destURL
        while !FileManager.default.fileExists(atPath: url.path) && url.path != "/" { url.deleteLastPathComponent() }
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /// 侧边栏的副标题：离开这一页后还能看到传输进度。
    var sidebarSubtitle: String {
        let transferring = allDevices.filter { $0.state == .transferring }
        guard !transferring.isEmpty else { return "安卓照片传到 Mac" }
        let total = transferring.reduce(Int64(0)) { $0 + $1.totalBytes }
        let done = transferring.reduce(Int64(0)) { $0 + $1.doneBytes + $1.liveBytes }
        guard total > 0 else { return "正在传输" }
        return "正在传输 \(min(Int(Double(done) / Double(total) * 100), 100))%"
    }

    // MARK: 页面生命周期

    func pageAppeared() {
        isPageVisible = true
        startWatching()
    }

    func pageDisappeared() {
        isPageVisible = false
        if !isTransferring { stopWatching() }
    }

    private func startWatching() {
        guard !isWatching else { return }
        isWatching = true
        mtp.start()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.pollADB()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.tick()
            }
        }
    }

    private func stopWatching() {
        guard isWatching else { return }
        isWatching = false
        pollTask?.cancel()
        tickTask?.cancel()
        closeSessions()
        mtp.stop()
        allDevices = []
        deviceObservers = [:]
    }

    /// App 退出前调用：停掉传输、清掉半截文件、释放手机。
    /// 否则下次启动时 ptpcamerad 可能还占着设备。
    func shutdown() {
        for device in allDevices { device.abortForQuit() }
        closeSessions()
    }

    private func closeSessions() {
        for device in allDevices {
            if case .mtp(let camera) = device.backend { camera.requestCloseSession() }
        }
    }

    private func addDevice(_ device: PhoneDevice) {
        allDevices.append(device)
        // 底部合计要跟着每台手机的进度变化
        deviceObservers[device.id] = device.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    private func removeDevice(_ device: PhoneDevice) {
        device.stop()
        allDevices.removeAll { $0 === device }
        deviceObservers[device.id] = nil
    }

    // MARK: 计划与传输

    func recomputeAll() {
        var taken = Set<String>()
        var cache = PhoneDirCache()
        for device in allDevices where device.state == .transferring {
            for planned in device.plan { taken.insert(planned.url.path.lowercased()) }
        }
        let order = allDevices.filter { $0.state != .transferring }.sorted { $0.enabled && !$1.enabled }
        for device in order { device.computePlan(settings, taken: &taken, cache: &cache) }
    }

    func startAll() {
        recomputeAll()
        for device in active where !device.plan.isEmpty { device.start() }
    }

    func stopAll() { allDevices.forEach { $0.stop() } }

    func deviceFinished() {
        recomputeAll()
        guard !isTransferring else { return }
        NSSound(named: "Glass")?.play()
        if !isPageVisible { stopWatching() }
    }

    func rescan(_ device: PhoneDevice) {
        guard device.state != .transferring else { return }
        switch device.backend {
        case .adb: Task { await scanADB(device) }
        case .mtp(let camera): mtpCatalogReady(camera)
        }
    }

    private func tick() {
        for device in allDevices where device.state == .transferring { device.sampleProgress() }
    }

    // MARK: adb

    private func pollADB() async {
        guard PhoneADB.path != nil else { return }
        let (code, output) = await PhoneADB.run(["devices", "-l"], timeout: 10)
        guard code == 0, !Task.isCancelled else { return }
        var seen = Set<String>()
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2, ["device", "unauthorized", "offline", "authorizing"].contains(parts[1]) else { continue }
            let serial = parts[0], status = parts[1]
            seen.insert(serial)
            if let device = allDevices.first(where: { $0.isADB && $0.serial == serial }) {
                if status == "device" && device.state == .unauthorized {
                    device.state = .connecting
                    Task { await scanADB(device) }
                } else if status != "device" && device.state != .transferring {
                    device.state = .unauthorized
                }
                continue
            }
            let model = parts.first { $0.hasPrefix("model:") }
                .map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") } ?? serial
            let device = PhoneDevice(id: "adb:\(serial)", backend: .adb, serial: serial, model: model, manager: self)
            addDevice(device)
            if status == "device" {
                Task { await scanADB(device) }
            } else {
                device.state = .unauthorized
            }
        }
        for device in allDevices where device.isADB && !seen.contains(device.serial) { removeDevice(device) }
    }

    private func scanADB(_ device: PhoneDevice) async {
        device.state = .scanning
        let (_, name) = await PhoneADB.run(["-s", device.serial, "shell", "getprop ro.product.marketname"], timeout: 10)
        let market = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !market.isEmpty && !market.lowercased().contains("error") { device.model = market }
        let items = await PhoneADB.scan(serial: device.serial)
        guard allDevices.contains(where: { $0 === device }) else { return }
        device.setItems(items)
        device.state = .ready
        recomputeAll()
    }

    // MARK: MTP

    private func mtpDevice(_ device: ICDevice) -> PhoneDevice? {
        allDevices.first {
            if case .mtp(let camera) = $0.backend { return camera === device }
            return false
        }
    }

    func addMTP(_ camera: ICCameraDevice) {
        guard mtpDevice(camera) == nil else { return }
        let serial = camera.serialNumberString ?? camera.uuidString ?? UUID().uuidString
        let device = PhoneDevice(id: "mtp:\(camera.uuidString ?? serial)", backend: .mtp(camera), serial: serial,
                                 model: camera.name ?? "相机设备", manager: self)
        device.state = .scanning
        addDevice(device)
    }

    func removeMTP(_ camera: ICDevice) {
        if let device = mtpDevice(camera) { removeDevice(device) }
    }

    func mtpFailed(_ camera: ICDevice, _ message: String) {
        mtpDevice(camera)?.state = .failed("连接失败：\(message)")
    }

    func mtpLocked(_ camera: ICDevice, _ locked: Bool) {
        guard let device = mtpDevice(camera), device.state != .transferring else { return }
        device.state = locked ? .unauthorized : .scanning
    }

    func mtpCatalogReady(_ camera: ICDevice) {
        guard let device = mtpDevice(camera), let camera = camera as? ICCameraDevice, device.state != .transferring else { return }
        let (items, files) = PhoneMTPWatcher.items(of: camera)
        device.mtpFiles = files
        device.mtpTotalFiles = camera.mediaFiles?.count ?? 0
        device.setItems(items)
        device.state = .ready
        recomputeAll()
    }

    func mtpContentsChanged(_ camera: ICCameraDevice) {
        guard let device = mtpDevice(camera), device.state == .ready || device.hasContent, device.state != .transferring,
              !pendingRescan.contains(device.id) else { return }
        pendingRescan.insert(device.id)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.pendingRescan.remove(device.id)
            self?.mtpCatalogReady(camera)
        }
    }
}
