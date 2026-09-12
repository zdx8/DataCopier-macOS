import AppKit
import UniformTypeIdentifiers

/// 原生文件选择面板封装。
enum FilePanels {

    /// 选择多个文件或文件夹作为来源。
    static func chooseSources() -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "选择"
        panel.message = "选择需要拷贝的文件或文件夹（可多选）"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.map { $0.path }
    }

    /// 选择单个目标文件夹。
    static func chooseDestination() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择目标"
        panel.message = "选择拷贝的目标文件夹"
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }

    /// 选择校验清单文件。
    static func chooseManifest() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "载入清单"
        panel.message = "选择 checksums 清单文件进行比对"
        if let txt = UTType(filenameExtension: "txt") {
            panel.allowedContentTypes = [txt]
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }

    /// 保存导出文件。
    static func saveReport(suggestedName: String, fileExtension: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.prompt = "导出"
        if let type = UTType(filenameExtension: fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// 选择 FFmpeg 可执行文件。
    static func chooseFFmpeg() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "指定"
        panel.message = "选择 ffmpeg 可执行文件"
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
