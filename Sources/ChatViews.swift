import AppKit

// MARK: - 气泡

final class ChatBubbleView: NSView {
    enum Role {
        case user
        case pet
        case notice

        var isUser: Bool { self == .user }
        var isNotice: Bool { self == .notice }
    }

    let role: Role
    private let textView = NSTextView()
    private var measuredWidth: CGFloat = 0
    private var measuredText: String = ""
    private var cachedTextSize: CGSize = .zero
    private(set) var text: String

    static let font = NSFont.systemFont(ofSize: 13.5)
    static let textInset = NSSize(width: 12, height: 8)
    static let avatarSize: CGFloat = 26
    static let avatarGap: CGFloat = 8
    static let sideInset: CGFloat = 14

    init(role: Role, text: String) {
        self.role = role
        self.text = text
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        switch role {
        case .user:
            layer?.backgroundColor = NSColor(srgbRed: 0.29, green: 0.65, blue: 0.84, alpha: 1).cgColor
            layer?.cornerRadius = 14
            textView.textColor = .white
        case .pet:
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.cornerRadius = 14
            textView.textColor = .labelColor
        case .notice:
            textView.textColor = .secondaryLabelColor
            textView.font = NSFont.systemFont(ofSize: 11.5)
        }

        // NSTextView 比 NSTextField 更可控：能精确按测量宽度换行、不裁字。
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.isRichText = false
        textView.font = role.isNotice ? NSFont.systemFont(ofSize: 11.5) : Self.font
        addSubview(textView)
        setText(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setText(_ value: String) {
        text = value
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2
        let attributes: [NSAttributedString.Key: Any] = [
            .font: (textView.font ?? Self.font) as Any,
            .foregroundColor: textView.textColor as Any,
            .paragraphStyle: paragraph
        ]
        textView.textStorage?.setAttributedString(NSAttributedString(string: value, attributes: attributes))
        measuredText = ""
    }

    func textSize(maxWidth: CGFloat) -> CGSize {
        if abs(measuredWidth - maxWidth) < 0.5, measuredText == text { return cachedTextSize }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: (textView.font ?? Self.font) as Any, .paragraphStyle: paragraph])
        let size = CGSize(width: ceil(rect.width), height: ceil(rect.height) + 1)
        measuredWidth = maxWidth
        measuredText = text
        cachedTextSize = size
        return size
    }

    var textViewFrame: NSRect {
        get { textView.frame }
        set { textView.frame = newValue }
    }

    var hasAvatar: Bool { role == .pet }

    override var isFlipped: Bool { true }
}

// MARK: - 对话记录

final class ChatTranscriptView: NSView {
    private(set) var bubbles: [ChatBubbleView] = []
    private var avatarViews: [NSImageView?] = []
    var avatarImage: NSImage?

    var onLayout: (() -> Void)?

    override var isFlipped: Bool { true }

    func reset() {
        for bubble in bubbles { bubble.removeFromSuperview() }
        for avatar in avatarViews { avatar?.removeFromSuperview() }
        bubbles.removeAll()
        avatarViews.removeAll()
        relayout()
    }

    @discardableResult
    func append(role: ChatBubbleView.Role, text: String) -> ChatBubbleView {
        let bubble = ChatBubbleView(role: role, text: text)
        addSubview(bubble)
        bubbles.append(bubble)

        if role == .pet, let image = avatarImage {
            let avatar = NSImageView()
            avatar.image = image
            avatar.imageScaling = .scaleProportionallyUpOrDown
            avatar.wantsLayer = true
            avatar.layer?.cornerRadius = ChatBubbleView.avatarSize / 2
            avatar.layer?.masksToBounds = true
            avatar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            addSubview(avatar)
            avatarViews.append(avatar)
        } else {
            avatarViews.append(nil)
        }
        relayout()
        return bubble
    }

    func updateLast(text: String) {
        guard let last = bubbles.last else { return }
        last.setText(text)
        relayout()
    }

    func removeLast() {
        bubbles.popLast()?.removeFromSuperview()
        if !avatarViews.isEmpty { avatarViews.removeLast()?.removeFromSuperview() }
        relayout()
    }

