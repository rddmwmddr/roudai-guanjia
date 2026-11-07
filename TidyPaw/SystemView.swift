import SwiftUI
import AppKit

// MARK: - 板块 + 引擎

enum SysSection: String, CaseIterable, Identifiable {
    case network = "网络上传"
    case disk = "磁盘读写"
    case startup = "开机自启"
    case bluetooth = "蓝牙"
    case battery = "电池"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .network:   return "arrow.up.circle"
        case .disk:      return "internaldrive"
        case .startup:   return "power"
        case .bluetooth: return "wave.3.right"
        case .battery:   return "battery.75"
        }
    }
}

@MainActor
final class PrivacyEngine: ObservableObject {
    @Published private(set) var battery: BatteryReading?
    @Published private(set) var uploaders: [NetProc] = []
    @Published private(set) var diskProcs: [DiskProc] = []
    @Published private(set) var persistence: [PersistItem] = []
    @Published private(set) var btPowered: Bool?
    @Published private(set) var btDevices: [BTDevice] = []
    /// 正在扫描的板块集合：允许多板块并发，切板块不会丢请求（否则电池会卡在"正在读取…"）
    @Published private(set) var scanning: Set<SysSection> = []
    private var loaded: Set<SysSection> = []

    func loadIfNeeded(_ s: SysSection) { if !loaded.contains(s) { reload(s) } }

    func reload(_ s: SysSection) {
        guard !scanning.contains(s) else { return }   // 仅去重同一板块的并发请求
        scanning.insert(s)   // 同步置位：onAppear 和 onChange 可能在同一拍里各调一次
        Task { @MainActor in
            switch s {
            case .network:
                uploaders = await Task.detached(priority: .userInitiated) { NetworkScanner.topUploaders() }.value
            case .disk:
                diskProcs = await Task.detached(priority: .userInitiated) { DiskIOScanner.topReaders() }.value
            case .startup:
                persistence = await Task.detached(priority: .userInitiated) { PersistenceScanner.scan() }.value
            case .bluetooth:
                let r = await Task.detached(priority: .userInitiated) { BluetoothScanner.scan() }.value
                btPowered = r.powered; btDevices = r.devices
            case .battery:
                battery = await Task.detached(priority: .userInitiated) { BatteryReader.read() }.value
            }
            loaded.insert(s)
            scanning.remove(s)
        }
    }
}

// MARK: - 界面

enum NetSortKey: Hashable { case upload, download, name }
enum DiskSortKey: Hashable { case read, write, name }

