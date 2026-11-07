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
    @Published private(set) var isUninstalling = false
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
        guard !isUninstalling else { return }

        // 不能卸载自己：解析符号链接 + 比对 Bundle ID 双重防护
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let mine = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let targetID = Bundle(url: resolved)?.bundleIdentifier
        if resolved.path == mine.path || (targetID != nil && targetID == Bundle.main.bundleIdentifier) {
            errorMessage = "肉呆大管家正在运行，不能把自己作为卸载目标。"
            return
        }

        scanWorker?.cancel()
        // 状态要在这里同步切换：放进下面的 Task 会晚一拍，紧接着的 reset() 会被它覆盖，界面卡在「扫描中」
        state = .scanning
        clearResults()

        let worker = Task.detached(priority: .userInitiated) { try UninstallScanner().scan(appURL: resolved) }
        scanWorker = worker

        Task { @MainActor in
            do {
                let result = try await worker.value
                guard scanWorker == worker else { return }   // 已被新扫描取代则丢弃
                identity = result.identity
                candidates = result.candidates
                selectedIDs = Set(result.candidates.filter { $0.defaultSelected }.map { $0.id })
                appIcon = NSWorkspace.shared.icon(forFile: result.identity.appURL.path)
                state = result.candidates.isEmpty ? .empty : .loaded
            } catch is CancellationError {
                // 被新扫描取代，或用户离开了这一页
            } catch {
                guard scanWorker == worker else { return }
                state = .idle
                errorMessage = error.localizedDescription
            }
        }
    }

    func rescan() { if let url = identity?.appURL { load(url) } }

    func reset() {
        guard !isUninstalling else { return }
        scanWorker?.cancel()
        scanWorker = nil
        clearResults()
        state = .idle
    }

    private func clearResults() {
        identity = nil; candidates = []; selectedIDs = []; appIcon = nil
    }

    // MARK: 卸载（两步确认 → 退出运行中 App → 后台移废纸篓 → 管理员兜底）

    func uninstall() async {
        guard !isUninstalling, let identity, !selectedCandidates.isEmpty else { return }
        isUninstalling = true
        let finished = await performUninstall(identity: identity, selected: selectedCandidates)
        isUninstalling = false
        guard finished else { return }

        if PathSafety.itemExists(identity.appURL.path) {
            load(identity.appURL)
        } else {
            clearResults()
            state = .idle
        }
    }

    /// 返回 false 表示用户中途取消，什么都没动。
    private func performUninstall(identity: AppIdentity, selected: [RemovalCandidate]) async -> Bool {
        guard await confirmFirstStep(identity: identity, selected: selected) else { return false }
        guard await confirmByTyping(identity: identity) else { return false }
        guard await quitRunningAppIfNeeded(identity: identity) else { return false }

        // 普通项：后台线程移入废纸篓，不卡界面
        var part = await Task.detached(priority: .userInitiated) {
            UninstallEngine.trashNonAdmin(selected)
        }.value

        // 需管理员项：确认后一次性提权移动（并 chown 回当前用户，保证之后能在废纸篓里清理）
        if !part.needsAdmin.isEmpty {
            if await confirmAdminMove(count: part.needsAdmin.count) {
                let urls = part.needsAdmin
                let admin = await Task.detached(priority: .userInitiated) {
                    AdminTrash.moveToTrash(urls)
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

        await showResult(TrashResult(trashed: part.trashed, failures: part.failures))
        return true
    }

    // MARK: 确认弹窗

    /// 用窗口内的 sheet 弹出并异步等结果。
    /// 不在 async 函数里调 runModal：它会在当前 job 里套一层 RunLoop，期间的悬停事件读到的
    /// executor 状态不对，正是 v8 那次悬停闪退的温床。
    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
            return alert.runModal()
        }
        return await alert.beginSheetModal(for: window)
    }

    private func confirmFirstStep(identity: AppIdentity, selected: [RemovalCandidate]) async -> Bool {
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
        return await present(alert) == .alertFirstButtonReturn
    }

    private func confirmByTyping(identity: AppIdentity) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "最后确认"
        alert.informativeText = "请输入应用名称“\(identity.appName)”确认卸载。"
        alert.addButton(withTitle: "确认移到废纸篓")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.placeholderString = identity.appName
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        guard await present(alert) == .alertFirstButtonReturn else { return false }
        guard input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == identity.appName else {
            await showAlert(title: "名称不匹配", message: "已取消卸载。")
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
        guard await present(alert) == .alertFirstButtonReturn else { return false }

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
        guard await present(force) == .alertFirstButtonReturn else { return false }
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

    private func confirmAdminMove(count: Int) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要管理员权限"
        alert.informativeText = "\(count) 个项目无法直接移到废纸篓。继续后 macOS 会显示一次管理员授权弹窗，肉呆大管家只会移动你刚才勾选的这些路径。"
        alert.addButton(withTitle: "授权移动")
        alert.addButton(withTitle: "跳过")
        return await present(alert) == .alertFirstButtonReturn
    }

    private func showResult(_ result: TrashResult) async {
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
        _ = await present(alert)
    }

    private func showAlert(title: String, message: String) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        _ = await present(alert)
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
            guard !PathSafety.isProtected(c.url) else {
                p.failures.append((c.url, "受保护的路径，已跳过"))
                continue
            }
            guard PathSafety.itemExists(c.url.path) else {
                p.failures.append((c.url, "文件已经不存在了"))
                continue
            }
            do {
                var out: NSURL?
                try FileManager.default.trashItem(at: c.url, resultingItemURL: &out)
                p.trashed.append(c.url)
            } catch {
                // App Store / root 所有的应用（如 Compressor）父目录看似可写、但本体不可写，
                // trashItem 会以"没有权限"失败。不能只信预判的 requiresAdmin，
                // 一旦是权限类错误就转交管理员提权移动。
                if isPermissionError(error) || (c.requiresAdmin && !isReadOnlyVolumeError(error)) {
                    p.needsAdmin.append(c.url)
                } else {
                    p.failures.append((c.url, error.localizedDescription))
                }
            }
        }
        return p
    }

    /// 权限不足（管理员可以解决）。只读卷不算：提权也写不了。
    nonisolated private static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code) {
            return true
        }
        func posixDenied(_ e: NSError) -> Bool {
            e.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(e.code)
        }
        if posixDenied(ns) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, posixDenied(underlying) { return true }
        return false
    }

    nonisolated private static func isReadOnlyVolumeError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteVolumeReadOnlyError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EROFS) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(EROFS)
        }
        return false
    }
}

