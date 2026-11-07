import Foundation

// MARK: - 卸载相关模型（移植自 CleanDrop 的拖拽卸载器）

enum MatchConfidence: String, Sendable {
    case exact  = "精确匹配"
    case likely = "可能相关"
    case risky  = "高风险"

    var rank: Int {
        switch self {
        case .exact:  return 0
        case .likely: return 1
        case .risky:  return 2
        }
    }
}

struct RemovalCandidate: Identifiable, Hashable, Sendable {
    let id = UUID()
    let url: URL
    let kind: String
    let evidence: String
    let confidence: MatchConfidence
    let requiresAdmin: Bool
    let size: Int64?
    let defaultSelected: Bool
}

struct AppIdentity: Sendable {
    let appURL: URL
    let appName: String
    let bundleID: String?
    let executableName: String?
}

struct UninstallScanResult: Sendable {
    let identity: AppIdentity
    let candidates: [RemovalCandidate]
}

enum UninstallError: LocalizedError {
    case notApp
    case noBundle
    var errorDescription: String? {
        switch self {
        case .notApp:   return "请拖入一个 .app 应用程序包。"
        case .noBundle: return "无法读取这个应用的 Info.plist。"
        }
    }
}

// MARK: - 扫描器（每次扫描新建一个实例，无共享状态，可安全在后台线程使用）

final class UninstallScanner {
    private let fm = FileManager.default
    private var seenPaths = Set<String>()
    private var candidates = [RemovalCandidate]()

