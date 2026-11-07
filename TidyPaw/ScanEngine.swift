import Foundation
import Combine
import os

/// 跨分类汇总。同一个文件可能同时出现在多个分类（缓存与卸载残留、大文件与下载旧文件），
/// 所以这里的数字都按「实际要动的那批文件」算，不是各分类简单相加。
struct ScanOverview {
    var selectedCount = 0
    var selectedSize: Int64 = 0
    var permanentCount = 0          // 选中项里来自「废纸篓」、会被永久删除的数量
    var reclaimable: Int64 = 0
    var groupTotals: [CategoryGroup: Int64] = [:]
}

/// 决定一次清理实际要动哪些文件。纯函数，不碰磁盘以外的状态。
enum CleanPlanner {
    struct Plan {
        var items: [FileItem] = []
        var keptForSafety = 0
    }

    static func plan(selected: [FileItem]) -> Plan {
        let top = topLevel(selected)
        let paths = Set(top.map(\.path))
        let dirs = Set(top.filter(\.isDirectory).map(\.path))

        var plan = Plan()
        for item in top {
            // 「已保留另一份」的承诺要兑现：保留的那份也要被删或已经不在了，这份就不能动
            if let keeper = item.keeperPath,
               paths.contains(keeper) || hasAncestor(keeper, in: dirs) || !PathSafety.itemExists(keeper) {
                plan.keptForSafety += 1
            } else {
                plan.items.append(item)
            }
        }
        return plan
    }

    /// 去掉重复路径和「父目录也在列表里」的项，保持先出现者优先。
    static func topLevel(_ items: [FileItem]) -> [FileItem] {
        var seen = Set<String>()
        let unique = items.filter { seen.insert($0.path).inserted }
        let dirs = Set(unique.filter(\.isDirectory).map(\.path))
        guard !dirs.isEmpty else { return unique }
        return unique.filter { !hasAncestor($0.path, in: dirs) }
    }

    static func hasAncestor(_ path: String, in dirs: Set<String>) -> Bool {
        guard !dirs.isEmpty else { return false }
        var current = Substring(path)
        while let slash = current.lastIndex(of: "/"), slash != current.startIndex {
            current = current[..<slash]
            if dirs.contains(String(current)) { return true }
        }
        return false
    }
}

enum RemovalResult: Sendable {
    case trashed       // 移入废纸篓，可恢复
    case deleted       // 原本就在废纸篓里，已永久删除
    case failed
}

@MainActor
final class ScanEngine: ObservableObject {
    nonisolated private static let log = Logger(subsystem: "com.ahuamiao.roudaiguanjia", category: "clean")
    /// 同时扫描几个分类。留出余量，别把 Swift 并发的线程池占满（Intel 机型核心少）。
    private static let maxConcurrentScans = 3

    @Published private(set) var categories: [ScanCategory]
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published private(set) var diskTotal: Int64 = 0
    @Published private(set) var diskFree: Int64 = 0
    @Published var lastCleanSummary: CleanSummary?

    private var bag = Set<AnyCancellable>()
    private var overviewCache: ScanOverview?

    init() {
        categories = CategoryKind.allCases.map { ScanCategory(kind: $0) }
        // 让任一分类内部（勾选/扫描状态）变化时，引擎本身也通知视图刷新，
        // 这样底部「合计」之类的跨分类汇总才能实时更新。
        for cat in categories {
            cat.objectWillChange
                .sink { [weak self] _ in
                    self?.overviewCache = nil
                    self?.objectWillChange.send()
                }
                .store(in: &bag)
        }
        refreshDiskInfo()
    }

    func category(_ kind: CategoryKind) -> ScanCategory? {
        categories.first { $0.kind == kind }
    }

    // MARK: - 跨分类汇总

    var hasScannedAnything: Bool { categories.contains { $0.state == .done } }

    var overview: ScanOverview {
        if let overviewCache { return overviewCache }
        var result = ScanOverview()

        let plan = CleanPlanner.plan(selected: selectedItems())
        let trashPaths = Set(category(.trash)?.items.map(\.path) ?? [])
        result.selectedCount = plan.items.count
        result.selectedSize = plan.items.reduce(0) { $0 + $1.size }
        result.permanentCount = plan.items.filter { trashPaths.contains($0.path) }.count

        // 分组小计也去重：先出现的分类算数，这样各组加起来等于总数
        var seen = Set<String>()
        var allItems: [(item: FileItem, group: CategoryGroup)] = []
        for cat in categories {
            for item in cat.items where seen.insert(item.path).inserted {
                allItems.append((item, cat.kind.group))
            }
        }
        let dirs = Set(allItems.filter(\.item.isDirectory).map(\.item.path))
        for entry in allItems where !CleanPlanner.hasAncestor(entry.item.path, in: dirs) {
            result.reclaimable += entry.item.size
            result.groupTotals[entry.group, default: 0] += entry.item.size
        }

        overviewCache = result
        return result
    }

    private func selectedItems() -> [FileItem] {
        categories.flatMap { cat in cat.items.filter { cat.selectedIDs.contains($0.id) } }
    }

    // MARK: - 扫描

