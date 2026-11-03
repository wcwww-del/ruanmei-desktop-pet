import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// 设置窗口：模型 API / 语音 / 记忆 / 人格。
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let config = ConfigStore.shared
    private let store: ChatStore?
    private let effects: PetEffects
    var onSave: (() -> Void)?

    // 模型
    private var llmBaseURL: NSTextField!
    private var llmKey: NSSecureTextField!
    private var llmModel: NSTextField!
    private var llmTemp: NSSlider!
    private var llmTempValue: NSTextField!
    private var llmMaxTokens: NSTextField!
    private var llmStatus: NSTextField!

    // 语音
    private var ttsEnabled: NSButton!
    private var ttsProvider: NSPopUpButton!
    private var ttsBaseURL: NSTextField!
    private var ttsKey: NSSecureTextField!
    private var ttsModel: NSTextField!
    private var ttsVoice: NSTextField!
    private var ttsSpeed: NSSlider!
    private var ttsSpeedValue: NSTextField!
    private var ttsSystemVoice: NSPopUpButton!
    private var ttsStatus: NSTextField!

    // 记忆
    private var memoryEnabled: NSButton!
    private var memoryEvery: NSPopUpButton!
    private var memoryInject: NSPopUpButton!
    private var memoryHistory: NSPopUpButton!
    private var memorySummarize: NSPopUpButton!
    private var memoryStatus: NSTextField!

    // 人格
    private var personaPopup: NSPopUpButton!
    private var personaName: NSTextField!
    private var personaTagline: NSTextField!
    private var personaGreeting: NSTextField!
    private var personaPrompt: NSTextView!
    private var personaNewButton: NSButton!
    private var personaCopyButton: NSButton!
    private var personaSaveButton: NSButton!
    private var personaDeleteButton: NSButton!
    private var personaStatus: NSTextField!
    private var editingPersonaID: String = ""

    private var tabs: NSTabView!
    private var tester: ChatTask?

    init(store: ChatStore?, effects: PetEffects) {
        self.store = store
        self.effects = effects
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 660),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "阮·梅桌宠 · 设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        loadValues()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 构建界面

    private func buildUI() {
        guard let content = window?.contentView else { return }

        tabs = NSTabView(frame: NSRect(x: 12, y: 56, width: 536, height: 592))
        tabs.autoresizingMask = [.width, .height]
        content.addSubview(tabs)

        tabs.addTabViewItem(tab(title: "模型", content: buildModelTab()))
        tabs.addTabViewItem(tab(title: "语音", content: buildTTSTab()))
        tabs.addTabViewItem(tab(title: "记忆", content: buildMemoryTab()))
        tabs.addTabViewItem(tab(title: "人格", content: buildPersonaTab()))

        let saveButton = NSButton(title: "保存并关闭", target: self, action: #selector(saveAndClose))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.frame = NSRect(x: 416, y: 16, width: 120, height: 30)
        saveButton.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(saveButton)

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(closeWindow))
        cancelButton.bezelStyle = .rounded
        cancelButton.frame = NSRect(x: 336, y: 16, width: 68, height: 30)
        cancelButton.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(cancelButton)
    }

    private func tab(title: String, content: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = content
        return item
    }

    private func form(_ rows: [NSView]) -> NSView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        let container = NSView()
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -16)
        ])
        return container
    }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 10
        return stack
    }

    private func textField(_ placeholder: String, secure: Bool = false, width: CGFloat = 380) -> NSTextField {
        let field: NSTextField = secure ? NSSecureTextField(string: "") : NSTextField(string: "")
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 12.5)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    private func secureField(_ placeholder: String, width: CGFloat = 380) -> NSSecureTextField {
        let field = NSSecureTextField(string: "")
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 12.5)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    private func statusLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 380).isActive = true
        return label
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    private func integerPopup(_ values: [Int], suffix: String) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .small
        popup.addItems(withTitles: values.map { "\($0) \(suffix)" })
        return popup
    }

    // MARK: 模型

    private func buildModelTab() -> NSView {
        llmBaseURL = textField("https://api.deepseek.com")
        llmKey = secureField("sk-…")
        llmModel = textField("deepseek-flash")
        llmTemp = NSSlider(value: 0.85, minValue: 0, maxValue: 1.5, target: self, action: #selector(tempChanged))
        llmTemp.controlSize = .small
        llmTempValue = NSTextField(labelWithString: "0.85")
        llmTempValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let tempStack = NSStackView(views: [llmTemp, llmTempValue])
        tempStack.orientation = .horizontal
        tempStack.spacing = 8
        llmMaxTokens = textField("400", width: 100)

        llmStatus = statusLabel()
        let test = button("测试连接", #selector(testLLM))
        let hint = NSTextField(wrappingLabelWithString: """
        Base URL 填到 /v1 这一级，程序会自己拼 /chat/completions。
        只允许 https；本机地址（http://127.0.0.1:…）例外。API Key 保存在钥匙串。
        """)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.widthAnchor.constraint(equalToConstant: 380).isActive = true

        return form([
            row("Base URL", llmBaseURL),
            row("API Key", llmKey),
            row("模型", llmModel),
            row("温度", tempStack),
            row("最大 tokens", llmMaxTokens),
            test,
            llmStatus,
            hint
        ])
    }

    @objc private func tempChanged() {
        llmTempValue.stringValue = String(format: "%.2f", llmTemp.doubleValue)
    }

    @objc private func testLLM() {
        tester?.cancel()
        let base = llmBaseURL.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = llmModel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = llmKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !model.isEmpty, !key.isEmpty else {
            llmStatus.stringValue = "请先填写 Base URL、模型名和 API Key（灰字只是占位提示）"
            return
        }
        guard EndpointPolicy.isAllowed(base) else {
            llmStatus.stringValue = "Base URL 只允许 https（本机 http 例外）"
            return
        }
        llmStatus.stringValue = "正在测试…"
        let llm = ChatRequestConfig(baseURL: base, apiKey: key, model: model,
                                    temperature: 0.7, maxTokens: 256)
        let started = Date()
        tester = ChatClient.shared.complete(
            messages: [ChatMessage(role: "system", content: "你是连接测试。"),
                       ChatMessage(role: "user", content: "ping")],
            config: llm) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                    self.llmStatus.stringValue = "连接成功：\(model)（\(seconds)s）· 点「保存并关闭」才会生效"
                case .failure(let error):
                    let message = error.localizedDescription
                    self.llmStatus.stringValue = "失败：\(message)"
                    let alert = NSAlert()
                    alert.messageText = "测试连接失败"
                    alert.informativeText = """
                    \(message)

                    请求地址：\(ChatClient.endpoint(base, path: "/chat/completions")?.absoluteString ?? base)
                    模型：\(model)
                    """
                    alert.addButton(withTitle: "好")
                    alert.runModal()
                }
            }
        }
    }

    // MARK: 语音

    private func buildTTSTab() -> NSView {
        ttsEnabled = NSButton(checkboxWithTitle: "开启语音输出（回复时朗读）", target: nil, action: nil)
        ttsProvider = NSPopUpButton(frame: .zero, pullsDown: false)
        ttsProvider.controlSize = .small
        ttsProvider.addItems(withTitles: TTSProvider.allCases.map { $0.title })
        ttsProvider.target = self
        ttsProvider.action = #selector(ttsProviderChanged)

        ttsBaseURL = textField("https://api.siliconflow.cn/v1")
        ttsKey = secureField("sk-…（可留空）")
        ttsModel = textField("fnlp/tts-1")
        ttsVoice = textField("克隆得到的 voice ID")
        ttsSpeed = NSSlider(value: 1.0, minValue: 0.5, maxValue: 2.0, target: self, action: #selector(speedChanged))
        ttsSpeed.controlSize = .small
        ttsSpeedValue = NSTextField(labelWithString: "1.00")
        ttsSpeedValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let speedStack = NSStackView(views: [ttsSpeed, ttsSpeedValue])
        speedStack.orientation = .horizontal
        speedStack.spacing = 8

        ttsSystemVoice = NSPopUpButton(frame: .zero, pullsDown: false)
        ttsSystemVoice.controlSize = .small
        ttsSystemVoice.addItem(withTitle: "自动（中文）")
        for voice in AVSpeechSynthesisVoice.speechVoices()
            .filter({ $0.language.hasPrefix("zh") })
            .sorted(by: { $0.name < $1.name }) {
            ttsSystemVoice.addItem(withTitle: "\(voice.name) · \(voice.language)")
        }

        ttsStatus = statusLabel()
        let preview = button("试听", #selector(previewTTS))
        let export = button("导出音色样本…", #selector(exportVoiceSample))
        let guide = button("怎么得到阮·梅的音色？", #selector(showVoiceGuide))
        let hint = NSTextField(wrappingLabelWithString: """
        系统语音是离线的，但音色不是阮·梅。要用她的音色，需要把「导出的参考样本」上传到支持声音克隆的 TTS 服务
        （如 SiliconFlow CosyVoice、MiniMax、ElevenLabs），把克隆出来的 voice ID 填到上面。
        应用本身不内置声音克隆模型。
        """)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.widthAnchor.constraint(equalToConstant: 380).isActive = true

        let buttons = NSStackView(views: [preview, export, guide])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        return form([
            ttsEnabled,
            row("提供方", ttsProvider),
            row("Base URL", ttsBaseURL),
            row("API Key", ttsKey),
            row("模型", ttsModel),
            row("声音 ID", ttsVoice),
            row("语速", speedStack),
            row("系统语音", ttsSystemVoice),
            buttons,
            ttsStatus,
            hint
        ])
    }

    @objc private func speedChanged() {
        ttsSpeedValue.stringValue = String(format: "%.2f", ttsSpeed.doubleValue)
    }

    @objc private func ttsProviderChanged() {
        ttsStatus.stringValue = ttsProvider.indexOfSelectedItem == 0
            ? "系统语音：离线可用，音色不是阮·梅"
            : "OpenAI 兼容 TTS：需要 Base URL 和声音 ID"
    }

    private func currentTTSConfig() -> TTSConfig {
        var tts = TTSConfig()
        tts.enabled = ttsEnabled.state == .on
        tts.provider = ttsProvider.indexOfSelectedItem == 1 ? .openAICompatible : .system
        tts.baseURL = ttsBaseURL.stringValue
        tts.model = ttsModel.stringValue
        tts.voice = ttsVoice.stringValue
        tts.speed = ttsSpeed.doubleValue
        let index = ttsSystemVoice.indexOfSelectedItem
        tts.systemVoice = index > 0 ? Self.systemVoiceIdentifiers[safe: index - 1] ?? "" : ""
        return tts
    }

    @objc private func previewTTS() {
        let tts = currentTTSConfig()
        SpeechEngine.shared.transientAPIKey = ttsKey.stringValue
        SpeechEngine.shared.configure(tts)
        ttsStatus.stringValue = "试听：你好，我是阮·梅。"
        SpeechEngine.shared.enqueue("你好，我是阮·梅。茶还温着，慢慢说。")
    }

    @objc private func exportVoiceSample() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "RuanMei-voice-reference.m4a"
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            var urls: [URL] = []
            if let greet = self.effects.greetVoiceURL { urls.append(greet) }
            if let voice = self.effects.voiceURL { urls.append(voice) }
            if let move = self.effects.moveVoiceURL { urls.append(move) }
            urls.append(contentsOf: self.effects.clickVoiceURLs)
            VoiceSampleExporter.export(urls: urls, to: url) { result in
                switch result {
                case .success:
                    self.ttsStatus.stringValue = "已导出：\(url.lastPathComponent)（约 25 秒）"
                case .failure(let error):
                    self.ttsStatus.stringValue = "导出失败：\(error.localizedDescription)"
                }
            }
        }
    }

    @objc private func showVoiceGuide() {
        let alert = NSAlert()
        alert.messageText = "怎么得到阮·梅的音色"
        alert.informativeText = """
        1. 点「导出音色样本…」，会在你选的位置生成一段约 25 秒的阮·梅语音（内置语音包拼接、已去静音）。
        2. 打开一个支持「声音克隆 / voice clone」的 TTS 服务（SiliconFlow 的 CosyVoice、MiniMax、ElevenLabs 等），上传这段样本，创建你自己的音色。
        3. 把服务商给的 voice ID 填到「声音 ID」，Base URL 填服务的 OpenAI 兼容 TTS 地址（程序会拼 /audio/speech），模型按服务商文档填写。
        4. 点「试听」确认，再保存。

        应用不自带声音克隆模型：本机是 2.5 MB 的原生小应用，跑不动也装不下克隆模型；样本导出 + 第三方克隆是目前最稳的做法。
        不想用云服务时，可以在「提供方」里选「系统语音」，离线可用，只是音色不是她。
        """
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    private static let systemVoiceIdentifiers: [String] = AVSpeechSynthesisVoice.speechVoices()
        .filter { $0.language.hasPrefix("zh") }
        .sorted(by: { $0.name < $1.name })
        .map { $0.identifier }

    // MARK: 记忆

    private func buildMemoryTab() -> NSView {
        memoryEnabled = NSButton(checkboxWithTitle: "开启长期记忆（本地 SQLite）", target: nil, action: nil)
        memoryEvery = integerPopup([2, 4, 6, 8, 10], suffix: "轮对话整理一次")
        memoryInject = integerPopup([3, 4, 6, 8], suffix: "条相关记忆注入上下文")
        memoryHistory = integerPopup([6, 12, 20, 30], suffix: "条最近消息作为上下文")
        memorySummarize = integerPopup([8, 12, 16, 24], suffix: "条消息生成一次摘要")

        memoryStatus = statusLabel()
        let viewButton = button("查看 / 删除记忆", #selector(openMemoryList))
        let extractButton = button("立即整理", #selector(extractNow))
        let clearButton = button("清空记忆", #selector(clearMemories))

        let hint = NSTextField(wrappingLabelWithString: """
        记忆只存在本机：~/Library/Application Support/RuanMeiPet/pet.sqlite3。
        整理和摘要会用你配置的模型额外发一次请求（可关闭）。
        """)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.widthAnchor.constraint(equalToConstant: 380).isActive = true

        let buttons = NSStackView(views: [viewButton, extractButton, clearButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        return form([
            memoryEnabled,
            row("自动整理", memoryEvery),
            row("注入上限", memoryInject),
            row("上下文", memoryHistory),
            row("摘要", memorySummarize),
            buttons,
            memoryStatus,
            hint
        ])
    }

    @objc private func openMemoryList() {
        (NSApp.delegate as? AppDelegate)?.petController?.openMemoryList()
    }

    @objc private func extractNow() {
        (NSApp.delegate as? AppDelegate)?.petController?.extractMemoriesNow()
        memoryStatus.stringValue = "已请求整理，稍后可在记忆列表查看"
    }

    @objc private func clearMemories() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "清空全部记忆？"
        alert.informativeText = "这会删除所有记忆卡片，无法恢复。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.store?.clearMemories()
            self?.memoryStatus.stringValue = "记忆已清空"
            (NSApp.delegate as? AppDelegate)?.petController?.refreshMemoryWindow()
        }
    }

    // MARK: 人格

    private func buildPersonaTab() -> NSView {
        personaPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        personaPopup.controlSize = .small
        personaPopup.target = self
        personaPopup.action = #selector(personaSelectionChanged)
        personaPopup.translatesAutoresizingMaskIntoConstraints = false
        personaPopup.widthAnchor.constraint(equalToConstant: 380).isActive = true

        personaName = textField("名字")
        personaTagline = textField("一句话介绍")
        personaGreeting = textField("打开对话时说的第一句")

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 200))
        textView.font = .systemFont(ofSize: 12)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.minSize = NSSize(width: 0, height: 200)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        let promptScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 200))
        promptScroll.hasVerticalScroller = true
        promptScroll.borderType = .bezelBorder
        promptScroll.documentView = textView
        promptScroll.translatesAutoresizingMaskIntoConstraints = false
        promptScroll.widthAnchor.constraint(equalToConstant: 380).isActive = true
        promptScroll.heightAnchor.constraint(equalToConstant: 200).isActive = true
        personaPrompt = textView

        personaNewButton = button("新建", #selector(newPersona))
        personaCopyButton = button("复制为自定义", #selector(copyPersona))
        personaSaveButton = button("保存人格", #selector(savePersona))
        personaDeleteButton = button("删除", #selector(deletePersona))
        let buttons = NSStackView(views: [personaNewButton, personaCopyButton, personaSaveButton, personaDeleteButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        personaStatus = statusLabel()
        let hint = NSTextField(wrappingLabelWithString: """
        切换人格后，下一轮对话就会用新的系统 Prompt。内置人格只读，点「复制为自定义」可以改。
        建议把「称呼」和「回复长度」写进 Prompt，桌宠气泡装不下长回复。
        """)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.widthAnchor.constraint(equalToConstant: 380).isActive = true

        return form([
            row("人格", personaPopup),
            row("名字", personaName),
            row("介绍", personaTagline),
            row("打招呼", personaGreeting),
            row("系统 Prompt", promptScroll),
            buttons,
            personaStatus,
            hint
        ])
    }

    private func refreshPersonaPopup(selecting id: String?) {
        let personas = config.allPersonas
        personaPopup.removeAllItems()
        for persona in personas {
            personaPopup.addItem(withTitle: persona.builtIn ? "\(persona.name)（内置）" : persona.name)
        }
        if let id, let index = personas.firstIndex(where: { $0.id == id }) {
            personaPopup.selectItem(at: index)
        }
        loadPersonaFields()
    }

    private func loadPersonaFields() {
        let personas = config.allPersonas
        let index = personaPopup.indexOfSelectedItem
        guard personas.indices.contains(index) else { return }
        let persona = personas[index]
        editingPersonaID = persona.id
        personaName.stringValue = persona.name
        personaTagline.stringValue = persona.tagline
        personaGreeting.stringValue = persona.greeting
        personaPrompt.string = persona.systemPrompt
        let editable = !persona.builtIn
        personaName.isEnabled = editable
        personaTagline.isEnabled = editable
        personaGreeting.isEnabled = editable
        personaPrompt.isEditable = editable
        personaSaveButton.isEnabled = editable
        personaDeleteButton.isEnabled = editable
        personaStatus.stringValue = persona.builtIn ? "内置人格（只读）" : "自定义人格"
    }

    @objc private func personaSelectionChanged() { loadPersonaFields() }

    @objc private func newPersona() {
        var persona = PersonaLibrary.template
        persona.id = UUID().uuidString
        persona.name = "新人格 \(config.config.customPersonas.count + 1)"
        config.config.customPersonas.append(persona)
        config.save()
        refreshPersonaPopup(selecting: persona.id)
        personaStatus.stringValue = "已新建，改完记得「保存人格」"
        onSave?()
    }

    @objc private func copyPersona() {
        var persona = config.allPersonas[personaPopup.indexOfSelectedItem]
        persona.id = UUID().uuidString
        persona.name += "（副本）"
        persona.builtIn = false
        config.config.customPersonas.append(persona)
        config.save()
        refreshPersonaPopup(selecting: persona.id)
        personaStatus.stringValue = "已复制为自定义人格"
        onSave?()
    }

    @objc private func savePersona() {
        guard let index = config.config.customPersonas.firstIndex(where: { $0.id == editingPersonaID }) else { return }
        let name = personaName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = personaPrompt.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !prompt.isEmpty else {
            personaStatus.stringValue = "名字和系统 Prompt 不能为空"
            return
        }
        config.config.customPersonas[index].name = name
        config.config.customPersonas[index].tagline = personaTagline.stringValue
        config.config.customPersonas[index].greeting = personaGreeting.stringValue
        config.config.customPersonas[index].systemPrompt = prompt
        config.save()
        refreshPersonaPopup(selecting: editingPersonaID)
        personaStatus.stringValue = "已保存"
        onSave?()
    }

    @objc private func deletePersona() {
        guard let index = config.config.customPersonas.firstIndex(where: { $0.id == editingPersonaID }) else { return }
        let name = config.config.customPersonas[index].name
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "删除人格「\(name)」？"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.config.config.customPersonas.remove(at: index)
            if self.config.config.activePersonaID == self.editingPersonaID {
                self.config.config.activePersonaID = PersonaLibrary.defaultID
            }
            self.config.save()
            self.refreshPersonaPopup(selecting: self.config.config.activePersonaID)
            self.personaStatus.stringValue = "已删除"
            self.onSave?()
        }
    }

    // MARK: 读取 / 保存

    private func loadValues() {
        let llm = config.config.llm
        llmBaseURL.stringValue = llm.baseURL
        llmKey.stringValue = config.llmAPIKey
        llmModel.stringValue = llm.model
        llmTemp.doubleValue = llm.temperature
        llmTempValue.stringValue = String(format: "%.2f", llm.temperature)
        llmMaxTokens.stringValue = "\(llm.maxTokens)"

        let tts = config.config.tts
        ttsEnabled.state = tts.enabled ? .on : .off
        ttsProvider.selectItem(at: tts.provider == .openAICompatible ? 1 : 0)
        ttsBaseURL.stringValue = tts.baseURL
        ttsKey.stringValue = config.ttsAPIKey
        ttsModel.stringValue = tts.model
        ttsVoice.stringValue = tts.voice
        ttsSpeed.doubleValue = tts.speed
        ttsSpeedValue.stringValue = String(format: "%.2f", tts.speed)
        if let index = Self.systemVoiceIdentifiers.firstIndex(of: tts.systemVoice) {
            ttsSystemVoice.selectItem(at: index + 1)
        } else {
            ttsSystemVoice.selectItem(at: 0)
        }

        let memory = config.config.memory
        memoryEnabled.state = memory.enabled ? .on : .off
        selectPopup(memoryEvery, value: memory.autoExtractEvery, options: [2, 4, 6, 8, 10])
        selectPopup(memoryInject, value: memory.maxInjected, options: [3, 4, 6, 8])
        selectPopup(memoryHistory, value: memory.historyTurns, options: [6, 12, 20, 30])
        selectPopup(memorySummarize, value: memory.summarizeEvery, options: [8, 12, 16, 24])
        memoryStatus.stringValue = "已保存的记忆：\(store?.memoryCount() ?? 0) 条"

        refreshPersonaPopup(selecting: config.config.activePersonaID)
    }

    private func selectPopup(_ popup: NSPopUpButton, value: Int, options: [Int]) {
        if let index = options.firstIndex(of: value) {
            popup.selectItem(at: index)
        } else {
            popup.selectItem(at: 0)
        }
    }

    private func popupValue(_ popup: NSPopUpButton, options: [Int]) -> Int {
        let index = popup.indexOfSelectedItem
        return options.indices.contains(index) ? options[index] : options[0]
    }

    @objc private func saveAndClose() {
        let base = llmBaseURL.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty && !EndpointPolicy.isAllowed(base) {
            let alert = NSAlert()
            alert.messageText = "接口地址不允许"
            alert.informativeText = "只允许 https；本机地址（http://127.0.0.1 或 localhost）例外。"
            alert.runModal()
            return
        }

        config.config.llm.baseURL = base
        config.config.llm.model = llmModel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        config.config.llm.temperature = llmTemp.doubleValue
        config.config.llm.maxTokens = clamp(Int(llmMaxTokens.stringValue) ?? 400, 32, 4000)
        var keychainError: String?
        if let error = config.setLLMKey(llmKey.stringValue) { keychainError = error }

        config.config.tts = currentTTSConfig()
        if let error = config.setTTSKey(ttsKey.stringValue) { keychainError = keychainError ?? error }

        config.config.memory.enabled = memoryEnabled.state == .on
        config.config.memory.autoExtractEvery = popupValue(memoryEvery, options: [2, 4, 6, 8, 10])
        config.config.memory.maxInjected = popupValue(memoryInject, options: [3, 4, 6, 8])
        config.config.memory.historyTurns = popupValue(memoryHistory, options: [6, 12, 20, 30])
        config.config.memory.summarizeEvery = popupValue(memorySummarize, options: [8, 12, 16, 24])
        config.save()

        SpeechEngine.shared.configure(config.config.tts)
        SpeechEngine.shared.transientAPIKey = nil
        onSave?()

        if let keychainError {
            let alert = NSAlert()
            alert.messageText = "钥匙串写入失败"
            alert.informativeText = "\(keychainError)\n\nAPI Key 只会保留在本次运行中，重启后需要重新填写。其他设置已保存。"
            alert.runModal()
        }
        close()
    }

    @objc private func closeWindow() {
        close()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
