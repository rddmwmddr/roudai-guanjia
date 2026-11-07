import Foundation
import AppKit

@MainActor
final class UninstallEngine: ObservableObject {
    enum State: Equatable { case idle, scanning, loaded, empty }

    @Published private(set) var identity: AppIdentity?
    @Published private(set) var candidates: [RemovalCandidate] = []
    @Published var selectedIDs: Set<UUID> = []
    @Published private(set) var state: State = .idle
    @Published private(set) var appIcon: NSImage?
    @Published var errorMessage: String?

    private var scanWorker: Task<UninstallScanResult, Error>?

    // MARK: 选择

    var selectedCandidates: [RemovalCandidate] { candidates.filter { selectedIDs.contains($0.id) } }
    var selectedCount: Int { selectedIDs.count }
    var selectedSize: Int64 { selectedCandidates.reduce(0) { $0 + ($1.size ?? 0) } }
    var totalSize: Int64 { candidates.reduce(0) { $0 + ($1.size ?? 0) } }

    func isSelected(_ c: RemovalCandidate) -> Bool { selectedIDs.contains(c.id) }
    func toggle(_ c: RemovalCandidate) {
        if selectedIDs.contains(c.id) { selectedIDs.remove(c.id) } else { selectedIDs.insert(c.id) }
    }
    func selectAll() { selectedIDs = Set(candidates.map { $0.id }) }
    func selectNone() { selectedIDs = [] }
    func selectExact() { selectedIDs = Set(candidates.filter { $0.confidence == .exact }.map { $0.id }) }

    // MARK: 扫描

    func load(_ url: URL) {
        // 不能卸载自己：解析符号链接 + 比对 Bundle ID 双重防护
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let mine = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        if resolved.path == mine.path
            || (Bundle(url: resolved)?.bundleIdentifier != nil
                && Bundle(url: resolved)?.bundleIdentifier == Bundle.main.bundleIdentifier) {
            errorMessage = "肉呆大管家正在运行，不能把自己作为卸载目标。"
            return
        }

        scanWorker?.cancel()
        let worker = Task.detached(priority: .userInitiated) { try UninstallScanner().scan(appURL: url) }
        scanWorker = worker

        Task { @MainActor in
            state = .scanning
            identity = nil; candidates = []; selectedIDs = []; appIcon = nil
            do {
                let result = try await worker.value
                guard !Task.isCancelled, scanWorker == worker else { return }   // 已被新扫描取代则丢弃
                identity = result.identity
                candidates = result.candidates
                selectedIDs = Set(result.candidates.filter { $0.defaultSelected }.map { $0.id })
                appIcon = NSWorkspace.shared.icon(forFile: result.identity.appURL.path)
                state = result.candidates.isEmpty ? .empty : .loaded
            } catch is CancellationError {
                // 被新扫描取代，忽略
            } catch {
                guard scanWorker == worker else { return }
                state = .idle
                errorMessage = error.localizedDescription
            }
        }
    }

    func rescan() { if let url = identity?.appURL { load(url) } }

    func reset() {
        scanWorker?.cancel()
        scanWorker = nil
        identity = nil; candidates = []; selectedIDs = []; appIcon = nil; state = .idle
    }

    // MARK: 卸载（异步：两步确认 → 退出运行中 App → 后台移废纸篓 → 管理员兜底）

    func uninstall() async {
        guard let identity, !selectedCandidates.isEmpty else { return }
        let selected = selectedCandidates

        guard confirmFirstStep(identity: identity, selected: selected) else { return }
        guard confirmByTyping(identity: identity) else { return }
        guard await quitRunningAppIfNeeded(identity: identity) else { return }

        // 普通项：后台线程移入废纸篓，不卡界面
        var part = await Task.detached(priority: .userInitiated) {
            UninstallEngine.trashNonAdmin(selected)
        }.value

        // 需管理员项：确认后提权移动（并 chown 回当前用户，保证之后能在废纸篓里清理）
        if !part.needsAdmin.isEmpty {
            if confirmAdminMove(count: part.needsAdmin.count) {
                let urls = part.needsAdmin
                let admin = await Task.detached(priority: .userInitiated) {
                    UninstallEngine.trashWithAdmin(urls)
                }.value
                part.trashed.append(contentsOf: admin.trashed)
                part.failures.append(contentsOf: admin.failures)
            } else {
                // 用 for-in 而非 .forEach：Swift 6.3.x 对 @MainActor async 里的 .forEach 闭包
                // 有隔离推断 bug，会污染线程的 executor 追踪，之后 SwiftUI 悬停命中测试里的
                // MainActor.assumeIsolated 会误判并崩溃。
                for u in part.needsAdmin { part.failures.append((u, "需要管理员权限，已跳过")) }
            }
        }

        showResult(TrashResult(trashed: part.trashed, failures: part.failures))

        if FileManager.default.fileExists(atPath: identity.appURL.path) {
            load(identity.appURL)
        } else {
            self.identity = nil; candidates = []; selectedIDs = []; appIcon = nil; state = .idle
        }
    }

