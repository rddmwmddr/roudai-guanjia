import SwiftUI

/// 侧边栏条目：首页 + 三个工具 + 若干清理分类
enum SidebarItem: Hashable {
    case home
    case uninstall
    case permissions
    case system
    case wechat
    case category(CategoryKind)
}

struct ContentView: View {
    @StateObject private var engine = ScanEngine()
    @StateObject private var uninstall = UninstallEngine()
    @StateObject private var permissions = PermissionsEngine()
    @StateObject private var privacy = PrivacyEngine()
    @StateObject private var wechat = WeChatEngine()
    @State private var selection: SidebarItem? = .home
    @State private var showCleanConfirm = false

    var body: some View {
        NavigationSplitView {
            SidebarView(engine: engine, selection: $selection)
                .navigationSplitViewColumnWidth(min: 256, ideal: 296, max: 360)
        } detail: {
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppBackground())
        }
        .tint(Brand.blue)
        .onValueChange(of: selection) { newValue in
            if newValue != .uninstall { uninstall.reset() }
        }
        // 工具栏恒定（首页 / 全部扫描 / 清理），不随选中项增减，避免整窗重排
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { selection = .home } label: { Label("首页", systemImage: "house") }
                    .help("返回首页")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { engine.scanAll() } label: { Label("全部扫描", systemImage: "magnifyingglass") }
                    .disabled(engine.isScanning || engine.isCleaning)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { showCleanConfirm = true } label: {
                    Label(cleanButtonTitle, systemImage: "trash")
                }
                .disabled(overview.selectedCount == 0 || engine.isScanning || engine.isCleaning)
            }
        }
        // 强制工具栏背景常驻，让标题栏留白恒定，避免切换详情时侧栏内容滑到红绿灯下"跳一下"
        .toolbarBackground(.visible, for: .windowToolbar)
        .confirmationDialog(
            "确认清理 \(overview.selectedCount) 项，约 \(formatBytes(overview.selectedSize))？",
            isPresented: $showCleanConfirm, titleVisibility: .visible
        ) {
            Button("移到废纸篓并清理", role: .destructive) { engine.cleanSelected() }
            Button("取消", role: .cancel) { }
        } message: {
            Text(cleanConfirmMessage)
        }
        .alert(item: $engine.lastCleanSummary) { summary in
            Alert(title: Text("清理完成"), message: Text(cleanMessage(summary)), dismissButton: .default(Text("好")))
        }
    }

    @ViewBuilder private var detailContent: some View {
        switch selection {
        case .uninstall:
            UninstallView(engine: uninstall)
        case .permissions:
            PermissionsView(engine: permissions)
        case .system:
            SystemView(engine: privacy)
        case .wechat:
            WeChatView(engine: wechat)
        case .category(let kind):
            if let cat = engine.category(kind) {
                CategoryDetailView(engine: engine, category: cat)
            }
        case .home, .none:
            OverviewView(engine: engine, selection: $selection)
        }
    }

    private var overview: ScanOverview { engine.overview }

    private var cleanButtonTitle: String {
        if engine.isCleaning { return "正在清理…" }
        return overview.selectedCount > 0 ? "清理 \(formatBytes(overview.selectedSize))" : "清理选中"
    }

    private var cleanConfirmMessage: String {
        let permanent = overview.permanentCount
        guard permanent > 0 else { return "这些项目会移入废纸篓，可随时恢复。" }
        return "其中 \(permanent) 项来自废纸篓，将被永久删除，不可恢复；其余项目会移入废纸篓，可随时恢复。"
    }

    private func cleanMessage(_ s: CleanSummary) -> String {
        var lines: [String] = []
        if s.trashedCount > 0 {
            // 移到废纸篓不腾空间，不能说成「释放」
            lines.append("已把 \(s.trashedCount) 项（\(formatBytes(s.trashedBytes))）移到废纸篓，清空废纸篓后才会腾出这些空间。")
        }
        if s.deletedCount > 0 {
            lines.append("已永久删除 \(s.deletedCount) 项，腾出 \(formatBytes(s.deletedBytes))。")
        }
        if s.keptForSafety > 0 {
            lines.append("有 \(s.keptForSafety) 个重复文件没有动：它们保留的那一份也被选中或已经不在了，全部删掉就一份都不剩了。")
        }
        if s.failed > 0 {
            lines.append("有 \(s.failed) 项未能清理（可能需要在「系统设置 › 隐私与安全性 › 完全磁盘访问权限」中授权肉呆大管家）。")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 侧边栏（ScrollView：不会自动滚动 → 选中不"跳"；选中行玻璃作用在内容上 → 文字不被盖）

struct SidebarView: View {
    @ObservedObject var engine: ScanEngine
    @Binding var selection: SidebarItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                SidebarRow(selected: selection == .home) { selection = .home } content: {
                    HomeRowContent(engine: engine)
                }
                header("工具")
                SidebarRow(selected: selection == .uninstall) { selection = .uninstall } content: {
                    ToolRowContent(icon: "wand.and.sparkles", title: "拖拽卸载", subtitle: "拖入 App 干净卸载")
                }
                SidebarRow(selected: selection == .permissions) { selection = .permissions } content: {
                    ToolRowContent(icon: "lock.shield", title: "权限检查", subtitle: "谁动了你的相机麦克风")
                }
                SidebarRow(selected: selection == .system) { selection = .system } content: {
                    ToolRowContent(icon: "binoculars", title: "系统透视", subtitle: "上传/磁盘/自启/蓝牙/电池")
                }
                SidebarRow(selected: selection == .wechat) { selection = .wechat } content: {
                    ToolRowContent(icon: "message", title: "微信管理", subtitle: "聊天记录占用与分类")
                }
                ForEach(CategoryGroup.allCases) { group in
                    header(group.rawValue)
                    ForEach(engine.categories.filter { $0.kind.group == group }) { cat in
                        SidebarRow(selected: selection == .category(cat.kind)) { selection = .category(cat.kind) } content: {
                            CategoryRowContent(category: cat)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 侧边栏一行：onTapGesture 不抢焦点；玻璃高亮直接作用在内容上 → 文字永远在玻璃之上
struct SidebarRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hover = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .modifier(RowGlass(selected: selected, hover: hover))
            .contentShape(Rectangle())
            .onTapGesture { action() }
            .onHover { hover = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { action() }
    }
}

struct RowGlass: ViewModifier {
    let selected: Bool
    let hover: Bool
    func body(content: Content) -> some View {
        if selected {
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular.tint(Brand.blue.opacity(0.28)), in: .rect(cornerRadius: 9))
            } else {
                content.background(RoundedRectangle(cornerRadius: 9).fill(Brand.blue.opacity(0.18)))
            }
        } else if hover {
            content.background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
        } else {
            content
        }
    }
}

// MARK: - 行内容

struct HomeRowContent: View {
    @ObservedObject var engine: ScanEngine
    private var frac: Double {
        guard engine.diskTotal > 0 else { return 0 }
        return min(max(Double(engine.diskTotal - engine.diskFree) / Double(engine.diskTotal), 0), 1)
    }
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "house.fill").frame(width: 22).foregroundStyle(Brand.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text("首页 · 启动磁盘").fontWeight(.medium)
                ProgressView(value: frac)
                    .progressViewStyle(.linear)
                    .tint(frac > 0.9 ? .red : Brand.blue)
                Text("可用 \(formatBytes(engine.diskFree)) / 共 \(formatBytes(engine.diskTotal))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ToolRowContent: View {
    let icon: String
    let title: String
    let subtitle: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(Brand.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct CategoryRowContent: View {
    @ObservedObject var category: ScanCategory
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: category.kind.systemImage)
                .frame(width: 22).foregroundStyle(Brand.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.kind.title)
                trailingDetail
            }
            Spacer(minLength: 4)
            if category.state == .scanning { BusyDots() }
        }
        .padding(.vertical, 2)
    }
    @ViewBuilder private var trailingDetail: some View {
        switch category.state {
        case .idle:
            Text("未扫描").font(.caption).foregroundStyle(.secondary)
        case .scanning:
            Text("扫描中…").font(.caption).foregroundStyle(.secondary)
        case .done:
            if category.items.isEmpty, let issue = category.issue {
                Text(issue.shortLabel).font(.caption).foregroundStyle(.orange)
            } else if category.items.isEmpty {
                Text("没有可清理项").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("\(category.items.count) 项 · \(formatBytes(category.totalSize))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