    func scan(appURL: URL) throws -> UninstallScanResult {
        seenPaths.removeAll()
        candidates.removeAll()

        let standardizedURL = appURL.standardizedFileURL
        guard standardizedURL.pathExtension.lowercased() == "app" else { throw UninstallError.notApp }
        guard let bundle = Bundle(url: standardizedURL) else { throw UninstallError.noBundle }

        let displayName =
            bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? standardizedURL.deletingPathExtension().lastPathComponent
        let executableName = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
        let rawBundleID = bundle.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleID = (rawBundleID?.isEmpty == true) ? nil : rawBundleID
        let identity = AppIdentity(appURL: standardizedURL, appName: displayName,
                                   bundleID: bundleID, executableName: executableName)

        addIfExists(standardizedURL, kind: "应用本体", evidence: "你拖入的应用程序包",
                    confidence: .exact, requiresAdmin: !userCanRemove(standardizedURL),
                    defaultSelected: true)

        scanUserLibrary(identity: identity)
        scanSystemLibrary(identity: identity)
        scanReceipts(identity: identity)

        let sorted = candidates.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence.rank < rhs.confidence.rank }
            if lhs.requiresAdmin != rhs.requiresAdmin { return !lhs.requiresAdmin }
            return lhs.url.path.localizedCaseInsensitiveCompare(rhs.url.path) == .orderedAscending
        }
        return UninstallScanResult(identity: identity, candidates: sorted)
    }

    // MARK: 用户级 ~/Library

    private func scanUserLibrary(identity: AppIdentity) {
        let home = fm.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let names = unique([identity.appName, identity.executableName].compactMap { $0 })

        if let bundleID = identity.bundleID {
            addIfExists(library.appendingPathComponent("Preferences/\(bundleID).plist"),
                        kind: "偏好设置", evidence: "文件名与 Bundle ID 完全一致",
                        confidence: .exact, requiresAdmin: false, defaultSelected: true)
            addMatches(in: library.appendingPathComponent("Preferences/ByHost", isDirectory: true),
                       kind: "按设备保存的偏好设置", evidence: "ByHost 文件名前缀与 Bundle ID 一致",
                       confidence: .exact, requiresAdmin: false, defaultSelected: true) { name in
                name.lowercased().hasPrefix(bundleID.lowercased() + ".")
            }
            for base in ["Application Support", "Caches", "Containers", "HTTPStorages", "WebKit", "Application Scripts"] {
                addIfExists(library.appendingPathComponent(base, isDirectory: true).appendingPathComponent(bundleID),
                            kind: kindName(for: base), evidence: "目录名与 Bundle ID 完全一致",
                            confidence: .exact, requiresAdmin: false, defaultSelected: true)
            }
            addIfExists(library.appendingPathComponent("Saved Application State/\(bundleID).savedState", isDirectory: true),
                        kind: "窗口状态", evidence: "保存状态目录与 Bundle ID 完全一致",
                        confidence: .exact, requiresAdmin: false, defaultSelected: true)
            addIfExists(library.appendingPathComponent("Cookies/\(bundleID).binarycookies"),
                        kind: "Cookie", evidence: "Cookie 文件名与 Bundle ID 完全一致",
                        confidence: .exact, requiresAdmin: false, defaultSelected: true)
            addIfExists(library.appendingPathComponent("LaunchAgents/\(bundleID).plist"),
                        kind: "登录/后台项目", evidence: "LaunchAgent 与 Bundle ID 完全一致",
                        confidence: .exact, requiresAdmin: false, defaultSelected: true)
        }

        for name in names {
            for base in ["Application Support", "Caches", "Logs"] {
                addIfExists(library.appendingPathComponent(base, isDirectory: true).appendingPathComponent(name),
                            kind: kindName(for: base), evidence: "目录名与 App 名称完全一致",
                            confidence: .exact, requiresAdmin: false, defaultSelected: true)
            }
        }

        if let bundleID = identity.bundleID {
            addMatches(in: library.appendingPathComponent("Group Containers", isDirectory: true),
                       kind: "共享容器", evidence: "名称按段包含 Bundle ID；可能被同厂商其他 App 共用",
                       confidence: .likely, requiresAdmin: false, defaultSelected: false) { name in
                bundleIDComponentMatch(name, bundleID)
            }
        }

        let normalizedNames = Set(names.map(normalized))
        addMatches(in: library.appendingPathComponent("Group Containers", isDirectory: true),
                   kind: "共享容器", evidence: "名称与 App 名称一致；请确认不是其他 App 共用",
                   confidence: .likely, requiresAdmin: false, defaultSelected: false) { name in
            // 用精确相等而非子串包含，避免 “Mail” 误配 “MailChimpHelper”
            normalizedNames.contains(normalized(name))
        }
    }

    // MARK: 系统级 /Library（需管理员）

    private func scanSystemLibrary(identity: AppIdentity) {
        let library = URL(fileURLWithPath: "/Library", isDirectory: true)
        let names = unique([identity.appName, identity.executableName].compactMap { $0 })

        if let bundleID = identity.bundleID {
            for path in ["Preferences/\(bundleID).plist", "LaunchAgents/\(bundleID).plist",
                         "LaunchDaemons/\(bundleID).plist", "Application Support/\(bundleID)"] {
                addIfExists(library.appendingPathComponent(path),
                            kind: systemKindName(for: path), evidence: "系统级文件名与 Bundle ID 完全一致",
                            confidence: .exact, requiresAdmin: true, defaultSelected: false)
            }
            addMatches(in: library.appendingPathComponent("PrivilegedHelperTools", isDirectory: true),
                       kind: "特权辅助工具", evidence: "名称按段匹配 Bundle ID；删除前请确认该辅助工具只属于此 App",
                       confidence: .likely, requiresAdmin: true, defaultSelected: false) { name in
                bundleIDComponentMatch(name, bundleID)
            }
        }

        for name in names {
            addIfExists(library.appendingPathComponent("Application Support", isDirectory: true).appendingPathComponent(name),
                        kind: "系统级应用数据", evidence: "系统级目录名与 App 名称完全一致",
                        confidence: .exact, requiresAdmin: true, defaultSelected: false)
        }
    }

    // MARK: 安装收据（高风险，默认不选）

    private func scanReceipts(identity: AppIdentity) {
        guard let bundleID = identity.bundleID else { return }
        addMatches(in: URL(fileURLWithPath: "/private/var/db/receipts", isDirectory: true),
                   kind: "安装收据", evidence: "pkg 收据前缀与 Bundle ID 一致；通常不建议默认删除",
                   confidence: .risky, requiresAdmin: true, defaultSelected: false) { name in
            let lower = name.lowercased()
            let id = bundleID.lowercased()
            return lower.hasPrefix(id + ".") || lower == "\(id).bom" || lower == "\(id).plist"
        }
    }

    // MARK: 累加助手

    private func addIfExists(_ url: URL, kind: String, evidence: String,
                             confidence: MatchConfidence, requiresAdmin: Bool, defaultSelected: Bool) {
        let standardizedURL = url.standardizedFileURL
        guard fm.fileExists(atPath: standardizedURL.path) else { return }
        guard seenPaths.insert(standardizedURL.path).inserted else { return }
        candidates.append(RemovalCandidate(
            url: standardizedURL, kind: kind, evidence: evidence, confidence: confidence,
            requiresAdmin: requiresAdmin, size: allocatedSize(at: standardizedURL),
            defaultSelected: defaultSelected
        ))
    }

    private func addMatches(in directory: URL, kind: String, evidence: String,
                            confidence: MatchConfidence, requiresAdmin: Bool, defaultSelected: Bool,
                            matches: (String) -> Bool) {
        guard let items = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for item in items where matches(item.lastPathComponent) {
            addIfExists(item, kind: kind, evidence: evidence, confidence: confidence,
                        requiresAdmin: requiresAdmin, defaultSelected: defaultSelected)
        }
    }

    private func canWriteParent(of url: URL) -> Bool {
        fm.isWritableFile(atPath: url.deletingLastPathComponent().path)
    }

    /// 当前用户能否直接把这个 App 移到废纸篓（不必管理员提权）。
    /// 搬到废纸篓本质是 rename，POSIX 只要求父目录可写；本体本身可写与否不重要——
    /// 只要本体归当前用户所有，owner 随时能自己改权限后删。真正搬不动的是
    /// App Store / pkg 安装、root 所有的本体（如 Compressor），它们才需要提权。
    private func userCanRemove(_ url: URL) -> Bool {
        guard canWriteParent(of: url) else { return false }
        if fm.isWritableFile(atPath: url.path) { return true }
        if let uid = (try? fm.attributesOfItem(atPath: url.path))?[.ownerAccountID] as? NSNumber {
            return uid.uint32Value == getuid()   // 本体只读但归我所有 → 仍可自行删除，不必提权
        }
        return false
    }

    private func allocatedSize(at url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                         .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        func fileSize(_ fileURL: URL) -> Int64 {
            guard let v = try? fileURL.resourceValues(forKeys: keys) else { return 0 }
            if v.isSymbolicLink == true { return 0 }
            return Int64(max(0, v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0))
        }
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        if v.isDirectory != true { return fileSize(url) }
        var total = fileSize(url)
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                     options: [], errorHandler: { _, _ in true }) else { return total }
        for case let fileURL as URL in en {
            if Task.isCancelled { return total }   // 换 App / 重扫时及时停止深目录遍历
            total += fileSize(fileURL)
        }
        return total
    }
}

