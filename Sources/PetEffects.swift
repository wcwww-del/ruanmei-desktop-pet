import AppKit

/// 形象与所有特效图层。缺失的图层会自动跳过，不影响主程序。
///
/// 所有素材来源都会经过 `PetSecurity` 校验：
/// 只接受当前用户拥有的普通文件（非软链接、组/其他人不可写、大小和像素尺寸有上限），
/// 图片由 ImageIO 判断真实格式，语音在载入时整段读进内存。
/// 被拒绝的自定义素材会记录到 `warnings`，由菜单栏在启动后提示用户。
struct PetEffects {
    let pet: NSImage
    let shadow: NSImage?
    let blinkHalf: NSImage?
    let blinkClosed: NSImage?
    let voiceURL: URL?
    let greetVoiceURL: URL?
    let moveVoiceURL: URL?
    let clickVoiceURLs: [URL]
    let warnings: [String]
}

enum PetAssetLoader {
    static func load() -> PetEffects {
        var warnings: [String] = []
        let support = PetSecurity.userAssetDirectory()

        func userFile(_ name: String, _ ext: String, maxBytes: Int64) -> URL? {
            guard let support else { return nil }
            let candidate = support.appendingPathComponent("\(name).\(ext)")
            guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
            guard let trusted = PetSecurity.trustedFile(in: support,
                                                        named: "\(name).\(ext)",
                                                        maxBytes: maxBytes) else {
                warnings.append("自定义素材 \(name).\(ext) 未通过安全检查，已忽略。")
                return nil
            }
            return trusted
        }

        func bundledFile(_ name: String, _ ext: String, maxBytes: Int64) -> URL? {
            if let url = Bundle.main.url(forResource: name, withExtension: ext),
               let safe = PetSecurity.bundleFile(url, maxBytes: maxBytes) {
                return safe
            }
            // 只有显式打开 RUANMEI_DEV_ASSETS=1 才允许从工作目录读素材（开发调试用）。
            guard PetSecurity.allowsWorkingDirectoryAssets, let exeDir = PetSecurity.executableDirectory else {
                return nil
            }
            let candidates = [
                exeDir.appendingPathComponent("\(name).\(ext)"),
                exeDir.deletingLastPathComponent().appendingPathComponent("Resources/\(name).\(ext)"),
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("assets/\(name).\(ext)")
            ]
            for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
                if let safe = PetSecurity.bundleFile(candidate, maxBytes: maxBytes) { return safe }
            }
            return nil
        }

        func image(_ name: String, allowCustom: Bool = false) -> NSImage? {
            if allowCustom, let url = userFile(name, "png", maxBytes: PetSecurity.maxImageBytes) {
                if let image = PetSecurity.image(at: url) { return image }
                warnings.append("自定义形象 \(name).png 无法解码或尺寸超限，已回退到内置形象。")
            }
            guard let url = bundledFile(name, "png", maxBytes: PetSecurity.maxImageBytes) else { return nil }
            return PetSecurity.image(at: url)
        }

        func audio(_ name: String) -> URL? {
            userFile(name, "m4a", maxBytes: PetSecurity.maxAudioBytes)
                ?? bundledFile(name, "m4a", maxBytes: PetSecurity.maxAudioBytes)
        }

        let pet = image("ruanmei", allowCustom: true) ?? fallbackPet()
        let clickURLs = (1...3).compactMap { audio("ruanmei_click\($0)") }

        return PetEffects(
            pet: pet,
            shadow: image("fx_shadow"),
            blinkHalf: image("fx_blink_half"),
            blinkClosed: image("fx_blink_closed"),
            voiceURL: audio("ruanmei_voice"),
            greetVoiceURL: audio("ruanmei_greet"),
            moveVoiceURL: audio("ruanmei_move"),
            clickVoiceURLs: clickURLs,
            warnings: warnings
        )
    }

    private static func fallbackPet() -> NSImage {
        let img = NSImage(size: NSSize(width: 512, height: 512))
        img.lockFocus()
        NSColor(srgbRed: 0.55, green: 0.83, blue: 0.88, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 48, y: 48, width: 416, height: 416)).fill()
        img.unlockFocus()
        return img
    }
}
