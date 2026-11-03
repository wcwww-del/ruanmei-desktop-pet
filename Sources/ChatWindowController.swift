import AppKit

/// 对话窗口 + 流式对话编排（发送、朗读、落库、记忆整理）。
final class ChatWindowController: NSWindowController, NSWindowDelegate {

    // MARK: 依赖

    private let config = ConfigStore.shared
    private let store: ChatStore?
    private let client = ChatClient.shared
    private let speech = SpeechEngine.shared

    // MARK: 视图

    private let header = ChatHeaderView()
    private let scrollView = NSScrollView()
    private let transcript = ChatTranscriptView()
    private let input = ChatInputView()

    // MARK: 状态

    private var task: ChatTask?
    private var assistantBuffer = ""
    private var flushScheduled = false
    private var lastFlush: CFAbsoluteTime = 0
    private var streaming = false
    private var currentAssistantBubble: ChatBubbleView?
    private var sentenceStreamer = SentenceStreamer()
    private var extractInFlight = false
    private var summarizeInFlight = false
    private var didLoadHistory = false

    // MARK: 回调

    /// 回复结束时调用（用于桌宠气泡 / 语音之外的提示）。
    var onAssistantFinished: ((String) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenMemory: (() -> Void)?

    // MARK: 初始化

    init(store: ChatStore?, avatar: NSImage? = nil) {
        self.store = store
        let width = max(340, config.config.windowWidth)
        let height = max(420, config.config.windowHeight)
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered,
                             defer: false)
        window.title = "阮·梅 · 对话"
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 340, height: 420)
        window.setFrameAutosaveName("RuanMeiChat")
        super.init(window: window)
        window.delegate = self
        buildContent()
        transcript.avatarImage = avatar
        speech.configure(config.config.tts)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildContent() {
        guard let window, let content = window.contentView else { return }
        content.wantsLayer = true
        window.backgroundColor = .windowBackgroundColor

        header.translatesAutoresizingMaskIntoConstraints = false
        header.setPersonas(config.allPersonas, activeID: config.config.activePersonaID)
        header.setVoice(on: config.config.chatVoiceEnabled)
        header.onPersona = { [weak self] index in self?.selectPersona(index) }
        header.onVoice = { [weak self] in self?.toggleVoice() }
        header.onMemory = { [weak self] in self?.onOpenMemory?() }
        header.onSettings = { [weak self] in self?.onOpenSettings?() }
        header.onClear = { [weak self] in self?.confirmClear() }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = transcript
        transcript.frame = NSRect(x: 0, y: 0, width: max(300, window.frame.width), height: 80)

        input.translatesAutoresizingMaskIntoConstraints = false
        input.onSend = { [weak self] text in self?.send(text) }
        input.onStop = { [weak self] in self?.stop() }

        for view in [header, scrollView, input] { content.addSubview(view) }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 54),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: input.topAnchor),

            input.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            input.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            input.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            input.heightAnchor.constraint(equalToConstant: 64)
        ])
    }

    // MARK: 打开 / 关闭

    func open() {
        if !didLoadHistory {
            didLoadHistory = true
            loadHistory()
        }
        layoutTranscript()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        input.focus()
        if !config.llmReady() {
            header.statusLabel.stringValue = "还没配置模型 API · 点齿轮设置"
        } else if config.config.memory.enabled {
            header.statusLabel.stringValue = "记忆已开启（\(store?.memoryCount() ?? 0) 条）"
        } else {
            header.statusLabel.stringValue = "记忆已关闭"
        }
    }

    func windowDidResize(_ notification: Notification) {
        layoutTranscript()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if let frame = window?.frame {
            config.config.windowWidth = Double(frame.width)
            config.config.windowHeight = Double(frame.height)
            config.save()
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let frame = window?.frame {
            config.config.windowWidth = Double(frame.width)
            config.config.windowHeight = Double(frame.height)
            config.save()
        }
        speech.stop()
    }

    // MARK: 历史

    private func loadHistory() {
        transcript.reset()
        guard let store else {
            showNotice("对话数据库不可用，本次对话不会被记住。")
            return
        }
        let messages = store.recentMessages(limit: 40)
        if messages.isEmpty {
            transcript.append(role: .pet, text: config.activePersona.greeting)
        } else {
            for message in messages {
                transcript.append(role: message.role == "user" ? .user : .pet, text: message.content)
            }
        }
    }

    private func layoutTranscript() {
        guard let window else { return }
        let width = max(260, scrollView.contentView.bounds.width)
        if abs(transcript.frame.width - width) > 0.5 || transcript.frame.width <= 0 {
            transcript.frame = NSRect(x: 0, y: 0, width: width, height: transcript.frame.height)
            transcript.relayout()
        }
        if window.isVisible { scrollToBottom() }
    }

    private func scrollToBottom() {
        transcript.layoutSubtreeIfNeeded()
        let height = transcript.frame.height
        let clipHeight = scrollView.contentView.bounds.height
        let y = max(0, height - clipHeight)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: 发送

    func send(_ raw: String) {
        guard !streaming else { return }
        guard let store else {
            showNotice("对话数据库不可用，无法发送。")
            return
        }
        let text = PetSecurity.sanitizeChatText(raw)
        guard !text.isEmpty else { return }

        guard config.llmReady() else {
            showNotice("还没有配置模型 API。点右上角齿轮，填好 Base URL、模型名和 API Key。")
            onOpenSettings?()
            return
        }
        guard EndpointPolicy.isAllowed(config.config.llm.baseURL) else {
            showNotice("接口地址只允许 https（本机 http://127.0.0.1 例外）。")
            return
        }

        input.clear()
        transcript.append(role: .user, text: text)
        store.insertMessage(role: "user", content: text, persona: config.activePersona.id)
        layoutTranscript()

        assistantBuffer = ""
        sentenceStreamer = SentenceStreamer()
        sentenceStreamer.onSentence = { [weak self] sentence in
            guard let self, self.config.config.chatVoiceEnabled else { return }
            self.speech.enqueue(sentence)
        }
        speech.stop()
        currentAssistantBubble = transcript.append(role: .pet, text: "……")
        setStreaming(true)
        lastFlush = 0

        let history = store.recentMessages(limit: max(4, config.config.memory.historyTurns))
        let messages = buildMessages(userText: text, history: history, store: store)
        let llm = config.config.llm
        let requestConfig = ChatRequestConfig(baseURL: llm.baseURL,
                                             apiKey: config.llmAPIKey,
                                             model: llm.model,
                                             temperature: config.activePersona.temperature ?? llm.temperature,
                                             maxTokens: llm.maxTokens)

        task = client.stream(messages: messages,
                             config: requestConfig,
                             onDelta: { [weak self] delta in
                                 DispatchQueue.main.async { self?.handleDelta(delta) }
                             },
                             completion: { [weak self] result in
                                 DispatchQueue.main.async { self?.handleCompletion(result) }
                             })
    }

    private func buildMessages(userText: String, history: [ChatStore.Message],
                               store: ChatStore) -> [ChatMessage] {
        let persona = config.activePersona
        let memories = config.config.memory.enabled
            ? MemoryEngine.relevantMemories(from: store, query: userText, limit: config.config.memory.maxInjected)
            : []
        let summary = config.config.memory.enabled ? store.latestSummary()?.content : nil
        var messages = [ChatMessage(role: "system",
                                    content: MemoryEngine.systemPrompt(persona: persona,
                                                                       memories: memories,
                                                                       summary: summary))]
        for message in history.dropLast() {
            messages.append(ChatMessage(role: message.role, content: message.content))
        }
        messages.append(ChatMessage(role: "user", content: userText))
        return messages
    }

    private func handleDelta(_ delta: String) {
        assistantBuffer += delta
        sentenceStreamer.feed(delta)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        let delay = max(0, 0.05 - (CFAbsoluteTimeGetCurrent() - lastFlush))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        lastFlush = CFAbsoluteTimeGetCurrent()
        guard let bubble = currentAssistantBubble else { return }
        bubble.setText(assistantBuffer.isEmpty ? "……" : assistantBuffer)
        transcript.relayout()
        if window?.isVisible == true { scrollToBottom() }
    }

    private func handleCompletion(_ result: Result<String, Error>) {
        task = nil
        setStreaming(false)
        sentenceStreamer.flush()

        switch result {
        case .success(let text):
            assistantBuffer = text
            flush()
            store?.insertMessage(role: "assistant", content: text, persona: config.activePersona.id)
            header.statusLabel.stringValue = "已连接"
            onAssistantFinished?(text)
            maybeExtractMemories()
            maybeSummarize()
            store?.pruneMessages(keep: 600)
        case .failure(let error):
            if case ChatError.cancelled = error {
                if assistantBuffer.isEmpty {
                    transcript.removeLast()
                } else {
                    flush()
                    store?.insertMessage(role: "assistant", content: assistantBuffer,
                                         persona: config.activePersona.id)
                    onAssistantFinished?(assistantBuffer)
                }
                header.statusLabel.stringValue = "已停止"
            } else {
                let message = error.localizedDescription
                if assistantBuffer.isEmpty {
                    transcript.removeLast()
                    transcript.append(role: .notice, text: "出错了：\(message)")
                } else {
                    flush()
                    store?.insertMessage(role: "assistant", content: assistantBuffer,
                                         persona: config.activePersona.id)
                    transcript.append(role: .notice, text: "（连接中断：\(message)）")
                }
                header.statusLabel.stringValue = "连接失败"
            }
        }
        currentAssistantBubble = nil
        layoutTranscript()
    }

    func stop() {
        task?.cancel()
        speech.stop()
    }

    private func setStreaming(_ value: Bool) {
        streaming = value
        input.setStreaming(value)
        header.statusLabel.stringValue = value ? "正在输入…" : header.statusLabel.stringValue
    }

    // MARK: 记忆 / 摘要

    private func maybeExtractMemories() {
        extractMemories(force: false)
    }

    /// 手动「立即整理」（设置 / 记忆窗口）。
    func extractMemoriesNow() {
        extractMemories(force: true)
    }

    private func extractMemories(force: Bool) {
        guard config.config.memory.enabled, !extractInFlight,
              let store, config.llmReady() else { return }
        let every = max(2, config.config.memory.autoExtractEvery)
        if !force {
            guard store.userMessageCount() > 0, store.userMessageCount() % every == 0 else { return }
        }
        extractInFlight = true

        let recent = store.recentMessages(limit: 10)
        let existing = store.memories(limit: 60).map { $0.content }
        let prompt = MemoryEngine.extractionPrompt(
            conversation: MemoryEngine.conversationText(recent, personaName: config.activePersona.name),
            existing: existing)
        let llm = config.config.llm
        let requestConfig = ChatRequestConfig(baseURL: llm.baseURL, apiKey: config.llmAPIKey,
                                             model: llm.model, temperature: 0.2, maxTokens: 500)
        ChatClient.shared.complete(messages: [ChatMessage(role: "system", content: "你只输出 JSON 数组。"),
                                              ChatMessage(role: "user", content: prompt)],
                                   config: requestConfig) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.extractInFlight = false
                guard case .success(let text) = result else { return }
                let items = MemoryEngine.parseMemoryJSON(text)
                for item in items {
                    let keywords = MemoryEngine.tokens(item.content).prefix(24).joined(separator: " ")
                    _ = self.store?.upsertMemory(kind: item.kind, content: item.content, keywords: keywords)
                }
                if !items.isEmpty {
                    self.header.statusLabel.stringValue = "记住了 \(items.count) 件事"
                }
            }
        }
    }

    private func maybeSummarize() {
        guard config.config.memory.enabled, !summarizeInFlight,
              let store, config.llmReady() else { return }
        let every = max(6, config.config.memory.summarizeEvery)
        let count = store.messageCount()
        guard count > 0, count % every == 0 else { return }
        summarizeInFlight = true

        let recent = store.recentMessages(limit: 24)
        let prompt = MemoryEngine.summaryPrompt(
            conversation: MemoryEngine.conversationText(recent, personaName: config.activePersona.name))
        let llm = config.config.llm
        let requestConfig = ChatRequestConfig(baseURL: llm.baseURL, apiKey: config.llmAPIKey,
                                             model: llm.model, temperature: 0.3, maxTokens: 300)
        ChatClient.shared.complete(messages: [ChatMessage(role: "system", content: "你只输出一段简短的中文提要。"),
                                              ChatMessage(role: "user", content: prompt)],
                                   config: requestConfig) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.summarizeInFlight = false
                guard case .success(let text) = result else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                self.store?.insertSummary(content: trimmed, coversUntil: recent.last?.id ?? 0)
                self.store?.pruneSummaries(keep: 20)
            }
        }
    }

    // MARK: 头部动作

    private func selectPersona(_ index: Int) {
        let personas = config.allPersonas
        guard personas.indices.contains(index) else { return }
        let persona = personas[index]
        config.config.activePersonaID = persona.id
        config.save()
        header.setPersonas(personas, activeID: persona.id)
        window?.title = "阮·梅 · 对话"
        if transcript.bubbles.isEmpty {
            transcript.append(role: .pet, text: persona.greeting)
            layoutTranscript()
        }
        header.statusLabel.stringValue = "人格：\(persona.name)"
    }

    private func toggleVoice() {
        config.config.chatVoiceEnabled.toggle()
        header.setVoice(on: config.config.chatVoiceEnabled)
        config.save()
        if !config.config.chatVoiceEnabled {
            speech.stop()
            header.statusLabel.stringValue = "语音输出已关闭"
        } else {
            header.statusLabel.stringValue = "语音输出已开启"
            speech.enqueue("语音已经打开了。")
        }
    }

    private func confirmClear() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "清空当前对话？"
        alert.informativeText = "消息记录会被删除；记忆卡片和设置会保留。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.stop()
            self.store?.deleteAllMessages()
            self.transcript.reset()
            self.transcript.append(role: .pet, text: self.config.activePersona.greeting)
            self.layoutTranscript()
            self.header.statusLabel.stringValue = "对话已清空"
        }
    }

    // MARK: 提示

    private func showNotice(_ text: String) {
        transcript.append(role: .notice, text: text)
        layoutTranscript()
    }

    /// 设置保存后刷新语音配置与人格列表。
    func reloadConfig() {
        speech.configure(config.config.tts)
        header.setPersonas(config.allPersonas, activeID: config.config.activePersonaID)
        header.setVoice(on: config.config.chatVoiceEnabled)
        if let store {
            header.statusLabel.stringValue = config.config.memory.enabled
                ? "记忆已开启（\(store.memoryCount()) 条）"
                : "记忆已关闭"
        }
    }
}
