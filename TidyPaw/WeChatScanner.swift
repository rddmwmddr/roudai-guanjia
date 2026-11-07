import Foundation
import UniformTypeIdentifiers

struct WeChatFile: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let size: Int64
    let modified: Date
    var name: String { url.lastPathComponent }
}

struct WeChatBucket: Identifiable, Sendable {
    let id = UUID()
    let label: String
    let count: Int             // 该类文件总数
    let size: Int64            // 该类总大小
    let files: [WeChatFile]    // 该类中最大的若干个（可能少于 count，见 isTruncated）
    var isTruncated: Bool { count > files.count }
}

struct WeChatResult: Sendable {
    let total: Int64
    let buckets: [WeChatBucket]
    let unreadable: Int
}

/// 微信数据分析（严格只读：仅统计大小并分类，绝不删改任何聊天数据）
enum WeChatScanner {
    static var candidateRoots: [URL] {
        let h = FileManager.default.homeDirectoryForCurrentUser
        return [
            h.appendingPathComponent("Library/Group Containers/5A4RE8SF68.com.tencent.xinWeChat"),
            h.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/com.tencent.xinWeChat"),
            h.appendingPathComponent("Library/Application Support/com.tencent.xinWeChat"),
        ]
    }

    /// 探测：(存在的根, 是否至少有一个可读)。可读 = 能列目录（没被 TCC 挡住）。
    static func probe() -> (roots: [URL], readable: Bool) {
        let fm = FileManager.default
        var roots: [URL] = []
        var readable = false
        for r in candidateRoots where fm.fileExists(atPath: r.path) {
            roots.append(r)
            if (try? fm.contentsOfDirectory(atPath: r.path)) != nil { readable = true }
        }
        return (roots, readable)
    }

    static func scan() -> WeChatResult {
        let fm = FileManager.default
        let roots = probe().roots
        var sizes: [String: Int64] = [:]
        var counts: [String: Int] = [:]
        // 只存 (url, size, 修改时间) 元组；UUID/WeChatFile 留到最终 top-N 再建，省掉对每个文件(可能上万)的分配
        var files: [String: [(url: URL, size: Int64, modified: Date)]] = [:]
        var unreadable = 0
        let keepN = 1000, pruneAt = 2000
        // contentType + 修改时间都并进这一次批量读，避免再单独读盘
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                                         .totalFileAllocatedSizeKey, .fileSizeKey, .contentTypeKey,
                                         .contentModificationDateKey]
        for root in roots {
            // 只数能真正进入的根（contentsOfDirectory 失败 = EPERM，跳过）
            guard (try? fm.contentsOfDirectory(atPath: root.path)) != nil else { unreadable += 1; continue }
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                         options: [.skipsHiddenFiles],
                                         errorHandler: { _, _ in unreadable += 1; return true }) else { continue }
            for case let url as URL in en {
                if Task.isCancelled { return result(sizes, counts, files, unreadable, keepN) }
                guard let rv = try? url.resourceValues(forKeys: keys) else { unreadable += 1; continue }
                if rv.isSymbolicLink == true { continue }                  // 不跟随符号链接 farm，避免误数整个 $HOME
                if rv.isDirectory == true {
                    if url.lastPathComponent.caseInsensitiveCompare("OpenData") == .orderedSame {
                        en.skipDescendants()                               // OpenData 是 File/ 的重复副本，跳过避免重复计
                    }
                    continue
                }
                guard rv.isRegularFile == true else { continue }
                let size = Int64(rv.totalFileAllocatedSize ?? rv.fileSize ?? 0)
                let b = bucket(for: url, contentType: rv.contentType)
                sizes[b, default: 0] += size
                counts[b, default: 0] += 1
                files[b, default: []].append((url, size, rv.contentModificationDate ?? .distantPast))
                // 超过 pruneAt 就排序留最大的 keepN，内存有上限又始终保留"最大的若干个"
                if files[b]!.count >= pruneAt {
                    files[b] = Array(files[b]!.sorted { $0.size > $1.size }.prefix(keepN))
                }
            }
        }
        return result(sizes, counts, files, unreadable, keepN)
    }

    private static func result(_ sizes: [String: Int64], _ counts: [String: Int],
                               _ files: [String: [(url: URL, size: Int64, modified: Date)]], _ unreadable: Int, _ keepN: Int) -> WeChatResult {
        let order = ["视频", "图片", "文档", "音频", "其他"]
        let buckets = order.compactMap { label -> WeChatBucket? in
            let c = counts[label] ?? 0
            guard c > 0 else { return nil }
            // 只对最终保留的最大 keepN 个建 WeChatFile（含 UUID）
            let top = (files[label] ?? []).sorted { $0.size > $1.size }.prefix(keepN)
                .map { WeChatFile(url: $0.url, size: $0.size, modified: $0.modified) }
            return WeChatBucket(label: label, count: c, size: sizes[label] ?? 0, files: Array(top))
        }
        return WeChatResult(total: sizes.values.reduce(0, +), buckets: buckets, unreadable: unreadable)
    }

    /// 微信把图片/语音存成专有格式（.pic/.dat/.silk），UTType 认不出，先按扩展名兜底；
    /// 未知扩展名再用已经批量读到的 contentType 判断，不再单独读盘。
    /// 注：.dat 是最大的假设——微信的加密图片多为 .dat，但 .dat 也可能是别的二进制；此处统一归「图片」。
    static func bucket(for url: URL, contentType ct: UTType?) -> String {
        switch url.pathExtension.lowercased() {
        case "pic", "pic_thumb", "dat", "heic", "webp", "jpg", "jpeg", "png", "gif", "bmp":
            return "图片"
        case "silk", "amr", "aud", "slk", "mp3", "m4a", "wav":
            return "音频"
        case "mp4", "mov", "m4v", "avi", "mkv":
            return "视频"
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "csv",
             "key", "pages", "numbers":
            return "文档"
        case "zip", "rar", "7z", "gz", "tar",                       // 压缩包归「其他」
             "db", "db-wal", "db-shm", "sqlite", "sqlite-wal",       // 消息数据库
             "fts", "idx", "log", "plist", "":                       // 索引/日志/无扩展名
            return "其他"
        default:
            guard let ct else { return "其他" }
            if ct.conforms(to: .image) { return "图片" }
            if ct.conforms(to: .movie) || ct.conforms(to: .audiovisualContent) { return "视频" }
            if ct.conforms(to: .audio) { return "音频" }
            if ct.conforms(to: .pdf) || ct.conforms(to: .text) || ct.conforms(to: .spreadsheet) { return "文档" }
            return "其他"
        }
    }
}
