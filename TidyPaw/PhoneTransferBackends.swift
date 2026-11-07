import Foundation
import ImageCaptureCore

// MARK: - adb

enum PhoneADB {
    /// 每次都重新找：用户可能在 App 开着的时候才装好 adb。
    static var path: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(home)/platform-tools/adb",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    /// 运行 adb，合并 stdout/stderr；任务取消或超时时终止进程。
    static func run(_ args: [String], timeout: TimeInterval? = nil) async -> (code: Int32, out: String) {
        guard let path else { return (-1, "") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let flag = CancelFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(returning: (-1, "\(error)"))
                        return
                    }
                    // 取消可能发生在进程启动之前，那时 terminate 没有对象，这里补上
                    if flag.isCancelled { process.terminate() }
                    if let timeout {
                        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                            if process.isRunning { process.terminate() }
                        }
                    }
                    // 先读完再 wait：输出超过管道缓冲时，反过来会互相等死
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
                }
            }
        } onCancel: {
            flag.cancel()
            if process.isRunning { process.terminate() }
        }
    }

    static func scan(serial: String) async -> [PhoneMediaItem] {
        let command = "for d in /sdcard/DCIM /sdcard/Pictures /sdcard/Movies; do [ -d \"$d\" ] && find \"$d\" -type f -exec stat -c '%s|%Y|%n' {} + ; done 2>/dev/null"
        let (_, output) = await run(["-s", serial, "shell", command], timeout: 180)
        return PhoneMedia.parseScan(output)
    }
}

// MARK: - MTP / PTP（ImageCaptureCore）

final class PhoneMTPWatcher: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    private var browser: ICDeviceBrowser?
    weak var manager: PhoneManager?

    func start() {
        guard browser == nil else { return }
        let browser = ICDeviceBrowser()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
            ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
        self.browser = browser
    }

    func stop() {
        browser?.stop()
        browser?.delegate = nil
        browser = nil
    }

    private func onMain(_ work: @escaping @MainActor (PhoneManager) -> Void) {
        Task { @MainActor [weak self] in
            if let manager = self?.manager { work(manager) }
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        camera.delegate = self
        onMain { $0.addMTP(camera) }
        camera.requestOpenSession()
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        onMain { $0.removeMTP(device) }
    }
    func didRemove(_ device: ICDevice) { onMain { $0.removeMTP(device) } }
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error { onMain { $0.mtpFailed(device, error.localizedDescription) } }
    }
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        onMain { $0.mtpCatalogReady(device) }
    }
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        onMain { $0.mtpContentsChanged(camera) }
    }
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        onMain { $0.mtpContentsChanged(camera) }
    }
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        onMain { $0.mtpLocked(device, true) }
    }
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        onMain { $0.mtpLocked(device, false) }
    }
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func deviceDidBecomeReady(_ device: ICDevice) {}

    static func items(of camera: ICCameraDevice) -> ([PhoneMediaItem], [String: ICCameraFile]) {
        var items: [PhoneMediaItem] = []
        var files: [String: ICCameraFile] = [:]
        for case let file as ICCameraFile in camera.mediaFiles ?? [] {
            guard let name = file.name, PhoneMedia.isUsableName(name), let kind = PhoneMedia.kind(for: name) else { continue }
            var folders: [String] = []
            var parent = file.parentFolder
            while let folder = parent {
                folders.insert(folder.name ?? "", at: 0)
                parent = folder.parentFolder
            }
            guard let album = PhoneMedia.albumName(forFolders: folders) else { continue }
            var id = (folders + [name]).joined(separator: "/")
            while files[id] != nil { id += "#" }
            files[id] = file
            items.append(PhoneMediaItem(id: id, name: name, album: album, size: Int64(file.fileSize),
                                        date: file.creationDate ?? file.modificationDate ?? Date(), kind: kind))
        }
        return (items, files)
    }
}
