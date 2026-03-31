import AppKit
import ApplicationServices

private let userHomeDirectory = NSHomeDirectory()
private let autoRefreshInterval: TimeInterval = 3
private let requestPollInterval: TimeInterval = 0.5
private let stateDirectoryPath = "\(userHomeDirectory)/.codex-terminal-sender"
private let codexStateDatabasePath = "\(userHomeDirectory)/.codex/state_5.sqlite"
private let codexSessionIndexPath = "\(userHomeDirectory)/.codex/session_index.jsonl"
private let pendingRequestDirectoryPath = "\(stateDirectoryPath)/requests/pending"
private let processingRequestDirectoryPath = "\(stateDirectoryPath)/requests/processing"
private let resultRequestDirectoryPath = "\(stateDirectoryPath)/requests/results"
private let sessionProbeInitialBatchSize = 4
private let sessionProbeBatchSize = 12

private func resolvedHelperPath() -> String {
    if let override = ProcessInfo.processInfo.environment["CODEX_TASKMASTER_HELPER_PATH"],
       !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return override
    }

    if let bundled = Bundle.main.path(forResource: "codex_terminal_sender", ofType: "sh") {
        return bundled
    }

    let fallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("codex_terminal_sender.sh")
        .path
    return fallback
}

private enum DefaultsKey {
    static let target = "target"
    static let interval = "interval"
    static let message = "message"
    static let forceSend = "forceSend"
}

private func initialTargetValue() -> String {
    let saved = UserDefaults.standard.string(forKey: DefaultsKey.target)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if saved.isEmpty {
        return "test"
    }
    return saved
}

final class CodexBianCeZheApp: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = buildMainMenu()
        let controller = MainWindowController()
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.windowController = controller
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Codex Taskmaster", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        return mainMenu
    }
}

