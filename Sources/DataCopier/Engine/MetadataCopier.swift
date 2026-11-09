import Foundation

/// 拷贝完成后保留来源文件的权限位、时间戳与扩展属性。
///
/// 扩展属性（xattr）是 macOS 上承载 Finder 标签、隔离属性（com.apple.quarantine）、
/// 资源分支等信息的关键载体，普通 `copyItem` 之外的实现很容易丢失。
enum MetadataCopier {

    static func copy(from sourcePath: String, to destinationPath: String) {
        copyPOSIXAttributes(from: sourcePath, to: destinationPath)
        copyExtendedAttributes(from: sourcePath, to: destinationPath)
    }

    // MARK: - 权限与时间戳

    private static func copyPOSIXAttributes(from sourcePath: String, to destinationPath: String) {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: sourcePath) else { return }

        var settable: [FileAttributeKey: Any] = [:]
        if let permissions = attributes[.posixPermissions] { settable[.posixPermissions] = permissions }
        if let modified = attributes[.modificationDate] { settable[.modificationDate] = modified }
        if let created = attributes[.creationDate] { settable[.creationDate] = created }
        guard !settable.isEmpty else { return }

        try? fm.setAttributes(settable, ofItemAtPath: destinationPath)
    }

    // MARK: - 扩展属性

    private static func copyExtendedAttributes(from sourcePath: String, to destinationPath: String) {
        let bufferSize = sourcePath.withCString { listxattr($0, nil, 0, 0) }
        guard bufferSize > 0 else { return }

        var nameBuffer = [CChar](repeating: 0, count: bufferSize)
        let written = sourcePath.withCString { listxattr($0, &nameBuffer, bufferSize, 0) }
        guard written > 0 else { return }

        var index = 0
        while index < written {
            var end = index
            while end < written && nameBuffer[end] != 0 { end += 1 }

            let nameBytes = nameBuffer[index..<end].map { UInt8(bitPattern: $0) }
            let name = String(decoding: nameBytes, as: UTF8.self)
            index = end + 1

            guard !name.isEmpty else { continue }
            copyAttribute(named: name, from: sourcePath, to: destinationPath)
        }
    }

    private static func copyAttribute(named name: String, from sourcePath: String, to destinationPath: String) {
        let valueSize = name.withCString { getxattr(sourcePath, $0, nil, 0, 0, 0) }
        guard valueSize > 0 else { return }

        var value = [UInt8](repeating: 0, count: valueSize)
        let readCount = name.withCString { namePointer in
            value.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return getxattr(sourcePath, namePointer, base, valueSize, 0, 0)
            }
        }
        guard readCount > 0 else { return }

        _ = name.withCString { namePointer in
            value.withUnsafeBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return -1 }
                return setxattr(destinationPath, namePointer, base, readCount, 0, 0)
            }
        }
    }
}