    func scanAll() {
        guard !isScanning, !isCleaning else { return }
        // 必须在这里同步置位：放进 Task 会晚一拍，连点两下就会启动两轮扫描
        isScanning = true
        let queue = categories
        for cat in queue { cat.state = .scanning }
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                var next = queue.makeIterator()
                for _ in 0..<Self.maxConcurrentScans {
                    if let cat = next.next() { group.addTask { await self.scan(cat) } }
                }
                while await group.next() != nil {
                    if let cat = next.next() { group.addTask { await self.scan(cat) } }
                }
            }
            isScanning = false
        }
    }

    func scanOne(_ cat: ScanCategory) {
        guard !isScanning, !isCleaning else { return }
        isScanning = true
        Task { @MainActor in
            await scan(cat)
            isScanning = false
        }
    }

    private func scan(_ cat: ScanCategory) async {
        cat.state = .scanning
        let kind = cat.kind
        // 扫描和分类都放后台，主线程只负责把结果装回去
        let (outcome, purposes) = await Task.detached(priority: .userInitiated) {
            let outcome = FileScanner.scan(kind)
            return (outcome, FileClassifier.classifyAll(outcome.items, category: kind))
        }.value
        cat.items = outcome.items
        cat.purposes = purposes
        cat.issue = outcome.issue
        cat.selectedIDs = kind.defaultSelectAll ? Set(outcome.items.map { $0.id }) : []
        cat.state = .done
    }

    // MARK: - 磁盘信息

    func refreshDiskInfo() {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        if let rv = try? FileScanner.home.resourceValues(forKeys: keys) {
            diskTotal = Int64(rv.volumeTotalCapacity ?? 0)
            diskFree = rv.volumeAvailableCapacityForImportantUsage ?? 0
        }
    }

    // MARK: - 清理（安全）

    private struct CleanOutcome: Sendable {
        var removedPaths = Set<String>()
        var removedDirs = Set<String>()
        var trashedCount = 0
        var trashedBytes: Int64 = 0
        var deletedCount = 0
        var deletedBytes: Int64 = 0
        var failed = 0
    }

    func cleanSelected() {
        guard !isScanning, !isCleaning else { return }
        let plan = CleanPlanner.plan(selected: selectedItems())
        guard !plan.items.isEmpty else { return }
        isCleaning = true
        let items = plan.items
        let keptForSafety = plan.keptForSafety

        Task { @MainActor in
            // 几千个文件逐个移废纸篓要好一会儿，放后台，界面不卡
            let outcome = await Task.detached(priority: .userInitiated) { Self.perform(items) }.value
            applyRemovals(outcome)
            refreshDiskInfo()
            isCleaning = false
            lastCleanSummary = CleanSummary(trashedCount: outcome.trashedCount,
                                            trashedBytes: outcome.trashedBytes,
                                            deletedCount: outcome.deletedCount,
                                            deletedBytes: outcome.deletedBytes,
                                            failed: outcome.failed,
                                            keptForSafety: keptForSafety)
            // 刚移进去的东西让「废纸篓」分类的数字过时了
            if let trash = category(.trash), trash.state == .done { scanOne(trash) }
        }
    }

    nonisolated private static func perform(_ items: [FileItem]) -> CleanOutcome {
        var outcome = CleanOutcome()
        for item in items {
            switch remove(item.url) {
            case .trashed:
                outcome.trashedCount += 1
                outcome.trashedBytes += item.size
            case .deleted:
                outcome.deletedCount += 1
                outcome.deletedBytes += item.size
            case .failed:
                outcome.failed += 1
                continue
            }
            outcome.removedPaths.insert(item.path)
            if item.isDirectory { outcome.removedDirs.insert(item.path) }
        }
        return outcome
    }

    /// 把已经动过的文件从所有分类里摘掉，否则同一个文件还留在别的分类，下次清理必然报失败。
    private func applyRemovals(_ outcome: CleanOutcome) {
        func isGone(_ path: String) -> Bool {
            outcome.removedPaths.contains(path) || CleanPlanner.hasAncestor(path, in: outcome.removedDirs)
        }
        for cat in categories {
            let gone = cat.items.filter { item in
                isGone(item.path) || (item.keeperPath.map(isGone) ?? false)   // 保留的那份没了，它就不再是「多余的副本」
            }
            guard !gone.isEmpty else { continue }
            let goneIDs = Set(gone.map(\.id))
            cat.items.removeAll { goneIDs.contains($0.id) }
            cat.selectedIDs.subtract(goneIDs)
        }
    }

    /// 安全删除策略：
    /// - 已经在废纸篓里的文件 → 永久删除（即「清空废纸篓」语义）
    /// - 其它任何文件 → 移入废纸篓，随时可恢复，绝不直接抹除
    nonisolated static func remove(_ url: URL) -> RemovalResult {
        guard !PathSafety.isProtected(url) else {
            log.error("拒绝清理受保护路径 \(url.path, privacy: .public)")
            return .failed
        }
        // 仅用「规范化 + 解析符号链接」后的路径来判断是否真的在废纸篓里（按路径分段比较，
        // 避免 ~/.Trashes、~/.TrashBackup 这类同前缀目录或 .. 路径被误判）。
        // 实际删除仍针对原始 url，不动符号链接指向的真实文件。
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        let trashURL = FileScanner.home.appendingPathComponent(".Trash")
            .standardizedFileURL.resolvingSymlinksInPath()
        let inTrash = target.pathComponents.starts(with: trashURL.pathComponents)
        do {
            if inTrash {
                try FileManager.default.removeItem(at: url)   // 已在废纸篓 → 永久删除（清空语义）
                return .deleted
            }
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)  // 其它 → 移入废纸篓，可恢复
            return .trashed
        } catch {
            log.error("清理失败 \(url.path, privacy: .public)：\(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }
}
