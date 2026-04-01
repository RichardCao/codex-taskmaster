import AppKit
import ApplicationServices
import UniformTypeIdentifiers

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
    static let targetHistory = "targetHistory"
    static let messageHistory = "messageHistory"
}

private func initialTargetValue() -> String {
    let saved = UserDefaults.standard.string(forKey: DefaultsKey.target)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if saved.isEmpty {
        return "test"
    }
    return saved
}

final class AdjustableSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 10 }

    override func drawDivider(in rect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        rect.fill()

        let lineThickness: CGFloat = 1
        let lineRect: NSRect
        if isVertical {
            lineRect = NSRect(
                x: rect.midX - (lineThickness / 2),
                y: rect.minY + 2,
                width: lineThickness,
                height: max(0, rect.height - 4)
            )
        } else {
            lineRect = NSRect(
                x: rect.minX + 2,
                y: rect.midY - (lineThickness / 2),
                width: max(0, rect.width - 4),
                height: lineThickness
            )
        }

        NSColor.tertiaryLabelColor.withAlphaComponent(0.22).setFill()
        lineRect.fill()
    }
}

final class HistoryDropdownRowView: NSView {
    private let titleButton = NSButton(title: "", target: nil, action: nil)
    private let deleteButton = NSButton(title: "×", target: nil, action: nil)
    private var trackingAreaRef: NSTrackingArea?
    private var isClearAction = false
    private let horizontalInset: CGFloat = 8
    private let deleteWidth: CGFloat = 16
    private let deleteTrailingInset: CGFloat = 6
    private let contentGap: CGFloat = 8

    var onSelect: (() -> Void)?
    var onDelete: (() -> Void)?
    var onHover: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        heightAnchor.constraint(equalToConstant: 22).isActive = true

        titleButton.isBordered = false
        titleButton.alignment = .left
        titleButton.lineBreakMode = .byTruncatingMiddle
        titleButton.target = self
        titleButton.action = #selector(handleSelect)
        titleButton.translatesAutoresizingMaskIntoConstraints = false
        titleButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        deleteButton.isBordered = false
        deleteButton.font = .systemFont(ofSize: 12, weight: .semibold)
        deleteButton.contentTintColor = .secondaryLabelColor
        deleteButton.target = self
        deleteButton.action = #selector(handleDelete)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.setContentHuggingPriority(.required, for: .horizontal)
        deleteButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(titleButton)
        addSubview(deleteButton)

        setHighlighted(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func layout() {
        super.layout()

        let contentBounds = bounds
        let buttonHeight = max(18, contentBounds.height - 4)

        if deleteButton.isHidden {
            deleteButton.frame = .zero
            titleButton.frame = NSRect(
                x: horizontalInset,
                y: floor((contentBounds.height - buttonHeight) / 2),
                width: max(0, contentBounds.width - (horizontalInset * 2)),
                height: buttonHeight
            )
            return
        }

        let deleteX = max(horizontalInset, contentBounds.width - deleteTrailingInset - deleteWidth)
        deleteButton.frame = NSRect(
            x: deleteX,
            y: floor((contentBounds.height - deleteWidth) / 2),
            width: deleteWidth,
            height: deleteWidth
        )

        let titleMaxX = deleteButton.frame.minX - contentGap
        titleButton.frame = NSRect(
            x: horizontalInset,
            y: floor((contentBounds.height - buttonHeight) / 2),
            width: max(0, titleMaxX - horizontalInset),
            height: buttonHeight
        )
    }

    func configure(title: String, isClearAction: Bool, canDelete: Bool) {
        self.isClearAction = isClearAction
        titleButton.title = title
        titleButton.font = isClearAction
            ? .systemFont(ofSize: 12, weight: .medium)
            : .systemFont(ofSize: 12)
        titleButton.contentTintColor = .labelColor
        deleteButton.isHidden = !canDelete
        needsLayout = true
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?()
    }

    func setHighlighted(_ highlighted: Bool) {
        layer?.backgroundColor = highlighted ? NSColor.selectedContentBackgroundColor.cgColor : NSColor.clear.cgColor
        titleButton.contentTintColor = highlighted ? .selectedTextColor : (isClearAction ? .secondaryLabelColor : .labelColor)
        if !deleteButton.isHidden {
            deleteButton.contentTintColor = highlighted ? .selectedTextColor : .secondaryLabelColor
        }
    }

    @objc
    private func handleSelect() {
        onSelect?()
    }

    @objc
    private func handleDelete() {
        onDelete?()
    }
}

final class HistoryDropdownListView: NSView {
    override var isFlipped: Bool { true }
}

final class CodexBianCeZheApp: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var didRunTerminationCleanup = false

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

    func applicationWillTerminate(_ notification: Notification) {
        performTerminationCleanupIfNeeded()
    }

    private func performTerminationCleanupIfNeeded() {
        guard !didRunTerminationCleanup else { return }
        didRunTerminationCleanup = true

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: resolvedHelperPath())
        process.arguments = ["stop", "--all"]
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
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
        window.minSize = NSSize(width: 760, height: 560)
        window.contentMinSize = NSSize(width: 760, height: 560)
        window.contentMaxSize = NSSize(width: 10_000, height: 10_000)
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
    private enum LayoutMetrics {
        static let headerHeight: CGFloat = 188
        static let headerOuterMargin: CGFloat = 20
        static let headerToContentSpacing: CGFloat = 6
        static let contentBottomMargin: CGFloat = 20
        static let topPaneMinHeight: CGFloat = 210
        static let bottomPaneMinHeight: CGFloat = 106
    }

    private enum HistoryKind: String {
        case target
        case message

        var clearLabel: String {
            switch self {
            case .target:
                return "清空最近目标"
            case .message:
                return "清空最近消息"
            }
        }
    }

    private let helperPath = resolvedHelperPath()

