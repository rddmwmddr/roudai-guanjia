import Foundation

// MARK: - 清理风险等级

/// 每一类垃圾的"安全程度"，决定默认是否勾选、以及界面提示颜色
enum CleanRisk {
    case safe       // 可放心清理：缓存/日志类，应用会自动重建
    case review     // 建议人工确认：你的个人文件或工程产物

    var label: String {
        switch self {
        case .safe:   return "可放心清理"
        case .review: return "建议先确认"
        }
    }
}

// MARK: - 清理分类

enum CategoryKind: String, CaseIterable, Identifiable {
    case userCaches         // 用户缓存
    case appLogs            // 应用日志
    case xcodeDerivedData   // Xcode 编译中间产物
    case xcodeArchives      // Xcode 归档
    case xcodeDeviceSupport // Xcode 设备支持文件
    case trash              // 废纸篓
    case downloadsOld       // 下载目录旧文件
    case largeFiles         // 大文件
    case duplicates         // 重复文件
    case appLeftovers       // 卸载残留

    var id: String { rawValue }

    var title: String {
        switch self {
        case .userCaches:         return "用户缓存"
        case .appLogs:            return "应用日志"
        case .xcodeDerivedData:   return "Xcode 编译缓存"
        case .xcodeArchives:      return "Xcode 归档"
        case .xcodeDeviceSupport: return "Xcode 设备支持"
        case .trash:              return "废纸篓"
        case .downloadsOld:       return "下载目录旧文件"
        case .largeFiles:         return "大文件"
        case .duplicates:         return "重复文件"
        case .appLeftovers:       return "卸载残留"
        }
    }

    var subtitle: String {
        switch self {
        case .userCaches:         return "~/Library/Caches，应用临时缓存，清掉后会自动重建"
        case .appLogs:            return "~/Library/Logs，应用运行日志，可安全清理"
        case .xcodeDerivedData:   return "~/Library/Developer/Xcode/DerivedData，编译中间产物，下次编译会重新生成"
        case .xcodeArchives:      return "~/Library/Developer/Xcode/Archives，App 归档与 dSYM，删除前请确认不再需要"
        case .xcodeDeviceSupport: return "连接真机时生成的调试符号，删除后重连设备会重新生成"
        case .trash:              return "~/.Trash，这里的「清理」是永久清空，不可恢复"
        case .downloadsOld:       return "~/Downloads 中超过 90 天未修改的文件，可能仍有用，请逐个确认"
        case .largeFiles:         return "个人目录中大于 200 MB 的文件，方便快速找出占空间大户"
        case .duplicates:         return "桌面/文稿/下载中内容完全相同的重复文件（保留一份）"
        case .appLeftovers:       return "已卸载应用在 ~/Library 留下的缓存/偏好/数据残留。判断保守、仅供参考，请逐项确认；清理走废纸篓可恢复"
        }
    }

    var systemImage: String {
        switch self {
        case .userCaches:         return "shippingbox"
        case .appLogs:            return "doc.text"
        case .xcodeDerivedData:   return "hammer"
        case .xcodeArchives:      return "archivebox"
        case .xcodeDeviceSupport: return "iphone.gen3"
        case .trash:              return "trash"
        case .downloadsOld:       return "clock.arrow.circlepath"
        case .largeFiles:         return "externaldrive"
        case .duplicates:         return "doc.on.doc"
        case .appLeftovers:       return "app.dashed"
        }
    }

    var risk: CleanRisk {
        switch self {
        case .userCaches, .appLogs, .xcodeDerivedData, .xcodeDeviceSupport:
            return .safe
        case .xcodeArchives, .trash, .downloadsOld, .largeFiles, .duplicates, .appLeftovers:
            return .review
        }
    }

    /// 扫描完成后是否默认全选（仅对「可放心清理」的类别默认勾选）
    var defaultSelectAll: Bool { risk == .safe }

    /// 所属分组（用于侧边栏标签化分区，让用户一眼看懂）
    var group: CategoryGroup {
        switch self {
        case .userCaches, .appLogs, .trash:                       return .systemJunk
        case .xcodeDerivedData, .xcodeDeviceSupport, .xcodeArchives: return .development
        case .downloadsOld, .largeFiles, .duplicates:             return .personal
        case .appLeftovers:                                       return .apps
        }
    }
}

/// 清理分类的分组（侧边栏分区标题）
enum CategoryGroup: String, CaseIterable, Identifiable {
    case systemJunk  = "系统垃圾"
    case development = "开发"
    case personal    = "个人文件"
    case apps        = "应用残留"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .systemJunk:  return "trash"
        case .development: return "hammer"
        case .personal:    return "folder"
        case .apps:        return "app.badge"
        }
    }
}