final class MainWindowController: NSWindowController {
    init() {
        let contentViewController = MainViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Taskmaster"
        window.minSize = NSSize(width: 760, height: 520)
        window.contentViewController = contentViewController
        super.init(window: window)
        shouldCascadeWindows = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class MainViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSplitViewDelegate, NSTextFieldDelegate {
    private let helperPath = resolvedHelperPath()

    private struct LoopSnapshot {
        let target: String
        let loopDaemonRunning: String
        let intervalSeconds: String
        let forceSend: String
        let message: String
        let nextRunEpoch: String
        let logPath: String
        let lastLogLine: String
    }

    private struct SessionSnapshot {
        let name: String
        let target: String
        let threadID: String
        let status: String
        let reason: String
        let terminalState: String
        let tty: String
        let updatedAtEpoch: String
        let rolloutPath: String
    }

    private let targetField = NSTextField(string: initialTargetValue())
    private let intervalField = NSTextField(string: UserDefaults.standard.string(forKey: DefaultsKey.interval) ?? "600")
    private let messageField = NSTextField(string: UserDefaults.standard.string(forKey: DefaultsKey.message) ?? "继续")
    private let forceSendCheckbox: NSButton = {
        let checkbox = NSButton(checkboxWithTitle: "强制发送（忽略 session 状态）", target: nil, action: nil)
        checkbox.state = UserDefaults.standard.bool(forKey: DefaultsKey.forceSend) ? .on : .off
        return checkbox
    }()
    private let activeLoopsTableView = NSTableView()
    private let activeLoopsScrollView = NSScrollView()
    private let sessionStatusTableView = NSTableView()
    private let sessionStatusScrollView = NSScrollView()
    private let renameField = NSTextField(string: "")
    private let sessionDetailView = NSTextView()
    private let sessionDetailScrollView = NSScrollView()
    private let topSplitView = NSSplitView()
    private let contentSplitView = NSSplitView()
    private let outputView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let activeLoopsMetaLabel = NSTextField(labelWithString: "No active loops.")
    private let sessionStatusMetaLabel = NSTextField(labelWithString: "点击“检测状态”加载 session 列表。")
    private var refreshTimer: Timer?
    private var requestTimer: Timer?
    private var isProcessingSendRequest = false
    private var loopSnapshots: [LoopSnapshot] = []
    private var sessionSnapshots: [SessionSnapshot] = []
    private var loopWarnings: [String] = []
    private var isSessionScanRunning = false
    private var sessionScanGeneration = 0
    private var sessionScanTotal = 0
    private var sessionScanShouldStop = false
    private var statusSegments: [String: String] = [:]
    private let defaultLoopSortKey = "nextRun"
    private let defaultSessionSortKey = "updatedAt"
    private var lastValidIntervalValue = "600"
    private var topSplitRatio: CGFloat = 0.5
    private var didApplyInitialTopSplitRatio = false
    private var lastTopSplitWidth: CGFloat = 0
    private var isApplyingTopSplitRatio = false
    private let sessionScanProcessLock = NSLock()
    private var currentSessionScanProcess: Process?
    private var sessionDetailLoadGeneration = 0

    private lazy var sendButton = makeButton(title: "发送一次", action: #selector(sendOnce))
    private lazy var startButton = makeButton(title: "开始循环", action: #selector(startLoop))
    private lazy var refreshLoopsButton = makeButton(title: "刷新循环", action: #selector(refreshLoopsAction))
    private lazy var detectStatusButton = makeButton(title: "检测状态", action: #selector(detectStatuses))
    private lazy var stopButton = makeButton(title: "停止当前", action: #selector(stopLoop))
    private lazy var stopAllButton = makeButton(title: "全部停止", action: #selector(stopAllLoops))
    private lazy var saveRenameButton = makeButton(title: "保存名称", action: #selector(saveSessionRename))
    private lazy var deleteSessionButton = makeButton(title: "删除 Session", action: #selector(deleteSelectedSession))

    override func loadView() {
        self.view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        normalizeInitialIntervalValue()
        updateDetectStatusButtonState()
        stopButton.isEnabled = false
        appendOutput("Codex Taskmaster is ready.")
        appendOutput("Active Loops will refresh automatically every \(Int(autoRefreshInterval)) seconds.")
        refreshLoopsSnapshot()
        startAutoRefresh()
        startRequestPump()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyInitialSplitRatiosIfNeeded()
        preserveTopSplitRatioOnResizeIfNeeded()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setTopSplitRatio(0.5)
            self.didApplyInitialTopSplitRatio = true
            self.lastTopSplitWidth = self.topSplitView.bounds.width
        }
    }

    deinit {
        refreshTimer?.invalidate()
        requestTimer?.invalidate()
    }

    private func buildUI() {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.spacing = 14
        rootStack.alignment = .leading
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])

        let titleLabel = NSTextField(labelWithString: "Codex Taskmaster")
        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)

        let subtitleLabel = NSTextField(wrappingLabelWithString: "配置 session、间隔和消息，然后向 Terminal 里的 Codex 发送输入。")
        subtitleLabel.textColor = .secondaryLabelColor

        let headerStack = NSStackView(views: [titleLabel, subtitleLabel])
        headerStack.orientation = .vertical
        headerStack.spacing = 6
        rootStack.addArrangedSubview(headerStack)
        headerStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        targetField.placeholderString = "例如 test 或具体 session id"
        intervalField.placeholderString = "秒，例如 600"
        messageField.placeholderString = "例如 继续"
        targetField.translatesAutoresizingMaskIntoConstraints = false
        intervalField.translatesAutoresizingMaskIntoConstraints = false
        messageField.translatesAutoresizingMaskIntoConstraints = false
        intervalField.delegate = self

        let formGrid = NSGridView(views: [
            [makeFieldLabel("Session 名称 / ID"), targetField],
            [makeFieldLabel("循环间隔(秒)"), intervalField],
            [makeFieldLabel("输出内容"), messageField],
            [makeFieldLabel("发送策略"), forceSendCheckbox]
        ])
        formGrid.rowSpacing = 12
        formGrid.columnSpacing = 14
        formGrid.xPlacement = .leading
        formGrid.yPlacement = .center
        formGrid.translatesAutoresizingMaskIntoConstraints = false
        formGrid.column(at: 0).width = 120
        rootStack.addArrangedSubview(formGrid)
        formGrid.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        targetField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true

        let buttonRow = NSStackView(views: [sendButton, startButton, refreshLoopsButton, detectStatusButton, stopButton, stopAllButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.alignment = .centerY
        rootStack.addArrangedSubview(buttonRow)
        buttonRow.widthAnchor.constraint(lessThanOrEqualTo: rootStack.widthAnchor).isActive = true

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        rootStack.addArrangedSubview(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        configureLoopsTable()
        activeLoopsScrollView.borderType = .bezelBorder
        activeLoopsScrollView.hasVerticalScroller = true
        activeLoopsScrollView.hasHorizontalScroller = true
        activeLoopsScrollView.autohidesScrollers = true
        activeLoopsScrollView.drawsBackground = true
        activeLoopsScrollView.translatesAutoresizingMaskIntoConstraints = false
        activeLoopsScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        configureSessionStatusTable()
        sessionStatusScrollView.borderType = .bezelBorder
        sessionStatusScrollView.hasVerticalScroller = true
        sessionStatusScrollView.hasHorizontalScroller = true
        sessionStatusScrollView.autohidesScrollers = true
        sessionStatusScrollView.drawsBackground = true
        sessionStatusScrollView.translatesAutoresizingMaskIntoConstraints = false
        sessionStatusScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        configureTextView(sessionDetailView, inset: NSSize(width: 10, height: 8))
        sessionDetailView.font = .systemFont(ofSize: 12)
        sessionDetailView.string = "选中一条 session 后，这里会显示完整信息和提示词历史。"

        renameField.placeholderString = "输入新名称，留空可恢复为未 rename 状态"
        renameField.translatesAutoresizingMaskIntoConstraints = false
        renameField.isEnabled = false
        saveRenameButton.isEnabled = false
        deleteSessionButton.isEnabled = false
        deleteSessionButton.contentTintColor = .systemRed

        let renameLabel = makeFieldLabel("Rename")
        let renameRow = NSStackView(views: [renameLabel, renameField, saveRenameButton, deleteSessionButton])
        renameRow.orientation = .horizontal
        renameRow.spacing = 8
        renameRow.alignment = .centerY
        renameLabel.setContentHuggingPriority(.required, for: .horizontal)
        saveRenameButton.setContentHuggingPriority(.required, for: .horizontal)
        deleteSessionButton.setContentHuggingPriority(.required, for: .horizontal)

        sessionDetailScrollView.borderType = .bezelBorder
        sessionDetailScrollView.hasVerticalScroller = true
        sessionDetailScrollView.hasHorizontalScroller = false
        sessionDetailScrollView.autohidesScrollers = true
        sessionDetailScrollView.drawsBackground = true
        sessionDetailScrollView.translatesAutoresizingMaskIntoConstraints = false
        sessionDetailScrollView.documentView = sessionDetailView
        sessionDetailScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true

        configureTextView(outputView, inset: NSSize(width: 10, height: 10))
        outputView.string = ""

        let outputScrollView = NSScrollView()
        outputScrollView.borderType = .bezelBorder
        outputScrollView.hasVerticalScroller = true
        outputScrollView.hasHorizontalScroller = false
        outputScrollView.autohidesScrollers = true
        outputScrollView.drawsBackground = true
        outputScrollView.translatesAutoresizingMaskIntoConstraints = false
        outputScrollView.documentView = outputView
        outputScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        let activeLoopsPanel = makePanel(title: "Active Loops", metaLabel: activeLoopsMetaLabel, contentView: activeLoopsScrollView)
        let sessionStatusContentStack = NSStackView(views: [sessionStatusScrollView, renameRow, sessionDetailScrollView])
        sessionStatusContentStack.orientation = .vertical
        sessionStatusContentStack.spacing = 8
        sessionStatusContentStack.alignment = .leading
        sessionStatusContentStack.translatesAutoresizingMaskIntoConstraints = false
        sessionStatusScrollView.widthAnchor.constraint(equalTo: sessionStatusContentStack.widthAnchor).isActive = true
        renameRow.widthAnchor.constraint(equalTo: sessionStatusContentStack.widthAnchor).isActive = true
        sessionDetailScrollView.widthAnchor.constraint(equalTo: sessionStatusContentStack.widthAnchor).isActive = true
        renameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        let sessionStatusPanel = makePanel(title: "Session Status", metaLabel: sessionStatusMetaLabel, contentView: sessionStatusContentStack)
        let logPanel = makePanel(title: "Activity Log", metaLabel: nil, contentView: outputScrollView)
        topSplitView.isVertical = true
        topSplitView.dividerStyle = .thin
        topSplitView.translatesAutoresizingMaskIntoConstraints = false
        topSplitView.delegate = self
        topSplitView.addArrangedSubview(activeLoopsPanel)
        topSplitView.addArrangedSubview(sessionStatusPanel)
        topSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        topSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        contentSplitView.isVertical = false
        contentSplitView.dividerStyle = .thin
        contentSplitView.translatesAutoresizingMaskIntoConstraints = false
        contentSplitView.addArrangedSubview(topSplitView)
        contentSplitView.addArrangedSubview(logPanel)
        contentSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        contentSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        rootStack.addArrangedSubview(contentSplitView)
        contentSplitView.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        contentSplitView.heightAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        contentSplitView.setContentHuggingPriority(.defaultLow, for: .vertical)
        contentSplitView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        logPanel.setContentHuggingPriority(.defaultLow, for: .vertical)
        logPanel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        outputScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        outputScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    private func configureTextView(_ textView: NSTextView, inset: NSSize) {
        textView.frame = NSRect(x: 0, y: 0, width: 700, height: 160)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = inset
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }

    private func configureLoopsTable() {
        let columns: [(identifier: String, title: String, width: CGFloat)] = [
            ("target", "Target", 140),
            ("interval", "Interval", 70),
            ("forceSend", "Mode", 80),
            ("nextRun", "Next Run", 140),
            ("message", "Message", 130),
            ("lastLog", "Last Result", 420)
        ]

        activeLoopsTableView.headerView = NSTableHeaderView()
        activeLoopsTableView.usesAlternatingRowBackgroundColors = true
        activeLoopsTableView.allowsEmptySelection = true
        activeLoopsTableView.allowsMultipleSelection = false
        activeLoopsTableView.delegate = self
        activeLoopsTableView.dataSource = self
        activeLoopsTableView.rowHeight = 24
        activeLoopsTableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        for column in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.identifier))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.identifier, ascending: column.identifier != defaultLoopSortKey)
            if column.identifier == "lastLog" {
                tableColumn.minWidth = 180
                tableColumn.resizingMask = .autoresizingMask
            } else {
                tableColumn.resizingMask = []
            }
            activeLoopsTableView.addTableColumn(tableColumn)
        }

        activeLoopsScrollView.documentView = activeLoopsTableView
        activeLoopsTableView.sortDescriptors = [NSSortDescriptor(key: defaultLoopSortKey, ascending: true)]
    }

    private func configureSessionStatusTable() {
        let columns: [(identifier: String, title: String, width: CGFloat)] = [
            ("name", "Name", 180),
            ("target", "Target", 180),
            ("threadID", "Session ID", 210),
            ("status", "Status", 150),
            ("terminalState", "Terminal", 110),
            ("tty", "TTY", 80),
            ("updatedAt", "Updated", 140),
            ("reason", "原因", 320)
        ]

        sessionStatusTableView.headerView = NSTableHeaderView()
        sessionStatusTableView.usesAlternatingRowBackgroundColors = true
        sessionStatusTableView.allowsEmptySelection = true
        sessionStatusTableView.allowsMultipleSelection = false
        sessionStatusTableView.delegate = self
        sessionStatusTableView.dataSource = self
        sessionStatusTableView.rowHeight = 24
        sessionStatusTableView.target = self
        sessionStatusTableView.doubleAction = #selector(handleSessionStatusDoubleClick)
        sessionStatusTableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        for column in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.identifier))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.identifier, ascending: column.identifier == defaultSessionSortKey ? false : true)
            if column.identifier == "reason" {
                tableColumn.minWidth = 220
                tableColumn.resizingMask = .autoresizingMask
            } else {
                tableColumn.resizingMask = []
            }
            sessionStatusTableView.addTableColumn(tableColumn)
        }

        sessionStatusScrollView.documentView = sessionStatusTableView
        sessionStatusTableView.sortDescriptors = [NSSortDescriptor(key: defaultSessionSortKey, ascending: false)]
    }

    private func preferredTargetValue(for session: SessionSnapshot) -> String {
        let candidate = session.target.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.isEmpty {
            return candidate
        }
        return session.threadID
    }

    private func sessionActualName(_ session: SessionSnapshot) -> String {
        session.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sessionEffectiveTarget(_ session: SessionSnapshot) -> String {
        let target = session.target.trimmingCharacters(in: .whitespacesAndNewlines)
        return target.isEmpty ? session.threadID : target
    }

    private func normalizeInitialIntervalValue() {
        let raw = currentInterval()
        if let intValue = Int(raw), intValue > 0 {
            let normalized = String(intValue)
            intervalField.stringValue = normalized
            lastValidIntervalValue = normalized
        } else {
            intervalField.stringValue = lastValidIntervalValue
        }
    }

    @discardableResult
    private func validateAndCommitIntervalField(showAlert: Bool) -> Bool {
        let raw = currentInterval()
        guard let intValue = Int(raw), intValue > 0 else {
            intervalField.stringValue = lastValidIntervalValue
            if showAlert {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "循环间隔无效"
                alert.informativeText = "循环间隔只能是正整数秒，已恢复为上一个合法值 \(lastValidIntervalValue)。"
                alert.addButton(withTitle: "确定")
                alert.runModal()
            }
            return false
        }

        let normalized = String(intValue)
        intervalField.stringValue = normalized
        lastValidIntervalValue = normalized
        return true
    }

    private func applyLoopSorting() {
        let descriptor = activeLoopsTableView.sortDescriptors.first ?? NSSortDescriptor(key: defaultLoopSortKey, ascending: true)
        let key = descriptor.key ?? defaultLoopSortKey
        let ascending = descriptor.ascending

        loopSnapshots.sort { lhs, rhs in
            let orderedAscending: Bool
            switch key {
            case "target":
                orderedAscending = lhs.target.localizedStandardCompare(rhs.target) == .orderedAscending
            case "interval":
                orderedAscending = (Int(lhs.intervalSeconds) ?? 0) < (Int(rhs.intervalSeconds) ?? 0)
            case "forceSend":
                orderedAscending = lhs.forceSend.localizedStandardCompare(rhs.forceSend) == .orderedAscending
            case "nextRun":
                orderedAscending = (TimeInterval(lhs.nextRunEpoch) ?? 0) < (TimeInterval(rhs.nextRunEpoch) ?? 0)
            case "message":
                orderedAscending = lhs.message.localizedStandardCompare(rhs.message) == .orderedAscending
            case "lastLog":
                orderedAscending = lhs.lastLogLine.localizedStandardCompare(rhs.lastLogLine) == .orderedAscending
            default:
                orderedAscending = lhs.target.localizedStandardCompare(rhs.target) == .orderedAscending
            }

            if compareLoopValuesEqual(lhs: lhs, rhs: rhs, key: key) {
                return lhs.target.localizedStandardCompare(rhs.target) == .orderedAscending
            }
            return ascending ? orderedAscending : !orderedAscending
        }
    }

    private func compareLoopValuesEqual(lhs: LoopSnapshot, rhs: LoopSnapshot, key: String) -> Bool {
        switch key {
        case "target":
            return lhs.target == rhs.target
        case "interval":
            return lhs.intervalSeconds == rhs.intervalSeconds
        case "forceSend":
            return lhs.forceSend == rhs.forceSend
        case "nextRun":
            return lhs.nextRunEpoch == rhs.nextRunEpoch
        case "message":
            return lhs.message == rhs.message
        case "lastLog":
            return lhs.lastLogLine == rhs.lastLogLine
        default:
            return lhs.target == rhs.target
        }
    }

    private func applySessionSorting() {
        let descriptor = sessionStatusTableView.sortDescriptors.first ?? NSSortDescriptor(key: defaultSessionSortKey, ascending: false)
        let key = descriptor.key ?? defaultSessionSortKey
        let ascending = descriptor.ascending

        sessionSnapshots.sort { lhs, rhs in
            let orderedAscending: Bool
            switch key {
            case "name":
                orderedAscending = sessionActualName(lhs).localizedStandardCompare(sessionActualName(rhs)) == .orderedAscending
            case "target":
                orderedAscending = sessionEffectiveTarget(lhs).localizedStandardCompare(sessionEffectiveTarget(rhs)) == .orderedAscending
            case "threadID":
                orderedAscending = lhs.threadID.localizedStandardCompare(rhs.threadID) == .orderedAscending
            case "status":
                orderedAscending = lhs.status.localizedStandardCompare(rhs.status) == .orderedAscending
            case "terminalState":
                orderedAscending = lhs.terminalState.localizedStandardCompare(rhs.terminalState) == .orderedAscending
            case "tty":
                orderedAscending = lhs.tty.localizedStandardCompare(rhs.tty) == .orderedAscending
            case "updatedAt":
                orderedAscending = (TimeInterval(lhs.updatedAtEpoch) ?? 0) < (TimeInterval(rhs.updatedAtEpoch) ?? 0)
            case "reason":
                orderedAscending = localizedSessionReason(lhs.reason).localizedStandardCompare(localizedSessionReason(rhs.reason)) == .orderedAscending
            default:
                orderedAscending = (TimeInterval(lhs.updatedAtEpoch) ?? 0) < (TimeInterval(rhs.updatedAtEpoch) ?? 0)
            }

            if compareSessionValuesEqual(lhs: lhs, rhs: rhs, key: key) {
                return lhs.threadID.localizedStandardCompare(rhs.threadID) == .orderedAscending
            }
            return ascending ? orderedAscending : !orderedAscending
        }
    }

    private func compareSessionValuesEqual(lhs: SessionSnapshot, rhs: SessionSnapshot, key: String) -> Bool {
        switch key {
        case "name":
            return sessionActualName(lhs) == sessionActualName(rhs)
        case "target":
            return sessionEffectiveTarget(lhs) == sessionEffectiveTarget(rhs)
        case "threadID":
            return lhs.threadID == rhs.threadID
        case "status":
            return lhs.status == rhs.status
        case "terminalState":
            return lhs.terminalState == rhs.terminalState
        case "tty":
            return lhs.tty == rhs.tty
        case "updatedAt":
            return lhs.updatedAtEpoch == rhs.updatedAtEpoch
        case "reason":
            return localizedSessionReason(lhs.reason) == localizedSessionReason(rhs.reason)
        default:
            return lhs.threadID == rhs.threadID
        }
    }

    private func sessionDetailText(for session: SessionSnapshot) -> String {
        let name = sessionActualName(session)
        return [
            "Target: \(sessionEffectiveTarget(session))",
            "Name: \(name.isEmpty ? "-" : name)",
            "Session ID: \(session.threadID)",
            "Status: \(session.status)",
            "Terminal: \(session.terminalState)",
            "TTY: \(session.tty.isEmpty ? "-" : session.tty)",
            "Updated: \(formatEpoch(session.updatedAtEpoch))",
            "原因: \(localizedSessionReason(session.reason))"
        ].joined(separator: "\n")
    }

    private func loadPromptHistoryText(for session: SessionSnapshot) -> String {
        guard !session.rolloutPath.isEmpty else {
            return "未找到 rollout 路径，无法读取提示词历史。"
        }

        let rolloutURL = URL(fileURLWithPath: session.rolloutPath)
        guard let data = try? Data(contentsOf: rolloutURL),
              let text = String(data: data, encoding: .utf8) else {
            return "读取 rollout 文件失败：\(session.rolloutPath)"
        }

        var entries: [(timestamp: String, message: String)] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let lineData = rawLine.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = object["type"] as? String,
                  type == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String,
                  payloadType == "user_message" else {
                continue
            }

            let timestamp = object["timestamp"] as? String ?? "-"
            let message = (payload["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty {
                entries.append((timestamp, message))
            }
        }

        guard !entries.isEmpty else {
            return "没有找到用户提示词历史。"
        }

        let recentEntries = entries.suffix(12)
        return recentEntries.enumerated().map { index, entry in
            "提示词 \(index + 1)\n时间: \(entry.timestamp)\n\(entry.message)"
        }.joined(separator: "\n\n")
    }

    private func updateSessionDetailView() {
        let selectedRow = sessionStatusTableView.selectedRow
        guard selectedRow >= 0, selectedRow < sessionSnapshots.count else {
            renameField.stringValue = ""
            renameField.isEnabled = false
            saveRenameButton.isEnabled = false
            deleteSessionButton.isEnabled = false
            sessionDetailView.string = "选中一条 session 后，这里会显示完整信息和提示词历史。"
            sessionDetailView.scrollToBeginningOfDocument(nil)
            return
        }

        let session = sessionSnapshots[selectedRow]
        renameField.stringValue = session.name
        renameField.isEnabled = true
        saveRenameButton.isEnabled = true
        deleteSessionButton.isEnabled = true
        sessionDetailView.string = "\(sessionDetailText(for: session))\n\n提示词历史加载中…"
        sessionDetailView.scrollToBeginningOfDocument(nil)

        sessionDetailLoadGeneration += 1
        let generation = sessionDetailLoadGeneration
        let threadID = session.threadID

        DispatchQueue.global(qos: .utility).async {
            let historyText = self.loadPromptHistoryText(for: session)
            let detailText = "\(self.sessionDetailText(for: session))\n\n提示词历史\n\(historyText)"

            DispatchQueue.main.async {
                guard self.sessionDetailLoadGeneration == generation else { return }
                guard self.sessionStatusTableView.selectedRow >= 0, self.sessionStatusTableView.selectedRow < self.sessionSnapshots.count else { return }
                guard self.sessionSnapshots[self.sessionStatusTableView.selectedRow].threadID == threadID else { return }
                self.sessionDetailView.string = detailText
                self.sessionDetailView.scrollToBeginningOfDocument(nil)
            }
        }
    }

    private func updateSessionName(threadID: String, newName: String) -> (success: Bool, error: String) {
        if newName.isEmpty {
            return clearSessionName(threadID: threadID)
        }
        let result = runStandardHelper(arguments: ["thread-name-set", "-t", threadID, "-n", newName])
        if result.status == 0 {
            return (true, "")
        }
        let detail = [result.stderr, result.stdout].first { !$0.isEmpty } ?? "重命名失败"
        return (false, detail)
    }

    private func clearSessionName(threadID: String) -> (success: Bool, error: String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            """
import json, os, sqlite3, sys, time
db_path, session_index_path, thread_id = sys.argv[1:]

entries = []
if os.path.exists(session_index_path):
    with open(session_index_path, "r", encoding="utf-8") as fh:
        for raw_line in fh:
            raw_line = raw_line.strip()
            if not raw_line:
                continue
            try:
                obj = json.loads(raw_line)
            except json.JSONDecodeError:
                continue
            if obj.get("id") == thread_id:
                continue
            entries.append(obj)

os.makedirs(os.path.dirname(session_index_path), exist_ok=True)
tmp_index_path = session_index_path + ".tmp"
with open(tmp_index_path, "w", encoding="utf-8") as fh:
    for entry in entries:
        fh.write(json.dumps(entry, ensure_ascii=False) + "\\n")
os.replace(tmp_index_path, session_index_path)

conn = sqlite3.connect(db_path)
cur = conn.cursor()
cur.execute(
    "update threads set updated_at = ? where id = ?",
    (int(time.time()), thread_id),
)
if cur.rowcount != 1:
    raise SystemExit("session not found")
conn.commit()
conn.close()
""",
            codexStateDatabasePath,
            codexSessionIndexPath,
            threadID
        ]
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (false, "启动清空名称失败: \(error.localizedDescription)")
        }

        let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if process.terminationStatus != 0 {
            return (false, errText.isEmpty ? "清空名称失败" : errText)
        }

        return (true, "")
    }

    private func archiveSession(threadID: String) -> (success: Bool, error: String) {
        let result = runStandardHelper(arguments: ["thread-archive", "-t", threadID])
        if result.status == 0 {
            return (true, "")
        }
        let detail = [result.stderr, result.stdout].first { !$0.isEmpty } ?? "删除 session 失败"
        return (false, detail)
    }

    private func selectSessionRow(threadID: String) {
        guard let row = sessionSnapshots.firstIndex(where: { $0.threadID == threadID }) else { return }
        sessionStatusTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        sessionStatusTableView.scrollRowToVisible(row)
    }

    private func applyInitialSplitRatiosIfNeeded() {
        guard !didApplyInitialTopSplitRatio else { return }
        guard topSplitView.subviews.count == 2 else { return }
        guard topSplitView.bounds.width > topSplitView.dividerThickness else { return }
        setTopSplitRatio(0.5)
        didApplyInitialTopSplitRatio = true
        lastTopSplitWidth = topSplitView.bounds.width
    }

    private func preserveTopSplitRatioOnResizeIfNeeded() {
        guard topSplitView.subviews.count == 2 else { return }
        let currentWidth = topSplitView.bounds.width
        guard currentWidth > topSplitView.dividerThickness else { return }

        defer { lastTopSplitWidth = currentWidth }

        guard didApplyInitialTopSplitRatio else { return }
        guard abs(currentWidth - lastTopSplitWidth) > 0.5 else { return }
        setTopSplitRatio(topSplitRatio)
    }

    private func setTopSplitRatio(_ ratio: CGFloat) {
        guard topSplitView.subviews.count == 2 else { return }
        let availableWidth = topSplitView.bounds.width - topSplitView.dividerThickness
        guard availableWidth > 0 else { return }

        let clampedRatio = min(max(ratio, 0.2), 0.8)
        isApplyingTopSplitRatio = true
        topSplitView.setPosition(availableWidth * clampedRatio, ofDividerAt: 0)
        topSplitRatio = clampedRatio
        isApplyingTopSplitRatio = false
    }

    private func updateTopSplitRatioFromCurrentLayout() {
        guard !isApplyingTopSplitRatio else { return }
        guard didApplyInitialTopSplitRatio else { return }
        guard topSplitView.subviews.count == 2 else { return }
        let availableWidth = topSplitView.bounds.width - topSplitView.dividerThickness
        guard availableWidth > 0 else { return }
        let currentLeadingWidth = topSplitView.subviews[0].frame.width
        topSplitRatio = min(max(currentLeadingWidth / availableWidth, 0.2), 0.8)
    }

    private func localizedSessionReason(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let exactMappings: [String: String] = [
            "insufficient local events": "本地事件不足，暂时无法可靠判断状态",
            "last completed turn is newer than the last started turn": "最近一次完成回合晚于最近一次开始回合，当前看起来已空闲",
            "a started turn has no later task_complete": "检测到已开始的回合，但后面没有看到 task_complete，当前可能仍在执行",
            "final answer emitted but task_complete not seen yet": "已经看到最终回答，但还没有看到 task_complete，可能仍在收尾",
            "open turn with a recent interrupt log": "当前回合未闭合，且最近有中断日志",
            "open turn with recent stream disconnect warnings": "当前回合未闭合，且最近有流断开告警",
            "a newer turn_aborted event is present and terminal is ready again": "检测到更新的 turn_aborted，且 Terminal 已恢复到可输入状态",
            "a newer turn_aborted event is present": "检测到更新的 turn_aborted 事件",
            "turn is complete, but terminal still shows unsent input": "回合已完成，但 Terminal 输入框里仍残留未发送内容",
            "turn is complete, but queued messages are still visible in Terminal": "回合已完成，但 Terminal 里仍能看到排队中的消息",
            "terminal is back at a ready prompt while rollout still looks open": "Terminal 已回到可输入提示，但 rollout 记录看起来仍未闭合",
            "terminal is ready and a fresh interrupt log was recorded": "Terminal 已恢复可输入，且最近记录到新的中断日志",
            "tty not found": "未找到对应的终端 TTY",
            "prompt/footer not visible in terminal tail": "终端尾部没有看到明确的提示符或底栏",
            "queued messages are visible in the terminal tail": "终端尾部能看到排队中的消息",
            "placeholder prompt and model footer are visible": "终端中能看到占位提示符和模型底栏",
            "prompt line and model footer are visible with non-placeholder input": "终端中能看到带实际输入内容的提示符和模型底栏",
            "model footer is visible without a clear prompt line": "只能看到模型底栏，没有看到清晰的提示符行"
        ]

        if let mapped = exactMappings[trimmed] {
            return mapped
        }
        if trimmed.hasPrefix("osascript failed:") {
            let prefix = "osascript failed:"
            let detail = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return "读取 Terminal 状态失败: \(detail)"
        }
        return trimmed
    }

    private func makePanel(title: String, metaLabel: NSTextField?, contentView: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let headerViews = [titleLabel, metaLabel].compactMap { $0 }
        let headerStack = NSStackView(views: headerViews)
        headerStack.orientation = .vertical
        headerStack.spacing = 2
        headerStack.alignment = .leading

        metaLabel?.font = .systemFont(ofSize: 11, weight: .regular)
        metaLabel?.textColor = .secondaryLabelColor
        metaLabel?.lineBreakMode = .byTruncatingTail

        let panelStack = NSStackView(views: [headerStack, contentView])
        panelStack.orientation = .vertical
        panelStack.spacing = 8
        panelStack.alignment = .leading
        panelStack.translatesAutoresizingMaskIntoConstraints = false
        panelStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        panelStack.setContentHuggingPriority(.defaultLow, for: .vertical)
        panelStack.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        headerStack.widthAnchor.constraint(equalTo: panelStack.widthAnchor).isActive = true
        contentView.widthAnchor.constraint(equalTo: panelStack.widthAnchor).isActive = true

        return panelStack
    }

    private func makeFieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func persistDefaults() {
        UserDefaults.standard.set(targetField.stringValue, forKey: DefaultsKey.target)
        UserDefaults.standard.set(intervalField.stringValue, forKey: DefaultsKey.interval)
        UserDefaults.standard.set(messageField.stringValue, forKey: DefaultsKey.message)
        UserDefaults.standard.set(forceSendCheckbox.state == .on, forKey: DefaultsKey.forceSend)
    }

    private func currentTarget() -> String {
        targetField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func currentMessage() -> String {
        messageField.stringValue
    }

    private func currentInterval() -> String {
        intervalField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isForceSendEnabled() -> Bool {
        forceSendCheckbox.state == .on
    }

    private func setButtonsEnabled(_ enabled: Bool) {
        [sendButton, startButton, refreshLoopsButton, stopAllButton].forEach { $0.isEnabled = enabled }
        detectStatusButton.isEnabled = enabled || isSessionScanRunning
        stopButton.isEnabled = enabled && activeLoopsTableView.selectedRow >= 0
    }

    private func updateDetectStatusButtonState() {
        detectStatusButton.title = isSessionScanRunning ? "停止检测" : "检测状态"
        detectStatusButton.isEnabled = true
    }

    private func appendOutput(_ text: String) {
        let prefix = Self.timestampFormatter.string(from: Date())
        let normalized = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : "  \($0)" }
            .joined(separator: "\n")
        let line = "[\(prefix)]\n\(normalized)\n\n"
        outputView.string.append(line)
        outputView.needsDisplay = true
        outputView.scrollToEndOfDocument(nil)
    }

    private func setStatus(_ text: String, key: String = "general") {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            statusSegments.removeValue(forKey: key)
        } else {
            statusSegments[key] = trimmed
        }

        let orderedKeys = ["scan", "action", "general"]
        let orderedTexts = orderedKeys.compactMap { statusSegments[$0] }
        let fallbackTexts = statusSegments
            .filter { !orderedKeys.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map(\.value)
        let allTexts = orderedTexts + fallbackTexts
        statusLabel.stringValue = allTexts.isEmpty ? "Ready" : allTexts.joined(separator: " | ")
    }

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: autoRefreshInterval, repeats: true) { [weak self] _ in
            self?.refreshLoopsSnapshot()
        }
        if let refreshTimer {
            RunLoop.main.add(refreshTimer, forMode: .common)
        }
    }

