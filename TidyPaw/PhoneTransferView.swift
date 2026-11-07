import SwiftUI
import AppKit

struct PhoneTransferView: View {
    @ObservedObject var manager: PhoneManager

    var body: some View {
        // 根必须是 ScrollView：否则 NavigationSplitView 会把侧栏顶部留白收走、切到这页时侧栏"跳"
        ScrollView {
            VStack(spacing: 0) {
                header
                Divider()
                PhoneSettingsCard(manager: manager, settings: manager.settings)
                    .padding([.horizontal, .top], 16)
                if manager.devices.isEmpty {
                    PhoneEmptyState()
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 14, alignment: .top)], spacing: 14) {
                        ForEach(manager.devices) { PhoneDeviceCard(device: $0, manager: manager) }
                    }
                    .padding(16)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { PhoneFooter(manager: manager) }
        .onAppear { manager.pageAppeared() }
        .onDisappear { manager.pageDisappeared() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled").font(.title).foregroundStyle(Brand.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("手机传图").font(.title2.bold())
                Text("把安卓手机的照片和视频传到 Mac，传过的不重复传，手机上的文件不动")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }
}

// MARK: - 保存位置和筛选

private struct PhoneSettingsCard: View {
    @ObservedObject var manager: PhoneManager
    @ObservedObject var settings: PhoneTransferSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").foregroundStyle(Brand.blue)
                Text("保存到").foregroundStyle(.secondary)
                Button(action: chooseFolder) {
                    Text((settings.destPath as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.link)
                Spacer()
                Button("更改…", action: chooseFolder).glassButton()
                Button {
                    try? FileManager.default.createDirectory(at: settings.destURL, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(settings.destURL)
                } label: { Label("在访达中打开", systemImage: "arrow.up.forward.square") }
                .glassButton()
            }
            HStack(spacing: 16) {
                Picker("整理", selection: $settings.layout) {
                    ForEach(PhoneFolderLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize()
                Toggle("照片", isOn: $settings.photos)
                Toggle("视频", isOn: $settings.videos)
                Picker("时间", selection: $settings.range) {
                    ForEach(PhoneDateRange.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Spacer()
            }
            .disabled(manager.isTransferring)
            Text("示例：" + example)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(14)
        .glassCard(cornerRadius: 14)
    }

    private var example: String {
        let device = manager.devices.first
        let item = device?.items.last
            ?? PhoneMediaItem(id: "", name: "IMG_20260922_101500.jpg", album: "Camera", size: 0, date: Date(), kind: .photo)
        let path = settings.targetDir(for: item, folder: device?.folderName ?? "我的手机")
            .appendingPathComponent(item.name).path
        return (path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择照片要保存到的文件夹"
        panel.directoryURL = settings.destURL
        if panel.runModal() == .OK, let url = panel.url { settings.destPath = url.path }
    }
}

// MARK: - 单台手机

private struct PhoneDeviceCard: View {
    @ObservedObject var device: PhoneDevice
    @ObservedObject var manager: PhoneManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch device.state {
            case .connecting, .scanning:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(device.statusText).foregroundStyle(.secondary)
                }
            case .unauthorized:
                PhoneHint(icon: "lock.iphone", text: device.isADB
                          ? "请解锁手机，在弹出的「允许 USB 调试吗？」里点允许。"
                          : "请解锁手机，并在通知栏把 USB 用途设为「文件传输」。")
            default:
                if device.items.isEmpty {
                    if let message = device.resultMessage {
                        PhoneHint(icon: "exclamationmark.triangle", text: message)
                    } else {
                        PhoneHint(icon: "photo.badge.exclamationmark", text: device.isADB || device.mtpTotalFiles > 0
                                  ? "手机的 DCIM、Pictures、Movies 里没有照片或视频。"
                                  : "没读到任何文件。请解锁手机，确认 USB 用途是「文件传输」，然后点右上角刷新。")
                    }
                } else {
                    content
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .opacity(device.enabled || device.state == .transferring ? 1 : 0.6)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "smartphone")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Brand.blue)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(device.model).font(.headline)
                HStack(spacing: 6) {
                    Badge(text: device.channelLabel, color: device.isADB ? .green : Brand.blue)
                    Text(device.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if device.state != .transferring {
                Button { manager.rescan(device) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("重新读取")
                    .disabled(device.state == .scanning || device.state == .connecting)
            }
            Toggle("传输这台", isOn: $device.enabled)
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .disabled(device.state == .transferring)
                .help("是否传输这台手机")
        }
    }

    @ViewBuilder private var content: some View {
        if manager.settings.layout != .flat {
            HStack(spacing: 8) {
                Text("文件夹名").foregroundStyle(.secondary)
                TextField(device.model, text: $device.alias).textFieldStyle(.roundedBorder)
            }
            .disabled(device.state == .transferring)
        }

        VStack(spacing: 0) {
            ForEach(device.albums) { album in
                HStack(spacing: 8) {
                    Toggle("", isOn: albumBinding(album.name)).labelsHidden()
                    Text(album.name).lineLimit(1)
                    Spacer()
                    Text("\(album.count.formatted()) 项").monospacedDigit().foregroundStyle(.secondary)
                    Text(formatBytes(album.bytes)).monospacedDigit().foregroundStyle(.tertiary)
                        .frame(width: 72, alignment: .trailing)
                }
                .padding(.vertical, 3)
            }
        }
        .font(.callout)
        .disabled(device.state == .transferring)

        if device.state == .transferring {
            progress
        } else {
            if let message = device.resultMessage {
                Label(message, systemImage: device.failedCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(.callout)
                    .foregroundStyle(device.failedCount > 0 ? Color.orange : Color.green)
            }
            HStack(spacing: 6) {
                Image(systemName: device.plan.isEmpty ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(device.plan.isEmpty ? Color.green : Brand.blue)
                if device.plan.isEmpty {
                    Text("没有要传的新文件").foregroundStyle(.secondary)
                } else {
                    Text("待传 \(device.plan.count.formatted()) 项 · \(formatBytes(device.planBytes))")
                }
                if device.skipped > 0 {
                    Text("已存在 \(device.skipped.formatted()) 项，跳过").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }

    private var progress: some View {
        let done = device.doneBytes + device.liveBytes
        let fraction = device.totalBytes > 0 ? Double(done) / Double(device.totalBytes) : 0
        let remaining = Double(max(0, device.totalBytes - done))
        return VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: min(fraction, 1))
            HStack {
                Text("\(device.doneCount.formatted()) / \(device.totalCount.formatted()) 项").monospacedDigit()
                Text("\(formatBytes(done)) / \(formatBytes(device.totalBytes))").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                if device.speed > 0 {
                    Text("\(formatBytes(Int64(device.speed)))/s").monospacedDigit()
                    Text("剩余 " + formatDuration(remaining / device.speed)).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            Text(device.current).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
        }
    }

    private func albumBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { !device.excludedAlbums.contains(name) },
            set: { on in
                if on { device.excludedAlbums.remove(name) } else { device.excludedAlbums.insert(name) }
            }
        )
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        if seconds < 60 { return "\(Int(seconds)) 秒" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分 \(Int(seconds) % 60) 秒" }
        return "\(Int(seconds / 3600)) 小时 \(Int(seconds / 60) % 60) 分"
    }
}

private struct PhoneHint: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(.orange)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 还没连接手机

private struct PhoneEmptyState: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 52, weight: .thin)).foregroundStyle(Brand.blue)
            Text("连接安卓手机").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                Label("用 USB 线连接手机并解锁", systemImage: "1.circle")
                Label("在手机通知栏把 USB 用途改为「文件传输」", systemImage: "2.circle")
                Label("开启「USB 调试」并安装 adb 后传得更快（可选）", systemImage: "3.circle")
            }
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }
}

// MARK: - 底栏

private struct PhoneFooter: View {
    @ObservedObject var manager: PhoneManager

    var body: some View {
        let free = manager.freeBytes
        let short = free.map { manager.pendingBytes > $0 } ?? false
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                if manager.isTransferring {
                    let transferring = manager.allDevices.filter { $0.state == .transferring }
                    let speed = transferring.reduce(0) { $0 + $1.speed }
                    Text("正在从 \(transferring.count) 台手机传输 · 合计 \(formatBytes(Int64(speed)))/s").monospacedDigit()
                } else if manager.pendingCount > 0 {
                    Text("共 \(manager.pendingCount.formatted()) 项 · \(formatBytes(manager.pendingBytes))")
                } else {
                    Text(manager.devices.isEmpty ? "等待连接手机" : "没有要传的新文件").foregroundStyle(.secondary)
                }
                if let free {
                    Text(short ? "目标磁盘空间不足（剩余 \(formatBytes(free))）" : "目标磁盘剩余 \(formatBytes(free))")
                        .font(.caption).foregroundStyle(short ? Color.red : Color.secondary)
                }
            }
            Spacer()
            if manager.isTransferring {
                Button { manager.stopAll() } label: {
                    Label("停止", systemImage: "stop.fill").padding(.horizontal, 6).padding(.vertical, 2)
                }
                .glassButton()
            } else {
                Button { manager.startAll() } label: {
                    Label("开始传输", systemImage: "arrow.down.circle.fill").padding(.horizontal, 6).padding(.vertical, 2)
                }
                .glassButton(prominent: true)
                .disabled(manager.pendingCount == 0 || short)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.bar)
    }
}
