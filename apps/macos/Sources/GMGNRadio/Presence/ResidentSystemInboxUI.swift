import AppKit

/// Envelope entry button with an unread badge, shared by the stage transport
/// row and the Live Cam control stack. Independent of the chat button; the
/// unread count is the shared inbox truth, never the background ACK state.
@MainActor
final class ResidentSystemMailBadgeButton: NSView {
    private let button: NSButton
    private let badge: NSTextField
    private var unreadCount = -1
    private var restingTint = NSColor.white.withAlphaComponent(0.72)
    private var handler: (@MainActor () -> Void)?

    init(identifier: String, toolTip: String = "系统消息",
         accessibilityLabel: String = "系统消息",
         action: @escaping @MainActor () -> Void = {}) {
        handler = action
        button = NSButton(frame: .zero)
        badge = NSTextField(labelWithString: "")
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        button.image = NSImage(systemSymbolName: "envelope", accessibilityDescription: accessibilityLabel)
        button.isBordered = false
        button.contentTintColor = .white.withAlphaComponent(0.72)
        button.target = self
        button.action = #selector(activate)
        button.toolTip = toolTip
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.9).cgColor
        badge.layer?.cornerRadius = 7
        badge.font = .systemFont(ofSize: 9, weight: .semibold)
        badge.textColor = .white
        badge.alignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)

        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 30),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            badge.leadingAnchor.constraint(equalTo: centerXAnchor, constant: 4),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 14),
            badge.heightAnchor.constraint(equalToConstant: 14),
        ])
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        setAccessibilityLabel(accessibilityLabel)
        setUnreadCount(0)
    }

    required init?(coder: NSCoder) { nil }

    func setAction(_ action: @escaping @MainActor () -> Void) {
        handler = action
    }

    func setIconStyle(pointSize: CGFloat, color: NSColor) {
        restingTint = color
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        button.contentTintColor = unreadCount > 0 ? .white : restingTint
    }

    func setUnreadCount(_ count: Int) {
        guard unreadCount != count else { return }
        unreadCount = count
        badge.stringValue = count > 99 ? "99+" : String(count)
        badge.isHidden = count == 0
        button.contentTintColor = count > 0 ? .white : restingTint
        setAccessibilityValue(count > 0 ? "\(count) 条未读" : "无未读")
        toolTip = count > 0 ? "系统消息（\(count) 条未读）" : "系统消息"
    }

    @objc private func activate() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        handler?()
    }
}

/// The standalone system message window: list + detail, restrained dark
/// native chrome. Selecting a row only shows its detail — a message becomes
/// read solely through an explicit open (double-click, the open button, or
/// return). User conversation lives elsewhere; this window carries only
/// system task deliveries.
@MainActor
final class ResidentSystemInboxWindowController: NSWindowController, NSTableViewDelegate, NSTableViewDataSource {
    struct Row: Identifiable {
        let id: String
        let eventID: String
        let title: String
        let status: String
        let detail: String
        let isRead: Bool
        let updatedAt: Date
    }

    var onOpenEntry: ((Row) -> Void)?
    private var rows: [Row] = []
    private let tableView = NSTableView()
    private let detailText = NSTextView()
    private let emptyLabel = NSTextField(labelWithString: "暂无系统消息")
    private let detailPlaceholder = NSTextField(labelWithString: "选择一条消息查看完整内容；双击或按“打开”标记为已读")
    private let openButton = NSButton(title: "打开", target: nil, action: nil)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "系统消息"
        window.appearance = NSAppearance(named: .darkAqua)
        window.identifier = NSUserInterfaceItemIdentifier("resident.system-inbox.window")
        window.isReleasedWhenClosed = false
        super.init(window: window)

