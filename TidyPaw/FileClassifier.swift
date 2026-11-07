import Foundation
import UniformTypeIdentifiers
import AppKit

/// 一次分类的结果：一个简短的中文类型标签 + 一句「用途/来源」说明。纯值类型。
struct FilePurpose: Hashable, Sendable {
    let typeLabel: String     // 视频 / 图片 / 缓存数据 / 文件夹 …
    let explanation: String   // "Safari 的缓存数据，清掉后会自动重建"
}

/// 给每个扫描到的条目判断「这是什么类型」+「大概是干嘛的」。
/// 两条轴互相独立：类型由 UTType 决定，用途由它所属的清理分类 + 名字解析决定。
enum FileClassifier {

    /// 批量分类（在后台线程一次性算完一类的所有条目）。
    /// 用一个本地 cache 复用 bundle id → 应用名 的解析结果，避免重复的 LaunchServices 查询，也避免全局可变状态。
    static func classifyAll(_ items: [FileItem], category: CategoryKind) -> [UUID: FilePurpose] {
        var nameCache: [String: String?] = [:]
        var out: [UUID: FilePurpose] = [:]
        out.reserveCapacity(items.count)
        for item in items {
            let type = coarseType(of: item)
            let why = explanation(for: item, category: category, type: type, nameCache: &nameCache)
            out[item.id] = FilePurpose(typeLabel: type, explanation: why)
        }
        return out
    }

    // MARK: - 类型（UTType 驱动）

    static func coarseType(of item: FileItem) -> String {
        let ext = item.url.pathExtension.lowercased()
        // dyn.* 类型没有 localizedDescription，按扩展名特判
        if ext == "xcarchive" { return "Xcode归档" }
        if ext == "noindex"   { return "缓存数据" }

        let ct = (try? item.url.resourceValues(forKeys: [.contentTypeKey]).contentType)
                 ?? UTType(filenameExtension: ext)

        guard let ct else { return item.isDirectory ? "文件夹" : "文件" }

        // 顺序重要：音频要排在视频前面（public.audio 也符合 audiovisualContent，反过来所有音频都会被判成视频）；
        // 磁盘镜像要排在压缩包前面（.dmg 同时符合两者）
        if ct.conforms(to: .audio) { return "音频" }
        if ct.conforms(to: .movie) || ct.conforms(to: .audiovisualContent) { return "视频" }
        if ct.conforms(to: .image) { return "图片" }
        if ct.conforms(to: .diskImage) { return "磁盘镜像" }
        if ["pkg", "ipa", "mpkg"].contains(ext)
            || ct.identifier.contains("installer-package")
            || ct.identifier.contains("itunes.ipa") { return "安装包" }
        if ct.conforms(to: .archive) { return "压缩包" }
        if ct.conforms(to: .application) { return "应用程序" }
        if ct.conforms(to: .sourceCode) { return "代码" }
        if ct.conforms(to: .spreadsheet) || ext == "csv" { return "表格" }
        if ct.conforms(to: .pdf) { return "PDF" }
        if ct.conforms(to: .text) { return "文档" }
        if item.isDirectory || ct.conforms(to: .folder) { return "文件夹" }
        if let d = ct.localizedDescription, !d.isEmpty { return d }
        return ext.isEmpty ? "文件" : ext.uppercased()
    }

    // MARK: - 用途/来源（分类驱动）

