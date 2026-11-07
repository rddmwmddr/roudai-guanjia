import SwiftUI
import AppKit
import QuickLookUI

// MARK: - 通用应用内文件预览（全 App 复用：清理分类 / 拖拽卸载 / 系统透视 / 微信）

/// 要预览的文件。用 Identifiable 配合 `.sheet(item:)`，url 变了就重开预览。
struct FilePreviewItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

/// 把 AppKit 的 QLPreviewView 包进 SwiftUI，内嵌在 sheet 里做应用内预览（图片/视频/PDF/文本/plist 等都能看）
struct QuickLookPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        nsView.previewItem = url as NSURL
    }
    // sheet 关闭时主动停掉预览，释放 QL 资源，避免视频/大图遗留
    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: ()) {
        nsView.close()
    }
}

/// 预览弹层：顶部一条工具栏（文件名 + 在访达中显示 + 完成），下面是 Quick Look 内容
struct PreviewSheet: View {
    let url: URL
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "eye").foregroundStyle(Brand.blue)
                Text(url.lastPathComponent).font(.headline)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: { Label("在访达中显示", systemImage: "folder") }
                Button("完成") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            QuickLookPreview(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 760, height: 560)
    }
}

extension View {
    /// 给任意视图挂上「应用内预览」sheet：把某行的 👁 设成 `item.wrappedValue = FilePreviewItem(url:)` 即可
    func filePreview(_ item: Binding<FilePreviewItem?>) -> some View {
        sheet(item: item) { it in
            PreviewSheet(url: it.url) { item.wrappedValue = nil }
        }
    }
}

/// 统一的「👁 应用内预览」小按钮（各文件行复用，外观一致）
struct PreviewButton: View {
    let url: URL
    @Binding var target: FilePreviewItem?
    var body: some View {
        Button {
            target = FilePreviewItem(url: url)
        } label: {
            Image(systemName: "eye.circle.fill").font(.title3)
        }
        .buttonStyle(.borderless).foregroundStyle(Brand.blue)
        .help("应用内预览")
    }
}