    // MARK: 确认弹窗（NSAlert 在主线程，await 之间互不交错）

    private func confirmFirstStep(identity: AppIdentity, selected: [RemovalCandidate]) -> Bool {
        let size = selected.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let adminCount = selected.filter { $0.requiresAdmin }.count
        let riskyCount = selected.filter { $0.confidence != .exact }.count
        let recovery = adminCount > 0
            ? "普通项目移入废纸篓后可随时恢复；其中 \(adminCount) 项系统/管理员项目也会放进废纸篓，但无法用访达「放回」，需要时得手动移回，且可能再次需要管理员权限。"
            : "此操作不会静默永久删除；需要时可以从废纸篓恢复。"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "准备卸载 \(identity.appName)"
        alert.informativeText = """
        将把 \(selected.count) 个选中项目移到废纸篓，估算大小 \(formatBytes(size))。

        其中 \(adminCount) 项可能需要管理员授权，\(riskyCount) 项不是精确匹配。请确认列表里的每个路径都确实属于这个 App。

        \(recovery)
        """
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmByTyping(identity: AppIdentity) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "最后确认"
        alert.informativeText = "请输入应用名称“\(identity.appName)”确认卸载。"
        alert.addButton(withTitle: "确认移到废纸篓")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.placeholderString = identity.appName
        alert.accessoryView = input
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        guard input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == identity.appName else {
            showAlert(title: "名称不匹配", message: "已取消卸载。")
            return false
        }
        return true
    }

