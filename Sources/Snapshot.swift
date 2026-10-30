import AppKit

/// 离屏渲染，用于开发时检查视觉效果（无需屏幕录制权限）。
enum Snapshot {
    static func render(to path: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let view = PetView(effects: PetAssetLoader.load())
        view.petSize = 230
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 502)
        view.wantsLayer = false

        let window = NSWindow(contentRect: view.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderBack(nil)

        if let scene = ProcessInfo.processInfo.environment["PET_SCENE"] {
            view.debugScene = scene
        }
        if view.debugScene == "bubble" {
            view.showBubble("休息一下，茶点时间到了。", duration: 600)
        } else if view.debugScene == nil {
            view.waterReminder()
        }
        view.layoutSubtreeIfNeeded()

        // 让弹簧动画和粒子先跑起来
        RunLoop.main.run(until: Date().addingTimeInterval(1.4))

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        print("snapshot -> \(path)  \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }
}