        tableView.identifier = NSUserInterfaceItemIdentifier("resident.system-inbox.list")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.width = 280
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 44
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelected)
        tableView.style = .fullWidth
        tableView.setAccessibilityLabel("系统消息列表")
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        detailText.isEditable = false
        detailText.drawsBackground = false
        detailText.textContainerInset = NSSize(width: 12, height: 12)
        detailText.font = .systemFont(ofSize: 12)
        detailText.textColor = .white.withAlphaComponent(0.88)
        detailText.setAccessibilityLabel("消息详情")
        let detailScroll = NSScrollView()
        detailScroll.documentView = detailText
        detailScroll.hasVerticalScroller = true
        detailScroll.translatesAutoresizingMaskIntoConstraints = false

        openButton.target = self
        openButton.action = #selector(openSelected)
        openButton.keyEquivalent = "\r"
        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.setAccessibilityLabel("打开选中的系统消息")

        emptyLabel.textColor = .white.withAlphaComponent(0.45)
        detailPlaceholder.textColor = .white.withAlphaComponent(0.4)
        detailPlaceholder.font = .systemFont(ofSize: 11)

        let detailStack = NSStackView(views: [emptyLabel, detailPlaceholder, detailScroll, openButton])
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 8
        detailStack.translatesAutoresizingMaskIntoConstraints = false

        let split = NSSplitView(frame: .zero)
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(detailStack)
        split.translatesAutoresizingMaskIntoConstraints = false

        window.contentView?.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 10),
            split.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -10),
            split.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 10),
            split.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -10),
            scroll.widthAnchor.constraint(equalToConstant: 300),
            detailStack.trailingAnchor.constraint(equalTo: split.trailingAnchor, constant: -8),
            detailScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            detailScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])
        refreshEmptyStates()
    }

    required init?(coder: NSCoder) { nil }

    /// Pushes the latest projection. Selection is preserved by id and never
    /// marks anything read — reading happens only through the explicit open.
    func reload(_ updated: [Row]) {
        let selectedID = selectedRowID
        rows = updated
        tableView.reloadData()
        if let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
            detailText.string = ""
        }
        refreshEmptyStates()
    }

    private var selectedRowID: String? {
        tableView.selectedRow >= 0 && tableView.selectedRow < rows.count ? rows[tableView.selectedRow].id : nil
    }

    private func refreshEmptyStates() {
        emptyLabel.isHidden = !rows.isEmpty
        detailPlaceholder.isHidden = selectedRowID != nil
        openButton.isEnabled = selectedRowID != nil
    }

    @objc private func openSelected() {
        guard let id = selectedRowID, let row = rows.first(where: { $0.id == id }) else { return }
        onOpenEntry?(row)
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row rowIndex: Int) -> NSView? {
        let row = rows[rowIndex]
        let cell = NSTableCellView()
        let dot = NSTextField(labelWithString: row.isRead ? " " : "●")
        dot.textColor = .systemBlue
        dot.font = .systemFont(ofSize: 9)
        let title = NSTextField(labelWithString: row.title)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        let status = NSTextField(labelWithString: row.status)
        status.font = .systemFont(ofSize: 10)
        status.textColor = .white.withAlphaComponent(0.6)
        status.lineBreakMode = .byTruncatingTail
        let time = NSTextField(labelWithString: Self.timeText(row.updatedAt))
        time.font = .systemFont(ofSize: 10)
        time.textColor = .white.withAlphaComponent(0.45)
        for view in [dot, title, status, time] { view.translatesAutoresizingMaskIntoConstraints = false }
        cell.addSubview(dot)
        cell.addSubview(title)
        cell.addSubview(status)
        cell.addSubview(time)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            dot.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            title.trailingAnchor.constraint(lessThanOrEqualTo: time.leadingAnchor, constant: -6),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
            status.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            status.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            status.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            time.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            time.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        ])
        cell.setAccessibilityElement(true)
        cell.setAccessibilityLabel([row.title, row.status, row.isRead ? "已读" : "未读"].joined(separator: "，"))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard tableView.selectedRow >= 0, tableView.selectedRow < rows.count else { return }
        let row = rows[tableView.selectedRow]
        detailText.string = [row.title, row.status, row.updatedAt.formatted(date: .abbreviated, time: .shortened), "", row.detail]
            .joined(separator: "\n")
        refreshEmptyStates()
    }

    private static func timeText(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}