    static func explanation(for item: FileItem,
                            category: CategoryKind,
                            type: String,
                            nameCache: inout [String: String?]) -> String {
        let name = item.name
        switch category {
        case .userCaches:
            if let app = appName(forFolder: name, &nameCache) {
                return "\(app) 的缓存数据，清掉后会自动重建"
            }
            if looksLikeBundleID(name) {
                return "\(name) 的残留缓存（应用可能已卸载），可安全清理"
            }
            return "\(name) 的缓存数据，可安全清理"

        case .appLogs:
            if let app = appName(forFolder: name, &nameCache) {
                return "\(app) 的运行日志，可安全清理"
            }
            return "\(name) 的运行日志，可安全清理"

        case .xcodeDerivedData:
            if let proj = xcodeProjectName(fromDerivedDataFolder: name) {
                return "Xcode 工程「\(proj)」的编译中间产物，下次编译会重新生成"
            }
            return "Xcode 共享编译缓存（\(name)），可安全清理"

        case .xcodeArchives:
            return "Xcode 打包归档（含 dSYM），删除前请确认不再需要"
        case .xcodeDeviceSupport:
            return "连接真机时生成的调试符号，重连设备会重新生成"

        case .trash:
            return "已移入废纸篓的\(type)，清空后不可恢复"
        case .downloadsOld:
            return "下载目录中的\(type)，超过 90 天未修改，可能仍有用"
        case .largeFiles:
            return "\(rootFolderCN(for: item.url))中的大\(type)（\(formatBytes(item.size))）"
        case .duplicates:
            if let keeper = item.keeperPath {
                return "与 \((keeper as NSString).abbreviatingWithTildeInPath) 内容完全相同的重复\(type)，清理时保留那一份"
            }
            return "与其他文件内容完全相同的重复\(type)"

        case .appLeftovers:
            return "疑似已卸载应用的残留：\(leftoverKindCN(for: item.url))，移到废纸篓可恢复"
        }
    }

    // MARK: - 名字 → 应用名（带本地 cache）

    /// 一些常见的、不是 bundle id 的文件夹名，给个更友好的中文叫法
    static let curatedNames: [String: String] = [
        "Homebrew": "Homebrew", "Google": "Google", "CloudKit": "iCloud (CloudKit)",
        "ChatGPTHelper": "ChatGPT", "Codex": "Codex", "GeoServices": "地图服务",
    ]

    static func appName(forFolder folder: String, _ cache: inout [String: String?]) -> String? {
        if let hit = cache[folder] { return hit }
        let resolved = curatedNames[folder] ?? appDisplayName(forBundleID: folder)
        cache[folder] = resolved
        return resolved
    }

    /// nil = 不是 bundle id，或没有对应应用安装。优先取本地化显示名（中文/emoji 名）。
    static func appDisplayName(forBundleID id: String) -> String? {
        guard looksLikeBundleID(id),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
              let bundle = Bundle(url: url) else { return nil }
        let info = bundle.localizedInfoDictionary ?? bundle.infoDictionary
        if let name = (info?["CFBundleDisplayName"] as? String)
                      ?? (info?["CFBundleName"] as? String), !name.isEmpty {
            return name
        }
        return url.deletingPathExtension().lastPathComponent
    }

    static func looksLikeBundleID(_ s: String) -> Bool {
        LeftoverScanner.looksLikeBundleID(s)
    }

    /// DerivedData 文件夹名形如 <工程名>-<28位小写hash>，只剥掉结尾的 -hash
    static func xcodeProjectName(fromDerivedDataFolder folder: String) -> String? {
        guard let r = folder.range(of: "-[a-z]{28}$", options: .regularExpression) else {
            return nil
        }
        let proj = String(folder[folder.startIndex..<r.lowerBound])
        return proj.isEmpty ? nil : proj   // 仅有 hash 的文件夹 → 当共享缓存处理，不显示 工程「」
    }

    /// 大文件根目录的中文名。只看 Home 下的第一段：~/Documents/Movies/x.mov 属于「文稿」。
    static func rootFolderCN(for url: URL) -> String {
        let map = ["Desktop": "桌面", "Documents": "文稿", "Downloads": "下载",
                   "Movies": "影片", "Music": "音乐", "Pictures": "图片"]
        let homeParts = FileScanner.home.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > homeParts.count, parts.starts(with: homeParts) else { return "个人目录" }
        return map[parts[homeParts.count]] ?? "个人目录"
    }

    /// 残留文件按它所在的 Library 子目录给出种类
    static func leftoverKindCN(for url: URL) -> String {
        let p = url.path
        if p.contains("/Library/Caches/") { return "缓存数据" }
        if p.contains("/Library/Preferences/") { return "偏好设置" }
        if p.contains("/Library/Application Support/") { return "应用数据" }
        if p.contains("/Library/Logs/") { return "日志" }
        if p.contains("/Library/HTTPStorages/") { return "网络存储" }
        if p.contains("/Library/WebKit/") { return "网页数据" }
        if p.contains("/Library/Saved Application State/") { return "窗口状态" }
        return "残留文件"
    }
}