    private func quitRunningAppIfNeeded(identity: AppIdentity) async -> Bool {
        guard !runningApplications(for: identity).isEmpty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(identity.appName) 正在运行"
        alert.informativeText = "卸载前需要先退出该 App。是否现在请求它退出？"
        alert.addButton(withTitle: "退出后继续")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        for app in runningApplications(for: identity) { app.terminate() }
        // 异步等待最多 8 秒（不再用嵌套 RunLoop 阻塞主线程）
        for _ in 0..<40 {
            if runningApplications(for: identity).isEmpty { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard runningApplications(for: identity).isEmpty == false else { return true }

        let force = NSAlert()
        force.alertStyle = .critical
        force.messageText = "\(identity.appName) 没有正常退出"
        force.informativeText = "是否强制退出后继续？未保存的内容可能丢失。"
        force.addButton(withTitle: "强制退出并继续")
        force.addButton(withTitle: "取消")
        guard force.runModal() == .alertFirstButtonReturn else { return false }
        for app in runningApplications(for: identity) { app.forceTerminate() }
        return true
    }

    private func runningApplications(for identity: AppIdentity) -> [NSRunningApplication] {
        let byID = identity.bundleID.map { NSRunningApplication.runningApplications(withBundleIdentifier: $0) } ?? []
        let byPath = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.standardizedFileURL.path == identity.appURL.path
        }
        var seen = Set<pid_t>()
        return (byID + byPath).filter { seen.insert($0.processIdentifier).inserted }
    }

    private func confirmAdminMove(count: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要管理员权限"
        alert.informativeText = "\(count) 个项目无法直接移到废纸篓。继续后 macOS 会显示管理员授权弹窗，肉呆大管家只会移动你刚才勾选的这些路径。"
        alert.addButton(withTitle: "授权移动")
        alert.addButton(withTitle: "跳过")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showResult(_ result: TrashResult) {
        let alert = NSAlert()
        alert.alertStyle = result.failures.isEmpty ? .informational : .warning
        alert.messageText = result.failures.isEmpty ? "卸载项目已移到废纸篓" : "部分项目未完成"
        var message = "成功移动 \(result.trashed.count) 个项目。"
        if !result.failures.isEmpty {
            let lines = result.failures.prefix(8).map { "- \($0.0.path)\n  \($0.1)" }.joined(separator: "\n")
            message += "\n\n失败 \(result.failures.count) 个：\n\(lines)"
            if result.failures.count > 8 { message += "\n..." }
        }
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: 实际移动（后台线程，nonisolated）

    struct PartialTrash: Sendable {
        var trashed: [URL] = []
        var failures: [(URL, String)] = []
        var needsAdmin: [URL] = []
    }

    nonisolated private static func trashNonAdmin(_ selected: [RemovalCandidate]) -> PartialTrash {
        var p = PartialTrash()
        for c in selected {
            do {
                var out: NSURL?
                try FileManager.default.trashItem(at: c.url, resultingItemURL: &out)
                p.trashed.append(c.url)
            } catch {
                // 关键修复：App Store / root 所有的应用（如 Compressor）父目录看似可写、
                // 但本体不可写，trashItem 会以"没有权限"失败。不能只信预判的 requiresAdmin，
                // 一旦是权限类错误就转交管理员提权移动，否则会像之前那样直接报失败。
                if c.requiresAdmin || isPermissionError(error) {
                    p.needsAdmin.append(c.url)
                } else {
                    p.failures.append((c.url, error.localizedDescription))
                }
            }
        }
        return p
    }

    /// 是否为"权限不足/只读卷"类错误（需要管理员才能完成）
    nonisolated private static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           [NSFileWriteNoPermissionError, NSFileReadNoPermissionError,
            NSFileWriteVolumeReadOnlyError].contains(ns.code) {
            return true
        }
        func posixDenied(_ e: NSError) -> Bool {
            e.domain == NSPOSIXErrorDomain
                && [Int(EPERM), Int(EACCES), Int(EROFS)].contains(e.code)
        }
        if posixDenied(ns) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, posixDenied(underlying) { return true }
        return false
    }

    nonisolated private static func trashWithAdmin(_ urls: [URL]) -> (trashed: [URL], failures: [(URL, String)]) {
        var trashed: [URL] = []
        var failures: [(URL, String)] = []
        for url in urls {
            do { try moveToTrashWithAdmin(url); trashed.append(url) }
            catch { failures.append((url, error.localizedDescription)) }
        }
        return (trashed, failures)
    }

    nonisolated private static func moveToTrashWithAdmin(_ url: URL) throws {
        let trashDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let destination = uniqueTrashDestination(for: url, in: trashDir)
        // 移动后把所有权 chown 回当前用户，否则 root:wheel 文件留在废纸篓里用户无法清理/恢复。
        // chown 用 `|| true` 兜底：成败只取决于 mv——否则 mv 已成功、仅 chown 在某个子节点失败时，
        // 会被误报成"卸载失败"，而 App 其实已经进了废纸篓。
        let uid = getuid(); let gid = getgid()
        let command = "/bin/mv -- \(shellQuote(url.path)) \(shellQuote(destination.path))"
            + " && ( /usr/sbin/chown -R \(uid):\(gid) \(shellQuote(destination.path)) || true )"
        let script = "do shell script \"\(appleScriptEscaped(command))\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? "管理员移动失败"
            throw NSError(domain: "RouDaiButler", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: output.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
    }

    nonisolated private static func uniqueTrashDestination(for url: URL, in trashDir: URL) -> URL {
        let baseName = url.lastPathComponent
        let destination = trashDir.appendingPathComponent(baseName)
        guard FileManager.default.fileExists(atPath: destination.path) else { return destination }
        let name = (baseName as NSString).deletingPathExtension
        let ext = (baseName as NSString).pathExtension
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let stampedName = ext.isEmpty ? "\(name)-\(stamp)" : "\(name)-\(stamp).\(ext)"
        return trashDir.appendingPathComponent(stampedName)
    }
}

struct TrashResult {
    let trashed: [URL]
    let failures: [(URL, String)]
}

// MARK: - shell / AppleScript 转义

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
func appleScriptEscaped(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}
