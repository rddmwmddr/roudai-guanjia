import Foundation
import CryptoKit
import Darwin

/// 纯函数式的文件扫描器。所有方法都在后台线程调用，不触碰 UI。
enum FileScanner {
    static let fm = FileManager.default
    static var home: URL { fm.homeDirectoryForCurrentUser }

    /// 用户个人目录中值得扫描大文件的根目录
    static var userRoots: [URL] {
        ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"]
            .map { home.appendingPathComponent($0) }
    }

    static var duplicateRoots: [URL] {
        ["Desktop", "Documents", "Downloads"].map { home.appendingPathComponent($0) }
    }

    /// 系统自动生成的文件，既不值得用户操心，也不该出现在清理列表里
    private static let systemNoiseFiles: Set<String> = [".DS_Store", ".localized"]

    // MARK: - 入口

    static func scan(_ kind: CategoryKind) -> ScanOutcome {
        let items: [FileItem]
        switch kind {
        case .userCaches:
            items = children(of: home.appendingPathComponent("Library/Caches"))
        case .appLogs:
            items = children(of: home.appendingPathComponent("Library/Logs"))
        case .xcodeDerivedData:
            items = children(of: home.appendingPathComponent("Library/Developer/Xcode/DerivedData"))
        case .xcodeArchives:
            items = archives()
        case .xcodeDeviceSupport:
            items = deviceSupport()
        case .trash:
            items = children(of: home.appendingPathComponent(".Trash"))
        case .downloadsOld:
            items = oldEntries(in: home.appendingPathComponent("Downloads"), olderThanDays: 90)
        case .largeFiles:
            items = largeFiles(minBytes: 200 * 1024 * 1024)
        case .duplicates:
            items = duplicates(minBytes: 1024 * 1024)
        case .appLeftovers:
            guard let urls = LeftoverScanner.candidateURLs() else {
                return ScanOutcome(items: [], issue: .inventoryUnavailable)
            }
            return ScanOutcome(items: leftoverItems(urls), issue: nil)
        }
        return ScanOutcome(items: items, issue: accessIssue(for: kind))
    }

    // MARK: - 权限

    /// 这个分类依赖的目录里，有没有被系统拦下来的。
    static func accessIssue(for kind: CategoryKind) -> ScanIssue? {
        let roots: [URL]
        switch kind {
        case .userCaches:         roots = [home.appendingPathComponent("Library/Caches")]
        case .appLogs:            roots = [home.appendingPathComponent("Library/Logs")]
        case .trash:              roots = [home.appendingPathComponent(".Trash")]
        case .downloadsOld:       roots = [home.appendingPathComponent("Downloads")]
        case .largeFiles:         roots = userRoots
        case .duplicates:         roots = duplicateRoots
        case .xcodeDerivedData, .xcodeArchives, .xcodeDeviceSupport, .appLeftovers:
            return nil
        }
        return roots.contains(where: isAccessDenied) ? .needsFullDiskAccess : nil
    }

