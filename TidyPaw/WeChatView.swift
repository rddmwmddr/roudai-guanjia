import SwiftUI
import AppKit

// MARK: - 引擎

@MainActor
final class WeChatEngine: ObservableObject {
    enum State: Equatable { case idle, scanning, loaded, needsAccess, notInstalled }
    @Published private(set) var state: State = .idle
    @Published private(set) var result: WeChatResult? {
        didSet { rowCache = nil }
    }

    private var rowCache: (drill: WCDrill, key: WCSortKey, ascending: Bool, rows: [WeChatRow])?

    func scan() {
        guard state != .scanning else { return }
        state = .scanning   // 同步置位，连点两下不会启动两次
        Task { @MainActor in
            let probe = await Task.detached(priority: .userInitiated) { WeChatScanner.probe() }.value
            if probe.roots.isEmpty { state = .notInstalled; return }
            if !probe.readable { state = .needsAccess; return }
            let r = await Task.detached(priority: .userInitiated) { WeChatScanner.scan() }.value
            result = r
            state = (r.total == 0 && r.unreadable > 0) ? .needsAccess : .loaded
        }
    }

    /// 下钻后的文件列表。结果会缓存：打开预览等无关的界面刷新，不该让几千个文件名重新排序。
    func rows(for drill: WCDrill, key: WCSortKey, ascending: Bool) -> [WeChatRow] {
        if let c = rowCache, c.drill == drill, c.key == key, c.ascending == ascending { return c.rows }
        let buckets = (result?.buckets ?? []).filter { bucket in
            if case .category(let label) = drill { return bucket.label == label }
            return true
        }
        let rows = buckets.flatMap { b in b.files.map { WeChatRow(file: $0, category: b.label) } }
        var sorted: [WeChatRow]
        switch key {
        case .size: sorted = rows.sorted { $0.file.size < $1.file.size }
        case .date: sorted = rows.sorted { $0.file.modified < $1.file.modified }
        case .name:
            sorted = rows.map { ($0, $0.file.name) }
                .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
                .map { $0.0 }
        case .category:
            sorted = rows.sorted { a, b in
                if a.category != b.category { return a.category.localizedStandardCompare(b.category) == .orderedAscending }
                return a.file.size < b.file.size
            }
        }
        if !ascending { sorted.reverse() }
        rowCache = (drill, key, ascending, sorted)
        return sorted
    }
}

struct WeChatRow: Identifiable {
    let file: WeChatFile
    let category: String
    var id: UUID { file.id }
}

// MARK: - 界面

struct WeChatView: View {
    @ObservedObject var engine: WeChatEngine
    @State private var drill: WCDrill?               // nil=分类总览；.category/.all=进入文件列表
    @State private var sortKey: WCSortKey = .size    // 文件列表排序：大小/名称/日期/分类
    @State private var sortAsc = false               // 升/降序（名称/分类默认升序，大小/日期默认降序）
    @State private var previewItem: FilePreviewItem?  // 应用内预览的文件（sheet）

    var body: some View {
        // 根用 ScrollView，保证 NavigationSplitView 侧栏顶部留白稳定（切到此页不"跳"）
        ScrollView {
            VStack(spacing: 0) {
                header
                Divider()
                content
            }
            .frame(maxWidth: .infinity)
        }
        // 应用内 Quick Look 预览（共用 FilePreview.swift 的内嵌 QLPreviewView sheet）
        .filePreview($previewItem)
        .onValueChange(of: sortKey) { sortAsc = ($0 == .name || $0 == .category) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "message.fill").font(.title).foregroundStyle(Brand.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("微信管理").font(.title2.bold())
                Text("看微信聊天记录占了多少空间，并按文档/图片/视频/音频分类")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if engine.state == .loaded {
                Button { drill = nil; engine.scan() } label: { Label("重新扫描", systemImage: "arrow.clockwise") }
                    .glassButton()
            }
        }
        .padding(16)
    }

