import SwiftUI
import AppKit

// MARK: - 引擎

@MainActor
final class PermissionsEngine: ObservableObject {
    enum State: Equatable { case idle, scanning, loaded, needsAccess }
    @Published private(set) var state: State = .idle
    @Published private(set) var apps: [AppPermissions] = []

    func scan() {
        guard state != .scanning else { return }
        state = .scanning   // 同步置位，连点两下不会启动两次
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { PermissionsScanner.scan() }.value
            apps = result.apps
            state = result.readable ? .loaded : .needsAccess
        }
    }
}

// MARK: - 界面

enum PermSortKey: Hashable { case sensitive, count, name }

struct PermissionsView: View {
    @ObservedObject var engine: PermissionsEngine
    @State private var sortKey: PermSortKey = .sensitive
    @State private var sortAsc = false

    private var sortedApps: [AppPermissions] {
        let apps = engine.apps
        let s: [AppPermissions]
        switch sortKey {
        case .name: s = apps.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .count: s = apps.sorted { $0.grants.count < $1.grants.count }
        case .sensitive:
            s = apps.sorted { a, b in
                if a.hasSensitive != b.hasSensitive { return !a.hasSensitive && b.hasSensitive }  // 升序=非敏感在前
                return a.grants.count < b.grants.count
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
        .onValueChange(of: sortKey) { sortAsc = ($0 == .name) }  // 名称默认升序；敏感/权限数默认降序（敏感、多权限在前）
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield").font(.title).foregroundStyle(Brand.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("权限检查").font(.title2.bold())
                Text("看清哪些应用拿到了相机、麦克风、屏幕录制、完全磁盘访问等敏感权限")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if engine.state == .loaded {
                Button { engine.scan() } label: { Label("重新扫描", systemImage: "arrow.clockwise") }
                    .glassButton()
            }
        }
        .padding(16)
    }

    @ViewBuilder private var content: some View {
        switch engine.state {
        case .idle:
            VStack(spacing: 16) {
                Image(systemName: "lock.shield").font(.system(size: 50)).foregroundStyle(Brand.blue)
                Text("扫描系统权限授予记录").font(.title3.weight(.semibold))
                Text("读取系统的 TCC 隐私数据库，列出每个 App 被授予过的权限。只读，不会修改任何授权。")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 460)
                Button { engine.scan() } label: {
                    Label("开始扫描", systemImage: "magnifyingglass").padding(.horizontal, 8).padding(.vertical, 4)
                }
                .glassButton(prominent: true).controlSize(.large)
                Text("需要「完全磁盘访问权限」才能读取，未授权会引导你去开。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 60)
        case .scanning:
            ScanningAnimation(size: 120, caption: "正在读取权限记录…")
                .frame(maxWidth: .infinity).padding(.vertical, 70)
        case .needsAccess:
            NeedsAccessView(
                message: "肉呆大管家需要「完全磁盘访问权限」才能读取系统隐私数据库（TCC.db）。请在系统设置里把它打开，再回来重新检测。",
                onRetry: { engine.scan() }
            )
        case .loaded:
            if engine.apps.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal").font(.system(size: 40)).foregroundStyle(.green)
                    Text("没有读到任何已授予的权限").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 60)
            } else {
                LazyVStack(spacing: 10) {
                    summaryBar
                    ForEach(sortedApps) { app in AppPermissionCard(app: app) }
                }
                .padding(16)
            }
        }
    }

    private var summaryBar: some View {
        let sensitiveCount = engine.apps.filter { $0.hasSensitive }.count
        return HStack {
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
            Text("共 \(engine.apps.count) 个 App 拥有授权，其中 ")
                + Text("\(sensitiveCount)").bold().foregroundColor(.orange)
                + Text(" 个握有高敏感权限")
            Spacer()
            SortBar(options: [("敏感优先", .sensitive), ("权限数", .count), ("名称", .name)],
                    key: $sortKey, ascending: $sortAsc)
        }
        .font(.callout)
        .padding(12)
        .glassCard(cornerRadius: 12)
    }
}

struct AppPermissionCard: View {
    let app: AppPermissions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: app.hasSensitive ? "exclamationmark.triangle.fill" : "app.fill")
                    .foregroundStyle(app.hasSensitive ? .orange : Brand.blue)
                Text(app.displayName).font(.headline)
                if !app.isBundleID {
                    Text("命令行/进程").font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                Text("\(app.grants.count) 项").font(.caption).foregroundStyle(.secondary)
            }
            FlowBadges(grants: app.grants)
            Text(app.id).font(.caption2).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 权限徽标自动换行排布
struct FlowBadges: View {
    let grants: [PermissionGrant]
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(grants) { g in
                HStack(spacing: 3) {
                    if g.sensitive { Image(systemName: "exclamationmark.circle.fill").font(.caption2) }
                    Text(g.friendly + (g.limited ? "（受限）" : ""))
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background((g.sensitive ? Color.orange : Brand.blue).opacity(0.15), in: Capsule())
                .foregroundStyle(g.sensitive ? Color.orange : Brand.blue)
            }
        }
    }
}

// MARK: - 共享：需要完全磁盘访问权限引导

struct NeedsAccessView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill").font(.system(size: 52)).foregroundStyle(.orange)
            Text("需要完全磁盘访问权限").font(.title2.bold())
            Text(message)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 480)
            HStack(spacing: 12) {
                Button { openFullDiskAccessSettings() } label: {
                    Label("去系统设置授权", systemImage: "gearshape").padding(.horizontal, 8).padding(.vertical, 4)
                }
                .glassButton(prominent: true)
                Button { onRetry() } label: {
                    Label("已授权，重新检测", systemImage: "arrow.clockwise")
                }
                .glassButton()
            }
            Text("在「隐私与安全性 › 完全磁盘访问权限」里把肉呆大管家打开；授权后可能需要重开本 App 生效。")
                .font(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center).frame(maxWidth: 480)
        }
        .padding(40).padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }
}

func openFullDiskAccessSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
        NSWorkspace.shared.open(url)
    }
}
