import Foundation

/// 一台已挂载的 USB 存储设备及其识别出的拍摄设备型号。
struct USBDeviceHit: Sendable {
    /// 卷的挂载路径（如 `/Volumes/Untitled`）。
    let volumePath: String
    /// 从卷内媒体文件识别到的设备型号；读不到时为 nil。
    let deviceModel: String?
}

/// 插入 USB 设备后扫描卷内媒体文件，识别拍摄设备型号。
///
/// 相机卡里的照片 EXIF 与视频容器都写有机型；打开新建任务时先扫几个文件，
/// 就能把「这台设备是谁」提前告诉用户并用于路径预览，不必等拷贝完再看报告。
/// 读不到型号时返回 nil，由调用方按「未知设备」处理。
enum USBDeviceScanner {

    /// 最多读取的媒体文件数。读到第一个有效型号即返回，
    /// 上限只防止整卡素材全部无 EXIF 时的空转。
    private static let maxFilesToRead = 8

    /// 目录遍历深度上限：相机卡素材通常位于 DCIM 等浅层目录。
    private static let maxDepth = 4

    /// 收集文件数的软上限：够挑出可读的样本即可，不为扫描耗时买单。
    private static let maxCollectedFiles = 200

    /// 返回识别到的设备型号（已规范化、可直接用作目录名）；无法识别时返回 nil。
    static func detectDeviceModel(at rootPath: String) -> String? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: rootPath, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }

        var candidates: [String] = []
        collectMediaFiles(at: rootPath, depth: 0, into: &candidates)
        guard !candidates.isEmpty else { return nil }

        let settings = MediaImportSettings()
        for path in candidates.prefix(maxFilesToRead) {
            let ext = ((path as NSString).pathExtension as String).lowercased()
            let kind: MediaKind = MediaFileTypes.photoExtensions.contains(ext) ? .photo : .video
            let result = MediaMetadata.read(forPath: path,
                                            kind: kind,
                                            settings: settings,
                                            probe: nil,
                                            modifiedDate: nil)
            if let model = MediaImportSettings.normalizedDeviceName(result.deviceModel) {
                return MediaArchiver.sanitize(model)
            }
        }
        return nil
    }

    /// 枚举电脑上当前挂载的可移动存储卷，并逐个尝试识别拍摄设备型号。
    ///
    /// 判定口径与挂载监听一致：可移除或可弹出即视为 USB 存储设备，
    /// 内置磁盘与隐藏系统卷不在结果中。
    static func detectUSBDevices() -> [USBDeviceHit] {
        let fm = FileManager.default
        let urls = (try? fm.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsRemovableKey, .volumeIsEjectableKey],
            options: [.skipHiddenVolumes])) ?? []

        var hits: [USBDeviceHit] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.volumeIsRemovableKey,
                                                           .volumeIsEjectableKey])
            guard values?.volumeIsRemovable == true || values?.volumeIsEjectable == true,
                  url.path != "/" else { continue }
            hits.append(USBDeviceHit(volumePath: url.path,
                                     deviceModel: detectDeviceModel(at: url.path)))
        }
        return hits
    }

    /// 深度优先收集卷内的照片与视频路径，先到先得。
    ///
    /// 刻意不排序、不按时间筛选：相机卡里的文件位置与机型无关，
    /// 任意一张能读出 EXIF 的照片都足以确定设备身份。
    private static func collectMediaFiles(at directory: String,
                                          depth: Int,
                                          into files: inout [String]) {
        guard depth <= maxDepth, files.count < maxCollectedFiles else { return }
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: directory))?.sorted() ?? []
        for name in contents {
            let full = (directory as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                collectMediaFiles(at: full, depth: depth + 1, into: &files)
            } else {
                let ext = ((full as NSString).pathExtension as String).lowercased()
                if MediaFileTypes.photoExtensions.contains(ext)
                    || MediaFileTypes.videoExtensions.contains(ext) {
                    files.append(full)
                    if files.count >= maxCollectedFiles { return }
                }
            }
        }
    }
}
