import SwiftUI
import AppKit

// MARK: - 首页 / 概览

struct OverviewView: View {
    @ObservedObject var engine: ScanEngine
    @Binding var selection: SidebarItem?

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                // 品牌头
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 88, height: 88)
                        .shadow(color: Brand.blue.opacity(0.25), radius: 14, y: 5)
                    Text("肉呆大管家").font(.largeTitle.bold())
                    Text("清理磁盘、卸载应用、看管权限——你的 Mac 大管家")
                        .font(.title3).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                DiskDetailView(engine: engine)
                    .frame(maxWidth: 620)

                // 快捷入口
                HStack(spacing: 12) {
                    QuickAction(icon: "magnifyingglass", title: "全部扫描", prominent: true) { engine.scanAll() }
                    QuickAction(icon: "wand.and.sparkles", title: "拖拽卸载") { selection = .uninstall }
                    QuickAction(icon: "lock.shield", title: "权限检查") { selection = .permissions }
                    QuickAction(icon: "message", title: "微信管理") { selection = .wechat }
                }
                .frame(maxWidth: 620)

                Label("所有清理默认「移到废纸篓」，可随时恢复；缓存类自动勾选，个人文件需手动确认。",
                      systemImage: "checkmark.shield")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(36)
            .frame(maxWidth: .infinity)
        }
    }
}

struct QuickAction: View {
    let icon: String
    let title: String
    var prominent: Bool = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.callout)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
        }
        .glassButton(prominent: prominent)
    }
}

// MARK: - 磁盘详情

struct DiskDetailView: View {
    @ObservedObject var engine: ScanEngine

    private var used: Int64 { max(engine.diskTotal - engine.diskFree, 0) }
    private var usedFraction: Double {
        guard engine.diskTotal > 0 else { return 0 }
        return min(max(Double(used) / Double(engine.diskTotal), 0), 1)
    }
    private var scannedGroups: [(group: CategoryGroup, size: Int64)] {
        CategoryGroup.allCases.compactMap { g in
            let size = engine.categories.filter { $0.kind.group == g }.reduce(Int64(0)) { $0 + $1.totalSize }
            return size > 0 ? (g, size) : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "internaldrive").foregroundStyle(Brand.blue)
                Text("启动磁盘").font(.title3.bold())
                Spacer()
                Text("\(Int(usedFraction * 100))% 已用").font(.callout).foregroundStyle(.secondary)
            }

