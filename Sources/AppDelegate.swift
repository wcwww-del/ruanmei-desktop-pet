import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var petController: PetController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        petController = PetController()
        petController.start()

        if !UserDefaults.standard.bool(forKey: "pet.hasLaunched") {
            UserDefaults.standard.set(true, forKey: "pet.hasLaunched")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.petController.showSpeech("我是阮·梅。今天也请多关照。", duration: 5)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        petController?.savePosition()
    }
}