    private func startRequestPump() {
        requestTimer?.invalidate()
        requestTimer = Timer.scheduledTimer(withTimeInterval: requestPollInterval, repeats: true) { [weak self] _ in
            self?.processPendingSendRequests()
        }
        if let requestTimer {
            RunLoop.main.add(requestTimer, forMode: .common)
        }
    }

    private func processPendingSendRequests() {
        guard !isProcessingSendRequest else { return }

        let pendingDirectoryURL = URL(fileURLWithPath: pendingRequestDirectoryPath, isDirectory: true)
        let processingDirectoryURL = URL(fileURLWithPath: processingRequestDirectoryPath, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: pendingDirectoryURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: processingDirectoryURL, withIntermediateDirectories: true)
        } catch {
            return
        }

        guard let nextRequestURL = (try? FileManager.default.contentsOfDirectory(
            at: pendingDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ))?
            .filter({ $0.pathExtension == "json" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .first else {
            return
        }

        let processingURL = processingDirectoryURL.appendingPathComponent(nextRequestURL.lastPathComponent)

        do {
            if FileManager.default.fileExists(atPath: processingURL.path) {
                try FileManager.default.removeItem(at: processingURL)
            }
            try FileManager.default.moveItem(at: nextRequestURL, to: processingURL)
        } catch {
            return
        }

        isProcessingSendRequest = true
        DispatchQueue.global(qos: .userInitiated).async {
            self.handleQueuedSendRequest(at: processingURL)
        }
    }

    private func parseStatusOutput(_ output: String) -> [LoopSnapshot] {
        var loops: [LoopSnapshot] = []
        var current: [String: String] = [:]

        func flushCurrent() {
            guard let target = current["target"] else {
                current.removeAll()
                return
            }
            loops.append(
                LoopSnapshot(
                    target: target,
                    loopDaemonRunning: current["loop_daemon_running"] ?? "unknown",
                    intervalSeconds: current["interval_seconds"] ?? "unknown",
                    forceSend: current["force_send"] ?? "no",
                    message: current["message"] ?? "unknown",
                    nextRunEpoch: current["next_run_epoch"] ?? "unknown",
                    logPath: current["log"] ?? "-",
                    lastLogLine: current["last_log_line"] ?? ""
                )
            )
            current.removeAll()
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                continue
            }
            if line == "---" {
                flushCurrent()
                continue
            }
            if line == "no active loops" {
                continue
            }
            if let range = line.range(of: ": ") {
                let key = String(line[..<range.lowerBound])
                let value = String(line[range.upperBound...])
                current[key] = value
            }
        }

        flushCurrent()
        return loops
    }

