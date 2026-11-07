import SwiftUI
import AppKit
import QuickLookUI

// MARK: - 引擎

@MainActor
final class WeChatEngine: ObservableObject {
    enum State: Equatable { case idle, scanning, loaded, needsAccess, notInstalled }
    @Published private(set) var state: State = .idle
    @Published private(set) var result: WeChatResult?

    func scan() {
        guard state != .scanning else { return }
        Task { @MainActor in
            state = .scanning
            let probe = WeChatScanner.probe()
            if probe.roots.isEmpty { state = .notInstalled; return }
            if !probe.readable { state = .needsAccess; return }
            let r = await Task.detached(priority: .userInitiated) { WeChatScanner.scan() }.value
            result = r
            state = (r.total == 0 && r.unreadable > 0) ? .needsAccess : .loaded
        }
    }
}

// MARK: - 界面

struct WeChatView: View {
    @ObservedObject var engine: WeChatEngine
    @State private var drill: WCDrill?               // nil=分类总览；.category/.all=进入文件列表
    @State private var sortKey: WCSortKey = .size    // 文件列表排序：大小/名称/日期/分类
    @State private var sortAsc = false               // 升/降序（不同键有不同默认方向，见 sortControl）
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
                                 size: r.total, files: allFiles(r), showCategory: true)
                case .category(let label):
                    if let b = r.buckets.first(where: { $0.label == label }) {
                        fileListView(title: b.label, count: b.count, size: b.size,
                                     files: b.files.map { ($0, b.label) }, showCategory: false)
                    } else {
                        resultView(r)   // 重扫后该分类不存在了 → 回总览
                    }
                case nil:
                    resultView(r)
                }
            }
        }
    }

    private func allFiles(_ r: WeChatResult) -> [(WeChatFile, String)] {
        r.buckets.flatMap { b in b.files.map { ($0, b.label) } }
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
                              files: [(WeChatFile, String)], showCategory: Bool) -> some View {
        let sorted = sortedFiles(files)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button { drill = nil } label: { Label("返回", systemImage: "chevron.left") }
                    .buttonStyle(.link)
                Spacer()
                sortControl
            }
            HStack(spacing: 8) {
                Image(systemName: showCategory ? "square.grid.2x2.fill" : icon(title))
                    .foregroundStyle(showCategory ? Brand.blue : color(title))
                Text(title).font(.title3.bold())
                Text("· 共 \(count) 个 · \(formatBytes(size))").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            if count > files.count {
                Text("文件较多，只列出最大的 \(files.count) 个（按当前排序展示）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LazyVStack(spacing: 6) {
                ForEach(sorted, id: \.0.id) { item in
                    fileRow(item.0, category: item.1, showCategory: showCategory)
                }
            }
            Text("只读：👁 应用内预览，🔍 在访达中定位；肉呆大管家不会替你删微信数据。")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(20).frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private var sortControl: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.arrow.down").font(.caption).foregroundStyle(.secondary)
            Picker("排序", selection: $sortKey) {
                Text("大小").tag(WCSortKey.size)
                Text("名称").tag(WCSortKey.name)
                Text("日期").tag(WCSortKey.date)
                Text("分类").tag(WCSortKey.category)
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
            Button { sortAsc.toggle() } label: {
                Image(systemName: sortAsc ? "arrow.up" : "arrow.down")
            }
            .buttonStyle(.borderless)
            .help(sortAsc ? "升序" : "降序")
        }
        .onValueChange(of: sortKey) { key in
            sortAsc = (key == .name || key == .category)   // 名称/分类默认升序；大小/日期默认降序
        }
    }

    private func sortedFiles(_ files: [(WeChatFile, String)]) -> [(WeChatFile, String)] {
        var s = files
        switch sortKey {
        case .size: s.sort { $0.0.size < $1.0.size }
        case .name: s.sort { $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending }
        case .date: s.sort { $0.0.modified < $1.0.modified }
        case .category:
            s.sort { a, b in
                if a.1 != b.1 { return a.1.localizedStandardCompare(b.1) == .orderedAscending }
                return a.0.size < b.0.size
            }
        }
        if !sortAsc { s.reverse() }
        return s
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
