import AppKit

/// 记忆查看 / 删除窗口。
final class MemoryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: ChatStore?
    private var memories: [ChatStore.Memory] = []
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    var onExtract: (() -> Void)?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    init(store: ChatStore?) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "阮·梅 · 记忆"
        window.minSize = NSSize(width: 520, height: 360)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildUI()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let scroll = NSScrollView(frame: NSRect(x: 12, y: 56, width: 596, height: 452))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = table

        table.addTableColumn(column("kind", title: "类型", width: 58))
        table.addTableColumn(column("content", title: "内容", width: 300))
        table.addTableColumn(column("date", title: "更新时间", width: 116))
        table.addTableColumn(column("delete", title: "", width: 56))
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = NSTableHeaderView()
        table.rowHeight = 28
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        content.addSubview(scroll)

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 14, y: 20, width: 270, height: 18)
        status.autoresizingMask = [.maxYMargin]
        content.addSubview(status)

        let refresh = NSButton(title: "刷新", target: self, action: #selector(reloadAction))
        refresh.bezelStyle = .rounded
        refresh.controlSize = .small
        refresh.frame = NSRect(x: 300, y: 16, width: 64, height: 26)
        refresh.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(refresh)

        let extract = NSButton(title: "立即整理", target: self, action: #selector(extractAction))
        extract.bezelStyle = .rounded
        extract.controlSize = .small
        extract.frame = NSRect(x: 370, y: 16, width: 88, height: 26)
        extract.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(extract)

        let clear = NSButton(title: "清空全部", target: self, action: #selector(clearAction))
        clear.bezelStyle = .rounded
        clear.controlSize = .small
        clear.frame = NSRect(x: 464, y: 16, width: 84, height: 26)
        clear.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(clear)

        let close = NSButton(title: "关闭", target: self, action: #selector(closeAction))
        close.bezelStyle = .rounded
        close.controlSize = .small
        close.frame = NSRect(x: 554, y: 16, width: 54, height: 26)
        close.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(close)
    }

    private func column(_ id: String, title: String, width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.headerCell = NSTableHeaderCell(textCell: title)
        column.width = width
        return column
    }

    @objc func reloadAction() { reload() }

    func reload() {
        memories = store?.memories() ?? []
        table.reloadData()
        status.stringValue = "共 \(memories.count) 条记忆 · 只存在本机"
    }

    @objc private func extractAction() {
        onExtract?()
        status.stringValue = "已请求整理；有结果后点「刷新」"
    }

    @objc private func clearAction() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "清空全部记忆？"
        alert.informativeText = "所有记忆卡片都会被删除，无法恢复。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.store?.clearMemories()
            self?.reload()
        }
    }

    @objc private func closeAction() { close() }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { memories.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, memories.indices.contains(row) else { return nil }
        let memory = memories[row]
        switch tableColumn.identifier.rawValue {
        case "delete":
            let cell = (tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? MemoryDeleteCell) ?? {
                let cell = MemoryDeleteCell(frame: .zero)
                cell.identifier = tableColumn.identifier
                cell.button.target = self
                cell.button.action = #selector(deleteButton(_:))
                return cell
            }()
            cell.button.tag = row
            return cell
        case "kind":
            let cell = textCell(tableView, tableColumn)
            cell.label.stringValue = Self.kindName(memory.kind)
            cell.label.textColor = .secondaryLabelColor
            return cell
        case "date":
            let cell = textCell(tableView, tableColumn)
            cell.label.stringValue = Self.dateFormatter.string(from: memory.updatedAt)
            cell.label.textColor = .secondaryLabelColor
            return cell
        default:
            let cell = textCell(tableView, tableColumn)
            cell.label.stringValue = memory.content
            cell.label.textColor = .labelColor
            cell.toolTip = memory.content
            return cell
        }
    }

    private func textCell(_ tableView: NSTableView, _ column: NSTableColumn) -> MemoryTextCell {
        if let cell = tableView.makeView(withIdentifier: column.identifier, owner: self) as? MemoryTextCell {
            return cell
        }
        let cell = MemoryTextCell(frame: .zero)
        cell.identifier = column.identifier
        return cell
    }

    @objc private func deleteButton(_ sender: NSButton) {
        guard memories.indices.contains(sender.tag) else { return }
        store?.deleteMemory(id: memories[sender.tag].id)
        reload()
    }

    static func kindName(_ kind: String) -> String {
        switch kind {
        case "preference": return "偏好"
        case "preference_": return "偏好"
        case "fact": return "事实"
        case "plan": return "计划"
        case "relationship": return "关系"
        default: return kind
        }
    }
}

final class MemoryTextCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 12)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class MemoryDeleteCell: NSTableCellView {
    let button = NSButton(title: "删除", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.bezelStyle = .inline
        button.controlSize = .small
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
