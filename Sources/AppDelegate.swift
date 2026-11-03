import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PetController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        controller = PetController()
        controller.start()

        if !UserDefaults.standard.bool(forKey: "pet.hasLaunched") {
            UserDefaults.standard.set(true, forKey: "pet.hasLaunched")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.controller.showSpeech("我是阮·梅。今天也请多关照。", duration: 5)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.savePosition()
    }
}