    private enum SessionListMode {
        case active
        case archived
    }

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
        let preview: String
        let isArchived: Bool
    }

    private let targetField: NSTextField = {
        let field = NSTextField()
        field.stringValue = initialTargetValue()
        return field
    }()
    private let intervalField = NSTextField(string: UserDefaults.standard.string(forKey: DefaultsKey.interval) ?? "600")
    private let messageField: NSTextField = {
        let field = NSTextField()
        field.stringValue = UserDefaults.standard.string(forKey: DefaultsKey.message) ?? "继续"
        return field
    }()
    private lazy var targetHistoryButton = makeHistoryArrowButton(action: #selector(toggleTargetHistoryDropdown))
    private lazy var messageHistoryButton = makeHistoryArrowButton(action: #selector(toggleMessageHistoryDropdown))
    private let forceSendCheckbox: NSButton = {
        let checkbox = NSButton(checkboxWithTitle: "强制发送（忽略 session 状态）", target: nil, action: nil)
        checkbox.state = UserDefaults.standard.bool(forKey: DefaultsKey.forceSend) ? .on : .off
        return checkbox
    }()
    private let activeLoopsTableView = NSTableView()
    private let activeLoopsScrollView = NSScrollView()
    private let sessionStatusTableView = NSTableView()
    private let sessionStatusScrollView = NSScrollView()
    private let sessionScopeControl: NSSegmentedControl = {
        let control = NSSegmentedControl(labels: ["普通", "已归档"], trackingMode: .selectOne, target: nil, action: nil)
        control.selectedSegment = 0
        return control
    }()
    private let renameField = NSTextField(string: "")
    private let sessionDetailView = NSTextView()
    private let sessionDetailScrollView = NSScrollView()
    private let topSplitView = AdjustableSplitView()
    private let contentSplitView = AdjustableSplitView()
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
    private var targetHistory: [String] = []
    private var messageHistory: [String] = []
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
    private var contentSplitRatio: CGFloat = 0.62
    private var didApplyInitialContentSplitRatio = false
    private var lastContentSplitHeight: CGFloat = 0
    private var isApplyingContentSplitRatio = false
    private let sessionScanProcessLock = NSLock()
    private var currentSessionScanProcess: Process?
    private var sessionDetailLoadGeneration = 0
    private let historyListView = HistoryDropdownListView()
    private var historyPopoverKind: HistoryKind?
    private var historyRowViews: [HistoryDropdownRowView] = []
    private var historyHighlightedIndex: Int = -1
    private var historyKeyMonitor: Any?
    private var historyDropdownPanel: NSPanel?
    private var historyDropdownScrollView: NSScrollView?
    private var historyOutsideLocalMonitor: Any?
    private var historyOutsideGlobalMonitor: Any?

    private lazy var sendButton = makeButton(title: "发送一次", action: #selector(sendOnce))
    private lazy var startButton = makeButton(title: "开始循环", action: #selector(startLoop))
    private lazy var refreshLoopsButton = makeButton(title: "刷新循环", action: #selector(refreshLoopsAction))
    private lazy var detectStatusButton = makeButton(title: "检测状态", action: #selector(detectStatuses))
    private lazy var stopButton = makeButton(title: "停止当前", action: #selector(stopLoop))
    private lazy var stopAllButton = makeButton(title: "全部停止", action: #selector(stopAllLoops))
    private lazy var saveRenameButton = makeButton(title: "保存", action: #selector(saveSessionRename))
    private lazy var archiveSessionButton = makeButton(title: "归档", action: #selector(archiveSelectedSession))
    private lazy var restoreSessionButton = makeButton(title: "恢复", action: #selector(restoreSelectedSession))
    private lazy var deleteSessionButton = makeButton(title: "删除", action: #selector(deleteSelectedSession))
    private lazy var clearLogButton = makeButton(title: "清空日志", action: #selector(clearActivityLog))
    private lazy var saveLogButton = makeButton(title: "保存日志", action: #selector(saveActivityLog))

    override func loadView() {
        self.view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        loadHistoryState()
        normalizeInitialIntervalValue()
        sessionStatusMetaLabel.stringValue = sessionEmptyStateText()
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
        preserveContentSplitRatioOnResizeIfNeeded()
    }

    deinit {
        refreshTimer?.invalidate()
        requestTimer?.invalidate()
        removeHistoryKeyMonitor()
        removeHistoryOutsideMonitors()
    }

    private func buildUI() {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        targetField.placeholderString = "例如 test 或具体 session id"
        intervalField.placeholderString = "秒，例如 600"
        messageField.placeholderString = "例如 继续"
        targetField.translatesAutoresizingMaskIntoConstraints = false
        intervalField.translatesAutoresizingMaskIntoConstraints = false
        messageField.translatesAutoresizingMaskIntoConstraints = false
        intervalField.delegate = self
        targetField.heightAnchor.constraint(equalToConstant: 24).isActive = true
        intervalField.heightAnchor.constraint(equalToConstant: 24).isActive = true
        messageField.heightAnchor.constraint(equalToConstant: 24).isActive = true
        targetHistoryButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        messageHistoryButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        forceSendCheckbox.heightAnchor.constraint(equalToConstant: 20).isActive = true
        targetField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        messageField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let targetInputRow = NSStackView(views: [targetField, targetHistoryButton])
        targetInputRow.orientation = .horizontal
        targetInputRow.spacing = 4
        targetInputRow.alignment = .centerY
        targetInputRow.translatesAutoresizingMaskIntoConstraints = false
        targetField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        targetHistoryButton.setContentHuggingPriority(.required, for: .horizontal)

        let messageInputRow = NSStackView(views: [messageField, messageHistoryButton])
        messageInputRow.orientation = .horizontal
        messageInputRow.spacing = 4
        messageInputRow.alignment = .centerY
        messageInputRow.translatesAutoresizingMaskIntoConstraints = false
        messageField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        messageHistoryButton.setContentHuggingPriority(.required, for: .horizontal)

        let formGrid = NSGridView(views: [
            [makeFieldLabel("Session 名称 / ID"), targetInputRow],
            [makeFieldLabel("循环间隔(秒)"), intervalField],
            [makeFieldLabel("输出内容"), messageInputRow],
            [makeFieldLabel("发送策略"), forceSendCheckbox]
        ])
        formGrid.rowSpacing = 8
        formGrid.columnSpacing = 12
        formGrid.xPlacement = .leading
        formGrid.yPlacement = .center
        formGrid.translatesAutoresizingMaskIntoConstraints = false
        formGrid.column(at: 0).width = 120
        targetInputRow.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true

        let buttonRow = NSStackView(views: [sendButton, startButton, refreshLoopsButton, detectStatusButton, stopButton, stopAllButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY
        buttonRow.heightAnchor.constraint(equalToConstant: 30).isActive = true

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let headerStack = NSStackView(views: [formGrid, buttonRow, statusLabel])
        headerStack.orientation = .vertical
        headerStack.spacing = 8
        headerStack.alignment = .leading
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.setContentHuggingPriority(.required, for: .vertical)
        headerStack.setContentCompressionResistancePriority(.required, for: .vertical)
        view.addSubview(headerStack)
        headerStack.heightAnchor.constraint(equalToConstant: LayoutMetrics.headerHeight).isActive = true
        buttonRow.widthAnchor.constraint(lessThanOrEqualTo: headerStack.widthAnchor).isActive = true
        formGrid.setContentHuggingPriority(.required, for: .vertical)
        buttonRow.setContentHuggingPriority(.required, for: .vertical)
        statusLabel.setContentHuggingPriority(.required, for: .vertical)
        formGrid.setContentCompressionResistancePriority(.required, for: .vertical)
        buttonRow.setContentCompressionResistancePriority(.required, for: .vertical)
        statusLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        configureLoopsTable()
        activeLoopsScrollView.borderType = .bezelBorder
        activeLoopsScrollView.hasVerticalScroller = true
        activeLoopsScrollView.hasHorizontalScroller = true
        activeLoopsScrollView.autohidesScrollers = true
        activeLoopsScrollView.drawsBackground = true
        activeLoopsScrollView.translatesAutoresizingMaskIntoConstraints = false
        activeLoopsScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true

        configureSessionStatusTable()
        sessionStatusScrollView.borderType = .bezelBorder
        sessionStatusScrollView.hasVerticalScroller = true
        sessionStatusScrollView.hasHorizontalScroller = true
        sessionStatusScrollView.autohidesScrollers = true
        sessionStatusScrollView.drawsBackground = true
        sessionStatusScrollView.translatesAutoresizingMaskIntoConstraints = false
        sessionStatusScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true

        configureTextView(sessionDetailView, inset: NSSize(width: 10, height: 8))
        sessionDetailView.font = .systemFont(ofSize: 12)
        sessionDetailView.string = "选中一条 session 后，这里会显示完整信息和提示词历史。"

        sessionScopeControl.target = self
        sessionScopeControl.action = #selector(changeSessionScope)
        sessionScopeControl.translatesAutoresizingMaskIntoConstraints = false

        renameField.placeholderString = "输入新名称，留空可恢复为未 rename 状态"
        renameField.translatesAutoresizingMaskIntoConstraints = false
        renameField.isEnabled = false
        saveRenameButton.isEnabled = false
        archiveSessionButton.isEnabled = false
        restoreSessionButton.isEnabled = false
        deleteSessionButton.isEnabled = false
        archiveSessionButton.contentTintColor = .systemOrange
        restoreSessionButton.contentTintColor = .systemBlue
        deleteSessionButton.contentTintColor = .systemRed
        saveRenameButton.toolTip = "保存当前 session 的名称"
        archiveSessionButton.toolTip = "按 Codex 原生语义归档当前 session"
        restoreSessionButton.toolTip = "恢复当前已归档 session"
        deleteSessionButton.toolTip = "从本地状态中彻底删除当前 session"

        let renameRow = NSStackView(views: [renameField, saveRenameButton, archiveSessionButton, restoreSessionButton, deleteSessionButton])
        renameRow.orientation = .horizontal
        renameRow.spacing = 8
        renameRow.alignment = .centerY
        saveRenameButton.setContentHuggingPriority(.required, for: .horizontal)
        archiveSessionButton.setContentHuggingPriority(.required, for: .horizontal)
        restoreSessionButton.setContentHuggingPriority(.required, for: .horizontal)
        deleteSessionButton.setContentHuggingPriority(.required, for: .horizontal)

        let sessionScopeRow = NSStackView(views: [sessionScopeControl])
        sessionScopeRow.orientation = .horizontal
        sessionScopeRow.spacing = 8
        sessionScopeRow.alignment = .centerY
        sessionScopeControl.setContentHuggingPriority(.required, for: .horizontal)

        sessionDetailScrollView.borderType = .bezelBorder
        sessionDetailScrollView.hasVerticalScroller = true
        sessionDetailScrollView.hasHorizontalScroller = false
        sessionDetailScrollView.autohidesScrollers = true
        sessionDetailScrollView.drawsBackground = true
        sessionDetailScrollView.translatesAutoresizingMaskIntoConstraints = false
        sessionDetailScrollView.documentView = sessionDetailView
        sessionDetailScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true

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
        outputScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true

        let activeLoopsPanel = makePanel(title: "Active Loops", metaLabel: activeLoopsMetaLabel, contentView: activeLoopsScrollView)
        let sessionStatusContentStack = NSStackView(views: [sessionScopeRow, sessionStatusScrollView, renameRow, sessionDetailScrollView])
        sessionStatusContentStack.orientation = .vertical
        sessionStatusContentStack.spacing = 8
        sessionStatusContentStack.alignment = .leading
        sessionStatusContentStack.distribution = .fill
        sessionStatusContentStack.translatesAutoresizingMaskIntoConstraints = false
        sessionScopeRow.widthAnchor.constraint(equalTo: sessionStatusContentStack.widthAnchor).isActive = true
        sessionStatusScrollView.widthAnchor.constraint(equalTo: sessionStatusContentStack.widthAnchor).isActive = true
        renameRow.widthAnchor.constraint(equalTo: sessionStatusContentStack.widthAnchor).isActive = true
        sessionDetailScrollView.widthAnchor.constraint(equalTo: sessionStatusContentStack.widthAnchor).isActive = true
        renameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        sessionScopeRow.setContentHuggingPriority(.required, for: .vertical)
        sessionScopeRow.setContentCompressionResistancePriority(.required, for: .vertical)
        renameRow.setContentHuggingPriority(.required, for: .vertical)
        renameRow.setContentCompressionResistancePriority(.required, for: .vertical)
        sessionStatusScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        sessionStatusScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        sessionDetailScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        sessionDetailScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let sessionStatusPanel = makePanel(title: "Session Status", metaLabel: sessionStatusMetaLabel, contentView: sessionStatusContentStack)
        let logHeaderActions = NSStackView(views: [clearLogButton, saveLogButton])
        logHeaderActions.orientation = .horizontal
        logHeaderActions.spacing = 6
        logHeaderActions.alignment = .centerY
        clearLogButton.setContentHuggingPriority(.required, for: .horizontal)
        saveLogButton.setContentHuggingPriority(.required, for: .horizontal)
        clearLogButton.toolTip = "清空当前日志显示"
        saveLogButton.toolTip = "保存当前日志到文件"
        let logPanel = makePanel(title: "Activity Log", metaLabel: nil, contentView: outputScrollView, headerAccessoryView: logHeaderActions)
        let activeLoopsPane = makeSplitPane(contentView: activeLoopsPanel, minWidth: 260, minHeight: 100)
        let sessionStatusPane = makeSplitPane(contentView: sessionStatusPanel, minWidth: 220, minHeight: 100)
        let topContentPane = makeSplitPane(contentView: topSplitView, minHeight: LayoutMetrics.topPaneMinHeight)
        let logPane = makeSplitPane(contentView: logPanel, minHeight: LayoutMetrics.bottomPaneMinHeight)
        topSplitView.isVertical = true
        topSplitView.dividerStyle = .thin
        topSplitView.translatesAutoresizingMaskIntoConstraints = false
        topSplitView.delegate = self
        topSplitView.addArrangedSubview(activeLoopsPane)
        topSplitView.addArrangedSubview(sessionStatusPane)
        topSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        topSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        contentSplitView.isVertical = false
        contentSplitView.dividerStyle = .thin
        contentSplitView.translatesAutoresizingMaskIntoConstraints = false
        contentSplitView.delegate = self
        contentSplitView.addArrangedSubview(topContentPane)
        contentSplitView.addArrangedSubview(logPane)
        contentSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        contentSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        view.addSubview(contentSplitView)
        let minimumContentHeight = LayoutMetrics.topPaneMinHeight + LayoutMetrics.bottomPaneMinHeight + contentSplitView.dividerThickness
        contentSplitView.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumContentHeight).isActive = true
        contentSplitView.setContentHuggingPriority(.defaultLow, for: .vertical)
        contentSplitView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        logPanel.setContentHuggingPriority(.defaultLow, for: .vertical)
        logPanel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        outputScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        outputScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: view.topAnchor, constant: LayoutMetrics.headerOuterMargin),
            headerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            headerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            contentSplitView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: LayoutMetrics.headerToContentSpacing),
            contentSplitView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            contentSplitView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            contentSplitView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -LayoutMetrics.contentBottomMargin)
        ])
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
        activeLoopsTableView.columnAutoresizingStyle = .noColumnAutoresizing

        for column in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.identifier))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.identifier, ascending: column.identifier != defaultLoopSortKey)
            if column.identifier == "lastLog" {
                tableColumn.minWidth = 180
                tableColumn.resizingMask = [.autoresizingMask, .userResizingMask]
            } else {
                tableColumn.minWidth = 60
                tableColumn.resizingMask = .userResizingMask
            }
            activeLoopsTableView.addTableColumn(tableColumn)
        }

        activeLoopsScrollView.documentView = activeLoopsTableView
        activeLoopsTableView.sortDescriptors = [NSSortDescriptor(key: defaultLoopSortKey, ascending: true)]
    }

    private func configureSessionStatusTable() {
        let columns: [(identifier: String, title: String, width: CGFloat)] = [
            ("name", "Name", 180),
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
        sessionStatusTableView.columnAutoresizingStyle = .noColumnAutoresizing

        for column in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.identifier))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.identifier, ascending: column.identifier == defaultSessionSortKey ? false : true)
            if column.identifier == "reason" {
                tableColumn.minWidth = 220
                tableColumn.resizingMask = [.autoresizingMask, .userResizingMask]
            } else {
                tableColumn.minWidth = 60
                tableColumn.resizingMask = .userResizingMask
            }
            sessionStatusTableView.addTableColumn(tableColumn)
        }

        sessionStatusScrollView.documentView = sessionStatusTableView
        sessionStatusTableView.sortDescriptors = [NSSortDescriptor(key: defaultSessionSortKey, ascending: false)]
    }

    private func preferredTargetValue(for session: SessionSnapshot) -> String {
        let actualName = sessionActualName(session)
        if !actualName.isEmpty {
            return actualName
        }
        return session.threadID
    }

    private func currentSessionListMode() -> SessionListMode {
        sessionScopeControl.selectedSegment == 1 ? .archived : .active
    }

    private func sessionScopeText() -> String {
        currentSessionListMode() == .archived ? "已归档" : "普通"
    }

    private func sessionEmptyStateText() -> String {
        switch currentSessionListMode() {
        case .active:
            return "视图: 普通 | 未加载 session 状态。点击“检测状态”开始扫描。"
        case .archived:
            return "视图: 已归档 | 未加载归档 session。点击“检测状态”读取列表。"
        }
    }

    private func sessionActualName(_ session: SessionSnapshot) -> String {
        session.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sessionEffectiveTarget(_ session: SessionSnapshot) -> String {
        let target = session.target.trimmingCharacters(in: .whitespacesAndNewlines)
        return target.isEmpty ? session.threadID : target
    }

    private func sessionPossibleTargets(_ session: SessionSnapshot) -> [String] {
        var ordered: [String] = []

        func append(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !ordered.contains(trimmed) else { return }
            ordered.append(trimmed)
        }

        append(session.threadID)
        append(sessionActualName(session))
        append(sessionEffectiveTarget(session))
        append(session.preview)
        return ordered
    }

    private func loopTargetsAffectingSession(_ session: SessionSnapshot) -> [String] {
        let candidates = Set(sessionPossibleTargets(session))
        guard !candidates.isEmpty else { return [] }
        return loopSnapshots
            .map(\.target)
            .filter { candidates.contains($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func selectedLoopTarget() -> String? {
        let selectedRow = activeLoopsTableView.selectedRow
        guard selectedRow >= 0, selectedRow < loopSnapshots.count else { return nil }
        return loopSnapshots[selectedRow].target
    }

    private func restoreLoopSelection(preferredTarget: String?) {
        guard let preferredTarget else {
            activeLoopsTableView.deselectAll(nil)
            stopButton.isEnabled = false
            return
        }

        guard let row = loopSnapshots.firstIndex(where: { $0.target == preferredTarget }) else {
            activeLoopsTableView.deselectAll(nil)
            stopButton.isEnabled = false
            return
        }

        activeLoopsTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        activeLoopsTableView.scrollRowToVisible(row)
        stopButton.isEnabled = true
    }

    private func selectedSessionThreadID() -> String? {
        let selectedRow = sessionStatusTableView.selectedRow
        guard selectedRow >= 0, selectedRow < sessionSnapshots.count else { return nil }
        return sessionSnapshots[selectedRow].threadID
    }

    private func restoreSessionSelection(preferredThreadID: String?) {
        guard let preferredThreadID,
              let row = sessionSnapshots.firstIndex(where: { $0.threadID == preferredThreadID }) else {
            sessionStatusTableView.deselectAll(nil)
            updateSessionDetailView()
            return
        }

        sessionStatusTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        sessionStatusTableView.scrollRowToVisible(row)
        updateSessionDetailView()
    }

    private func parseThreadRuntimeStatus(_ raw: Any?) -> String {
        guard let object = raw as? [String: Any],
              let type = object["type"] as? String else {
            return "unknown"
        }
        if type == "active",
           let flags = object["activeFlags"] as? [String],
           !flags.isEmpty {
            return "active(\(flags.joined(separator: ",")))"
        }
        return type
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
            case "threadID":
                orderedAscending = lhs.threadID.localizedStandardCompare(rhs.threadID) == .orderedAscending
            case "status":
                orderedAscending = localizedSessionStatusLabel(lhs).localizedStandardCompare(localizedSessionStatusLabel(rhs)) == .orderedAscending
            case "terminalState":
                orderedAscending = localizedTerminalState(lhs.terminalState).localizedStandardCompare(localizedTerminalState(rhs.terminalState)) == .orderedAscending
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
        case "threadID":
            return lhs.threadID == rhs.threadID
        case "status":
            return localizedSessionStatusLabel(lhs) == localizedSessionStatusLabel(rhs)
        case "terminalState":
            return localizedTerminalState(lhs.terminalState) == localizedTerminalState(rhs.terminalState)
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

    private func localizedSessionStatusLabel(_ session: SessionSnapshot) -> String {
        if session.isArchived {
            return "已归档"
        }
        if session.terminalState == "unavailable" {
            return "断联"
        }

        switch session.status {
        case let status where status.hasPrefix("active"):
            return "运行中"
        case "idle_stable":
            return "空闲"
        case "interrupted_idle":
            return "中断后空闲"
        case "idle_with_residual_input":
            return "残留输入"
        case "queued_messages_visible":
            return "消息排队"
        case "rollout_stale":
            return "状态滞后"
        case "unknown":
            return "未知"
        default:
            return session.status
        }
    }

    private func localizedTerminalState(_ state: String) -> String {
        switch state {
        case "prompt_ready":
            return "可发送"
        case "prompt_with_input":
            return "有残留输入"
        case "busy":
            return "忙碌"
        case "unavailable":
            return "不可达"
        case "archived":
            return "已归档"
        default:
            return state
        }
    }

    private func sessionStatusColor(_ session: SessionSnapshot) -> NSColor {
        if session.isArchived {
            return .systemBlue
        }
        if session.terminalState == "unavailable" {
            return .systemRed
        }
        switch session.status {
        case let status where status.hasPrefix("active"):
            return .systemOrange
        case "idle_stable", "interrupted_idle":
            return .systemGreen
        case "idle_with_residual_input", "queued_messages_visible", "rollout_stale":
            return .systemYellow
        default:
            return .secondaryLabelColor
        }
    }

    private func sessionDetailText(for session: SessionSnapshot) -> String {
        let name = sessionActualName(session)
        var lines = [
            "Name: \(name.isEmpty ? "-" : name)",
            "Session ID: \(session.threadID)",
            "Archived: \(session.isArchived ? "yes" : "no")",
            "Status: \(localizedSessionStatusLabel(session))",
            "Terminal: \(localizedTerminalState(session.terminalState))",
            "TTY: \(session.tty.isEmpty ? "-" : session.tty)",
            "Updated: \(formatEpoch(session.updatedAtEpoch))",
            "原因: \(localizedSessionReason(session.reason))"
        ]
        let preview = session.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preview.isEmpty {
            lines.append("Preview: \(preview)")
        }
        return lines.joined(separator: "\n")
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
            archiveSessionButton.isEnabled = false
            restoreSessionButton.isEnabled = false
            deleteSessionButton.isEnabled = false
            sessionDetailView.string = "选中一条 session 后，这里会显示完整信息和提示词历史。"
            sessionDetailView.scrollToBeginningOfDocument(nil)
            return
        }

        let session = sessionSnapshots[selectedRow]
        renameField.stringValue = session.name
        renameField.isEnabled = !session.isArchived
        saveRenameButton.isEnabled = !session.isArchived
        archiveSessionButton.isEnabled = !session.isArchived
        restoreSessionButton.isEnabled = session.isArchived
        deleteSessionButton.isEnabled = true
        renameField.placeholderString = session.isArchived
            ? "已归档 session 需先恢复后再改名"
            : "输入新名称，留空可恢复为未 rename 状态"
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
        let detail = [result.stderr, result.stdout].first { !$0.isEmpty } ?? "归档 session 失败"
        return (false, detail)
    }

    private func unarchiveSession(threadID: String) -> (success: Bool, error: String) {
        let result = runStandardHelper(arguments: ["thread-unarchive", "-t", threadID])
        if result.status == 0 {
            return (true, "")
        }
        let detail = [result.stderr, result.stdout].first { !$0.isEmpty } ?? "恢复归档失败"
        return (false, detail)
    }

    private func deleteSessionPermanently(threadID: String) -> (success: Bool, detail: String) {
        let result = runStandardHelper(arguments: ["thread-delete", "-t", threadID])
        if result.status == 0 {
            return (true, result.stdout)
        }
        let detail = [result.stderr, result.stdout].first { !$0.isEmpty } ?? "彻底删除失败"
        return (false, detail)
    }

    private func selectSessionRow(threadID: String) {
        guard let row = sessionSnapshots.firstIndex(where: { $0.threadID == threadID }) else { return }
        sessionStatusTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        sessionStatusTableView.scrollRowToVisible(row)
    }

    private func applyInitialSplitRatiosIfNeeded() {
        if !didApplyInitialTopSplitRatio,
           topSplitView.subviews.count == 2,
           topSplitView.bounds.width > topSplitView.dividerThickness {
            setTopSplitRatio(0.5)
            didApplyInitialTopSplitRatio = true
            lastTopSplitWidth = topSplitView.bounds.width
        }

        if !didApplyInitialContentSplitRatio,
           contentSplitView.subviews.count == 2,
           contentSplitView.bounds.height > contentSplitView.dividerThickness {
            setContentSplitRatio(0.62)
            didApplyInitialContentSplitRatio = true
            lastContentSplitHeight = contentSplitView.bounds.height
        }
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

    private func preserveContentSplitRatioOnResizeIfNeeded() {
        guard contentSplitView.subviews.count == 2 else { return }
        let currentHeight = contentSplitView.bounds.height
        guard currentHeight > contentSplitView.dividerThickness else { return }

        defer { lastContentSplitHeight = currentHeight }

        guard didApplyInitialContentSplitRatio else { return }
        guard abs(currentHeight - lastContentSplitHeight) > 0.5 else { return }
        setContentSplitRatio(contentSplitRatio)
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

    private func setContentSplitRatio(_ ratio: CGFloat) {
        guard contentSplitView.subviews.count == 2 else { return }
        let availableHeight = contentSplitView.bounds.height - contentSplitView.dividerThickness
        guard availableHeight > 0 else { return }

        let clampedRatio = min(max(ratio, 0.18), 0.88)
        isApplyingContentSplitRatio = true
        contentSplitView.setPosition(availableHeight * clampedRatio, ofDividerAt: 0)
        contentSplitRatio = clampedRatio
        isApplyingContentSplitRatio = false
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

    private func updateContentSplitRatioFromCurrentLayout() {
        guard !isApplyingContentSplitRatio else { return }
        guard didApplyInitialContentSplitRatio else { return }
        guard contentSplitView.subviews.count == 2 else { return }
        let availableHeight = contentSplitView.bounds.height - contentSplitView.dividerThickness
        guard availableHeight > 0 else { return }
        let currentTopHeight = contentSplitView.subviews[0].frame.height
        contentSplitRatio = min(max(currentTopHeight / availableHeight, 0.18), 0.88)
    }

    private func localizedSessionReason(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let exactMappings: [String: String] = [
            "session is archived and can be restored": "该 session 已归档，可在当前列表中恢复",
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

    private func makePanel(title: String, metaLabel: NSTextField?, contentView: NSView, headerAccessoryView: NSView? = nil) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let titleStack = NSStackView(views: [titleLabel] + [metaLabel].compactMap { $0 })
        titleStack.orientation = .vertical
        titleStack.spacing = 2
        titleStack.alignment = .leading

        metaLabel?.font = .systemFont(ofSize: 11, weight: .regular)
        metaLabel?.textColor = .secondaryLabelColor
        metaLabel?.lineBreakMode = .byTruncatingTail

        let headerViews = [titleStack, headerAccessoryView].compactMap { $0 }
        let headerStack = NSStackView(views: headerViews)
        headerStack.orientation = .horizontal
        headerStack.spacing = 8
        headerStack.alignment = .firstBaseline
        headerStack.distribution = .fill

        titleStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerAccessoryView?.setContentHuggingPriority(.required, for: .horizontal)
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        headerStack.setContentHuggingPriority(.required, for: .vertical)
        headerStack.setContentCompressionResistancePriority(.required, for: .vertical)
        contentView.setContentHuggingPriority(.defaultLow, for: .vertical)
        contentView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let panelView = NSView()
        panelView.translatesAutoresizingMaskIntoConstraints = false
        panelView.addSubview(headerStack)
        panelView.addSubview(contentView)
        panelView.setContentHuggingPriority(.defaultLow, for: .vertical)
        panelView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: panelView.topAnchor),
            headerStack.leadingAnchor.constraint(equalTo: panelView.leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: panelView.trailingAnchor),

            contentView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 8),
            contentView.leadingAnchor.constraint(equalTo: panelView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: panelView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: panelView.bottomAnchor)
        ])

        return panelView
    }

    private func makeSplitPane(contentView: NSView, minWidth: CGFloat? = nil, minHeight: CGFloat? = nil) -> NSView {
        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = true
        pane.addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: pane.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: pane.bottomAnchor)
        ])

        if let minWidth {
            pane.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth).isActive = true
        }
        if let minHeight {
            pane.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight).isActive = true
        }

        pane.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pane.setContentHuggingPriority(.defaultLow, for: .vertical)
        pane.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pane.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return pane
    }

    private func makeFieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func normalizedHistory(_ values: [String], limit: Int = 10) -> [String] {
        var ordered: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !ordered.contains(trimmed) else { continue }
            ordered.append(trimmed)
            if ordered.count >= limit {
                break
            }
        }
        return ordered
    }

    private func loadHistoryState() {
        targetHistory = normalizedHistory(UserDefaults.standard.stringArray(forKey: DefaultsKey.targetHistory) ?? [])
        messageHistory = normalizedHistory(UserDefaults.standard.stringArray(forKey: DefaultsKey.messageHistory) ?? [])
        configureHistoryPopover()
    }

    private func configureHistoryPopover() {
        historyListView.translatesAutoresizingMaskIntoConstraints = false
        historyListView.wantsLayer = true
        historyListView.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        historyListView.frame = NSRect(x: 0, y: 0, width: 320, height: 10)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = historyListView
        scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 10)
        scrollView.autoresizingMask = [.width, .height]
        historyDropdownScrollView = scrollView

        let contentViewController = NSViewController()
        contentViewController.view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 10))
        contentViewController.view.wantsLayer = true
        contentViewController.view.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        contentViewController.view.addSubview(scrollView)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.contentViewController = contentViewController
        historyDropdownPanel = panel
    }

    private func historyValues(for kind: HistoryKind) -> [String] {
        switch kind {
        case .target:
            return targetHistory
        case .message:
            return messageHistory
        }
    }

    private func setHistoryValues(_ values: [String], for kind: HistoryKind) {
        let normalized = normalizedHistory(values)
        switch kind {
        case .target:
            targetHistory = normalized
            UserDefaults.standard.set(normalized, forKey: DefaultsKey.targetHistory)
        case .message:
            messageHistory = normalized
            UserDefaults.standard.set(normalized, forKey: DefaultsKey.messageHistory)
        }
        if isHistoryDropdownShown(), historyPopoverKind == kind {
            rebuildHistoryPopover(kind: kind)
        }
    }

    private func addHistoryValue(_ value: String, kind: HistoryKind) {
        let updated = [value] + historyValues(for: kind)
        setHistoryValues(updated, for: kind)
    }

    private func removeHistoryValue(_ value: String, kind: HistoryKind) {
        let updated = historyValues(for: kind).filter { $0 != value }
        setHistoryValues(updated, for: kind)
    }

    private func clearHistory(kind: HistoryKind) {
        setHistoryValues([], for: kind)
    }

    private func historyControl(for kind: HistoryKind) -> NSTextField {
        switch kind {
        case .target:
            return targetField
        case .message:
            return messageField
        }
    }

    private func historyButton(for kind: HistoryKind) -> NSButton {
        switch kind {
        case .target:
            return targetHistoryButton
        case .message:
            return messageHistoryButton
        }
    }

    private func historyAnchorView(for kind: HistoryKind) -> NSView {
        historyControl(for: kind)
    }

    private func historyDropdownWidth(for kind: HistoryKind) -> CGFloat {
        let control = historyControl(for: kind)
        control.layoutSubtreeIfNeeded()
        return max(220, control.bounds.width)
    }

    private func installHistoryKeyMonitor() {
        removeHistoryKeyMonitor()
        historyKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isHistoryDropdownShown() else { return event }

            switch event.keyCode {
            case 125:
                self.moveHistoryHighlight(delta: 1)
                return nil
            case 126:
                self.moveHistoryHighlight(delta: -1)
                return nil
            case 36, 76:
                self.activateHighlightedHistoryRow()
                return nil
            case 53:
                self.closeHistoryDropdown()
                return nil
            default:
                return event
            }
        }
    }

    private func removeHistoryKeyMonitor() {
        if let historyKeyMonitor {
            NSEvent.removeMonitor(historyKeyMonitor)
            self.historyKeyMonitor = nil
        }
    }

    private func installHistoryOutsideMonitors(anchorView: NSView) {
        removeHistoryOutsideMonitors()

        historyOutsideLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, self.isHistoryDropdownShown() else { return event }
            guard let panel = self.historyDropdownPanel else { return event }

            if let window = event.window, window == panel {
                return event
            }

            let eventLocation = NSEvent.mouseLocation
            if panel.frame.contains(eventLocation) {
                return event
            }

            if let window = anchorView.window {
                let anchorRectInWindow = anchorView.convert(anchorView.bounds, to: nil)
                let anchorRectOnScreen = window.convertToScreen(anchorRectInWindow)
                if anchorRectOnScreen.contains(eventLocation) {
                    return event
                }
            }

            self.closeHistoryDropdown()
            return event
        }

        historyOutsideGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.closeHistoryDropdown()
            }
        }
    }

    private func removeHistoryOutsideMonitors() {
        if let historyOutsideLocalMonitor {
            NSEvent.removeMonitor(historyOutsideLocalMonitor)
            self.historyOutsideLocalMonitor = nil
        }
        if let historyOutsideGlobalMonitor {
            NSEvent.removeMonitor(historyOutsideGlobalMonitor)
            self.historyOutsideGlobalMonitor = nil
        }
    }

    private func isHistoryDropdownShown() -> Bool {
        historyDropdownPanel?.isVisible == true
    }

    private func closeHistoryDropdown() {
        historyDropdownPanel?.orderOut(nil)
        removeHistoryKeyMonitor()
        removeHistoryOutsideMonitors()
        historyHighlightedIndex = -1
        historyRowViews.forEach { $0.setHighlighted(false) }
    }

    private func setHistoryHighlightedIndex(_ index: Int) {
        historyHighlightedIndex = index
        for (rowIndex, rowView) in historyRowViews.enumerated() {
            rowView.setHighlighted(rowIndex == index)
        }
    }

    private func moveHistoryHighlight(delta: Int) {
        guard !historyRowViews.isEmpty else { return }
        let nextIndex: Int
        if historyHighlightedIndex < 0 {
            nextIndex = delta >= 0 ? 0 : historyRowViews.count - 1
        } else {
            nextIndex = max(0, min(historyRowViews.count - 1, historyHighlightedIndex + delta))
        }
        setHistoryHighlightedIndex(nextIndex)
    }

    private func activateHighlightedHistoryRow() {
        guard historyHighlightedIndex >= 0, historyHighlightedIndex < historyRowViews.count else { return }
        historyRowViews[historyHighlightedIndex].onSelect?()
    }

    private func historyDropdownHeight(for rowCount: Int) -> CGFloat {
        CGFloat(min(max(1, rowCount), 8) * 22)
    }

    private func layoutHistoryRows(width: CGFloat) {
        var y: CGFloat = 0
        for row in historyRowViews {
            row.frame = NSRect(x: 0, y: y, width: width, height: 22)
            y += 22
        }

        for subview in historyListView.subviews where !(subview is HistoryDropdownRowView) {
            subview.frame = NSRect(x: 8, y: 4, width: max(0, width - 16), height: 18)
            y = max(y, subview.frame.maxY + 4)
        }

        historyListView.frame = NSRect(x: 0, y: 0, width: width, height: max(y, 22))
        historyDropdownScrollView?.frame = NSRect(x: 0, y: 0, width: width, height: historyDropdownScrollView?.frame.height ?? 10)
        historyDropdownScrollView?.documentView = historyListView
    }

    private func rebuildHistoryPopover(kind: HistoryKind) {
        historyPopoverKind = kind
        historyRowViews = []
        historyHighlightedIndex = -1
        historyListView.subviews.forEach { subview in
            subview.removeFromSuperview()
        }

        let values = historyValues(for: kind)
        var renderedRowCount = 0

        for value in values {
            let row = HistoryDropdownRowView()
            row.configure(title: value, isClearAction: false, canDelete: true)
            row.onHover = { [weak self, weak row] in
                guard let self, let row else { return }
                if let index = self.historyRowViews.firstIndex(where: { $0 === row }) {
                    self.setHistoryHighlightedIndex(index)
                }
            }
            row.onSelect = { [weak self] in
                guard let self else { return }
                self.historyControl(for: kind).stringValue = value
                self.setStatus(kind == .target ? "已填入最近目标" : "已填入最近消息", key: "general")
                self.closeHistoryDropdown()
            }
            row.onDelete = { [weak self] in
                guard let self else { return }
                self.removeHistoryValue(value, kind: kind)
                self.rebuildHistoryPopover(kind: kind)
                self.setStatus(kind == .target ? "已删除一条目标历史" : "已删除一条消息历史", key: "general")
            }
            historyListView.addSubview(row)
            historyRowViews.append(row)
            renderedRowCount += 1
        }

        if !values.isEmpty {
            let clearRow = HistoryDropdownRowView()
            clearRow.configure(title: kind.clearLabel, isClearAction: true, canDelete: false)
            clearRow.onHover = { [weak self, weak clearRow] in
                guard let self, let clearRow else { return }
                if let index = self.historyRowViews.firstIndex(where: { $0 === clearRow }) {
                    self.setHistoryHighlightedIndex(index)
                }
            }
            clearRow.onSelect = { [weak self] in
                guard let self else { return }
                self.clearHistory(kind: kind)
                self.setStatus(kind == .target ? "最近目标已清空" : "最近消息已清空", key: "general")
                self.closeHistoryDropdown()
            }
            historyListView.addSubview(clearRow)
            historyRowViews.append(clearRow)
            renderedRowCount += 1
        } else {
            let emptyLabel = NSTextField(labelWithString: "暂无历史")
            emptyLabel.font = .systemFont(ofSize: 12)
            emptyLabel.textColor = .secondaryLabelColor
            emptyLabel.alignment = .left
            historyListView.addSubview(emptyLabel)
            renderedRowCount = 1
        }

        let rowCount = max(1, renderedRowCount)
        let width = historyDropdownPanel?.frame.width ?? 320
        let height = historyDropdownHeight(for: rowCount)
        layoutHistoryRows(width: width)
        historyDropdownPanel?.contentViewController?.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        historyDropdownScrollView?.frame = NSRect(x: 0, y: 0, width: width, height: height)
        historyDropdownPanel?.setContentSize(NSSize(width: width, height: height))
    }

    private func toggleHistoryDropdown(kind: HistoryKind) {
        let anchorView = historyAnchorView(for: kind)
        if isHistoryDropdownShown(), historyPopoverKind == kind {
            closeHistoryDropdown()
            return
        }

        let width = historyDropdownWidth(for: kind)
        historyDropdownPanel?.contentViewController?.view.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        historyDropdownScrollView?.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        historyDropdownPanel?.setContentSize(NSSize(width: width, height: 10))
        rebuildHistoryPopover(kind: kind)
        guard let panel = historyDropdownPanel,
              let window = anchorView.window else { return }
        let anchorRectInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let anchorRectOnScreen = window.convertToScreen(anchorRectInWindow)
        let height = panel.frame.height
        let origin = NSPoint(x: anchorRectOnScreen.minX, y: anchorRectOnScreen.minY - height + 1)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
        panel.orderFront(nil)
        installHistoryKeyMonitor()
        installHistoryOutsideMonitors(anchorView: anchorView)
        if !historyRowViews.isEmpty {
            setHistoryHighlightedIndex(0)
        }
    }

    @objc
    private func toggleTargetHistoryDropdown() {
        toggleHistoryDropdown(kind: .target)
    }

    @objc
    private func toggleMessageHistoryDropdown() {
        toggleHistoryDropdown(kind: .message)
    }

    private func makeHistoryArrowButton(action: Selector) -> NSButton {
        let button = NSButton(title: "▾", target: self, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        return button
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

    @objc
    private func clearActivityLog() {
        outputView.string = ""
        outputView.needsDisplay = true
        setStatus("日志已清空", key: "general")
    }

    @objc
    private func saveActivityLog() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "codex_taskmaster_log_\(Self.logFilenameFormatter.string(from: Date())).log"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try outputView.string.write(to: url, atomically: true, encoding: .utf8)
                setStatus("日志已保存到 \(url.lastPathComponent)", key: "general")
            } catch {
                NSSound.beep()
                appendOutput("stderr: 保存日志失败: \(error.localizedDescription)")
                setStatus("保存日志失败", key: "general")
            }
        }
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
                    rolloutPath: current["rollout_path"] ?? "",
                    preview: "",
                    isArchived: false
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

    private func parseThreadListOutput(_ output: String, archived: Bool) -> [SessionSnapshot] {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["data"] as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            guard let threadID = item["id"] as? String else {
                return nil
            }

            let updatedAtValue = item["updatedAt"]
            let updatedAtEpoch: String
            if let intValue = updatedAtValue as? Int {
                updatedAtEpoch = String(intValue)
            } else if let doubleValue = updatedAtValue as? Double {
                updatedAtEpoch = String(Int(doubleValue))
            } else if let stringValue = updatedAtValue as? String {
                updatedAtEpoch = stringValue
            } else {
                updatedAtEpoch = "0"
            }

            return SessionSnapshot(
                name: item["name"] as? String ?? "",
                target: threadID,
                threadID: threadID,
                status: archived ? "archived" : parseThreadRuntimeStatus(item["status"]),
                reason: archived ? "session is archived and can be restored" : "",
                terminalState: archived ? "archived" : "unavailable",
                tty: "",
                updatedAtEpoch: updatedAtEpoch,
                rolloutPath: item["path"] as? String ?? "",
                preview: item["preview"] as? String ?? "",
                isArchived: archived
            )
        }
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
        let selectedThreadID = selectedSessionThreadID()
        if sessionSnapshots.isEmpty {
            if isSessionScanRunning, let scannedCount, let totalCount {
                sessionStatusMetaLabel.stringValue = "视图: \(sessionScopeText()) | 正在扫描 \(scannedCount)/\(totalCount)…"
            } else {
                sessionStatusMetaLabel.stringValue = sessionEmptyStateText()
            }
            sessionStatusTableView.reloadData()
            updateSessionDetailView()
            return
        }

        let refreshedAt = Self.timestampFormatter.string(from: Date())
        if let scannedCount, let totalCount {
            let progressText = isComplete ? "已扫描: \(scannedCount)/\(totalCount)" : "扫描中: \(scannedCount)/\(totalCount)"
            sessionStatusMetaLabel.stringValue = "视图: \(sessionScopeText()) | 已加载: \(sessionSnapshots.count) | \(progressText) | 总数: \(totalCount) | 刷新: \(refreshedAt)"
        } else {
            sessionStatusMetaLabel.stringValue = "视图: \(sessionScopeText()) | 已加载: \(sessionSnapshots.count) | 刷新: \(refreshedAt)"
        }
        applySessionSorting()
        sessionStatusTableView.reloadData()
        restoreSessionSelection(preferredThreadID: selectedThreadID)
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

    private func shouldAutoClearResidualInput(probeStatus: String, terminalState: String) -> Bool {
        probeStatus == "idle_with_residual_input" && terminalState == "prompt_with_input"
    }

    private func isSendableProbeState(probeStatus: String, terminalState: String) -> Bool {
        if terminalState == "prompt_ready" && (probeStatus == "idle_stable" || probeStatus == "interrupted_idle") {
            return true
        }
        if shouldAutoClearResidualInput(probeStatus: probeStatus, terminalState: terminalState) {
            return true
        }
        return false
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
        let rawTTY = initialProbe.values["tty"] ?? ""
        let tty = rawTTY == "-" ? "" : rawTTY
        let previousUserTimestamp = initialProbe.values["last_user_message_at"] ?? ""
        let clearResidualInputBeforeSend = !forceSend && shouldAutoClearResidualInput(probeStatus: probeStatus, terminalState: terminalState)
        let sendableByState = isSendableProbeState(probeStatus: probeStatus, terminalState: terminalState)
        guard !tty.isEmpty else {
            logActivity("发送请求失败: status=failed reason=tty_unavailable target=\(target) force_send=\(forceSend ? "yes" : "no") probe_status=\(probeStatus) terminal_state=\(terminalState) detail=\(compactProbeSummary(initialProbe))")
            finish(with: [
                "status": "failed",
                "reason": "tty_unavailable",
                "target": target,
                "force_send": forceSend,
                "detail": compactProbeSummary(initialProbe),
                "probe_status": probeStatus,
                "terminal_state": terminalState
            ])
            return
        }
        guard forceSend || sendableByState else {
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
                try self.sendViaAppKeystrokes(
                    ttyPath: ttyPath,
                    message: message,
                    clearExistingInput: clearResidualInputBeforeSend
                )
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
            let detail = "sent message via app sender to target=\(target) tty=\(tty) clear_existing_input=\(clearResidualInputBeforeSend ? "yes" : "no")"
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
          repeat with attempt from 1 to 6
            tell application "Terminal" to activate
            delay 0.05

            tell application "Terminal"
              repeat with w in windows
                try
                  repeat with t in tabs of w
                    if (tty of t) is equal to targetTTY then
                      set selected tab of w to t
                      set index of w to 1
                      exit repeat
                    end if
                  end repeat
                end try
              end repeat
            end tell

            delay 0.10

            tell application "System Events"
              try
                set frontAppName to name of first application process whose frontmost is true
              on error
                set frontAppName to ""
              end try
            end tell

            if frontAppName is equal to "Terminal" then
              tell application "Terminal"
                try
                  if (tty of selected tab of front window) is equal to targetTTY then
                    return "ok"
                  end if
                end try
              end tell
            end if
          end repeat
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
        usleep(120_000)
    }

    private func clearPromptInputIfNeeded() throws {
        try postKey(53)
        usleep(100_000)
        try postKey(32, flags: .maskControl)
        usleep(220_000)
    }

    private func sendViaAppKeystrokes(ttyPath: String, message: String, clearExistingInput: Bool) throws {
        guard ensureAccessibilityTrust(prompt: true) else {
            throw NSError(domain: "CodexTaskmaster", code: 5, userInfo: [NSLocalizedDescriptionKey: "Codex Taskmaster 没有辅助功能权限，无法发送按键"])
        }

        try focusTerminalWindow(for: ttyPath)

        if clearExistingInput {
            try clearPromptInputIfNeeded()
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)

        usleep(250_000)
        try postKey(9, flags: .maskCommand)
        usleep(350_000)
        try postKey(36)
        usleep(250_000)
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
                    if actionName == "发送一次" || actionName == "开始循环" {
                        self.recordCurrentInputsInHistory()
                    }
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

    private func conflictingLoops(for target: String) -> [LoopSnapshot] {
        let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTarget.isEmpty else { return [] }

        if let session = sessionSnapshots.first(where: { sessionPossibleTargets($0).contains(trimmedTarget) }) {
            let targets = Set(loopTargetsAffectingSession(session))
            return loopSnapshots.filter { targets.contains($0.target) }
        }

        return loopSnapshots.filter { $0.target == trimmedTarget }
    }

    private func promptToReplaceExistingLoops(conflicts: [LoopSnapshot], target: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "检测到已有循环"
        let conflictList = conflicts.map(\.target).joined(separator: "、")
        alert.informativeText = "目标 \(target) 已存在运行中的循环：\(conflictList)。为避免重复发送，只能保留一个循环。是否先停止旧循环，再启动新的循环？"
        alert.addButton(withTitle: "替换旧循环")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func recordCurrentInputsInHistory() {
        let target = currentTarget()
        let message = currentMessage()
        if !target.isEmpty {
            addHistoryValue(target, kind: .target)
        }
        if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addHistoryValue(message, kind: .message)
        }
    }

    private func runLoopReplacement(target: String, interval: String, message: String, forceSend: Bool, conflicts: [LoopSnapshot]) {
        persistDefaults()
        setButtonsEnabled(false)
        setStatus("开始循环执行中…", key: "action")

        var displayArguments = ["start", "-t", target, "-i", interval, "-m", message]
        if forceSend {
            displayArguments.append("-f")
        }
        appendOutput("执行 开始循环: \(displayArguments.joined(separator: " "))")
        appendOutput("检测到循环冲突，先停止旧循环: \(conflicts.map(\.target).joined(separator: ", "))")

        DispatchQueue.global(qos: .userInitiated).async {
            var failureText: String?

            for conflict in conflicts {
                let stopResult = self.runStandardHelper(arguments: ["stop", "-t", conflict.target])
                if stopResult.status != 0 {
                    failureText = [stopResult.stderr, stopResult.stdout].first(where: { !$0.isEmpty }) ?? "停止旧循环失败"
                    break
                }
            }

            let startResult: (status: Int32, stdout: String, stderr: String)
            if let failureText {
                startResult = (1, "", failureText)
            } else {
                var arguments = ["start", "-t", target, "-i", interval, "-m", message]
                if forceSend {
                    arguments.append("-f")
                }
                startResult = self.runStandardHelper(arguments: arguments)
            }

            DispatchQueue.main.async {
                if !startResult.stdout.isEmpty {
                    self.appendOutput(startResult.stdout)
                }
                if !startResult.stderr.isEmpty {
                    self.appendOutput("stderr: \(startResult.stderr)")
                }
                if startResult.status == 0 {
                    self.recordCurrentInputsInHistory()
                    self.setStatus("开始循环完成", key: "action")
                } else {
                    self.setStatus("开始循环失败", key: "action")
                }
                self.setButtonsEnabled(true)
                self.refreshLoopsSnapshot()
            }
        }
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
            sessionStatusMetaLabel.stringValue = "视图: \(sessionScopeText()) | 检测已停止。"
            sessionStatusTableView.reloadData()
        }
    }

    private func refreshLoopsSnapshot() {
        DispatchQueue.global(qos: .utility).async {
            let selectedTarget = DispatchQueue.main.sync {
                self.selectedLoopTarget()
            }
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
                self.restoreLoopSelection(preferredTarget: selectedTarget)
            }
        }
    }

    private func refreshSessionStatuses() {
        if isSessionScanRunning {
            stopSessionStatusScan()
            return
        }

        if currentSessionListMode() == .archived {
            refreshArchivedSessions()
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
        sessionStatusMetaLabel.stringValue = "视图: 普通 | 正在准备扫描…"
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
                    self.sessionStatusMetaLabel.stringValue = "视图: 普通 | 检测状态失败: \(countResult.stderr.isEmpty ? countResult.stdout : countResult.stderr)"
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
                    self.sessionStatusMetaLabel.stringValue = "视图: 普通 | 没有可扫描的 session。"
                    self.sessionStatusTableView.reloadData()
                    self.setStatus("检测状态完成", key: "scan")
                } else {
                    self.sessionStatusMetaLabel.stringValue = "视图: 普通 | 正在扫描 0/\(totalCount)…"
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

    private func refreshArchivedSessions() {
        isSessionScanRunning = true
        sessionScanShouldStop = false
        sessionScanGeneration += 1
        let generation = sessionScanGeneration
        sessionScanTotal = 0
        updateDetectStatusButtonState()
        setStatus("读取已归档 session 中…", key: "scan")
        appendOutput("执行 检测状态: thread-list --archived")
        sessionSnapshots = []
        sessionStatusMetaLabel.stringValue = "视图: 已归档 | 正在读取列表…"
        sessionStatusTableView.reloadData()

        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.runInterruptibleSessionHelper(arguments: ["thread-list", "--archived"])

            if self.sessionScanShouldStop || self.sessionScanGeneration != generation {
                return
            }

            DispatchQueue.main.async {
                guard self.sessionScanGeneration == generation else { return }
                self.isSessionScanRunning = false
                self.updateDetectStatusButtonState()

                if result.status != 0 {
                    self.sessionSnapshots = []
                    self.sessionStatusMetaLabel.stringValue = "视图: 已归档 | 读取失败: \(result.stderr.isEmpty ? result.stdout : result.stderr)"
                    self.sessionStatusTableView.reloadData()
                    self.updateSessionDetailView()
                    self.setStatus("读取已归档 session 失败", key: "scan")
                    if !result.stderr.isEmpty {
                        self.appendOutput("stderr: \(result.stderr)")
                    }
                    return
                }

                let snapshots = self.parseThreadListOutput(result.stdout, archived: true)
                self.sessionSnapshots = snapshots
                self.sessionScanTotal = snapshots.count
                self.renderSessionSnapshots(scannedCount: snapshots.count, totalCount: snapshots.count, isComplete: true)
                self.setStatus("已加载已归档 session", key: "scan")
                self.appendOutput("检测到 \(snapshots.count) 个已归档 session。")
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

        let conflicts = conflictingLoops(for: target)
        if !conflicts.isEmpty {
            guard promptToReplaceExistingLoops(conflicts: conflicts, target: target) else {
                appendOutput("已取消开始循环：检测到互斥循环未替换。")
                setStatus("开始循环已取消", key: "action")
                return
            }
            runLoopReplacement(
                target: target,
                interval: interval,
                message: currentMessage(),
                forceSend: isForceSendEnabled(),
                conflicts: conflicts
            )
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
    private func changeSessionScope() {
        if isSessionScanRunning {
            stopSessionStatusScan()
        }
        sessionSnapshots = []
        sessionScanTotal = 0
        sessionStatusTableView.deselectAll(nil)
        sessionStatusTableView.reloadData()
        sessionStatusMetaLabel.stringValue = sessionEmptyStateText()
        updateSessionDetailView()
        setStatus("当前视图切换为\(sessionScopeText())", key: "scan")
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
        addHistoryValue(value, kind: .target)
        setStatus("已从 Session Status 填入 \(value)")
        if sessionActualName(session).isEmpty {
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
        guard !session.isArchived else {
            appendOutput("已归档 session 不能直接改名，请先恢复归档。")
            setStatus("请先恢复归档", key: "action")
            NSSound.beep()
            return
        }
        let newName = renameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        saveRenameButton.isEnabled = false
        archiveSessionButton.isEnabled = false
        restoreSessionButton.isEnabled = false
        deleteSessionButton.isEnabled = false
        renameField.isEnabled = false
        setStatus("保存名称中…", key: "action")
        appendOutput("执行 保存名称: thread_id=\(session.threadID) name=\(newName.isEmpty ? "<empty>" : newName)")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.updateSessionName(threadID: session.threadID, newName: newName)

            DispatchQueue.main.async {
                self.saveRenameButton.isEnabled = true
                self.renameField.isEnabled = true
                self.archiveSessionButton.isEnabled = self.sessionStatusTableView.selectedRow >= 0
                self.restoreSessionButton.isEnabled = false
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
                            rolloutPath: previous.rolloutPath,
                            preview: previous.preview,
                            isArchived: previous.isArchived
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
    private func archiveSelectedSession() {
        let selectedRow = sessionStatusTableView.selectedRow
        guard selectedRow >= 0, selectedRow < sessionSnapshots.count else {
            appendOutput("请先选择一条 session，再归档。")
            setStatus("请选择一个 session")
            NSSound.beep()
            return
        }

        let session = sessionSnapshots[selectedRow]
        guard !session.isArchived else {
            appendOutput("这条 session 已经归档。")
            setStatus("该 session 已归档", key: "action")
            NSSound.beep()
            return
        }
        let matchingLoopTargets = loopTargetsAffectingSession(session)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "归档这个 Session？"
        var informativeText = """
        这会调用 Codex 原生的 thread/archive。
        归档后该 session 会从当前非归档列表中消失，但后续仍可恢复。

        Session ID: \(session.threadID)
        Target: \(sessionEffectiveTarget(session))
        """
        if !matchingLoopTargets.isEmpty {
            informativeText += """

            
            警告：当前有循环任务仍可能指向这个 session：
            \(matchingLoopTargets.joined(separator: ", "))
            归档后这些循环不会自动停止。
            """
        }
        alert.informativeText = informativeText
        alert.addButton(withTitle: "归档")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        saveRenameButton.isEnabled = false
        archiveSessionButton.isEnabled = false
        restoreSessionButton.isEnabled = false
        deleteSessionButton.isEnabled = false
        renameField.isEnabled = false
        setStatus("归档 Session 中…", key: "action")
        appendOutput("执行 归档 Session: thread_id=\(session.threadID)")

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
                    self.setStatus("归档 Session 完成", key: "action")
                    self.appendOutput("已归档 session: \(session.threadID)")
                    self.refreshLoopsSnapshot()
                } else {
                    self.renameField.isEnabled = self.sessionStatusTableView.selectedRow >= 0
                    self.saveRenameButton.isEnabled = self.sessionStatusTableView.selectedRow >= 0
                    self.archiveSessionButton.isEnabled = self.sessionStatusTableView.selectedRow >= 0
                    self.restoreSessionButton.isEnabled = false
                    self.deleteSessionButton.isEnabled = self.sessionStatusTableView.selectedRow >= 0
                    self.setStatus("归档 Session 失败", key: "action")
                    self.appendOutput("stderr: \(result.error)")
                    NSSound.beep()
                }
            }
        }
    }

    @objc
    private func restoreSelectedSession() {
        let selectedRow = sessionStatusTableView.selectedRow
        guard selectedRow >= 0, selectedRow < sessionSnapshots.count else {
            appendOutput("请先选择一条已归档 session，再恢复。")
            setStatus("请选择一个 session")
            NSSound.beep()
            return
        }

        let session = sessionSnapshots[selectedRow]
        guard session.isArchived else {
            appendOutput("当前选择的 session 不在已归档列表中。")
            setStatus("请选择已归档 session", key: "action")
            NSSound.beep()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "恢复这个已归档 Session？"
        alert.informativeText = """
        这会调用 Codex 原生的 thread/unarchive。
        恢复后该 session 会重新回到普通 session 列表中。

        Session ID: \(session.threadID)
        Name: \(sessionActualName(session).isEmpty ? "-" : sessionActualName(session))
        """
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        saveRenameButton.isEnabled = false
        archiveSessionButton.isEnabled = false
        restoreSessionButton.isEnabled = false
        deleteSessionButton.isEnabled = false
        renameField.isEnabled = false
        setStatus("恢复归档中…", key: "action")
        appendOutput("执行 恢复归档: thread_id=\(session.threadID)")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.unarchiveSession(threadID: session.threadID)

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
                    self.setStatus("恢复归档完成", key: "action")
                    self.appendOutput("已恢复归档 session: \(session.threadID)")
                    self.refreshLoopsSnapshot()
                } else {
                    self.renameField.isEnabled = false
                    self.saveRenameButton.isEnabled = false
                    self.archiveSessionButton.isEnabled = false
                    self.restoreSessionButton.isEnabled = self.sessionStatusTableView.selectedRow >= 0
                    self.deleteSessionButton.isEnabled = self.sessionStatusTableView.selectedRow >= 0
                    self.setStatus("恢复归档失败", key: "action")
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
        let matchingLoopTargets = loopTargetsAffectingSession(session)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "彻底删除这个 Session？"
        var informativeText = """
        这是本地不可恢复删除，不是 Codex 当前公开的原生 archive/unarchive 语义。
        删除后会尝试同时移除：
        - state_5.sqlite 中的 thread 记录
        - 相关的本地扩展状态和结构化 thread 日志
        - session_index.jsonl 中对应的 rename/name 记录
        - 当前 rollout 文件（无论在 sessions 还是 archived_sessions）

        已知风险：
        - 目前没有公开的 Codex 原生永久删除 API，这是一种本地硬删除
        - 删除后通常无法恢复
        - 如果未来 Codex 增加了新的本地索引格式，这里可能删不全

        Session ID: \(session.threadID)
        Name: \(sessionActualName(session).isEmpty ? "-" : sessionActualName(session))
        当前路径: \(session.rolloutPath.isEmpty ? "-" : session.rolloutPath)
        """
        if !matchingLoopTargets.isEmpty {
            informativeText += """

            
            警告：当前有循环任务仍可能指向这个 session：
            \(matchingLoopTargets.joined(separator: ", "))
            删除后这些循环不会自动停止，后续只会继续失败或延期。
            """
        }
        alert.informativeText = informativeText
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        saveRenameButton.isEnabled = false
        archiveSessionButton.isEnabled = false
        restoreSessionButton.isEnabled = false
        deleteSessionButton.isEnabled = false
        renameField.isEnabled = false
        setStatus("彻底删除中…", key: "action")
        appendOutput("执行 彻底删除: thread_id=\(session.threadID)")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.deleteSessionPermanently(threadID: session.threadID)

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
                    self.setStatus("彻底删除完成", key: "action")
                    self.appendOutput(result.detail.isEmpty ? "已彻底删除 session: \(session.threadID)" : result.detail)
                    self.refreshLoopsSnapshot()
                } else {
                    self.updateSessionDetailView()
                    self.setStatus("彻底删除失败", key: "action")
                    self.appendOutput("stderr: \(result.detail)")
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
        case "threadID":
            textField.stringValue = session.threadID
        case "status":
            textField.stringValue = "● \(localizedSessionStatusLabel(session))"
            textField.textColor = sessionStatusColor(session)
        case "terminalState":
            textField.stringValue = localizedTerminalState(session.terminalState)
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
        guard let splitView = notification.object as? NSSplitView else { return }
        if splitView == topSplitView {
            let widthDelta = abs(topSplitView.bounds.width - lastTopSplitWidth)
            if widthDelta <= 0.5 {
                updateTopSplitRatioFromCurrentLayout()
            }
        } else if splitView == contentSplitView {
            let heightDelta = abs(contentSplitView.bounds.height - lastContentSplitHeight)
            if heightDelta <= 0.5 {
                updateContentSplitRatioFromCurrentLayout()
            }
        }
    }

    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        guard splitView == topSplitView || splitView == contentSplitView else {
            return proposedEffectiveRect
        }

        if splitView.isVertical {
            return drawnRect.insetBy(dx: -5, dy: 0)
        }
        return drawnRect.insetBy(dx: 0, dy: -6)
    }

    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView == topSplitView {
            let availableWidth = splitView.bounds.width - splitView.dividerThickness
            guard availableWidth > 0 else { return proposedPosition }
            let minLeading: CGFloat = 260
            let minTrailing: CGFloat = 220
            return min(max(proposedPosition, minLeading), availableWidth - minTrailing)
        }

        if splitView == contentSplitView {
            let availableHeight = splitView.bounds.height - splitView.dividerThickness
            guard availableHeight > 0 else { return proposedPosition }
            let minTop = LayoutMetrics.topPaneMinHeight
            let minBottom = LayoutMetrics.bottomPaneMinHeight
            return min(max(proposedPosition, minTop), availableHeight - minBottom)
        }

        return proposedPosition
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

    private static let logFilenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()
}

let app = NSApplication.shared
let delegate = CodexBianCeZheApp()
app.delegate = delegate
app.run()