    /// 目录不存在不算：那确实就是没有东西。
    static func isAccessDenied(_ dir: URL) -> Bool {
        do {
            _ = try fm.contentsOfDirectory(atPath: dir.path)
            return false
        } catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError { return true }
            guard let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError) ?? (ns.domain == NSPOSIXErrorDomain ? ns : nil),
                  posix.domain == NSPOSIXErrorDomain else { return false }
            return posix.code == Int(EPERM) || posix.code == Int(EACCES)
        }
    }

    // MARK: - 卸载残留

    /// 把 LeftoverScanner 找出的候选 URL 包装成 FileItem（带体积）
    static func leftoverItems(_ urls: [URL]) -> [FileItem] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        return urls.compactMap { url -> FileItem? in
            autoreleasepool {
                let rv = try? url.resourceValues(forKeys: keys)
                let bytes = size(of: url)
                guard bytes > 0 else { return nil }
                return FileItem(url: url,
                                size: bytes,
                                modified: rv?.contentModificationDate ?? .distantPast,
                                isDirectory: rv?.isDirectory ?? false)
            }
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
            guard !systemNoiseFiles.contains(url.lastPathComponent) else { return nil }
            // 每个子项单独一个 autoreleasepool：遍历深目录时临时对象不会一直累积到整个扫描结束
            return autoreleasepool {
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

    // MARK: - 旧文件

    static func oldEntries(in dir: URL, olderThanDays days: Int) -> [FileItem] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        return children(of: dir).filter { isInactive($0.url, since: cutoff) }
    }

    /// 这个文件/文件夹自 cutoff 以来有没有动静。拿不准就算有动静，宁可少列也不错列：
    /// - 刚下载的文件可能保留着服务器上的旧修改时间，所以也要看「加入目录的时间」；
    /// - 文件夹的修改时间不随深层文件变化，所以要往里查。
    static func isInactive(_ url: URL, since cutoff: Date) -> Bool {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .addedToDirectoryDateKey, .isDirectoryKey]
        guard let rv = try? url.resourceValues(forKeys: keys),
              let modified = rv.contentModificationDate, modified < cutoff else { return false }
        if let added = rv.addedToDirectoryDate, added >= cutoff { return false }
        guard rv.isDirectory == true else { return true }
        guard let en = fm.enumerator(at: url,
                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                     options: [],
                                     errorHandler: { _, _ in true }) else { return false }
        for case let child as URL in en {
            if let date = try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               date >= cutoff { return false }
        }
        return true
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

    private struct DuplicateCandidate {
        let url: URL
        let allocated: Int64
        let modified: Date
        let inDownloads: Bool
    }

    private struct InodeKey: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    /// 每个文件头尾各读这么多字节做初筛
    private static let sampleBytes: Int64 = 64 * 1024

    /// 逐层过滤，越往后越贵：体积相同 → 头尾指纹相同 → 全文 SHA-256 相同。
    static func duplicates(minBytes: Int64) -> [FileItem] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]

        var bySize: [Int64: [DuplicateCandidate]] = [:]
        for root in duplicateRoots {
            guard let en = fm.enumerator(at: root,
                                         includingPropertiesForKeys: Array(keys),
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                         errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in en {
                guard let rv = try? url.resourceValues(forKeys: keys),
                      rv.isRegularFile == true,
                      let s = rv.fileSize, Int64(s) >= minBytes else { continue }
                bySize[Int64(s), default: []].append(
                    DuplicateCandidate(url: url,
                                       allocated: Int64(rv.totalFileAllocatedSize ?? s),
                                       modified: rv.contentModificationDate ?? .distantPast,
                                       inDownloads: root.lastPathComponent == "Downloads"))
            }
        }

        var result: [FileItem] = []
        for (bytes, sameSize) in bySize where sameSize.count > 1 {
            let local = distinctLocalFiles(sameSize)
            guard local.count > 1 else { continue }

            var bySample: [SHA256.Digest: [DuplicateCandidate]] = [:]
            for file in local {
                if let digest = sampleDigest(of: file.url, size: bytes) {
                    bySample[digest, default: []].append(file)
                }
            }
            for (_, sameSample) in bySample where sameSample.count > 1 {
                var byHash: [SHA256.Digest: [DuplicateCandidate]] = [:]
                for file in sameSample {
                    if let digest = sha256(of: file.url, expectedSize: bytes) {
                        byHash[digest, default: []].append(file)
                    }
                }
                for (_, group) in byHash where group.count > 1 {
                    let ordered = group.sorted(by: shouldKeep)
                    let keeper = ordered[0].url.path
                    for dup in ordered.dropFirst() {
                        result.append(FileItem(url: dup.url, size: dup.allocated, modified: dup.modified,
                                               isDirectory: false, keeperPath: keeper))
                    }
                }
            }
        }
        return result
    }

    /// 去掉两种不算重复的情况：
    /// - 硬链接（或同一文件经两条路径扫到）：本来就是同一份数据，删一个什么也省不下；
    /// - 只在 iCloud 上的占位文件：一读就会触发下载，几百 GB 也可能被拉回本地。
    private static func distinctLocalFiles(_ files: [DuplicateCandidate]) -> [DuplicateCandidate] {
        var seen = Set<InodeKey>()
        // 先按保留优先级排序：同一份数据有多个名字时，留下的是最该留的那个名字
        return files.sorted(by: shouldKeep).filter { file in
            var st = stat()
            guard lstat(file.url.path, &st) == 0 else { return false }
            guard st.st_flags & UInt32(SF_DATALESS) == 0 else { return false }
            return seen.insert(InodeKey(device: st.st_dev, inode: st.st_ino)).inserted
        }
    }

    /// 排在前面的是保留的那份：优先留在桌面/文稿而不是下载目录，再优先留名字短的
    /// （「报告.pdf」而不是「报告 (1).pdf」）。
    private static func shouldKeep(_ a: DuplicateCandidate, over b: DuplicateCandidate) -> Bool {
        if a.inDownloads != b.inDownloads { return b.inDownloads }
        let aName = a.url.lastPathComponent.count
        let bName = b.url.lastPathComponent.count
        if aName != bName { return aName < bName }
        return a.url.path < b.url.path
    }

    /// 全文 SHA-256。读取出错或读到的长度对不上都返回 nil：
    /// 绝不能拿半截内容的哈希去比较，否则两个都读失败的不同文件会被判成「完全相同」，然后被建议删掉。
    static func sha256(of url: URL, expectedSize: Int64? = nil) -> SHA256.Digest? {
        withOpenFile(url) { fd, buffer in
            var hasher = SHA256()
            var total: Int64 = 0
            while true {
                let count = read(fd, buffer.baseAddress, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    return nil
                }
                if count == 0 { break }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
                total += Int64(count)
            }
            if let expectedSize, total != expectedSize { return nil }
            return hasher.finalize()
        }
    }

    /// 文件头尾各取一段算指纹，大多数体积相同但内容不同的文件在这一步就分开了，不用读完整个文件。
    private static func sampleDigest(of url: URL, size: Int64) -> SHA256.Digest? {
        withOpenFile(url) { fd, buffer in
            var hasher = SHA256()
            let tailStart = max(size - sampleBytes, 0)
            for start in [0, tailStart] {
                var offset = start
                let end = min(start + sampleBytes, size)
                while offset < end {
                    let wanted = min(Int(end - offset), buffer.count)
                    let count = pread(fd, buffer.baseAddress, wanted, off_t(offset))
                    if count < 0 {
                        if errno == EINTR { continue }
                        return nil
                    }
                    if count == 0 { return nil }   // 比声明的体积短：文件在扫描期间变了
                    hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
                    offset += Int64(count)
                }
            }
            return hasher.finalize()
        }
    }

    /// 打开文件并提供一块复用的缓冲区：不经过 Data，几十 GB 的文件也不会把内存撑大。
    private static func withOpenFile<T>(_ url: URL, _ body: (Int32, UnsafeMutableRawBufferPointer) -> T?) -> T? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)   // 哈希只读一遍，别把系统文件缓存冲掉
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 16)
        defer { buffer.deallocate() }
        return body(fd, buffer)
    }
}