struct TrashResult {
    let trashed: [URL]
    let failures: [(URL, String)]
}

// MARK: - 管理员移动

/// 把所有需要提权的项目拼成**一个**脚本执行：每个 osascript 进程都要单独授权，逐个跑会连弹 N 次密码框。
enum AdminTrash {
    struct Move: Sendable {
        let source: URL
        let destination: URL
        /// 目标已存在时改用这个带时间戳的名字（`mv` 到已存在的目录会把东西塞进那个目录里）
        let fallback: URL
    }

    static func moveToTrash(_ urls: [URL]) -> (trashed: [URL], failures: [(URL, String)]) {
        let trashDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        } catch {
            return ([], urls.map { ($0, error.localizedDescription) })
        }
        let moves = plan(urls, in: trashDir)
        let shell = shellScript(moves, uid: getuid(), gid: getgid())
        return run(moves, script: appleScript(shell: shell, admin: true))
    }

    static func plan(_ urls: [URL], in trashDir: URL) -> [Move] {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        var reserved = Set<String>()
        return urls.enumerated().map { index, url in
            let base = url.lastPathComponent
            let name = (base as NSString).deletingPathExtension
            let ext = (base as NSString).pathExtension
            let stamped = ext.isEmpty ? "\(name)-\(stamp)-\(index)" : "\(name)-\(stamp)-\(index).\(ext)"
            let fallback = trashDir.appendingPathComponent(stamped)
            // 本批次里可能有同名项（~/Library 和 /Library 下各一个），APFS 默认不区分大小写
            let isFirstUse = reserved.insert(base.lowercased()).inserted
            return Move(source: url,
                        destination: isFirstUse ? trashDir.appendingPathComponent(base) : fallback,
                        fallback: fallback)
        }
    }

    /// 每行输出 `OK <序号>` 或 `FAIL <序号> <原因>`。
    /// 移动后把所有权 chown 回当前用户，否则 root:wheel 文件留在废纸篓里用户无法清理/恢复；
    /// chown 失败不影响结果：东西已经进了废纸篓。
    static func shellScript(_ moves: [Move], uid: uid_t, gid: gid_t) -> String {
        moves.enumerated().map { index, move in
            let src = shellQuote(move.source.path)
            let dst = shellQuote(move.destination.path)
            let alt = shellQuote(move.fallback.path)
            return "d=\(dst); if [ -e \"$d\" ] || [ -L \"$d\" ]; then d=\(alt); fi; "
                + "if e=$(/bin/mv -- \(src) \"$d\" 2>&1); then /usr/sbin/chown -R \(uid):\(gid) \"$d\" 2>/dev/null; echo \"OK \(index)\"; "
                + "else printf 'FAIL \(index) %s\\n' \"$(echo \"$e\" | tr '\\n' ' ')\"; fi"
        }.joined(separator: "\n")
    }

    static func appleScript(shell: String, admin: Bool) -> String {
        "do shell script \"\(appleScriptEscaped(shell))\"\(admin ? " with administrator privileges" : "") without altering line endings"
    }

    static func run(_ moves: [Move], script: String) -> (trashed: [URL], failures: [(URL, String)]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return ([], moves.map { ($0.source, error.localizedDescription) })
        }
        // 先读完再 wait，输出太多时才不会互相等死
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)

        var succeeded = Set<Int>()
        var reasons: [Int: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 2)
            guard parts.count >= 2, let index = Int(parts[1]) else { continue }
            if parts[0] == "OK" { succeeded.insert(index) }
            if parts[0] == "FAIL" { reasons[index] = parts.count > 2 ? String(parts[2]) : "移动失败" }
        }

        let scriptError: String
        if process.terminationStatus == 0 {
            scriptError = "没有返回结果"
        } else if text.contains("-128") {
            scriptError = "已取消管理员授权"
        } else {
            scriptError = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var trashed: [URL] = []
        var failures: [(URL, String)] = []
        for (index, move) in moves.enumerated() {
            // 没拿到明确结果时以磁盘为准：源文件没了就是搬走了
            if succeeded.contains(index) || (reasons[index] == nil && !PathSafety.itemExists(move.source.path)) {
                trashed.append(move.source)
            } else {
                failures.append((move.source, reasons[index] ?? scriptError))
            }
        }
        return (trashed, failures)
    }
}

// MARK: - shell / AppleScript 转义

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
func appleScriptEscaped(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}
