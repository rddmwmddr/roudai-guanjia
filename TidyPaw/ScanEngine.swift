import Foundation
import Combine
import os

@MainActor
final class ScanEngine: ObservableObject {
    private static let log = Logger(subsystem: "com.ahuamiao.roudaiguanjia", category: "clean")
    @Published private(set) var categories: [ScanCategory]
    @Published private(set) var isScanning = false
    @Published private(set) var progressText = ""
    @Published private(set) var diskTotal: Int64 = 0
    @Published private(set) var diskFree: Int64 = 0
    @Published var lastCleanSummary: CleanSummary?

    private var bag = Set<AnyCancellable>()

    init() {
        categories = CategoryKind.allCases.map { ScanCategory(kind: $0) }
        // 让任一分类内部（勾选/扫描状态）变化时，引擎本身也通知视图刷新，
        // 这样底部「合计」之类的跨分类汇总才能实时更新。
        for cat in categories {
            cat.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &bag)
        }
        refreshDiskInfo()
    }

    func category(_ kind: CategoryKind) -> ScanCategory? {
        categories.first { $0.kind == kind }
    }

    // MARK: - 跨分类汇总

    var totalSelectedSize: Int64 { categories.reduce(0) { $0 + $1.selectedSize } }
    var totalSelectedCount: Int { categories.reduce(0) { $0 + $1.selectedCount } }
    var totalReclaimable: Int64 { categories.reduce(0) { $0 + $1.totalSize } }
    var hasScannedAnything: Bool { categories.contains { $0.state == .done } }

    // MARK: - 扫描

    func scanAll() {
        guard !isScanning else { return }
        Task { @MainActor in
            isScanning = true
            for cat in categories { await scan(cat) }
            isScanning = false
            progressText = ""
        }
    }

    func scanOne(_ cat: ScanCategory) {
        Task { @MainActor in
            guard !isScanning else { return }   // 和 scanAll 同样的重入保护，避免重叠扫描
            isScanning = true
            await scan(cat)
            isScanning = false
            progressText = ""
        }
    }

    private func scan(_ cat: ScanCategory) async {
        cat.state = .scanning
        progressText = "正在扫描：\(cat.kind.title)…"
        let kind = cat.kind
        let items = await Task.detached(priority: .userInitiated) {
            FileScanner.scan(kind).sorted { $0.size > $1.size }
        }.value
        // 在后台一次性算好每个条目的类型/用途说明
        let purposes = await Task.detached(priority: .userInitiated) {
            FileClassifier.classifyAll(items, category: kind)
        }.value
        cat.items = items
        cat.purposes = purposes
        cat.selectedIDs = kind.defaultSelectAll ? Set(items.map { $0.id }) : []
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

    func cleanSelected() {
        var freed: Int64 = 0
        var removed = 0
        var failed = 0

        for cat in categories {
            let selected = cat.items.filter { cat.selectedIDs.contains($0.id) }
            var doneIDs = Set<UUID>()
            for item in selected {
                if Self.remove(item.url) {
                    freed += item.size
                    removed += 1
                    doneIDs.insert(item.id)
                } else {
                    failed += 1
                }
            }
            cat.items.removeAll { doneIDs.contains($0.id) }
            cat.selectedIDs.subtract(doneIDs)
        }

        refreshDiskInfo()
        lastCleanSummary = CleanSummary(freed: freed, removed: removed, failed: failed)
    }

    /// 安全删除策略：
    /// - 已经在废纸篓里的文件 → 永久删除（即「清空废纸篓」语义）
    /// - 其它任何文件 → 移入废纸篓，随时可恢复，绝不直接抹除
    static func remove(_ url: URL) -> Bool {
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
            } else {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)  // 其它 → 移入废纸篓，可恢复
            }
            return true
        } catch {
            log.error("清理失败 \(url.path, privacy: .public)：\(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
