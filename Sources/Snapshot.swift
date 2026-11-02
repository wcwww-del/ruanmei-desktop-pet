import AppKit

/// 离屏渲染，用于开发时检查视觉效果（无需屏幕录制权限）。
/// 画面现在由图层合成，所以直接把图层树（优先取动画中的 presentation）画进位图。
enum Snapshot {
    static func render(to path: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let view = PetView(effects: PetAssetLoader.load())
        view.petSize = 230
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 502)
        if let scene = ProcessInfo.processInfo.environment["PET_SCENE"] {
            view.debugScene = scene
        }

        let window = NSWindow(contentRect: view.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderBack(nil)

        switch view.debugScene {
        case "bubble":
            view.showBubble("休息一下，茶点时间到了。", duration: 600)
        case "click":
            view.celebrate(double: true)
            view.showBubble("有趣吗？", duration: 600)
        case .some:
            break
        case nil:
            view.waterReminder()
        }
        view.layoutSubtreeIfNeeded()

        // 让呼吸、粒子、气泡动画先跑起来
        RunLoop.main.run(until: Date().addingTimeInterval(1.4))

        let scale: CGFloat = 2
        let size = view.bounds.size
        let pixelW = Int(size.width * scale)
        let pixelH = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: pixelW, height: pixelH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        ctx.clear(CGRect(origin: .zero, size: size))
        if let layer = view.layer?.presentation() ?? view.layer {
            layer.render(in: ctx)
        }
        guard let image = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        print("snapshot -> \(path)  \(pixelW)x\(pixelH)")
    }
}