    @ViewBuilder private var content: some View {
        switch engine.state {
        case .idle:
            VStack(spacing: 16) {
                Image(systemName: "message.badge.filled.fill").font(.system(size: 50)).foregroundStyle(Brand.blue)
                Text("分析微信聊天记录占用").font(.title3.weight(.semibold))
                Text("扫描微信的数据目录，统计总大小并把附件分成图片、视频、文档、音频。\n严格只读：不会删除或改动任何聊天数据。")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 480)
                Button { engine.scan() } label: {
                    Label("开始扫描", systemImage: "magnifyingglass").padding(.horizontal, 8).padding(.vertical, 4)
                }
                .glassButton(prominent: true).controlSize(.large)
                Text("需要「完全磁盘访问权限」才能读取微信数据，未授权会引导你去开。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 60)
        case .scanning:
            ScanningAnimation(size: 120, caption: "正在扫描微信数据…（文件较多，请稍候）")
                .frame(maxWidth: .infinity).padding(.vertical, 70)
        case .needsAccess:
            NeedsAccessView(
                message: "微信的数据目录受系统保护，肉呆大管家需要「完全磁盘访问权限」才能读取并统计。请在系统设置里打开后回来重新扫描。",
                onRetry: { engine.scan() }
            )
        case .notInstalled:
            VStack(spacing: 12) {
                Image(systemName: "questionmark.folder").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("没有检测到微信数据").foregroundStyle(.secondary)
                Text("看起来这台 Mac 上没有安装微信，或数据在非标准位置。").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 60)
        case .loaded:
            if let r = engine.result {
                switch drill {
                case .all:
                    fileListView(title: "全部文件", count: r.buckets.reduce(0) { $0 + $1.count },
                                 size: r.total, drill: .all, showCategory: true)
                case .category(let label):
                    if let b = r.buckets.first(where: { $0.label == label }) {
                        fileListView(title: b.label, count: b.count, size: b.size,
                                     drill: .category(label), showCategory: false)
                    } else {
                        resultView(r)   // 重扫后该分类不存在了 → 回总览
                    }
                case nil:
                    resultView(r)
                }
            }
        }
    }

    private func resultView(_ r: WeChatResult) -> some View {
        Group {
            VStack(spacing: 18) {
                // 总占用
                VStack(spacing: 6) {
                    Text("微信数据总占用").font(.callout).foregroundStyle(.secondary)
                    Text(formatBytes(r.total)).font(.system(size: 40, weight: .bold)).foregroundStyle(Brand.blue)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 18)
                .glassCard(cornerRadius: 20)

                // 分类占用条
                VStack(alignment: .leading, spacing: 12) {
                    Text("按类型分布").font(.headline)
                    // 全部文件入口（可按大小/名称/日期/分类排序浏览）
                    Button { drill = .all } label: {
                        HStack {
                            Image(systemName: "square.grid.2x2.fill").foregroundStyle(Brand.blue).frame(width: 22)
                            Text("全部文件").fontWeight(.medium)
                            Spacer()
                            Text("浏览并排序所有文件").font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                    ForEach(r.buckets) { b in
                        bucketRow(b, total: r.total)
                    }
                }
                .padding(16)
                .glassCard(cornerRadius: 16)

                // 只读提示
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    Text("肉呆大管家只做统计，不会替你删微信数据——聊天附件和消息数据库相互依赖，乱删会损坏聊天记录。要清理请用微信自带的「设置 › 通用 › 存储空间」。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                if r.unreadable > 0 {
                    Text("有 \(r.unreadable) 处因权限不足未能读取，统计可能偏小。").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(20).frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
    }

    private func bucketRow(_ b: WeChatBucket, total: Int64) -> some View {
        let fraction = total > 0 ? Double(b.size) / Double(total) : 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon(b.label)).foregroundStyle(color(b.label)).frame(width: 22)
                Text(b.label)
                Text("·  \(b.count) 个文件").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(formatBytes(b.size)).monospacedDigit().foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            GeometryReader { geo in
                Capsule().fill(color(b.label).opacity(0.25))
                    .overlay(alignment: .leading) {
                        Capsule().fill(color(b.label)).frame(width: max(4, geo.size.width * fraction))
                    }
            }
            .frame(height: 8)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { drill = .category(b.label) }   // 点分类下钻看文件
    }

    // MARK: 某一类的文件列表（点进来）

    private func fileListView(title: String, count: Int, size: Int64,
                              drill listDrill: WCDrill, showCategory: Bool) -> some View {
        let rows = engine.rows(for: listDrill, key: sortKey, ascending: sortAsc)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button { drill = nil } label: { Label("返回", systemImage: "chevron.left") }
                    .buttonStyle(.link)
                Spacer()
                SortBar(options: [("大小", .size), ("名称", .name), ("日期", .date), ("分类", .category)],
                        key: $sortKey, ascending: $sortAsc)
            }
            HStack(spacing: 8) {
                Image(systemName: showCategory ? "square.grid.2x2.fill" : icon(title))
                    .foregroundStyle(showCategory ? Brand.blue : color(title))
                Text(title).font(.title3.bold())
                Text("· 共 \(count) 个 · \(formatBytes(size))").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            if count > rows.count {
                Text("文件较多，只列出最大的 \(rows.count) 个（按当前排序展示）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LazyVStack(spacing: 6) {
                ForEach(rows) { row in
                    fileRow(row.file, category: row.category, showCategory: showCategory)
                }
            }
            Text("只读：👁 应用内预览，🔍 在访达中定位；肉呆大管家不会替你删微信数据。")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(20).frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private func fileRow(_ f: WeChatFile, category: String, showCategory: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(category)).foregroundStyle(color(category)).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(f.name).lineLimit(1).truncationMode(.middle)
                    if showCategory {
                        Text(category).font(.caption2.weight(.medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(color(category).opacity(0.15), in: Capsule())
                            .foregroundStyle(color(category))
                    }
                }
                HStack(spacing: 8) {
                    Label {
                        Text(f.modified, format: .dateTime.year().month().day())
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .font(.caption2).foregroundStyle(.tertiary)
                    Text(f.url.deletingLastPathComponent().path)
                        .font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Text(formatBytes(f.size)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            PreviewButton(url: f.url, target: $previewItem)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([f.url])
            } label: {
                Image(systemName: "magnifyingglass.circle.fill").font(.title3)
            }
            .buttonStyle(.borderless).foregroundStyle(Brand.blue)
            .help("在访达中显示")
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .help(f.url.path)
    }

    private func icon(_ label: String) -> String {
        switch label {
        case "图片": return "photo"
        case "视频": return "video"
        case "文档": return "doc"
        case "音频": return "waveform"
        default:     return "shippingbox"
        }
    }
    private func color(_ label: String) -> Color {
        switch label {
        case "图片": return Brand.blue
        case "视频": return .purple
        case "文档": return .green
        case "音频": return .orange
        default:     return .gray
        }
    }
}

// MARK: - 下钻 / 排序

enum WCDrill: Equatable {
    case all                 // 全部文件
    case category(String)    // 某一类
}

enum WCSortKey: Hashable {
    case size, name, date, category
}
