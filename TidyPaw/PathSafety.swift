import Foundation
import Darwin

/// 删除前的最后一道闸：无论扫描器因为什么产出了路径，这些位置都绝不能被整个搬走。
enum PathSafety {

    /// 能否当作「单段文件名」拼进路径。
    /// Info.plist 的内容不可信：空串、"."、".."、带斜杠都会让拼接结果落到别的目录
    /// （空的 CFBundleDisplayName 曾让整个 ~/Library/Application Support 被当成该 App 的数据）。
    static func isSafeComponent(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "." && trimmed != ".."
            && !s.contains("/") && !s.contains("\0")
    }

    /// 这个路径是否受保护：系统目录本身及其内容、Home 的祖先目录、Home 下的标准目录。
    static func isProtected(_ url: URL) -> Bool {
        let path = normalized(url)
        if protectedExact.contains(path) { return true }
        if protectedTrees.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        return (homePath + "/").hasPrefix(path + "/")   // Home 自己和它的所有祖先
    }

    /// 用 lstat 判断路径是否存在：坏掉的符号链接也算存在（fileExists 会跟随链接并返回 false）。
    static func itemExists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    // MARK: - 内部

    /// 只解析父目录的符号链接、保留最后一段：搬走的是链接本身，不是它指向的目标。
    private static func normalized(_ url: URL) -> String {
        let standard = url.standardizedFileURL
        guard standard.path != "/" else { return "/" }
        let parent = standard.deletingLastPathComponent().resolvingSymlinksInPath().path
        return (parent as NSString).appendingPathComponent(standard.lastPathComponent)
    }

    private static let homePath = normalized(FileManager.default.homeDirectoryForCurrentUser)

    private static let protectedTrees: [String] = ["/System", "/usr", "/bin", "/sbin"]
        .map { normalized(URL(fileURLWithPath: $0)) }

    private static let protectedExact: Set<String> = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let homeSubpaths = [
            ".Trash", "Applications", "Desktop", "Documents", "Downloads", "Library",
            "Movies", "Music", "Pictures", "Public",
            "Library/Application Scripts", "Library/Application Support", "Library/Caches",
            "Library/Containers", "Library/Cookies", "Library/Developer", "Library/Group Containers",
            "Library/HTTPStorages", "Library/LaunchAgents", "Library/Logs", "Library/Preferences",
            "Library/Preferences/ByHost", "Library/Saved Application State", "Library/WebKit",
        ]
        let systemPaths = [
            "/", "/Applications", "/Library", "/Users", "/Volumes", "/private", "/private/var",
            "/private/var/db", "/private/var/db/receipts",
            "/Library/Application Support", "/Library/Caches", "/Library/LaunchAgents",
            "/Library/LaunchDaemons", "/Library/Logs", "/Library/Preferences",
            "/Library/PrivilegedHelperTools",
        ]
        return Set(homeSubpaths.map { normalized(home.appendingPathComponent($0)) }
                   + systemPaths.map { normalized(URL(fileURLWithPath: $0)) })
    }()
}