struct SystemView: View {
    @ObservedObject var engine: PrivacyEngine
    @State private var section: SysSection = .network
    @State private var netSort: NetSortKey = .upload
    @State private var netAsc = false
    @State private var diskSort: DiskSortKey = .read
    @State private var diskAsc = false
    @State private var previewItem: FilePreviewItem?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                Picker("", selection: $section) {
                    ForEach(SysSection.allCases) { s in
                        Label(s.rawValue, systemImage: s.icon).tag(s)
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
                content
            }
            .frame(maxWidth: 760).frame(maxWidth: .infinity).padding(20)
        }
        .filePreview($previewItem)
        .onAppear { engine.loadIfNeeded(section) }
        .onValueChange(of: section) { engine.loadIfNeeded($0) }
        .onValueChange(of: netSort) { netAsc = ($0 == .name) }
        .onValueChange(of: diskSort) { diskAsc = ($0 == .name) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "binoculars.fill").font(.title).foregroundStyle(Brand.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("系统透视").font(.title2.bold())
                Text("谁在偷偷上传数据、谁在后台扫描磁盘、谁开机自启常驻、蓝牙连了什么、电池还剩多少健康")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { engine.reload(section) } label: { Label("刷新", systemImage: "arrow.clockwise") }
                .glassButton().disabled(engine.scanning.contains(section))
        }
    }

    @ViewBuilder private var content: some View {
        if engine.scanning.contains(section) {
            ScanningAnimation(size: 90, caption: "正在读取系统信息…")
                .frame(maxWidth: .infinity).padding(.vertical, 50)
        } else {
            switch section {
            case .network:   networkSection
            case .disk:      diskSection
            case .startup:   startupSection
            case .bluetooth: bluetoothSection
            case .battery:   batterySection
            }
        }
    }

    // MARK: 网络上传

    private var sortedUploaders: [NetProc] {
        let u = engine.uploaders
        let s: [NetProc]
        switch netSort {
        case .upload:   s = u.sorted { $0.bytesOut < $1.bytesOut }
        case .download: s = u.sorted { $0.bytesIn < $1.bytesIn }
        case .name:     s = u.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return netAsc ? s : s.reversed()
    }

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("各 App 自启动以来的累计上传量，上传越多越值得留意").font(.callout).foregroundStyle(.secondary)
                Spacer()
                SortBar(options: [("上传", .upload), ("下载", .download), ("名称", .name)], key: $netSort, ascending: $netAsc)
            }
            if engine.uploaders.isEmpty {
                emptyHint("没有读到网络数据（或本次无活跃联网进程）")
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(sortedUploaders) { p in
                        HStack(spacing: 10) {
                            Image(systemName: "app.fill").foregroundStyle(.secondary).frame(width: 20)
                            Text(p.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Label(formatBytes(p.bytesOut), systemImage: "arrow.up")
                                .font(.caption.weight(.semibold)).foregroundStyle(p.bytesOut > 100_000_000 ? .orange : Brand.blue)
                                .monospacedDigit()
                            Label(formatBytes(p.bytesIn), systemImage: "arrow.down")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    // MARK: 磁盘读写

    private var sortedDiskProcs: [DiskProc] {
        let d = engine.diskProcs
        let s: [DiskProc]
        switch diskSort {
        case .read:  s = d.sorted { $0.bytesRead < $1.bytesRead }
        case .write: s = d.sorted { $0.bytesWritten < $1.bytesWritten }
        case .name:  s = d.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return diskAsc ? s : s.reversed()
    }

    private var diskSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("各进程自启动以来累计的磁盘读/写量。读取量异常大的，常在后台扫描整盘文件")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                SortBar(options: [("读取", .read), ("写入", .write), ("名称", .name)], key: $diskSort, ascending: $diskAsc)
            }
            if engine.diskProcs.isEmpty {
                emptyHint("没有读到磁盘读写数据")
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(sortedDiskProcs) { p in
                        HStack(spacing: 10) {
                            Image(systemName: "internaldrive.fill").foregroundStyle(.secondary).frame(width: 20)
                            Text(p.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Label(formatBytes(p.bytesRead), systemImage: "arrow.down.doc")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(p.bytesRead > 5_000_000_000 ? .orange : Brand.blue)
                                .monospacedDigit().help("累计读取")
                            Label(formatBytes(p.bytesWritten), systemImage: "arrow.up.doc")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit().help("累计写入")
                        }
                        .padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                Text("读写量大不一定有问题（浏览器缓存、备份、剪辑软件都会很高）——重点看那些你印象里「什么都没干」却读了几十 GB 的程序。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: 开机自启

    private var startupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("这些第三方程序会随系统/登录自动启动并常驻后台（已过滤系统自带项）")
                .font(.callout).foregroundStyle(.secondary)
            if engine.persistence.isEmpty {
                emptyHint("没有第三方开机自启项，很干净")
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(engine.persistence) { item in
                        HStack(spacing: 10) {
                            Image(systemName: "power").foregroundStyle(Brand.blue).frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).lineLimit(1).truncationMode(.middle)
                                Text(item.path).font(.caption2).foregroundStyle(.tertiary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            Text(item.kind).font(.caption2.weight(.medium))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Brand.blue.opacity(0.15), in: Capsule()).foregroundStyle(Brand.blue)
                            PreviewButton(url: URL(fileURLWithPath: item.path), target: $previewItem)
                            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) } label: {
                                Image(systemName: "magnifyingglass.circle.fill").font(.title3)
                            }
                            .buttonStyle(.borderless).foregroundStyle(Brand.blue).help("在访达中显示")
                        }
                        .padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                Text("如需取消某项自启，可在访达里查看该 plist，或用对应 App 的设置关闭——肉呆大管家不替你删系统配置。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: 蓝牙

    private var bluetoothSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: engine.btPowered == true ? "wave.3.right" : "wave.3.right.slash")
                    .foregroundStyle(engine.btPowered == true ? Brand.blue : .secondary)
                Text(bluetoothStatus).font(.headline)
            }
            let connected = engine.btDevices.filter { $0.connected }
            let paired = engine.btDevices.filter { !$0.connected }
            if engine.btDevices.isEmpty {
                emptyHint("没有读到蓝牙设备")
            } else {
                if !connected.isEmpty {
                    Text("已连接").font(.subheadline.bold())
                    ForEach(connected) { btRow($0) }
                }
                if !paired.isEmpty {
                    Text("已配对（未连接）").font(.subheadline.bold()).padding(.top, 6)
                    ForEach(paired) { btRow($0) }
                }
            }
        }
    }

    private var bluetoothStatus: String {
        switch engine.btPowered {
        case true?:  return "蓝牙：已开启"
        case false?: return "蓝牙：已关闭"
        case nil:    return "蓝牙：读不到状态"
        }
    }

    private func btRow(_ d: BTDevice) -> some View {
        HStack(spacing: 10) {
            Circle().fill(d.connected ? Color.green : Color.secondary).frame(width: 8, height: 8)
            Text(d.name)
            if let t = d.type { Text(t).font(.caption2).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: 电池

    @ViewBuilder private var batterySection: some View {
        switch engine.battery {
        case .info(let b):
            VStack(spacing: 16) {
                VStack(spacing: 6) {
                    Text("电池健康").font(.callout).foregroundStyle(.secondary)
                    Text("\(b.healthPercent)%")
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(b.healthPercent >= 80 ? Brand.blue : .orange)
                    Text(b.condition).font(.callout).foregroundStyle(b.healthPercent >= 80 ? Color.secondary : Color.orange)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 18).glassCard(cornerRadius: 20)

                VStack(spacing: 0) {
                    statRow("当前电量", "\(b.charge)%" + (b.charging ? " · 充电中" : (b.acConnected ? " · 已接电源" : "")))
                    Divider()
                    statRow("循环次数", "\(b.cycleCount) 次")
                    Divider()
                    statRow("满电容量", "\(b.maxCapacity) mAh")
                    Divider()
                    statRow("设计容量", "\(b.designCapacity) mAh")
                }
                .padding(.horizontal, 16).padding(.vertical, 4).glassCard(cornerRadius: 16)
            }
        case .noBattery:
            emptyHint("没有检测到电池（台式 Mac 没有内置电池）")
        case .unreadable:
            emptyHint("这台 Mac 有电池，但系统没有提供健康数据")
        case nil:
            emptyHint("正在读取…")
        }
    }

    private func statRow(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).monospacedDigit() }
            .font(.callout).padding(.vertical, 10)
    }

    private func emptyHint(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "tray").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}