    private func parseWarnings(from output: String) -> [String] {
        output.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("warning: ") else { return nil }
            return line
        }
    }

    private func parseProbeAllOutput(_ output: String) -> [SessionSnapshot] {
        var sessions: [SessionSnapshot] = []
        var current: [String: String] = [:]

        func flushCurrent() {
            guard let threadID = current["thread_id"] else {
                current.removeAll()
                return
            }
            sessions.append(
                SessionSnapshot(
                    name: current["name"] ?? "",
                    target: current["target"] ?? threadID,
                    threadID: threadID,
                    status: current["status"] ?? "unknown",
                    reason: current["reason"] ?? "",
                    terminalState: current["terminal_state"] ?? "unavailable",
                    tty: current["tty"] ?? "",
                    updatedAtEpoch: current["updated_at_epoch"] ?? "0",
                    rolloutPath: current["rollout_path"] ?? ""
                )
            )
            current.removeAll()
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                continue
            }
            if line == "---" {
                flushCurrent()
                continue
            }
            if let range = line.range(of: ": ") {
                let key = String(line[..<range.lowerBound])
                let value = String(line[range.upperBound...])
                current[key] = value
            }
        }

        flushCurrent()
        return sessions
    }

    private func parseSessionCountOutput(_ output: String) -> Int? {
        Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func formatEpoch(_ rawValue: String) -> String {
        guard let epoch = TimeInterval(rawValue) else { return rawValue }
        return Self.loopTimeFormatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    private func mergeSessionSnapshots(_ newSnapshots: [SessionSnapshot]) {
        guard !newSnapshots.isEmpty else { return }

        var mergedByID: [String: SessionSnapshot] = [:]
        for snapshot in sessionSnapshots {
            mergedByID[snapshot.threadID] = snapshot
        }
        for snapshot in newSnapshots {
            mergedByID[snapshot.threadID] = snapshot
        }

        sessionSnapshots = mergedByID.values.sorted { lhs, rhs in
            let lhsEpoch = TimeInterval(lhs.updatedAtEpoch) ?? 0
            let rhsEpoch = TimeInterval(rhs.updatedAtEpoch) ?? 0
            if lhsEpoch == rhsEpoch {
                return lhs.threadID < rhs.threadID
            }
            return lhsEpoch > rhsEpoch
        }
    }

    private func renderSessionSnapshots(scannedCount: Int? = nil, totalCount: Int? = nil, isComplete: Bool = true) {
        if sessionSnapshots.isEmpty {
            if isSessionScanRunning, let scannedCount, let totalCount {
                sessionStatusMetaLabel.stringValue = "正在扫描 \(scannedCount)/\(totalCount)…"
            } else {
                sessionStatusMetaLabel.stringValue = "未加载 session 状态。点击“检测状态”开始扫描。"
            }
            sessionStatusTableView.reloadData()
            updateSessionDetailView()
            return
        }

        let refreshedAt = Self.timestampFormatter.string(from: Date())
        if let scannedCount, let totalCount {
            let progressText = isComplete ? "已扫描: \(scannedCount)/\(totalCount)" : "扫描中: \(scannedCount)/\(totalCount)"
            sessionStatusMetaLabel.stringValue = "已加载: \(sessionSnapshots.count) | \(progressText) | 总数: \(totalCount) | 刷新: \(refreshedAt)"
        } else {
            sessionStatusMetaLabel.stringValue = "已加载: \(sessionSnapshots.count) | 刷新: \(refreshedAt)"
        }
        applySessionSorting()
        sessionStatusTableView.reloadData()
        if sessionStatusTableView.selectedRow >= sessionSnapshots.count {
            sessionStatusTableView.deselectAll(nil)
        }
        updateSessionDetailView()
    }

    private func validateTarget(required: Bool = true) -> String? {
        let value = currentTarget()
        if required && value.isEmpty {
            appendOutput("缺少 Session 名称 / ID。")
            setStatus("请填写 Session 名称 / ID")
            NSSound.beep()
            return nil
        }
        return value
    }

    private func validateInterval() -> String? {
        guard validateAndCommitIntervalField(showAlert: true) else {
            appendOutput("循环间隔必须是正整数秒。")
            setStatus("循环间隔无效")
            NSSound.beep()
            return nil
        }
        return currentInterval()
    }

    private func parseProbeOutput(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard let range = line.range(of: ": ") else { continue }
            let key = String(line[..<range.lowerBound])
            let value = String(line[range.upperBound...])
            result[key] = value
        }
        return result
    }

    private func probeResult(for target: String) -> (status: Int32, values: [String: String], stdout: String, stderr: String) {
        let result = runStandardHelper(arguments: ["probe", "-t", target])
        return (result.status, parseProbeOutput(result.stdout), result.stdout, result.stderr)
    }

    private func readJSONFile(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        return object as? [String: Any] ?? [:]
    }

    private func writeJSONFile(at url: URL, object: [String: Any]) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        let tempURL = parent.appendingPathComponent(UUID().uuidString).appendingPathExtension("tmp")
        try data.write(to: tempURL, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tempURL, to: url)
    }

    private func compactProbeSummary(_ probe: (status: Int32, values: [String: String], stdout: String, stderr: String)) -> String {
        if probe.status != 0 {
            return probe.stderr.isEmpty ? probe.stdout : probe.stderr
        }

        let keys = [
            "target",
            "thread_id",
            "tty",
            "status",
            "reason",
            "terminal_state",
            "terminal_reason",
            "last_user_message_at",
            "last_user_message"
        ]

        return keys.compactMap { key in
            guard let value = probe.values[key], !value.isEmpty else { return nil }
            return "\(key): \(value)"
        }.joined(separator: " | ")
    }

    private func verifyUserMessageAdvanced(target: String, previousTimestamp: String, timeoutSeconds: TimeInterval) -> (success: Bool, probe: (status: Int32, values: [String: String], stdout: String, stderr: String)) {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var latestProbe = probeResult(for: target)

        while Date() < deadline {
            latestProbe = probeResult(for: target)
            let currentTimestamp = latestProbe.values["last_user_message_at"] ?? ""
            if !currentTimestamp.isEmpty && currentTimestamp != previousTimestamp {
                return (true, latestProbe)
            }
            Thread.sleep(forTimeInterval: 0.4)
        }

        latestProbe = probeResult(for: target)
        return (false, latestProbe)
    }

    private func handleQueuedSendRequest(at processingURL: URL) {
        let resultURL = URL(fileURLWithPath: resultRequestDirectoryPath, isDirectory: true)
            .appendingPathComponent(processingURL.deletingPathExtension().deletingPathExtension().lastPathComponent + ".result.json")

        func logActivity(_ text: String) {
            DispatchQueue.main.async {
                self.appendOutput(text)
            }
        }

        func finish(with result: [String: Any]) {
            do {
                try writeJSONFile(at: resultURL, object: result)
            } catch {}
            try? FileManager.default.removeItem(at: processingURL)
            DispatchQueue.main.async {
                self.isProcessingSendRequest = false
                self.refreshLoopsSnapshot()
            }
        }

        let payload: [String: Any]
        do {
            payload = try readJSONFile(at: processingURL)
        } catch {
            logActivity("发送请求失败: status=failed reason=invalid_request detail=failed to read request: \(error.localizedDescription)")
            finish(with: [
                "status": "failed",
                "reason": "invalid_request",
                "detail": "failed to read request: \(error.localizedDescription)"
            ])
            return
        }

        guard let target = payload["target"] as? String,
              let message = payload["message"] as? String,
              let timeoutSeconds = payload["timeout_seconds"] as? NSNumber else {
            logActivity("发送请求失败: status=failed reason=invalid_request detail=request file is missing target, message, or timeout_seconds")
            finish(with: [
                "status": "failed",
                "reason": "invalid_request",
                "detail": "request file is missing target, message, or timeout_seconds"
            ])
            return
        }

        let forceSend = payload["force_send"] as? Bool ?? false
        let initialProbe = probeResult(for: target)
        guard initialProbe.status == 0 else {
            logActivity("发送请求失败: status=failed reason=probe_failed target=\(target) force_send=\(forceSend ? "yes" : "no") detail=\(compactProbeSummary(initialProbe))")
            finish(with: [
                "status": "failed",
                "reason": "probe_failed",
                "target": target,
                "force_send": forceSend,
                "detail": compactProbeSummary(initialProbe)
            ])
            return
        }

        let probeStatus = initialProbe.values["status"] ?? "unknown"
        let terminalState = initialProbe.values["terminal_state"] ?? "unknown"
        let tty = initialProbe.values["tty"] ?? ""
        let previousUserTimestamp = initialProbe.values["last_user_message_at"] ?? ""

        let sendableByState = terminalState == "prompt_ready" && (probeStatus == "idle_stable" || probeStatus == "interrupted_idle")
        guard !tty.isEmpty && (forceSend || sendableByState) else {
            logActivity("发送请求失败: status=failed reason=not_sendable target=\(target) force_send=\(forceSend ? "yes" : "no") probe_status=\(probeStatus) terminal_state=\(terminalState) detail=\(compactProbeSummary(initialProbe))")
            finish(with: [
                "status": "failed",
                "reason": "not_sendable",
                "target": target,
                "force_send": forceSend,
                "detail": compactProbeSummary(initialProbe),
                "probe_status": probeStatus,
                "terminal_state": terminalState
            ])
            return
        }

        let ttyPath = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"

        do {
            try DispatchQueue.main.sync {
                try self.sendViaAppKeystrokes(ttyPath: ttyPath, message: message)
            }
        } catch {
            logActivity("发送请求失败: status=failed reason=send_interrupted target=\(target) force_send=\(forceSend ? "yes" : "no") probe_status=\(probeStatus) terminal_state=\(terminalState) detail=\(error.localizedDescription)")
            finish(with: [
                "status": "failed",
                "reason": "send_interrupted",
                "target": target,
                "force_send": forceSend,
                "detail": error.localizedDescription,
                "probe_status": probeStatus,
                "terminal_state": terminalState
            ])
            return
        }

        let verification = verifyUserMessageAdvanced(
            target: target,
            previousTimestamp: previousUserTimestamp,
            timeoutSeconds: max(4, min(timeoutSeconds.doubleValue, 8))
        )

        if verification.success {
            let reason = forceSend ? "forced_sent" : "sent"
            let detail = "sent message via app sender to target=\(target) tty=\(tty)"
            logActivity("发送请求完成: status=success reason=\(reason) target=\(target) force_send=\(forceSend ? "yes" : "no") probe_status=\(probeStatus) terminal_state=\(terminalState) detail=\(detail)")
            finish(with: [
                "status": "success",
                "reason": reason,
                "target": target,
                "force_send": forceSend,
                "probe_status": probeStatus,
                "terminal_state": terminalState,
                "detail": detail
            ])
            return
        }

        logActivity("发送请求失败: status=failed reason=send_unverified target=\(target) force_send=\(forceSend ? "yes" : "no") probe_status=\(verification.probe.values["status"] ?? "unknown") terminal_state=\(verification.probe.values["terminal_state"] ?? "unknown") detail=\(compactProbeSummary(verification.probe))")
        finish(with: [
            "status": "failed",
            "reason": "send_unverified",
            "target": target,
            "force_send": forceSend,
            "detail": compactProbeSummary(verification.probe),
            "probe_status": verification.probe.values["status"] ?? "unknown",
            "terminal_state": verification.probe.values["terminal_state"] ?? "unknown"
        ])
    }

    private func ensureAccessibilityTrust(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw NSError(domain: "CodexTaskmaster", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建键盘事件源"])
        }
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw NSError(domain: "CodexTaskmaster", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法创建键盘事件"])
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func focusTerminalWindow(for ttyPath: String) throws {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-",
            ttyPath
        ]
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin

        let script = """
        on run argv
          set targetTTY to item 1 of argv
          tell application "Terminal"
            activate
            repeat with w in windows
              try
                if (tty of selected tab of w) is equal to targetTTY then
                  set index of w to 1
                  return "ok"
                end if
              end try
            end repeat
          end tell
          error "could not focus Terminal window for " & targetTTY
        end run
        """

        do {
            try process.run()
        } catch {
            throw NSError(domain: "CodexTaskmaster", code: 3, userInfo: [NSLocalizedDescriptionKey: "启动 Terminal 聚焦脚本失败: \(error.localizedDescription)"])
        }

        if let input = script.data(using: .utf8) {
            let inputHandle = stdin.fileHandleForWriting
            inputHandle.write(input)
            try? inputHandle.close()
        }

        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "聚焦 Terminal 失败"
            throw NSError(domain: "CodexTaskmaster", code: 4, userInfo: [NSLocalizedDescriptionKey: errText])
        }
        usleep(250_000)
    }

    private func sendViaAppKeystrokes(ttyPath: String, message: String) throws {
        guard ensureAccessibilityTrust(prompt: true) else {
            throw NSError(domain: "CodexTaskmaster", code: 5, userInfo: [NSLocalizedDescriptionKey: "Codex Taskmaster 没有辅助功能权限，无法发送按键"])
        }

        try focusTerminalWindow(for: ttyPath)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)

        usleep(300_000)
        try postKey(9, flags: .maskCommand)
        usleep(700_000)
        try postKey(36)
        usleep(500_000)
    }

    private func runHelper(arguments: [String], actionName: String) {
        persistDefaults()
        setButtonsEnabled(false)
        setStatus("\(actionName)执行中…", key: "action")
        appendOutput("执行 \(actionName): \(arguments.joined(separator: " "))")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.runStandardHelper(arguments: arguments)

            DispatchQueue.main.async {
                if !result.stdout.isEmpty {
                    self.appendOutput(result.stdout)
                }
                if !result.stderr.isEmpty {
                    self.appendOutput("stderr: \(result.stderr)")
                }

                if result.status == 0 {
                    self.setStatus("\(actionName)完成", key: "action")
                } else {
                    self.setStatus("\(actionName)失败", key: "action")
                }
                self.setButtonsEnabled(true)
                self.refreshLoopsSnapshot()
            }
        }
    }

    private func runStandardHelper(arguments: [String]) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: self.helperPath)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (1, "", "启动失败: \(error.localizedDescription)")
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let outText = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, outText, errText)
    }

    private func runInterruptibleSessionHelper(arguments: [String]) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: self.helperPath)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        sessionScanProcessLock.lock()
        currentSessionScanProcess = process
        sessionScanProcessLock.unlock()

        defer {
            sessionScanProcessLock.lock()
            if currentSessionScanProcess === process {
                currentSessionScanProcess = nil
            }
            sessionScanProcessLock.unlock()
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (1, "", "启动失败: \(error.localizedDescription)")
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let outText = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, outText, errText)
    }

    private func stopSessionStatusScan() {
        guard isSessionScanRunning else { return }
        sessionScanShouldStop = true
        sessionScanGeneration += 1

        sessionScanProcessLock.lock()
        let process = currentSessionScanProcess
        sessionScanProcessLock.unlock()

        if let process, process.isRunning {
            process.terminate()
        }

        isSessionScanRunning = false
        updateDetectStatusButtonState()
        setStatus("检测状态已停止", key: "scan")
        appendOutput("已请求停止检测状态。")
        if sessionScanTotal > 0 {
            renderSessionSnapshots(scannedCount: sessionSnapshots.count, totalCount: sessionScanTotal, isComplete: false)
            sessionStatusMetaLabel.stringValue += " | 已停止"
        } else {
            sessionStatusMetaLabel.stringValue = "检测已停止。"
            sessionStatusTableView.reloadData()
        }
    }

    private func refreshLoopsSnapshot() {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()

            process.executableURL = URL(fileURLWithPath: self.helperPath)
            process.arguments = ["status"]
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                DispatchQueue.main.async {
                    self.loopSnapshots = []
                    self.loopWarnings = ["Failed to load active loops: \(error.localizedDescription)"]
                    self.activeLoopsMetaLabel.stringValue = self.loopWarnings.first ?? "Failed to load active loops."
                    self.activeLoopsTableView.reloadData()
                    self.stopButton.isEnabled = false
                }
                return
            }

            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let outText = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            DispatchQueue.main.async {
                if process.terminationStatus == 0 {
                    self.loopSnapshots = self.parseStatusOutput(outText)
                    self.loopWarnings = self.parseWarnings(from: outText)
                    self.applyLoopSorting()
                    if self.loopSnapshots.isEmpty {
                        self.activeLoopsMetaLabel.stringValue = self.loopWarnings.first ?? "No active loops."
                    } else {
                        let warningSuffix = self.loopWarnings.isEmpty ? "" : " | warnings: \(self.loopWarnings.count)"
                        self.activeLoopsMetaLabel.stringValue = "Loops: \(self.loopSnapshots.count)\(warningSuffix)"
                    }
                } else {
                    self.loopSnapshots = []
                    self.loopWarnings = [errText.isEmpty ? "Failed to load active loops." : errText]
                    self.activeLoopsMetaLabel.stringValue = self.loopWarnings.first ?? "Failed to load active loops."
                }
                self.activeLoopsTableView.reloadData()
                if self.activeLoopsTableView.selectedRow >= self.loopSnapshots.count {
                    self.activeLoopsTableView.deselectAll(nil)
                }
                self.stopButton.isEnabled = self.activeLoopsTableView.selectedRow >= 0
            }
        }
    }

    private func refreshSessionStatuses() {
        if isSessionScanRunning {
            stopSessionStatusScan()
            return
        }

        isSessionScanRunning = true
        sessionScanShouldStop = false
        sessionScanGeneration += 1
        let generation = sessionScanGeneration
        sessionScanTotal = 0
        updateDetectStatusButtonState()
        setStatus("检测状态执行中…", key: "scan")
        appendOutput("执行 检测状态: session-count + probe-all batches")
        sessionSnapshots = []
        sessionStatusMetaLabel.stringValue = "正在准备扫描…"
        sessionStatusTableView.reloadData()

        DispatchQueue.global(qos: .userInitiated).async {
            let countResult = self.runInterruptibleSessionHelper(arguments: ["session-count"])

            if self.sessionScanShouldStop || self.sessionScanGeneration != generation {
                return
            }

            guard countResult.status == 0, let totalCount = self.parseSessionCountOutput(countResult.stdout) else {
                DispatchQueue.main.async {
                    guard self.sessionScanGeneration == generation else { return }
                    self.isSessionScanRunning = false
                    self.updateDetectStatusButtonState()
                    self.sessionSnapshots = []
                    self.sessionStatusMetaLabel.stringValue = "检测状态失败: \(countResult.stderr.isEmpty ? countResult.stdout : countResult.stderr)"
                    self.sessionStatusTableView.reloadData()
                    self.setStatus("检测状态失败", key: "scan")
                    if !countResult.stderr.isEmpty {
                        self.appendOutput("stderr: \(countResult.stderr)")
                    }
                }
                return
            }

            DispatchQueue.main.async {
                guard self.sessionScanGeneration == generation else { return }
                self.sessionScanTotal = totalCount
                if totalCount == 0 {
                    self.isSessionScanRunning = false
                    self.updateDetectStatusButtonState()
                    self.sessionStatusMetaLabel.stringValue = "没有可扫描的 session。"
                    self.sessionStatusTableView.reloadData()
                    self.setStatus("检测状态完成", key: "scan")
                } else {
                    self.sessionStatusMetaLabel.stringValue = "正在扫描 0/\(totalCount)…"
                    self.sessionStatusTableView.reloadData()
                }
            }

            guard totalCount > 0 else { return }

            var offset = 0
            var scannedCount = 0
            var encounteredFailure = false
            var failureDetail = ""

            while offset < totalCount {
                if self.sessionScanShouldStop || self.sessionScanGeneration != generation {
                    return
                }
                let batchSize = offset == 0 ? min(sessionProbeInitialBatchSize, totalCount) : min(sessionProbeBatchSize, totalCount - offset)
                let batchResult = self.runInterruptibleSessionHelper(arguments: ["probe-all", "-l", String(batchSize), "-o", String(offset)])

                if self.sessionScanShouldStop || self.sessionScanGeneration != generation {
                    return
                }

                if batchResult.status != 0 {
                    encounteredFailure = true
                    failureDetail = batchResult.stderr.isEmpty ? batchResult.stdout : batchResult.stderr
                    break
                }

                let batchSnapshots = self.parseProbeAllOutput(batchResult.stdout)
                scannedCount = min(totalCount, offset + batchSize)

                DispatchQueue.main.async {
                    guard self.sessionScanGeneration == generation else { return }
                    self.mergeSessionSnapshots(batchSnapshots)
                    self.renderSessionSnapshots(scannedCount: scannedCount, totalCount: totalCount, isComplete: scannedCount >= totalCount)
                    if scannedCount < totalCount {
                        self.setStatus("检测状态执行中… \(scannedCount)/\(totalCount)", key: "scan")
                    }
                }

                offset += batchSize
            }

            DispatchQueue.main.async {
                guard self.sessionScanGeneration == generation else { return }
                self.isSessionScanRunning = false
                self.updateDetectStatusButtonState()

                if encounteredFailure {
                    self.renderSessionSnapshots(scannedCount: scannedCount, totalCount: totalCount, isComplete: false)
                    self.sessionStatusMetaLabel.stringValue += " | 部分失败"
                    self.setStatus("检测状态部分失败", key: "scan")
                    if !failureDetail.isEmpty {
                        self.appendOutput("stderr: \(failureDetail)")
                    }
                    return
                }

                self.renderSessionSnapshots(scannedCount: scannedCount, totalCount: totalCount, isComplete: true)
                self.setStatus("检测状态完成", key: "scan")
                self.appendOutput("检测到 \(self.sessionSnapshots.count) 个 session 状态。")
            }
        }
    }

    @objc
    private func sendOnce() {
        guard let target = validateTarget(), !currentMessage().isEmpty else {
            if currentMessage().isEmpty {
                appendOutput("输出内容不能为空。")
                setStatus("请填写输出内容")
                NSSound.beep()
            }
            return
        }
        guard ensureAccessibilityTrust(prompt: true) else {
            appendOutput("Codex Taskmaster 缺少辅助功能权限，无法发送按键。请在 系统设置 > 隐私与安全性 > 辅助功能 中允许它。")
            setStatus("缺少辅助功能权限")
            NSSound.beep()
            return
        }
        var arguments = ["send", "-t", target, "-m", currentMessage()]
        if isForceSendEnabled() {
            arguments.append("-f")
        }
        runHelper(arguments: arguments, actionName: "发送一次")
    }

    @objc
    private func startLoop() {
        guard let target = validateTarget(), let interval = validateInterval(), !currentMessage().isEmpty else {
            if currentMessage().isEmpty {
                appendOutput("输出内容不能为空。")
                setStatus("请填写输出内容")
                NSSound.beep()
            }
            return
        }
        guard ensureAccessibilityTrust(prompt: true) else {
            appendOutput("Codex Taskmaster 缺少辅助功能权限，无法处理循环发送。请在 系统设置 > 隐私与安全性 > 辅助功能 中允许它。")
            setStatus("缺少辅助功能权限")
            NSSound.beep()
            return
        }
        var arguments = ["start", "-t", target, "-i", interval, "-m", currentMessage()]
        if isForceSendEnabled() {
            arguments.append("-f")
        }
        runHelper(arguments: arguments, actionName: "开始循环")
    }

    @objc
    private func refreshLoopsAction() {
        appendOutput("刷新循环列表。")
        refreshLoopsSnapshot()
    }

    @objc
    private func detectStatuses() {
        refreshSessionStatuses()
    }

    @objc
    private func stopLoop() {
        let selectedRow = activeLoopsTableView.selectedRow
        guard selectedRow >= 0, selectedRow < loopSnapshots.count else {
            appendOutput("请先在 Active Loops 中选择一条循环任务。")
            setStatus("请选择一个循环任务")
            NSSound.beep()
            return
        }
        let target = loopSnapshots[selectedRow].target
        targetField.stringValue = target
        runHelper(arguments: ["stop", "-t", target], actionName: "停止当前")
    }

    @objc
    private func stopAllLoops() {
        runHelper(arguments: ["stop", "--all"], actionName: "全部停止")
    }

    @objc
    private func handleSessionStatusDoubleClick() {
        let clickedRow = sessionStatusTableView.clickedRow
        guard clickedRow >= 0, clickedRow < sessionSnapshots.count else { return }
        let session = sessionSnapshots[clickedRow]
        let value = preferredTargetValue(for: session)
        targetField.stringValue = value
        setStatus("已从 Session Status 填入 \(value)")
        if session.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendOutput("Session Status 双击填入 ID: \(value)")
        } else {
            appendOutput("Session Status 双击填入 Name: \(value)")
        }
    }

    @objc
    private func saveSessionRename() {
        let selectedRow = sessionStatusTableView.selectedRow
        guard selectedRow >= 0, selectedRow < sessionSnapshots.count else {
            appendOutput("请先选择一条 session，再保存名称。")
            setStatus("请选择一个 session")
            NSSound.beep()
            return
        }

        let session = sessionSnapshots[selectedRow]
        let newName = renameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        saveRenameButton.isEnabled = false
        deleteSessionButton.isEnabled = false
        renameField.isEnabled = false
        setStatus("保存名称中…", key: "action")
        appendOutput("执行 保存名称: thread_id=\(session.threadID) name=\(newName.isEmpty ? "<empty>" : newName)")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.updateSessionName(threadID: session.threadID, newName: newName)

            DispatchQueue.main.async {
                self.saveRenameButton.isEnabled = true
                self.renameField.isEnabled = true
                self.deleteSessionButton.isEnabled = self.sessionStatusTableView.selectedRow >= 0

                if result.success {
                    if let index = self.sessionSnapshots.firstIndex(where: { $0.threadID == session.threadID }) {
                        let previous = self.sessionSnapshots[index]
                        self.sessionSnapshots[index] = SessionSnapshot(
                            name: newName,
                            target: newName.isEmpty ? previous.threadID : newName,
                            threadID: previous.threadID,
                            status: previous.status,
                            reason: previous.reason,
                            terminalState: previous.terminalState,
                            tty: previous.tty,
                            updatedAtEpoch: previous.updatedAtEpoch,
                            rolloutPath: previous.rolloutPath
                        )
                    }
                    self.applySessionSorting()
                    self.sessionStatusTableView.reloadData()
                    self.selectSessionRow(threadID: session.threadID)
                    self.updateSessionDetailView()
                    self.setStatus("保存名称完成", key: "action")
                    self.appendOutput(newName.isEmpty ? "已清空名称，恢复为未 rename 状态。" : "已保存名称: \(newName)")
                } else {
                    self.setStatus("保存名称失败", key: "action")
                    self.appendOutput("stderr: \(result.error)")
                    NSSound.beep()
                }
            }
        }
    }

    @objc
    private func deleteSelectedSession() {
        let selectedRow = sessionStatusTableView.selectedRow
        guard selectedRow >= 0, selectedRow < sessionSnapshots.count else {
            appendOutput("请先选择一条 session，再删除。")
            setStatus("请选择一个 session")
            NSSound.beep()
            return
        }

        let session = sessionSnapshots[selectedRow]
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除这个 Session？"
        alert.informativeText = """
        这会调用 Codex 原生的 thread/archive，相当于原生删除语义。
        删除后该 session 会从当前非归档列表中消失。

        Session ID: \(session.threadID)
        Target: \(sessionEffectiveTarget(session))
        """
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        saveRenameButton.isEnabled = false
        deleteSessionButton.isEnabled = false
        renameField.isEnabled = false
        setStatus("删除 Session 中…", key: "action")
        appendOutput("执行 删除 Session: thread_id=\(session.threadID)")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.archiveSession(threadID: session.threadID)

            DispatchQueue.main.async {
                if result.success {
                    self.sessionSnapshots.removeAll { $0.threadID == session.threadID }
                    if self.sessionScanTotal > 0 {
                        self.sessionScanTotal = max(0, self.sessionScanTotal - 1)
                    }
                    self.sessionStatusTableView.reloadData()
                    self.updateSessionDetailView()
                    self.renderSessionSnapshots(
                        scannedCount: self.sessionSnapshots.count,
                        totalCount: self.sessionScanTotal > 0 ? self.sessionScanTotal : self.sessionSnapshots.count,
                        isComplete: true
                    )
                    self.setStatus("删除 Session 完成", key: "action")
                    self.appendOutput("已按 Codex 原生 archive 语义删除 session: \(session.threadID)")
                } else {
                    self.renameField.isEnabled = self.sessionStatusTableView.selectedRow >= 0
                    self.saveRenameButton.isEnabled = self.sessionStatusTableView.selectedRow >= 0
                    self.deleteSessionButton.isEnabled = self.sessionStatusTableView.selectedRow >= 0
                    self.setStatus("删除 Session 失败", key: "action")
                    self.appendOutput("stderr: \(result.error)")
                    NSSound.beep()
                }
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == activeLoopsTableView {
            return max(loopSnapshots.count, loopWarnings.isEmpty ? 0 : 1)
        }
        if tableView == sessionStatusTableView {
            return sessionSnapshots.count
        }
        return 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }

        let tablePrefix = tableView == activeLoopsTableView ? "LoopCell" : "SessionCell"
        let identifier = NSUserInterfaceItemIdentifier("\(tablePrefix)-\(tableColumn.identifier.rawValue)")
        let textField: NSTextField
        let cellView: NSTableCellView

        if let existing = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView,
           let existingField = existing.textField {
            cellView = existing
            textField = existingField
        } else {
            cellView = NSTableCellView()
            cellView.identifier = identifier
            textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            textField.maximumNumberOfLines = 1
            cellView.addSubview(textField)
            cellView.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cellView.centerYAnchor)
            ])
        }

        textField.textColor = .labelColor

        if tableView == activeLoopsTableView {
            if row >= loopSnapshots.count {
                textField.textColor = .systemOrange
                textField.stringValue = tableColumn == activeLoopsTableView.tableColumns.first ? (loopWarnings.first ?? "Warning") : ""
                textField.toolTip = textField.stringValue
                return cellView
            }

            let loop = loopSnapshots[row]
            switch tableColumn.identifier.rawValue {
            case "target":
                textField.stringValue = loop.target
            case "interval":
                textField.stringValue = "\(loop.intervalSeconds)s"
            case "forceSend":
                textField.stringValue = loop.forceSend == "yes" ? "force" : "idle"
            case "nextRun":
                textField.stringValue = formatEpoch(loop.nextRunEpoch)
            case "message":
                textField.stringValue = loop.message
            case "lastLog":
                textField.stringValue = loop.lastLogLine
            default:
                textField.stringValue = ""
            }
            textField.toolTip = textField.stringValue
            return cellView
        }

        let session = sessionSnapshots[row]
        switch tableColumn.identifier.rawValue {
        case "name":
            textField.stringValue = sessionActualName(session)
        case "target":
            textField.stringValue = sessionEffectiveTarget(session)
        case "threadID":
            textField.stringValue = session.threadID
        case "status":
            textField.stringValue = session.status
        case "terminalState":
            textField.stringValue = session.terminalState
        case "tty":
            textField.stringValue = session.tty.isEmpty ? "-" : session.tty
        case "updatedAt":
            textField.stringValue = formatEpoch(session.updatedAtEpoch)
        case "reason":
            textField.stringValue = localizedSessionReason(session.reason)
        default:
            textField.stringValue = ""
        }
        textField.toolTip = textField.stringValue
        return cellView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView else { return }
        if tableView == activeLoopsTableView {
            let selectedRow = tableView.selectedRow
            if selectedRow >= 0, selectedRow < loopSnapshots.count {
                targetField.stringValue = loopSnapshots[selectedRow].target
                stopButton.isEnabled = true
            } else {
                stopButton.isEnabled = false
            }
            return
        }
        if tableView == sessionStatusTableView {
            updateSessionDetailView()
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        if tableView == activeLoopsTableView {
            applyLoopSorting()
            activeLoopsTableView.reloadData()
            return
        }
        if tableView == sessionStatusTableView {
            applySessionSorting()
            sessionStatusTableView.reloadData()
            updateSessionDetailView()
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field == intervalField else { return }
        _ = validateAndCommitIntervalField(showAlert: true)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let splitView = notification.object as? NSSplitView, splitView == topSplitView else { return }
        updateTopSplitRatioFromCurrentLayout()
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let loopTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

let app = NSApplication.shared
let delegate = CodexBianCeZheApp()
app.delegate = delegate
app.run()
