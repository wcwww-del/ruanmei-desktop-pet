import AppKit

if let idx = CommandLine.arguments.firstIndex(of: "--render") {
    let out = CommandLine.arguments.count > idx + 1 ? CommandLine.arguments[idx + 1] : "snapshot.png"
    Snapshot.render(to: out)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
