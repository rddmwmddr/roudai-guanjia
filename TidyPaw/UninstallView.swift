import SwiftUI
import UniformTypeIdentifiers

enum UninstallSortKey: Hashable { case size, name, confidence, kind }

struct UninstallView: View {
    @ObservedObject var engine: UninstallEngine
    @State private var isTargeted = false
    @State private var importing = false
    @State private var sortKey: UninstallSortKey = .confidence
    @State private var sortAsc = true
    @State private var previewItem: FilePreviewItem?

    private var sortedCandidates: [RemovalCandidate] {
        let cs = engine.candidates
        let s: [RemovalCandidate]
        switch sortKey {
        case .size: s = cs.sorted { ($0.size ?? 0) < ($1.size ?? 0) }
        case .name: s = cs.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        case .confidence: s = cs.sorted { ($0.confidence.rank, !$0.requiresAdmin ? 0 : 1) < ($1.confidence.rank, !$1.requiresAdmin ? 0 : 1) }
        case .kind: s = cs.sorted { a, b in
            if a.kind != b.kind { return a.kind.localizedStandardCompare(b.kind) == .orderedAscending }
            return (a.size ?? 0) > (b.size ?? 0)
        }
        }
        return sortAsc ? s : s.reversed()
    }

    var body: some View {
        // 根必须是 ScrollView：否则 NavigationSplitView 会把侧栏顶部留白收走、切到这页时侧栏"跳"
        ScrollView {
            VStack(spacing: 0) {
                header
                Divider()
                content
            }
            .frame(maxWidth: .infinity)
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        } isTargeted: { isTargeted = $0 }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.application],
                      allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first { engine.load(url) }
        }
        .alert("无法扫描", isPresented: Binding(
            get: { engine.errorMessage != nil },
            set: { if !$0 { engine.errorMessage = nil } })
        ) {
            Button("好", role: .cancel) { engine.errorMessage = nil }
        } message: {
            Text(engine.errorMessage ?? "")
        }
        .filePreview($previewItem)
        .onValueChange(of: sortKey) { sortAsc = ($0 != .size) }  // 大小默认降序，其余默认升序
    }

    private func handleDrop(_ urls: [URL]) -> Bool {
        guard let app = urls.first(where: { $0.pathExtension.lowercased() == "app" }) else {
            engine.errorMessage = "请拖入一个 .app 应用程序包。"
            return false
        }
        engine.load(app)
        return true
    }

    // MARK: 顶部

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.sparkles")
                    .font(.title).foregroundStyle(Brand.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("拖拽卸载").font(.title2.bold())
                    Text("拖入一个 App，揪出它在系统里的全部残留，逐项确认后干净卸载")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if engine.state == .loaded || engine.state == .empty {
                    Button { importing = true } label: { Label("换一个", systemImage: "arrow.triangle.2.circlepath") }
                        .glassButton()
                }
            }
        }
        .padding(16)
    }

    // MARK: 内容

    @ViewBuilder private var content: some View {
        switch engine.state {
        case .idle:
            dropZone
        case .scanning:
            ScanningAnimation(size: 130, caption: "正在揪出残留……")
                .frame(maxWidth: .infinity).padding(.vertical, 70)
        case .loaded, .empty:
            resultArea
        }
    }

    // MARK: 拖拽区

    private var dropZone: some View {
        VStack {
            GlassContainer {
                VStack(spacing: 16) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(isTargeted ? Brand.blueDeep : Brand.blue)
                        .scaleEffect(isTargeted ? 1.12 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isTargeted)
                    Text("把 App 拖到这里")
                        .font(.title3.weight(.semibold))
                    Text("或")
                        .font(.callout).foregroundStyle(.secondary)
                    Button { importing = true } label: {
                        Label("选择 App…", systemImage: "folder")
                            .padding(.horizontal, 6).padding(.vertical, 2)
                    }
                    .glassButton(prominent: true)
                }
                .padding(40)
                .frame(maxWidth: 460)
                .tintedGlassCard(isTargeted ? Brand.blue : Brand.mint, cornerRadius: 24)
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .foregroundStyle(Brand.blue.opacity(isTargeted ? 0.8 : 0.35))
                )
            }
            warningNote
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity)
        .padding(24).padding(.top, 30)
    }

    private var warningNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(Brand.blue)
            Text("会清理 App 本体、偏好、缓存、容器、后台启动项和安装收据。钥匙串、在线账号、同厂商共享数据无法保证自动判断，请按证据手动确认。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .glassCard(cornerRadius: 12)
        .padding(.top, 14)
    }

    // MARK: 结果区

    private var resultArea: some View {
        VStack(spacing: 0) {
            if let id = engine.identity { identityCard(id) }

            if engine.state == .empty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 40)).foregroundStyle(.green)
                    Text("没找到这个 App 的残留").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 60)
            } else {
                toolbar
                LazyVStack(spacing: 8) {
                    ForEach(sortedCandidates) { c in
                        CandidateRow(candidate: c, isSelected: engine.isSelected(c),
                                     toggle: { engine.toggle(c) },
                                     preview: { previewItem = FilePreviewItem(url: c.url) })
                    }
                }
                .padding(16)
                footer
            }
        }
    }

    private func identityCard(_ id: AppIdentity) -> some View {
        HStack(spacing: 12) {
            Group {
                if let icon = engine.appIcon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(id.appName).font(.headline)
                Text("Bundle ID：\(id.bundleID ?? "无")  ·  \(id.appURL.path)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { engine.rescan() } label: { Label("重新扫描", systemImage: "arrow.clockwise") }
                .glassButton()
        }
        .padding(12)
        .glassCard(cornerRadius: 14)
        .padding([.horizontal, .top], 16)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button("精确匹配") { engine.selectExact() }.buttonStyle(.link)
            Button("全选") { engine.selectAll() }.buttonStyle(.link)
            Button("清空") { engine.selectNone() }.buttonStyle(.link)
            SortBar(options: [("匹配度", .confidence), ("大小", .size), ("名称", .name), ("类型", .kind)],
                    key: $sortKey, ascending: $sortAsc)
            Spacer()
            Text("共 \(engine.candidates.count) 项 · \(formatBytes(engine.totalSize))")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.top, 12)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash.fill").foregroundStyle(Brand.blue)
            Text("已选 \(engine.selectedCount) 项 · 约 \(formatBytes(engine.selectedSize))")
            Spacer()
            Button { Task { await engine.uninstall() } } label: {
                Label("卸载选中项", systemImage: "trash")
                    .padding(.horizontal, 6).padding(.vertical, 2)
            }
            .glassButton(prominent: true)
            .disabled(engine.selectedCount == 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.bar)
    }
}

