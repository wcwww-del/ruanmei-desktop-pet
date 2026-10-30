import AppKit

/// 形象与所有特效图层。缺失的图层会自动跳过，不影响主程序。
struct PetEffects {
    let pet: NSImage
    let shadow: NSImage?
    let blinkHalf: NSImage?
    let blinkClosed: NSImage?
    let voiceURL: URL?
    let greetVoiceURL: URL?
    let moveVoiceURL: URL?
    let clickVoiceURLs: [URL]
}

enum PetAssetLoader {
    static func load() -> PetEffects {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("RuanMeiPet")

        func url(_ name: String, _ ext: String, allowSupport: Bool = false) -> URL? {
            if allowSupport, let support {
                let u = support.appendingPathComponent("\(name).\(ext)")
                if fm.fileExists(atPath: u.path) { return u }
            }
            if let u = Bundle.main.url(forResource: name, withExtension: ext) { return u }
            let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            let candidates = [
                exeDir.appendingPathComponent("\(name).\(ext)"),
                exeDir.deletingLastPathComponent().appendingPathComponent("Resources/\(name).\(ext)"),
                URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("assets/\(name).\(ext)")
            ]
            return candidates.first { fm.fileExists(atPath: $0.path) }
        }

        func image(_ name: String, allowSupport: Bool = false) -> NSImage? {
            guard let u = url(name, "png", allowSupport: allowSupport) else { return nil }
            return NSImage(contentsOf: u)
        }

        let pet = image("ruanmei", allowSupport: true) ?? fallbackPet()
        let clickURLs = (1...3).compactMap { url("ruanmei_click\($0)", "m4a", allowSupport: true) }

        return PetEffects(
            pet: pet,
            shadow: image("fx_shadow"),
            blinkHalf: image("fx_blink_half"),
            blinkClosed: image("fx_blink_closed"),
            voiceURL: url("ruanmei_voice", "m4a", allowSupport: true),
            greetVoiceURL: url("ruanmei_greet", "m4a", allowSupport: true),
            moveVoiceURL: url("ruanmei_move", "m4a", allowSupport: true),
            clickVoiceURLs: clickURLs
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