    /// 只重排，不重新测量没变化的文本（流式输出时很关键）。
    func relayout() {
        guard bounds.width > 10 else { return }
        let width = bounds.width
        let maxTextWidth = max(120, width - ChatBubbleView.sideInset * 2 - ChatBubbleView.avatarSize
                               - ChatBubbleView.avatarGap - ChatBubbleView.textInset.width * 2)
        var y: CGFloat = 10

        for (index, bubble) in bubbles.enumerated() {
            if index < avatarViews.count, let avatar = avatarViews[index] {
                avatar.frame = NSRect(x: ChatBubbleView.sideInset, y: y + 2,
                                      width: ChatBubbleView.avatarSize,
                                      height: ChatBubbleView.avatarSize)
            }
            if bubble.role.isNotice {
                let size = bubble.textSize(maxWidth: width - ChatBubbleView.sideInset * 2)
                let height = size.height + 4
                bubble.labelFrame = NSRect(x: ChatBubbleView.sideInset,
                                           y: y,
                                           width: width - ChatBubbleView.sideInset * 2,
                                           height: height)
                bubble.frame = NSRect(x: 0, y: y, width: width, height: height)
                y += height + 8
                continue
            }

            let size = bubble.textSize(maxWidth: maxTextWidth)
            let bubbleWidth = min(maxTextWidth, size.width) + ChatBubbleView.textInset.width * 2
            let bubbleHeight = size.height + ChatBubbleView.textInset.height * 2
            let left: CGFloat = bubble.role.isUser
                ? width - ChatBubbleView.sideInset - bubbleWidth
                : ChatBubbleView.sideInset + ChatBubbleView.avatarSize + ChatBubbleView.avatarGap
            bubble.frame = NSRect(x: left, y: y, width: bubbleWidth, height: bubbleHeight)
            bubble.labelFrame = NSRect(x: ChatBubbleView.textInset.width,
                                       y: ChatBubbleView.textInset.height,
                                       width: bubbleWidth - ChatBubbleView.textInset.width * 2,
                                       height: size.height)
            y += bubbleHeight + 10
        }

        let height = max(bounds.height, y + 6)
        if abs(frame.height - height) > 0.5 {
            frame = NSRect(x: 0, y: 0, width: width, height: height)
        }
        onLayout?()
    }

    override func layout() {
        super.layout()
        relayout()
    }
}

private extension ChatBubbleView {
    var labelFrame: NSRect {
        get { textViewFrame }
        set { textViewFrame = newValue }
    }
}

// MARK: - 头部

final class ChatHeaderView: NSView {
    let personaPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let statusLabel = NSTextField(labelWithString: "")
    let voiceButton = NSButton()
    let memoryButton = NSButton()
    let settingsButton = NSButton()
    let clearButton = NSButton()

    var onPersona: ((Int) -> Void)?
    var onVoice: (() -> Void)?
    var onMemory: (() -> Void)?
    var onSettings: (() -> Void)?
    var onClear: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        personaPopup.controlSize = .small
        personaPopup.font = NSFont.systemFont(ofSize: 12)
        personaPopup.target = self
        personaPopup.action = #selector(personaChanged)

        statusLabel.font = NSFont.systemFont(ofSize: 10.5)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        style(voiceButton, symbol: "speaker.wave.2.fill", tooltip: "语音输出")
        style(memoryButton, symbol: "brain", tooltip: "记忆")
        style(settingsButton, symbol: "gearshape", tooltip: "设置")
        style(clearButton, symbol: "square.and.pencil", tooltip: "清空对话")

        voiceButton.target = self
        voiceButton.action = #selector(voiceTapped)
        memoryButton.target = self
        memoryButton.action = #selector(memoryTapped)
        settingsButton.target = self
        settingsButton.action = #selector(settingsTapped)
        clearButton.target = self
        clearButton.action = #selector(clearTapped)

        for view in [personaPopup, voiceButton, memoryButton, settingsButton, clearButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        NSLayoutConstraint.activate([
            personaPopup.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            personaPopup.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            personaPopup.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.55),

            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            clearButton.centerYAnchor.constraint(equalTo: personaPopup.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 26),
            clearButton.heightAnchor.constraint(equalToConstant: 26),

            settingsButton.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -6),
            settingsButton.centerYAnchor.constraint(equalTo: clearButton.centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 26),
            settingsButton.heightAnchor.constraint(equalToConstant: 26),

            memoryButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -6),
            memoryButton.centerYAnchor.constraint(equalTo: clearButton.centerYAnchor),
            memoryButton.widthAnchor.constraint(equalToConstant: 26),
            memoryButton.heightAnchor.constraint(equalToConstant: 26),

            voiceButton.trailingAnchor.constraint(equalTo: memoryButton.leadingAnchor, constant: -6),
            voiceButton.centerYAnchor.constraint(equalTo: clearButton.centerYAnchor),
            voiceButton.widthAnchor.constraint(equalToConstant: 26),
            voiceButton.heightAnchor.constraint(equalToConstant: 26),

            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: voiceButton.leadingAnchor, constant: -8),
            statusLabel.topAnchor.constraint(equalTo: personaPopup.bottomAnchor, constant: 2),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func style(_ button: NSButton, symbol: String, tooltip: String) {
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.setButtonType(.momentaryChange)
    }

    func setPersonas(_ personas: [Persona], activeID: String) {
        personaPopup.removeAllItems()
        for persona in personas {
            personaPopup.addItem(withTitle: persona.name)
        }
        if let index = personas.firstIndex(where: { $0.id == activeID }) {
            personaPopup.selectItem(at: index)
        }
    }

    func setVoice(on: Bool) {
        voiceButton.image = NSImage(systemSymbolName: on ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                    accessibilityDescription: "语音输出")
        voiceButton.contentTintColor = on ? .labelColor : .tertiaryLabelColor
    }

    @objc private func personaChanged() { onPersona?(personaPopup.indexOfSelectedItem) }
    @objc private func voiceTapped() { onVoice?() }
    @objc private func memoryTapped() { onMemory?() }
    @objc private func settingsTapped() { onSettings?() }
    @objc private func clearTapped() { onClear?() }
}
