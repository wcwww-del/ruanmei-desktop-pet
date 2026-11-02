import AppKit
import Darwin
import ImageIO

/// 安全加固：所有来自 App 包之外的数据（用户自定义形象、语音、保存的位置、气泡文案）
/// 在进入渲染 / 播放 / 存储之前都要经过这里的校验和限幅。
enum PetSecurity {

    // MARK: - 限额

    /// 单条气泡最多显示多少字（防止异常长的文本撑爆布局与绘制）。
    static let maxBubbleCharacters = 400
    /// 自定义形象的最长边（像素）。900×900 的官方素材远小于此。
    static let maxImageEdge = 4096
    /// 自定义形象的总像素数上限，防止解压炸弹。
    static let maxImagePixels = 16_000_000
    static let maxImageBytes: Int64 = 32 << 20
    static let maxAudioBytes: Int64 = 24 << 20
    /// 屏幕上同时存在的粒子图层上限。
    static let maxLiveParticles = 96
    /// 一次动作最多生成多少粒子。
    static let maxParticlesPerBurst = 24

    // MARK: - 文本

    /// 去掉控制字符、压缩连续换行、限制长度。
    static func sanitizeBubbleText(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(min(text.count, maxBubbleCharacters))
        var lastWasNewline = false
        for scalar in text.unicodeScalars {
            if out.count >= maxBubbleCharacters { break }
            if scalar == "\n" {
                if lastWasNewline { continue }
                lastWasNewline = true
                out.unicodeScalars.append(scalar)
                continue
            }
            if CharacterSet.controlCharacters.contains(scalar) { continue }
            lastWasNewline = false
            out.unicodeScalars.append(scalar)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func clampBubbleDuration(_ duration: CGFloat) -> CGFloat {
        clamp(duration, 0.6, 120)
    }

    // MARK: - 位置

    /// 保存的值来自 UserDefaults，可能被手工改过（NaN / inf / 巨大值）。
    static func restoredPoint(_ string: String) -> NSPoint? {
        let parts = string.split(separator: ",")
        guard parts.count == 2,
              let x = Double(parts[0]), let y = Double(parts[1]),
              x.isFinite, y.isFinite,
              abs(x) < 100_000, abs(y) < 100_000 else { return nil }
        return NSPoint(x: x, y: y)
    }

    // MARK: - 用户目录

    /// `~/Library/Application Support/RuanMeiPet`。
    /// 只有在目录属于当前用户、不是软链接、且没有组/其他人写权限时才返回。
    static func userAssetDirectory() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("RuanMeiPet", isDirectory: true)

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dir.path, isDirectory: &isDir) {
            guard isDir.boolValue else { return nil }
            guard let values = try? dir.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink != true else { return nil }
            guard let attrs = try? fm.attributesOfItem(atPath: dir.path),
                  let owner = attrs[.ownerAccountID] as? NSNumber, owner.intValue == Int(getuid()),
                  let mode = attrs[.posixPermissions] as? NSNumber,
                  (mode.intValue & 0o002) == 0 else { return nil }
            return dir
        }

        guard (try? fm.createDirectory(at: dir,
                                       withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        return dir
    }

    /// 在受信目录里按名字取文件：解析符号链接后必须仍然是这个目录的直接子项。
    static func trustedFile(in directory: URL, named name: String, maxBytes: Int64) -> URL? {
        let candidate = directory.appendingPathComponent(name)
        let resolved = candidate.resolvingSymlinksInPath()
        let dir = directory.resolvingSymlinksInPath()
        guard resolved.deletingLastPathComponent().path == dir.path else { return nil }
        return trustedRegularFile(resolved, maxBytes: maxBytes)
    }

    /// 只接受属于当前用户、不是软链接、组/其他人不可写、大小受控的普通文件。
    static func trustedRegularFile(_ url: URL, maxBytes: Int64) -> URL? {
        let fm = FileManager.default
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, Int64(size) <= maxBytes,
              let attrs = try? fm.attributesOfItem(atPath: url.path),
              let mode = attrs[.posixPermissions] as? NSNumber, (mode.intValue & 0o022) == 0,
              let owner = attrs[.ownerAccountID] as? NSNumber, owner.intValue == Int(getuid()) else {
            return nil
        }
        return url
    }

    /// App 包内的资源受代码签名保护，这里只做大小与类型的基本检查。
    static func bundleFile(_ url: URL, maxBytes: Int64) -> URL? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size > 0, Int64(size) <= maxBytes else { return nil }
        return url
    }

    // MARK: - 资源解码

    /// 只解码有尺寸上限的图片；不信任扩展名，交给 ImageIO 判断真实格式。
    static func image(at url: URL) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0,
              width <= maxImageEdge, height <= maxImageEdge,
              width * height <= maxImagePixels else { return nil }

        guard let cgImage = CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// 只接受 ISO-BMFF（m4a/mp4）容器，并且整段读进内存，之后不再依赖磁盘文件。
    static func sound(at url: URL) -> NSSound? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12), head.count >= 12 else { return nil }
        let bytes = [UInt8](head)
        guard bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 else { return nil }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return NSSound(data: data)
    }

    /// 调试用：只有显式打开环境变量才允许从工作目录加载素材（开发模式）。
    static var allowsWorkingDirectoryAssets: Bool {
        ProcessInfo.processInfo.environment["RUANMEI_DEV_ASSETS"] == "1"
    }

    /// 当前进程可执行文件所在目录（绝对路径）。
    static var executableDirectory: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "").deletingLastPathComponent()
    }
}