// MARK: - 单个文件 / 文件夹条目

struct FileItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let size: Int64
    let modified: Date
    let isDirectory: Bool
    /// 仅重复文件有：这份副本对应的「保留那一份」的路径
    let keeperPath: String?

    init(url: URL, size: Int64, modified: Date, isDirectory: Bool, keeperPath: String? = nil) {
        self.id = UUID()
        self.url = url
        self.size = size
        self.modified = modified
        self.isDirectory = isDirectory
        self.keeperPath = keeperPath
    }

    var name: String { url.lastPathComponent }
    var path: String { url.path }
}

// MARK: - 一类垃圾的状态容器（可观察）

enum ScanState: Equatable {
    case idle       // 还没扫
    case scanning   // 扫描中
    case done       // 扫完
}

/// 扫描没能得出可靠结果的原因。没有它的话，读不了目录和目录是空的看起来一样，界面会误报「很干净」。
enum ScanIssue: Equatable, Sendable {
    case needsFullDiskAccess
    case inventoryUnavailable

    var message: String {
        switch self {
        case .needsFullDiskAccess:
            return "没有权限读取这里的内容，所以这里的结果不完整。请在「系统设置 › 隐私与安全性 › 完全磁盘访问权限」里打开肉呆大管家，再重新扫描。"
        case .inventoryUnavailable:
            return "这次没能拿到已安装应用的清单，无法判断哪些是残留，所以没有列出任何项目。请稍后重新扫描。"
        }
    }

    var shortLabel: String {
        switch self {
        case .needsFullDiskAccess:  return "需要磁盘访问权限"
        case .inventoryUnavailable: return "未能判断"
        }
    }
}

struct ScanOutcome: Sendable {
    let items: [FileItem]
    let issue: ScanIssue?
}

enum FileSortKey: Hashable { case size, name, date, type }

final class ScanCategory: ObservableObject, Identifiable {
    let kind: CategoryKind
    var id: CategoryKind { kind }

    @Published var items: [FileItem] = [] {
        didSet {
            totalSize = items.reduce(0) { $0 + $1.size }
            sortCache = nil
        }
    }
    @Published var selectedIDs: Set<UUID> = []
    @Published var state: ScanState = .idle
    @Published var issue: ScanIssue?
    /// 每个条目的类型/用途说明，扫描时在后台一次性算好
    @Published var purposes: [UUID: FilePurpose] = [:] {
        didSet { sortCache = nil }
    }

    /// items 改变时算好：侧边栏每次刷新都要读，不值得每次重新累加
    private(set) var totalSize: Int64 = 0
    private var sortCache: (key: FileSortKey, ascending: Bool, items: [FileItem])?

    init(kind: CategoryKind) { self.kind = kind }

    func isSelected(_ item: FileItem) -> Bool { selectedIDs.contains(item.id) }

    func toggle(_ item: FileItem) {
        if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
        else { selectedIDs.insert(item.id) }
    }

    func selectAll()  { selectedIDs = Set(items.map { $0.id }) }
    func selectNone() { selectedIDs = [] }

    /// 排好序的列表。结果会缓存：勾选一项不该让几千个文件名重新做一遍本地化比较。
    func sortedItems(by key: FileSortKey, ascending: Bool) -> [FileItem] {
        if let cache = sortCache, cache.key == key, cache.ascending == ascending { return cache.items }
        let sorted: [FileItem]
        switch key {
        case .size:
            sorted = items.sorted { $0.size < $1.size }
        case .date:
            sorted = items.sorted { $0.modified < $1.modified }
        case .name:
            sorted = items.map { ($0, $0.name) }
                .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
                .map { $0.0 }
        case .type:
            sorted = items.sorted { a, b in
                let ta = purposes[a.id]?.typeLabel ?? ""
                let tb = purposes[b.id]?.typeLabel ?? ""
                if ta != tb { return ta.localizedStandardCompare(tb) == .orderedAscending }
                return a.size > b.size
            }
        }
        let result = ascending ? sorted : Array(sorted.reversed())
        sortCache = (key, ascending, result)
        return result
    }
}

// MARK: - 清理结果汇总

struct CleanSummary: Identifiable {
    let id = UUID()
    let trashedCount: Int      // 移到废纸篓（可恢复，空间要清空废纸篓后才腾出来）
    let trashedBytes: Int64
    let deletedCount: Int      // 从废纸篓永久删除（空间真正腾出来）
    let deletedBytes: Int64
    let failed: Int
    let keptForSafety: Int     // 重复文件：保留的那份也被选中或已不在，这份不动
}

// MARK: - 通用格式化

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
