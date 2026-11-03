import AppKit

/// 底部输入条：圆角容器 + 单行输入框 + 发送 / 停止按钮。
final class ChatInputView: NSView, NSTextFieldDelegate {
    var onSend: ((String) -> Void)?
    var onStop: (() -> Void)?

    private let container = NSView()
    private let field = NSTextField()
    private let button = NSButton()
    private(set) var isStreaming = false

    var text: String { field.stringValue }

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        container.wantsLayer = true
        container.layer?.cornerRadius = 19
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)

        field.translatesAutoresizingMaskIntoConstraints = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 13.5)
        field.placeholderString = "和阮·梅说点什么…"
        field.target = self
        field.action = #selector(sendTapped)
        field.delegate = self
        container.addSubview(field)

        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryChange)
        button.target = self
        button.action = #selector(buttonTapped)
        container.addSubview(button)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            container.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            field.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            field.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -8),

            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 30)
        ])

        updateButton()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func focus() {
        window?.makeFirstResponder(field)
    }

    func clear() {
        field.stringValue = ""
        updateButton()
    }

    func setStreaming(_ streaming: Bool) {
        isStreaming = streaming
        updateButton()
    }

    private func updateButton() {
        if isStreaming {
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "停止")
            button.contentTintColor = .systemRed
        } else {
            button.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "发送")
            let hasText = !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            button.contentTintColor = hasText ? NSColor(srgbRed: 0.29, green: 0.65, blue: 0.84, alpha: 1) : .tertiaryLabelColor
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        updateButton()
    }

    @objc private func buttonTapped() {
        if isStreaming {
            onStop?()
        } else {
            sendTapped()
        }
    }

    @objc private func sendTapped() {
        guard !isStreaming else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        onSend?(value)
    }
}