// MARK: - 候选行

struct CandidateRow: View {
    let candidate: RemovalCandidate
    let isSelected: Bool
    let toggle: () -> Void
    let preview: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                .toggleStyle(.checkbox).labelsHidden()

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(candidate.kind).font(.system(size: 13, weight: .semibold))
                    Badge(text: candidate.confidence.rawValue, color: confidenceColor)
                    if candidate.requiresAdmin { Badge(text: "需管理员", color: .orange) }
                }
                Text(candidate.url.path)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text(candidate.evidence)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text(formatBytes(candidate.size ?? 0)).font(.caption).monospacedDigit()
                HStack(spacing: 10) {
                    Button { preview() } label: { Image(systemName: "eye.circle.fill").font(.title3) }
                        .buttonStyle(.borderless).foregroundStyle(Brand.blue).help("应用内预览")
                    Button("显示") { NSWorkspace.shared.activateFileViewerSelecting([candidate.url]) }
                        .controlSize(.small).buttonStyle(.borderless).foregroundStyle(Brand.blue)
                }
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .help(candidate.url.path)
        .onTapGesture { toggle() }
    }

    private var confidenceColor: Color {
        switch candidate.confidence {
        case .exact:  return .green
        case .likely: return Brand.blue
        case .risky:  return .red
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