            // 大磁盘条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(LinearGradient(colors: usedFraction > 0.9 ? [.red, .orange] : [Brand.blue, Brand.mint],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * usedFraction)
                }
            }
            .frame(height: 14)

            HStack(spacing: 0) {
                stat("已用", formatBytes(used), .secondary)
                Divider().frame(height: 28)
                stat("可用", formatBytes(engine.diskFree), Brand.blue)
                Divider().frame(height: 28)
                stat("总容量", formatBytes(engine.diskTotal), .primary)
            }

            Divider()

            // 可清理概况
            if engine.hasScannedAnything {
                HStack {
                    Image(systemName: "sparkles").foregroundStyle(Brand.blue)
                    Text("已扫描出可清理约 ")
                    Text(formatBytes(engine.totalReclaimable)).bold().foregroundStyle(Brand.blue)
                    Spacer()
                }
                .font(.callout)
                ForEach(scannedGroups, id: \.group.id) { item in
                    HStack {
                        Image(systemName: item.group.systemImage).frame(width: 20).foregroundStyle(.secondary)
                        Text(item.group.rawValue)
                        Spacer()
                        Text(formatBytes(item.size)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.callout)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text("还没扫描。点右上角或下方「全部扫描」看看能清出多少空间。")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .padding(20)
        .glassCard(cornerRadius: 20)
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.headline).foregroundStyle(color).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 工具占位（接入中）

struct ToolPlaceholder: View {
    let icon: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 16) {
            ScanningAnimation(size: 110)
            Text(title).font(.title2.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 单个分类详情

enum FileSortKey: Hashable { case size, name, date, type }

struct CategoryDetailView: View {
    @ObservedObject var engine: ScanEngine
    @ObservedObject var category: ScanCategory
    @State private var sortKey: FileSortKey = .size
    @State private var sortAsc = false
    @State private var previewItem: FilePreviewItem?

    private var sortedItems: [FileItem] {
        let items = category.items
        let s: [FileItem]
        switch sortKey {
        case .size: s = items.sorted { $0.size < $1.size }
        case .name: s = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .date: s = items.sorted { $0.modified < $1.modified }
        case .type:
            s = items.sorted { a, b in
                let ta = category.purposes[a.id]?.typeLabel ?? ""
                let tb = category.purposes[b.id]?.typeLabel ?? ""
                if ta != tb { return ta.localizedStandardCompare(tb) == .orderedAscending }
                return a.size > b.size
            }
        }
        return sortAsc ? s : s.reversed()
    }

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
        .filePreview($previewItem)
        .onValueChange(of: sortKey) { sortAsc = ($0 == .name || $0 == .type) }  // 名称/类型默认升序，大小/日期默认降序
    }

    // MARK: 顶部说明 + 操作

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: category.kind.systemImage)
                    .font(.title)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.kind.title).font(.title2.bold())
                    RiskBadge(risk: category.kind.risk)
                }
                Spacer()
                Button {
                    engine.scanOne(category)
                } label: {
                    Label(category.state == .done ? "重新扫描" : "扫描", systemImage: "arrow.clockwise")
                }
                .disabled(engine.isScanning)
            }

            Text(category.kind.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if category.kind == .appLeftovers {
                WarningBanner(text: "这些是根据 bundle id「找不到对应已安装应用」推断出的残留，可能有误判。请逐项核对（右键可在访达中查看内容），确认后再勾选。清理会移到废纸篓，可恢复。")
            }

            if category.state == .done && !category.items.isEmpty {
                HStack(spacing: 12) {
                    Button("全选") { category.selectAll() }
                        .buttonStyle(.link)
                    Button("全不选") { category.selectNone() }
                        .buttonStyle(.link)
                    SortBar(options: [("大小", .size), ("名称", .name), ("日期", .date), ("类型", .type)],
                            key: $sortKey, ascending: $sortAsc)
                    Spacer()
                    Text("共 \(category.items.count) 项 · \(formatBytes(category.totalSize))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
    }

    // MARK: 列表内容

    @ViewBuilder private var content: some View {
        switch category.state {
        case .idle:
            placeholder(icon: "magnifyingglass", text: "还没有扫描，点击右上角「扫描」开始")
        case .scanning:
            ScanningAnimation(size: 120, caption: "正在扫描 \(category.kind.title)…")
                .frame(maxWidth: .infinity).padding(.vertical, 70)
        case .done:
            if category.items.isEmpty {
                placeholder(icon: "checkmark.circle", text: "很干净，没有发现可清理的项目")
            } else {
                // 用 LazyVStack 而非 List：避免嵌在根 ScrollView 里造成双层滚动
                LazyVStack(spacing: 6) {
                    ForEach(sortedItems) { item in
                        FileRow(item: item,
                                purpose: category.purposes[item.id],
                                isSelected: category.isSelected(item),
                                toggle: { category.toggle(item) },
                                preview: { previewItem = FilePreviewItem(url: item.url) })
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(12)
            }
        }
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 70)
    }
}

// MARK: - 风险标签

struct RiskBadge: View {
    let risk: CleanRisk

    var body: some View {
        Text(risk.label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch risk {
        case .safe:   return .green
        case .review: return .orange
        }
    }
}

// MARK: - 警告横幅

struct WarningBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 类型小标签

struct TypeBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.secondary)
    }
}

// MARK: - 文件行

struct FileRow: View {
    let item: FileItem
    let purpose: FilePurpose?
    let isSelected: Bool
    let toggle: () -> Void
    let preview: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()

            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    if let label = purpose?.typeLabel {
                        TypeBadge(text: label)
                    }
                }
                // 优先显示「用途/来源」说明；没算出来时退回显示路径
                Text(purpose?.explanation.isEmpty == false ? purpose!.explanation : item.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(formatBytes(item.size)).monospacedDigit()
                Text(item.modified, format: .dateTime.year().month().day())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            // 应用内预览（图片/文档/plist 等都能看，文件夹则显示其内容概览）
            Button { preview() } label: {
                Image(systemName: "eye.circle.fill").font(.title3)
            }
            .buttonStyle(.borderless).foregroundStyle(Brand.blue).help("应用内预览")
        }
        .contentShape(Rectangle())
        .help(item.path)   // 悬停看完整路径
        .onTapGesture(count: 2) { FileActions.revealInFinder(item.url) }
        .onTapGesture { toggle() }
        .padding(.vertical, 2)
        .contextMenu {
            Button {
                preview()
            } label: { Label("应用内预览", systemImage: "eye") }
            Button {
                FileActions.revealInFinder(item.url)
            } label: { Label("在访达中显示", systemImage: "folder") }
            Button {
                FileActions.copyPath(item.path)
            } label: { Label("拷贝路径", systemImage: "doc.on.clipboard") }
        }
    }
}

// MARK: - 文件定位等系统操作

enum FileActions {
    /// 在访达中高亮选中该文件/文件夹
    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 拷贝完整路径到剪贴板
    static func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}