// MARK: - 工具函数

private func unique<T: Hashable>(_ values: [T]) -> [T] {
    var seen = Set<T>()
    return values.filter { seen.insert($0).inserted }
}

func confidenceLabel(_ c: MatchConfidence) -> String { c.rawValue }

func kindName(for base: String) -> String {
    switch base {
    case "Application Support": return "应用数据"
    case "Caches":             return "缓存"
    case "Containers":         return "沙盒容器"
    case "HTTPStorages":       return "HTTP 存储"
    case "WebKit":             return "WebKit 数据"
    case "Application Scripts": return "应用脚本"
    case "Logs":               return "日志"
    default:                   return base
    }
}

func systemKindName(for path: String) -> String {
    if path.contains("LaunchDaemons") || path.contains("LaunchAgents") { return "系统级后台项目" }
    if path.contains("Preferences") { return "系统级偏好设置" }
    return "系统级应用数据"
}

func normalized(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics
    let scalars = value.lowercased().unicodeScalars.filter { allowed.contains($0) }
    return String(String.UnicodeScalarView(scalars))
}

/// 把 name 按 `.` 分段后，判断是否把 bundleID 当作「完整的若干连续段」包含。
/// 这样 com.foo.bar 能匹配 TEAMID.com.foo.bar / group.com.foo.bar / com.foo.bar.helper，
/// 但绝不会误配 com.foo.bartender（边界不在 `.` 上）。
func bundleIDComponentMatch(_ name: String, _ id: String) -> Bool {
    let n = name.lowercased()
    let i = id.lowercased()
    return n == i || n.hasPrefix(i + ".") || n.hasSuffix("." + i) || n.contains("." + i + ".")
}
