import AppKit

final class PetController: NSObject, NSMenuDelegate {

    // MARK: 组件

    private(set) var panel: PetPanel!
    private(set) var petView: PetView!
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private let scheduler = ReminderScheduler()
    private var voice: NSSound?
    private var greetVoice: NSSound?
    private var moveVoice: NSSound?
    private var clickVoices: [NSSound] = []

    // MARK: 轮询 / 场景状态

    private var chatStore: ChatStore?
    private var chatWindow: ChatWindowController?
    private var settingsWindow: SettingsWindowController?
    private var memoryWindow: MemoryWindowController?

    private var hitTimer: Timer?
    private var hitInterval: TimeInterval = 0
    private var pointerInside = false
    private var scenePaused = false
    private var systemAsleep = false
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    // MARK: 设置

    private let defaults = UserDefaults.standard
    private var petSize: CGFloat = 230
    private var remindersEnabled = true
    private var quietHours = false
    private var alwaysOnTop = true
    private var voiceEnabled = true
    private var petalsEnabled = true
    private var lowPower = false
    private var petHidden = false

    // MARK: 生命周期

    func start() {
        ConfigStore.shared.load()
        chatStore = PetPaths.databaseURL.flatMap { ChatStore(url: $0) }
        loadSettings()

        let assets = PetAssetLoader.load()
        let size = windowSize(pet: petSize)
        panel = PetPanel(contentRect: NSRect(origin: .zero, size: size))
        petView = PetView(effects: assets)
        petView.petSize = petSize
        petView.petalsEnabled = petalsEnabled
        petView.lowPower = lowPower
        petView.controller = self
        panel.contentView = petView

        voice = assets.voiceURL.flatMap { PetSecurity.sound(at: $0) }
        voice?.volume = 0.9
        greetVoice = assets.greetVoiceURL.flatMap { PetSecurity.sound(at: $0) }
        greetVoice?.volume = 0.9
        moveVoice = assets.moveVoiceURL.flatMap { PetSecurity.sound(at: $0) }
        moveVoice?.volume = 0.9
        clickVoices = assets.clickVoiceURLs.compactMap { PetSecurity.sound(at: $0) }
        clickVoices.forEach { $0.volume = 0.9 }

        SpeechEngine.shared.configure(ConfigStore.shared.config.tts)
        SpeechEngine.shared.onError = { [weak self] message in
            self?.petView.showBubble(message, duration: 6)
        }

        restorePosition()
        applyWindowLevel()
        panel.orderFrontRegardless()

        setupStatusItem()
        setupReminders()
        startHitTesting()
        registerObservers()

        if let warning = assets.warnings.first {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) { [weak self] in
                self?.petView.showBubble(warning, duration: 7)
            }
        }
        if let error = ConfigStore.shared.loadError {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.petView.showBubble(error, duration: 8)
            }
        }
    }

    deinit {
        hitTimer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    // MARK: 设置读写

    private func loadSettings() {
        if defaults.object(forKey: "pet.sizeV2") != nil {
            petSize = clamp(CGFloat(defaults.double(forKey: "pet.sizeV2")), 180, 420)
        }
        if defaults.object(forKey: "pet.reminders") != nil {
            remindersEnabled = defaults.bool(forKey: "pet.reminders")
        }
        if defaults.object(forKey: "pet.quiet") != nil {
            quietHours = defaults.bool(forKey: "pet.quiet")
        }
        if defaults.object(forKey: "pet.alwaysOnTop") != nil {
            alwaysOnTop = defaults.bool(forKey: "pet.alwaysOnTop")
        }
        if defaults.object(forKey: "pet.voiceEnabled") != nil {
            voiceEnabled = defaults.bool(forKey: "pet.voiceEnabled")
        }
        if defaults.object(forKey: "pet.petalsEnabled") != nil {
            petalsEnabled = defaults.bool(forKey: "pet.petalsEnabled")
        }
        if defaults.object(forKey: "pet.lowPower") != nil {
            lowPower = defaults.bool(forKey: "pet.lowPower")
        }
    }

    private func windowSize(pet: CGFloat) -> NSSize {
        NSSize(width: max(320, pet + 80),
               height: pet + PetMetrics.bubblePad * 2)
    }

    private func applyWindowLevel() {
        panel.level = alwaysOnTop ? .floating : .normal
    }

    // MARK: 位置

    private func restorePosition() {
        var origin: NSPoint?
        if let saved = defaults.string(forKey: "pet.origin") {
            origin = PetSecurity.restoredPoint(saved)
        }
        let point = clampOrigin(origin ?? defaultOrigin())
        panel.setFrameOrigin(point)
    }

    private func defaultOrigin() -> NSPoint {
        let screen = NSScreen.main
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = petView.petSize
        let w = panel.frame.width
        let h = panel.frame.height
        let local = CGRect(x: (w - size) / 2, y: (h - size) / 2, width: size, height: size)
        // 宠物脚底距屏幕底部 96pt，靠右侧
        return NSPoint(x: frame.maxX - 56 - local.maxX,
                       y: frame.minY + 96 - local.minY)
    }

    /// 保证宠物本体（而不是透明窗口）留在屏幕内。
    private func clampOrigin(_ origin: NSPoint) -> NSPoint {
        guard panel != nil, petView != nil else { return origin }
        let size = petView.petSize
        let w = panel.frame.width
        let h = panel.frame.height
        let local = CGRect(x: (w - size) / 2, y: (h - size) / 2, width: size, height: size)
        let petCenter = NSPoint(x: origin.x + w / 2, y: origin.y + h / 2)
        let screen = NSScreen.screens.first { $0.frame.contains(petCenter) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return origin }
        let minX = visible.minX + 4 - local.minX
        let maxX = visible.maxX - 4 - local.maxX
        let minY = visible.minY + 4 - local.minY
        let maxY = visible.maxY - 4 - local.maxY
        return NSPoint(x: clamp(origin.x, minX, maxX),
                       y: clamp(origin.y, minY, maxY))
    }

    func savePosition() {
        guard panel != nil else { return }
        let o = panel.frame.origin
        guard o.x.isFinite, o.y.isFinite else { return }
        defaults.set(String(format: "%.1f,%.1f", o.x, o.y), forKey: "pet.origin")
    }

    private func resetPosition() {
        panel.setFrameOrigin(clampOrigin(defaultOrigin()))
        savePosition()
        petView.showBubble("回到老位置啦。", duration: 3)
    }

    @objc private func screensChanged() {
        guard panel != nil else { return }
        panel.setFrameOrigin(clampOrigin(panel.frame.origin))
    }

    // MARK: 场景暂停（休眠 / 遮挡 / 隐藏）

    private func registerObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        })
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                           object: panel, queue: .main) { [weak self] _ in
            self?.handleOcclusionChange()
        })

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.systemAsleep = true
                self?.setScenePaused(true)
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.systemAsleep = false
                self.setScenePaused(false)
                self.scheduler.reschedule()
            })
        }
    }

    private func handleOcclusionChange() {
        guard panel != nil, !petHidden, !systemAsleep else { return }
        if panel.occlusionState.contains(.visible) {
            setScenePaused(false)
        } else if panel.isVisible {
            setScenePaused(true)
        }
    }

    private func setScenePaused(_ paused: Bool) {
        guard scenePaused != paused else { return }
        scenePaused = paused
        petView.setScenePaused(paused)
        if paused {
            hitTimer?.invalidate()
            hitTimer = nil
            panel.ignoresMouseEvents = true
        } else {
            startHitTesting()
        }
    }

    // MARK: 鼠标穿透 / 悬停

    private func startHitTesting() {
        guard panel != nil, !scenePaused, !petHidden else { return }
        pointerInside = false
        scheduleHitTimer(interval: 1.0 / 6.0)
    }

    private func scheduleHitTimer(interval: TimeInterval) {
        hitTimer?.invalidate()
        hitInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.hitTick()
        }
        timer.tolerance = interval * 0.35
        RunLoop.main.add(timer, forMode: .common)
        hitTimer = timer
    }

    private func hitTick() {
        guard panel != nil, panel.isVisible, !scenePaused, !petHidden else { return }
        updateMouse()
        let wanted = desiredPollInterval()
        if abs(wanted - hitInterval) > 0.001 { scheduleHitTimer(interval: wanted) }
    }

    /// 指针压在宠物身上时靠窗口事件驱动（保留 1 秒兜底），
    /// 离开后按距离分级：近处 20Hz、中距 6Hz、远处 1Hz。
    private func desiredPollInterval() -> TimeInterval {
        if pointerInside { return 1.0 }
        if petView.isDragging { return 1.0 / 30.0 }
        let distance = cursorDistanceToPet()
        if distance < 80 { return 1.0 / 20.0 }
        if distance < 420 { return 1.0 / 6.0 }
        return 1.0
    }

    private func cursorDistanceToPet() -> CGFloat {
        guard panel != nil, petView != nil else { return .greatestFiniteMagnitude }
        let windowPoint = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let local = petView.convert(windowPoint, from: nil)
        let r = petView.petRect
        let dx = max(max(r.minX - local.x, 0), local.x - r.maxX)
        let dy = max(max(r.minY - local.y, 0), local.y - r.maxY)
        return hypot(dx, dy)
    }

    private func updateMouse() {
        guard panel != nil, panel.isVisible else { return }
        if petView.isDragging {
            panel.ignoresMouseEvents = false
            return
        }
        let screenPoint = NSEvent.mouseLocation
        let windowPoint = panel.convertPoint(fromScreen: screenPoint)
        let local = petView.convert(windowPoint, from: nil)
        let inside = petView.acceptsPoint(local)
        if panel.ignoresMouseEvents != !inside {
            panel.ignoresMouseEvents = !inside
        }

        if inside {
            let wasInside = pointerInside
            pointerInside = true
            petView.setHovering(true, cursor: local)
            if !wasInside { NSCursor.openHand.set() }
        } else {
            if pointerInside {
                pointerInside = false
                NSCursor.arrow.set()
            }
            petView.setHovering(false, cursor: local)
        }
    }

    /// 鼠标离开宠物视图：交还给桌面点击，并恢复快速轮询以便重新进入。
    func petPointerLeft() {
        pointerInside = false
        if petView.isDragging { return }
        panel.ignoresMouseEvents = true
        NSCursor.arrow.set()
        guard !scenePaused, !petHidden else { return }
        scheduleHitTimer(interval: 1.0 / 20.0)
    }

    // MARK: 拖拽回调

    func petDidBeginDrag() {
        panel.ignoresMouseEvents = false
        pointerInside = false
        stopAllVoices()
    }

    func petDidEndDrag() {
        panel.setFrameOrigin(clampOrigin(panel.frame.origin))
        savePosition()
        petView.showBubble("很好，优美的姿势。", duration: 5.5)
        play(moveVoice)
    }

    /// 点击分级：1 次 -> 点击 1；2 次 -> 点击 2；3 次及以上 -> 点击 3。
    func petClicked(count: Int) {
        let tier = min(3, max(1, count))
        let lines = ["那是什么？有点…感兴趣。", "有趣吗？", "离我远点。"]
        let durations: [CGFloat] = [7.0, 5.0, 4.5]
        petView.showBubble(lines[tier - 1], duration: durations[tier - 1])
        if clickVoices.indices.contains(tier - 1) {
            play(clickVoices[tier - 1])
        }
    }

    // MARK: 提醒

    private func setupReminders() {
        scheduler.isEnabled = remindersEnabled
        scheduler.quietHoursEnabled = quietHours
        scheduler.onFire = { [weak self] in
            self?.fireWaterReminder()
        }
        scheduler.start()
    }

    private func fireWaterReminder() {
        guard panel != nil, panel.isVisible, !petHidden, !systemAsleep else { return }
        panel.orderFrontRegardless()
        setScenePaused(false)
        petView.waterReminder()
        playVoice()
    }

    private func playVoice(force: Bool = false) {
        if !force && quietHours {
            let hour = Calendar.current.component(.hour, from: Date())
            if hour >= 23 || hour < 7 { return }
        }
        if let voice {
            play(voice)
            return
        }
        if let sound = NSSound(named: NSSound.Name("Glass")) {
            play(sound)
        }
    }

    private func stopAllVoices() {
        voice?.stop()
        greetVoice?.stop()
        moveVoice?.stop()
        clickVoices.forEach { $0.stop() }
    }

    private func play(_ sound: NSSound?) {
        stopAllVoices()
        guard voiceEnabled, let sound else { return }
        sound.stop()
        sound.volume = 0.9
        sound.play()
    }

    // MARK: 气泡 / 动作

    func showSpeech(_ text: String, duration: CGFloat = 5) {
        guard panel != nil, panel.isVisible else { return }
        petView.showBubble(text, duration: duration)
    }

    func greet() {
        if petHidden { setHidden(false) }
        petView.happyHop()
        petView.showBubble("我叫阮·梅，念我名字时，请别忘了中间气息的停歇。", duration: 8.5)
        playGreeting()
    }

    private func playGreeting() {
        if let greetVoice {
            play(greetVoice)
            return
        }
        if let sound = NSSound(named: NSSound.Name("Glass")) {
            play(sound)
        }
    }

    func reminderNow() {
        if petHidden { setHidden(false) }
        petView.waterReminder()
        playVoice(force: true)
    }

    // MARK: 状态栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "drop.fill", accessibilityDescription: "阮·梅桌宠")
            img?.isTemplate = true
            button.image = img
            button.toolTip = "阮·梅桌宠"
        }
        menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        buildMenu()
        statusItem.menu = menu
    }

    private func buildMenu() {
        let header = NSMenuItem(title: "阮·梅桌宠", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        addItem("和阮·梅说话…", action: #selector(openChatAction), key: "")
        addItem("打个招呼", action: #selector(greetAction), key: "")
        addItem("现在提醒我喝水", action: #selector(remindNowAction), key: "")
        menu.addItem(NSMenuItem.separator())

        let remind = addItem("整点喝水提醒", action: #selector(toggleRemindersAction), key: "")
        remind.tag = 100
        let quiet = addItem("夜间免打扰（23:00–07:00）", action: #selector(toggleQuietAction), key: "")
        quiet.tag = 101
        let voiceItem = addItem("语音", action: #selector(toggleVoiceAction), key: "")
        voiceItem.tag = 104
        let petalItem = addItem("梅花飘落", action: #selector(togglePetalsAction), key: "")
        petalItem.tag = 105
        let lowPowerItem = addItem("低耗电模式（静止）", action: #selector(toggleLowPowerAction), key: "")
        lowPowerItem.tag = 106
        menu.addItem(NSMenuItem.separator())

        let sizeItem = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for (title, value) in [("小", 190.0), ("中", 230.0), ("大", 300.0)] {
            let item = NSMenuItem(title: title, action: #selector(changeSizeAction(_:)), keyEquivalent: "")
            item.tag = Int(value)
            item.target = self
            sizeMenu.addItem(item)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let top = addItem("始终置顶", action: #selector(toggleOnTopAction), key: "")
        top.tag = 102
        addItem("重置位置", action: #selector(resetPositionAction), key: "")
        menu.addItem(NSMenuItem.separator())

        let hide = addItem("隐藏桌宠", action: #selector(toggleHiddenAction), key: "")
        hide.tag = 103
        addItem("记忆…", action: #selector(openMemoryAction), key: "")
        addItem("设置…", action: #selector(openSettingsAction), key: "")
        addItem("使用说明", action: #selector(helpAction), key: "")
        menu.addItem(NSMenuItem.separator())
        addItem("退出阮·梅", action: #selector(quitAction), key: "q")

        refreshMenuStates()
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    private func refreshMenuStates() {
        guard menu != nil else { return }
        for item in menu.items {
            switch item.tag {
            case 100: item.state = remindersEnabled ? .on : .off
            case 101: item.state = quietHours ? .on : .off
            case 102: item.state = alwaysOnTop ? .on : .off
            case 104: item.state = voiceEnabled ? .on : .off
            case 105: item.state = petalsEnabled ? .on : .off
            case 106: item.state = lowPower ? .on : .off
            case 103:
                item.title = petHidden ? "显示桌宠" : "隐藏桌宠"
                item.state = .off
            default: break
            }
            if let sub = item.submenu {
                for sizeItem in sub.items {
                    sizeItem.state = abs(CGFloat(sizeItem.tag) - petSize) < 0.5 ? .on : .off
                }
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenuStates()
    }

    func showContextMenu(at event: NSEvent) {
        refreshMenuStates()
        NSMenu.popUpContextMenu(menu, with: event, for: petView)
    }

    // MARK: 菜单动作

    @objc private func greetAction() { greet() }

    @objc private func remindNowAction() { reminderNow() }

    @objc private func toggleVoiceAction() {
        voiceEnabled.toggle()
        defaults.set(voiceEnabled, forKey: "pet.voiceEnabled")
        if !voiceEnabled { stopAllVoices() }
        refreshMenuStates()
        petView.showBubble(voiceEnabled ? "语音已开启" : "语音已关闭", duration: 2.8)
    }

    @objc private func togglePetalsAction() {
        petalsEnabled.toggle()
        petView.petalsEnabled = petalsEnabled
        defaults.set(petalsEnabled, forKey: "pet.petalsEnabled")
        refreshMenuStates()
        petView.showBubble(petalsEnabled ? "梅花飘落：已开启" : "梅花飘落：已关闭", duration: 2.8)
    }

    @objc private func toggleLowPowerAction() {
        lowPower.toggle()
        petView.lowPower = lowPower
        defaults.set(lowPower, forKey: "pet.lowPower")
        refreshMenuStates()
        petView.showBubble(lowPower ? "低耗电模式：只剩眨眼，几乎不耗电"
                                    : "低耗电模式已关闭",
                           duration: 3.2)
    }

    @objc private func toggleRemindersAction() {
        remindersEnabled.toggle()
        scheduler.isEnabled = remindersEnabled
        defaults.set(remindersEnabled, forKey: "pet.reminders")
        refreshMenuStates()
        petView.showBubble(remindersEnabled ? "整点喝水提醒：已开启" : "整点喝水提醒：已关闭",
                           duration: 3.2)
    }

    @objc private func toggleQuietAction() {
        quietHours.toggle()
        scheduler.quietHoursEnabled = quietHours
        defaults.set(quietHours, forKey: "pet.quiet")
        refreshMenuStates()
        petView.showBubble(quietHours ? "23:00–07:00 不再打扰你" : "夜间免打扰已关闭",
                           duration: 3.2)
    }

    @objc private func changeSizeAction(_ sender: NSMenuItem) {
        setPetSize(CGFloat(sender.tag))
    }

    private func setPetSize(_ newSize: CGFloat) {
        guard abs(newSize - petSize) > 0.5 else { return }
        let oldCenter = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        petSize = clamp(newSize, 180, 420)
        defaults.set(Double(newSize), forKey: "pet.sizeV2")

        let s = windowSize(pet: petSize)
        let origin = NSPoint(x: oldCenter.x - s.width / 2,
                             y: oldCenter.y - s.height / 2)
        petView.petSize = petSize
        panel.setFrame(NSRect(origin: origin, size: s), display: true)
        panel.setFrameOrigin(clampOrigin(origin))
        savePosition()
        refreshMenuStates()
        petView.showBubble("大小：\(Int(petSize)) pt", duration: 2.4)
    }

    @objc private func toggleOnTopAction() {
        alwaysOnTop.toggle()
        applyWindowLevel()
        defaults.set(alwaysOnTop, forKey: "pet.alwaysOnTop")
        refreshMenuStates()
        petView.showBubble(alwaysOnTop ? "会一直陪在最前面。" : "已取消置顶。", duration: 3)
        if alwaysOnTop { panel.orderFrontRegardless() }
    }

    @objc private func resetPositionAction() { resetPosition() }

    @objc private func toggleHiddenAction() { setHidden(!petHidden) }

    private func setHidden(_ hidden: Bool) {
        petHidden = hidden
        if hidden {
            panel.orderOut(nil)
            setScenePaused(true)
        } else {
            panel.orderFrontRegardless()
            panel.ignoresMouseEvents = true
            setScenePaused(false)
        }
        refreshMenuStates()
    }

    // MARK: 对话 / 记忆 / 设置

    @objc private func openChatAction() { openChat() }
    @objc private func openSettingsAction() { openSettings() }
    @objc private func openMemoryAction() { openMemoryList() }

    private func makeChatWindow() -> ChatWindowController {
        if let chatWindow { return chatWindow }
        let window = ChatWindowController(store: chatStore, avatar: petView.effects.pet)
        window.onOpenSettings = { [weak self] in self?.openSettings() }
        window.onOpenMemory = { [weak self] in self?.openMemoryList() }
        window.onAssistantFinished = { [weak self] text in
            guard let self else { return }
            // 对话窗口不在前台时，把回复的第一句带回到桌宠气泡上。
            if self.chatWindow?.window?.isKeyWindow != true {
                self.petView.showBubble(Self.firstSentence(text), duration: 6)
            }
        }
        chatWindow = window
        return window
    }

    func openChat() {
        makeChatWindow().open()
    }

    func openSettings() {
        if settingsWindow == nil {
            let window = SettingsWindowController(store: chatStore, effects: petView.effects)
            window.onSave = { [weak self] in
                self?.chatWindow?.reloadConfig()
                SpeechEngine.shared.configure(ConfigStore.shared.config.tts)
            }
            settingsWindow = window
        }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openMemoryList() {
        if memoryWindow == nil {
            let window = MemoryWindowController(store: chatStore)
            window.onExtract = { [weak self] in self?.extractMemoriesNow() }
            memoryWindow = window
        }
        memoryWindow?.reload()
        memoryWindow?.showWindow(nil)
        memoryWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func extractMemoriesNow() {
        // 即使对话窗口没打开过，也能用设置 / 记忆窗口里的「立即整理」。
        makeChatWindow().extractMemoriesNow()
    }

    func refreshMemoryWindow() {
        memoryWindow?.reload()
    }

    private static func firstSentence(_ text: String) -> String {
        let limit = 80
        for index in text.indices {
            if "。！？!?\n".contains(text[index]) {
                let sentence = String(text[...index]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty {
                    return sentence.count > limit ? String(sentence.prefix(limit)) + "…" : sentence
                }
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }

    @objc private func helpAction() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "阮·梅桌宠"
        alert.informativeText = """
        · 按住她，可以拖到屏幕任意位置
        · 单击会有回应，双击试试看
        · 右键打开菜单
        · 菜单栏的水滴图标里可以调整大小、开关整点提醒
        · 会呼吸、眨眼、飘落梅花（可开关）
        · 拖动结束、点击时会说不同的话
        · 每到整点，她弹文字气泡并播放语音，提醒你喝水
        · 透明区域不会挡住其他窗口的点击

        关闭提醒：菜单栏水滴 → 整点喝水提醒
        关闭梅花：菜单栏水滴 → 梅花飘落
        最省电：菜单栏水滴 → 低耗电模式（静止）
        """
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func quitAction() {
        savePosition()
        NSApp.terminate(nil)
    }
}
