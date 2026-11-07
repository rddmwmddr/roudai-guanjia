import Foundation
import CryptoKit

/// 纯函数式的文件扫描器。所有方法都在后台线程调用，不触碰 UI。
enum FileScanner {
    static let fm = FileManager.default
    static var home: URL { fm.homeDirectoryForCurrentUser }

    /// 用户个人目录中值得扫描大文件/重复文件的根目录
    static var userRoots: [URL] {
        ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"]
            .map { home.appendingPathComponent($0) }
    }

    // MARK: - 入口

    static func scan(_ kind: CategoryKind) -> [FileItem] {
        switch kind {
        case .userCaches:
            return children(of: home.appendingPathComponent("Library/Caches"))
        case .appLogs:
            return children(of: home.appendingPathComponent("Library/Logs"))
        case .xcodeDerivedData:
            return children(of: home.appendingPathComponent("Library/Developer/Xcode/DerivedData"))
        case .xcodeArchives:
            return archives()
        case .xcodeDeviceSupport:
            return deviceSupport()
        case .trash:
            return children(of: home.appendingPathComponent(".Trash"))
        case .downloadsOld:
            return oldEntries(in: home.appendingPathComponent("Downloads"), olderThanDays: 90)
        case .largeFiles:
            return largeFiles(minBytes: 200 * 1024 * 1024)
        case .duplicates:
            return duplicates(minBytes: 1024 * 1024)
        case .appLeftovers:
            return appLeftovers()
        }
    }

    // MARK: - 卸载残留

    /// 把 LeftoverScanner 找出的候选 URL 包装成 FileItem（带体积）
    static func appLeftovers() -> [FileItem] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        return LeftoverScanner.candidateURLs().compactMap { url -> FileItem? in
            let rv = try? url.resourceValues(forKeys: keys)
            let bytes = size(of: url)
            guard bytes > 0 else { return nil }
            return FileItem(url: url,
                            size: bytes,
                            modified: rv?.contentModificationDate ?? .distantPast,
                            isDirectory: rv?.isDirectory ?? false)
        }
    }

    // MARK: - 基础工具

    /// 递归累加一个文件/文件夹占用的磁盘空间
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        if let rv = try? url.resourceValues(forKeys: keys), rv.isRegularFile == true {
            return Int64(rv.totalFileAllocatedSize ?? rv.fileAllocatedSize ?? rv.fileSize ?? 0)
        }
        var total: Int64 = 0
        guard let en = fm.enumerator(at: url,
                                     includingPropertiesForKeys: Array(keys),
                                     options: [],
                                     errorHandler: { _, _ in true }) else { return 0 }
        for case let child as URL in en {
            guard let rv = try? child.resourceValues(forKeys: keys), rv.isRegularFile == true else { continue }
            total += Int64(rv.totalFileAllocatedSize ?? rv.fileAllocatedSize ?? rv.fileSize ?? 0)
        }
        return total
    }

    /// 列出某目录下的直接子项，每一项都计算好体积，按需要过滤掉 0 字节项
    static func children(of dir: URL) -> [FileItem] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        guard let entries = try? fm.contentsOfDirectory(at: dir,
                                                        includingPropertiesForKeys: Array(keys),
                                                        options: []) else { return [] }
        return entries.compactMap { url -> FileItem? in
            let rv = try? url.resourceValues(forKeys: keys)
            let isDir = rv?.isDirectory ?? false
            let bytes = size(of: url)
            guard bytes > 0 else { return nil }
            return FileItem(url: url,
                            size: bytes,
                            modified: rv?.contentModificationDate ?? .distantPast,
                            isDirectory: isDir)
        }
    }

    // MARK: - Xcode 归档

    static func archives() -> [FileItem] {
        let root = home.appendingPathComponent("Library/Developer/Xcode/Archives")
        guard let en = fm.enumerator(at: root,
                                     includingPropertiesForKeys: [.isDirectoryKey],
                                     options: [.skipsHiddenFiles],
                                     errorHandler: { _, _ in true }) else { return [] }
        var result: [FileItem] = []
        for case let url as URL in en where url.pathExtension == "xcarchive" {
            en.skipDescendants()  // 把整个 .xcarchive 当作一个条目
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            result.append(FileItem(url: url, size: size(of: url), modified: mod, isDirectory: true))
        }
        return result
    }

    // MARK: - 设备支持文件

    static func deviceSupport() -> [FileItem] {
        let base = home.appendingPathComponent("Library/Developer/Xcode")
        let dirs = ["iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport", "macOS DeviceSupport"]
        return dirs.flatMap { children(of: base.appendingPathComponent($0)) }
    }

    // MARK: - 旧文件（按修改时间）

    static func oldEntries(in dir: URL, olderThanDays days: Int) -> [FileItem] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        return children(of: dir).filter { $0.modified < cutoff }
    }

    // MARK: - 大文件

    static func largeFiles(minBytes: Int64) -> [FileItem] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey]
        var result: [FileItem] = []
        for root in userRoots {
            guard let en = fm.enumerator(at: root,
                                         includingPropertiesForKeys: Array(keys),
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                         errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in en {
                guard let rv = try? url.resourceValues(forKeys: keys), rv.isRegularFile == true else { continue }
                let bytes = Int64(rv.totalFileAllocatedSize ?? rv.fileSize ?? 0)
                guard bytes >= minBytes else { continue }
                result.append(FileItem(url: url, size: bytes,
                                       modified: rv.contentModificationDate ?? .distantPast,
                                       isDirectory: false))
            }
        }
        return result
    }

    // MARK: - 重复文件

    /// 先按体积分组（便宜），只有体积相同的才去算哈希（贵），最后把多余副本列出来
    static func duplicates(minBytes: Int64) -> [FileItem] {
        let roots = ["Desktop", "Documents", "Downloads"].map { home.appendingPathComponent($0) }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]

        var bySize: [Int64: [URL]] = [:]
        for root in roots {
            guard let en = fm.enumerator(at: root,
                                         includingPropertiesForKeys: Array(keys),
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                         errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in en {
                guard let rv = try? url.resourceValues(forKeys: keys),
                      rv.isRegularFile == true,
                      let s = rv.fileSize, Int64(s) >= minBytes else { continue }
                bySize[Int64(s), default: []].append(url)
            }
        }

        var result: [FileItem] = []
        for (bytes, urls) in bySize where urls.count > 1 {
            var byHash: [String: [URL]] = [:]
            for url in urls {
                if let h = sha256(of: url) { byHash[h, default: []].append(url) }
            }
            for (_, group) in byHash where group.count > 1 {
                // 路径排序后保留第一份，其余视为可删除的重复副本
                let sorted = group.sorted { $0.path < $1.path }
                for dup in sorted.dropFirst() {
                    let mod = (try? dup.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    result.append(FileItem(url: dup, size: bytes, modified: mod, isDirectory: false))
                }
            }
        }
        return result
    }

    /// 流式计算 SHA-256，避免一次性把大文件读进内存
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
