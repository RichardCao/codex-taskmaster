import AppKit
import ApplicationServices
import UniformTypeIdentifiers

private let userHomeDirectory = NSHomeDirectory()
private let autoRefreshInterval: TimeInterval = 3
private let requestPollInterval: TimeInterval = 0.5
private let stateDirectoryPath = "\(userHomeDirectory)/.codex-terminal-sender"
private let codexStateDatabasePath = "\(userHomeDirectory)/.codex/state_5.sqlite"
private let codexConfigPath = "\(userHomeDirectory)/.codex/config.toml"
private let codexSessionIndexPath = "\(userHomeDirectory)/.codex/session_index.jsonl"
private let pendingRequestDirectoryPath = "\(stateDirectoryPath)/requests/pending"
private let processingRequestDirectoryPath = "\(stateDirectoryPath)/requests/processing"
private let resultRequestDirectoryPath = "\(stateDirectoryPath)/requests/results"
private let sessionProbeInitialBatchSize = 4
private let sessionProbeBatchSize = 12
private let sessionPromptSearchEntryLimit = 12

private func chevronDownImage(pointSize: CGFloat = 11, weight: NSFont.Weight = .medium) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    return NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(config)
}

private func chevronUpImage(pointSize: CGFloat = 11, weight: NSFont.Weight = .medium) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    return NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil)?.withSymbolConfiguration(config)
}

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

protocol SessionStatusHeaderFilterDelegate: AnyObject {
    func sessionHeaderSupportsFilter(for columnIdentifier: String) -> Bool
    func sessionHeaderFilterIsActive(for columnIdentifier: String) -> Bool
    func sessionHeaderFilterIsShown(for columnIdentifier: String) -> Bool
    func toggleSessionHeaderFilter(for columnIdentifier: String, columnRect: NSRect, in headerView: NSTableHeaderView)
}

final class SessionStatusHeaderView: NSTableHeaderView {
    weak var filterDelegate: SessionStatusHeaderFilterDelegate?

    private func filterIndicatorRect(for columnRect: NSRect) -> NSRect {
        let width: CGFloat = 16
        let height: CGFloat = 14
        let x = max(columnRect.minX + 18, columnRect.maxX - 46)
        return NSRect(x: x, y: columnRect.midY - (height / 2), width: width, height: height)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let columnIndex = column(at: point)
        if columnIndex >= 0,
           let tableView,
           columnIndex < tableView.tableColumns.count {
            let column = tableView.tableColumns[columnIndex]
            let identifier = column.identifier.rawValue
            if filterDelegate?.sessionHeaderSupportsFilter(for: identifier) == true {
                let rect = headerRect(ofColumn: columnIndex)
                let indicatorRect = filterIndicatorRect(for: rect)
                let hotzoneRect = indicatorRect.insetBy(dx: -3, dy: -2)
                if hotzoneRect.contains(point) {
                    filterDelegate?.toggleSessionHeaderFilter(for: identifier, columnRect: rect, in: self)
                    return
                }
            }
        }

        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let tableView else { return }
        for (index, column) in tableView.tableColumns.enumerated() {
            let identifier = column.identifier.rawValue
            guard filterDelegate?.sessionHeaderSupportsFilter(for: identifier) == true else { continue }

            let rect = headerRect(ofColumn: index)
            guard rect.intersects(dirtyRect) else { continue }

            let indicatorRect = filterIndicatorRect(for: rect)
            let isActive = filterDelegate?.sessionHeaderFilterIsActive(for: identifier) == true
            let indicatorPath = NSBezierPath(roundedRect: indicatorRect, xRadius: 4, yRadius: 4)
            NSColor.quaternaryLabelColor.withAlphaComponent(0.08).setFill()
            indicatorPath.fill()
            NSColor.quaternaryLabelColor.withAlphaComponent(0.16).setStroke()
            indicatorPath.lineWidth = 1
            indicatorPath.stroke()

            let chevronRect = NSRect(x: indicatorRect.midX - 4, y: indicatorRect.midY - 3, width: 8, height: 8)
            let image = filterDelegate?.sessionHeaderFilterIsShown(for: identifier) == true
                ? chevronUpImage(pointSize: 10, weight: .medium)
                : chevronDownImage(pointSize: 10, weight: .medium)
            if let image {
                image.draw(in: chevronRect)
            }

            if isActive {
                let dotRect = NSRect(x: indicatorRect.minX + 3, y: indicatorRect.midY - 2, width: 4, height: 4)
                let dotPath = NSBezierPath(ovalIn: dotRect)
                NSColor.controlAccentColor.setFill()
                dotPath.fill()
            }
        }
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

struct AppFocusReturnContext {
    let bundleID: String
    let terminalTTY: String?
    let capturedAt: Date?
}

final class AppFocusTracker {
    static let shared = AppFocusTracker()

    private let currentProcessID = ProcessInfo.processInfo.processIdentifier
    private var activationObserver: Any?
    private let stateLock = NSLock()
    private var lastExternalBundleID = ""
    private var lastTerminalTTY = ""
    private var lastExternalCapturedAt: Date?

    private init() {}

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func start() {
        guard activationObserver == nil else { return }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleActivation(notification)
        }

        if let app = NSWorkspace.shared.frontmostApplication {
            updateTrackedAppIfNeeded(app)
        }
    }

    func preferredTerminalTTY() -> String? {
        stateLock.lock()
        let tracked = lastTerminalTTY
        stateLock.unlock()
        return tracked.isEmpty ? nil : tracked
    }

    func preferredReturnContext(fallbackBundleID: String, maxAge: TimeInterval) -> AppFocusReturnContext {
        stateLock.lock()
        let trackedBundleID = lastExternalBundleID
        let trackedTerminalTTY = lastTerminalTTY
        let trackedCapturedAt = lastExternalCapturedAt
        stateLock.unlock()

        if let trackedCapturedAt,
           !trackedBundleID.isEmpty,
           Date().timeIntervalSince(trackedCapturedAt) <= maxAge {
            return AppFocusReturnContext(
                bundleID: trackedBundleID,
                terminalTTY: trackedTerminalTTY.isEmpty ? nil : trackedTerminalTTY,
                capturedAt: trackedCapturedAt
            )
        }

        return AppFocusReturnContext(
            bundleID: fallbackBundleID,
            terminalTTY: nil,
            capturedAt: nil
        )
    }

    private func handleActivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        updateTrackedAppIfNeeded(app)
    }

    private func updateTrackedAppIfNeeded(_ app: NSRunningApplication) {
        guard app.processIdentifier != currentProcessID else { return }
        guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return }

        stateLock.lock()
        lastExternalBundleID = bundleID
        lastExternalCapturedAt = Date()
        if bundleID == "com.apple.Terminal" {
            lastTerminalTTY = currentFrontTerminalTTY()
        } else {
            lastTerminalTTY = ""
        }
        stateLock.unlock()
    }

    private func currentFrontTerminalTTY() -> String {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", """
        tell application "Terminal"
          try
            return tty of selected tab of front window
          on error
            return ""
          end try
        end tell
        """]
        process.standardOutput = stdout

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

final class CodeTaskMasterApp: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var didRunTerminationCleanup = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppFocusTracker.shared.start()
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

final class MainViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSplitViewDelegate, NSTextFieldDelegate, NSSearchFieldDelegate, SessionStatusHeaderFilterDelegate {
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

    private enum SessionFilterKind: String {
        case status
        case terminal
        case tty

        var title: String {
            switch self {
            case .status:
                return "Status"
            case .terminal:
                return "Terminal"
            case .tty:
                return "TTY"
            }
        }
    }

    private struct ActivityLogEntry {
        let timestamp: Date
        let sourceText: String
        let renderedText: String
        let normalizedText: String
        let isFailure: Bool
    }

    private struct LiveTTYResolution {
        let tty: String?
        let detail: String
        let changed: Bool
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
    private let sessionSearchField: NSSearchField = {
        let field = NSSearchField()
        field.placeholderString = "搜索 Name / Session ID / 近提示词"
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        return field
    }()
    private let sessionPromptSearchCheckbox: NSButton = {
        let checkbox = NSButton(checkboxWithTitle: "含近提示词", target: nil, action: nil)
        checkbox.toolTip = "勾选后会额外检索每个 session 最近几条用户提示词，速度会更慢。"
        return checkbox
    }()
    private let sessionScopeControl: NSSegmentedControl = {
        let control = NSSegmentedControl(labels: ["普通", "已归档"], trackingMode: .selectOne, target: nil, action: nil)
        control.selectedSegment = 0
        return control
    }()
    private let renameField = NSTextField(string: "")
    private let sessionDetailView = NSTextView()
    private let sessionDetailScrollView = NSScrollView()
    private let sessionStatusSplitView = AdjustableSplitView()
    private let topSplitView = AdjustableSplitView()
    private let contentSplitView = AdjustableSplitView()
    private let outputView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let activeLoopsMetaLabel = NSTextField(labelWithString: "No active loops.")
    private let sessionStatusMetaLabel = NSTextField(labelWithString: "点击“检测状态”加载 session 列表。")
    private let activityLogMetaLabel = NSTextField(labelWithString: "显示 0 / 0")
    private var refreshTimer: Timer?
    private var requestTimer: Timer?
    private var loopSnapshots: [LoopSnapshot] = []
    private var sessionSnapshots: [SessionSnapshot] = []
    private var allSessionSnapshots: [SessionSnapshot] = []
    private var activityLogEntries: [ActivityLogEntry] = []
    private var loopWarnings: [String] = []
    private var preferredLoopSelectionTarget: String?
    private var targetHistory: [String] = []
    private var messageHistory: [String] = []
    private var isSessionScanRunning = false
    private var sessionScanGeneration = 0
    private var sessionScanTotal = 0
    private var sessionScanShouldStop = false
    private var displayedSessionListMode: SessionListMode = .active
    private var activeSessionScanMode: SessionListMode?
    private var statusSegments: [String: String] = [:]
    private var statusSegmentColors: [String: NSColor] = [:]
    private var statusSegmentClearWorkItems: [String: DispatchWorkItem] = [:]
    private let defaultLoopSortKey = "nextRun"
    private let defaultSessionSortKey = "updatedAt"
    private var lastValidIntervalValue = "600"
    private var topSplitRatio: CGFloat = 0.5
    private var didApplyInitialTopSplitRatio = false
    private var didForceInitialTopSplitRatioAfterAppear = false
    private var lastTopSplitWidth: CGFloat = 0
    private var isApplyingTopSplitRatio = false
    private var sessionStatusSplitRatio: CGFloat = 0.56
    private var didApplyInitialSessionStatusSplitRatio = false
    private var lastSessionStatusSplitHeight: CGFloat = 0
    private var isApplyingSessionStatusSplitRatio = false
    private var contentSplitRatio: CGFloat = 0.62
    private var didApplyInitialContentSplitRatio = false
    private var lastContentSplitHeight: CGFloat = 0
    private var isApplyingContentSplitRatio = false
    private let sessionScanProcessLock = NSLock()
    private var currentSessionScanProcess: Process?
    private var sessionDetailLoadGeneration = 0
    private var sessionSearchDebounceTimer: Timer?
    private var sessionSearchRevision = 0
    private var isSessionPromptSearchRunning = false
    private var sessionPromptSearchCompletedRevision: Int?
    private var sessionPromptSearchMatchedThreadIDs = Set<String>()
    private var sessionPromptSearchProgressCompleted = 0
    private var sessionPromptSearchProgressTotal = 0
    private var sessionPromptSearchCache: [String: String] = [:]
    private let sessionPromptSearchCacheLock = NSLock()
    private var lastSessionRenderScannedCount: Int?
    private var lastSessionRenderTotalCount: Int?
    private var lastSessionRenderIsComplete = true
    private let tableCellFont = NSFont.systemFont(ofSize: 12)
    private let tableCellHorizontalPadding: CGFloat = 12
    private let tableCellVerticalPadding: CGFloat = 6
    private let tableBaseRowHeight: CGFloat = 24
    private let tableWrappedRowHeightCap: CGFloat = 110
    private var selectedSessionStatusFilters = Set<String>()
    private var selectedSessionTerminalFilters = Set<String>()
    private var selectedSessionTTYFilters = Set<String>()
    private let sessionFilterContainerView = NSView()
    private let sessionFilterStackView = NSStackView()
    private var sessionFilterPanel: NSPanel?
    private var sessionFilterPanelKind: SessionFilterKind?
    private var sessionFilterPanelColumnIdentifier: String?
    private var sessionFilterPanelHeaderView: NSTableHeaderView?
    private var sessionFilterOutsideLocalMonitor: Any?
    private var sessionFilterOutsideGlobalMonitor: Any?
    private let historyListView = HistoryDropdownListView()
    private var historyPopoverKind: HistoryKind?
    private var historyRowViews: [HistoryDropdownRowView] = []
    private var historyHighlightedIndex: Int = -1
    private var historyKeyMonitor: Any?
    private var historyDropdownPanel: NSPanel?
    private var historyDropdownScrollView: NSScrollView?
    private var historyOutsideLocalMonitor: Any?
    private var historyOutsideGlobalMonitor: Any?
    private var tableSelectionOutsideLocalMonitor: Any?
    private var announcedLoopAmbiguitySignatures: Set<String> = []
    private var lastTargetValidationFailureReason: String?
    private var lastTargetValidationFailureDetail = ""
    private var isFilteringActivityLogBySelectedSession = false
    private var isProgrammaticLoopSelectionChange = false
    private var didAutoSizeActiveLoopsColumns = false
    private var didAutoSizeSessionColumns = false

    private lazy var sendButton = makeButton(title: "发送一次", action: #selector(sendOnce))
    private lazy var startButton = makeButton(title: "开始循环", action: #selector(startLoop))
    private lazy var refreshLoopsButton = makeButton(title: "刷新循环", action: #selector(refreshLoopsAction))
    private lazy var detectStatusButton = makeButton(title: "检测状态", action: #selector(detectStatuses))
    private lazy var stopButton = makeButton(title: "停止当前", action: #selector(stopLoop))
    private lazy var resumeLoopButton = makeButton(title: "恢复当前", action: #selector(resumeSelectedLoop))
    private lazy var deleteLoopButton = makeButton(title: "删除当前", action: #selector(deleteSelectedLoop))
    private lazy var stopAllButton = makeButton(title: "全部停止", action: #selector(stopAllLoops))
    private lazy var saveRenameButton = makeButton(title: "保存", action: #selector(saveSessionRename))
    private lazy var archiveSessionButton = makeButton(title: "归档", action: #selector(archiveSelectedSession))
    private lazy var restoreSessionButton = makeButton(title: "恢复", action: #selector(restoreSelectedSession))
    private lazy var deleteSessionButton = makeButton(title: "删除", action: #selector(deleteSelectedSession))
    private lazy var migrateSessionProviderButton = makeButton(title: "迁移当前到当前Provider", action: #selector(migrateSelectedSessionToCurrentProvider))
    private lazy var migrateAllSessionsProviderButton = makeButton(title: "全部迁移到当前Provider", action: #selector(migrateAllSessionsToCurrentProvider))
    private lazy var clearLogButton = makeButton(title: "清空日志", action: #selector(clearActivityLog))
    private lazy var saveLogButton = makeButton(title: "保存日志", action: #selector(saveActivityLog))
    private lazy var exportSessionLogButton = makeButton(title: "导出当前 Session", action: #selector(exportSelectedSessionLogs))
    private let activityLogSearchField: NSSearchField = {
        let field = NSSearchField()
        field.placeholderString = "筛选 target / session / 关键词"
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.recentsAutosaveName = nil
        field.maximumRecents = 0
        field.searchMenuTemplate = nil
        return field
    }()
    private let activityLogFailuresOnlyCheckbox: NSButton = {
        let checkbox = NSButton(checkboxWithTitle: "仅失败", target: nil, action: nil)
        checkbox.toolTip = "只显示发送失败或 stderr 相关日志。"
        return checkbox
    }()
    private let activityLogSelectedSessionCheckbox: NSButton = {
        let checkbox = NSButton(checkboxWithTitle: "当前 Session", target: nil, action: nil)
        checkbox.toolTip = "只显示当前选中 Session 相关日志。"
        return checkbox
    }()
    private let platformSendAdapter: PlatformSendAdapter = MacOSTerminalSendAdapter()
    private let terminalAutomationQueue = DispatchQueue(label: "ai.codextaskmaster.terminal-automation")
    private lazy var sendRequestCoordinator = SendRequestCoordinator(
        pendingRequestDirectoryPath: pendingRequestDirectoryPath,
        processingRequestDirectoryPath: processingRequestDirectoryPath,
        resultRequestDirectoryPath: resultRequestDirectoryPath,
        sendAdapter: platformSendAdapter,
        terminalAutomationQueue: terminalAutomationQueue,
        runHelper: { [weak self] arguments in
            guard let self else {
                return (status: 1, stdout: "", stderr: "send runtime unavailable")
            }
            return self.runStandardHelper(arguments: arguments)
        },
        callbacks: SendRequestProcessorCallbacks(
            logActivity: { [weak self] text in
                DispatchQueue.main.async {
                    self?.appendOutput(text)
                }
            },
            updateSendStatus: { [weak self] kind, target, reason, probeStatus, terminalState, color in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.setStatus(
                        self.sendOutcomeStatusText(
                            kind: kind,
                            target: target,
                            reason: reason,
                            probeStatus: probeStatus,
                            terminalState: terminalState
                        ),
                        key: "send",
                        color: color
                    )
                }
            },
            requestDidFinish: { [weak self] in
                DispatchQueue.main.async {
                    self?.refreshLoopsSnapshot()
                }
            }
        )
    )

    override func loadView() {
        self.view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        loadHistoryState()
        normalizeInitialIntervalValue()
        configureSessionFilterPopover()
        updateSessionFilterHeaderIndicators()
        sessionStatusMetaLabel.stringValue = sessionEmptyStateText()
        updateDetectStatusButtonState()
        stopButton.isEnabled = false
        resumeLoopButton.isEnabled = false
        deleteLoopButton.isEnabled = false
        installTableSelectionOutsideMonitor()
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
        preserveSessionStatusSplitRatioOnResizeIfNeeded()
        preserveContentSplitRatioOnResizeIfNeeded()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        forceInitialTopSplitRatioAfterAppearIfNeeded()
    }

    deinit {
        refreshTimer?.invalidate()
        requestTimer?.invalidate()
        removeHistoryKeyMonitor()
        removeHistoryOutsideMonitors()
        removeTableSelectionOutsideMonitor()
        closeSessionFilterPanel()
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

        let buttonRow = NSStackView(views: [sendButton, startButton, refreshLoopsButton, detectStatusButton, stopButton, resumeLoopButton, deleteLoopButton, stopAllButton])
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
        sessionDetailView.string = "选中一条 session 后，这里会显示完整信息、最近发送结果、相关 Loop 和提示词历史。"

        sessionScopeControl.target = self
        sessionScopeControl.action = #selector(changeSessionScope)
        sessionScopeControl.translatesAutoresizingMaskIntoConstraints = false
        sessionSearchField.delegate = self
        sessionSearchField.translatesAutoresizingMaskIntoConstraints = false
        sessionSearchField.recentsAutosaveName = nil
        sessionSearchField.maximumRecents = 0
        sessionSearchField.searchMenuTemplate = nil
        sessionPromptSearchCheckbox.target = self
        sessionPromptSearchCheckbox.action = #selector(toggleSessionPromptSearch)
        sessionPromptSearchCheckbox.translatesAutoresizingMaskIntoConstraints = false
        activityLogSearchField.delegate = self
        activityLogSearchField.translatesAutoresizingMaskIntoConstraints = false
        activityLogFailuresOnlyCheckbox.target = self
        activityLogFailuresOnlyCheckbox.action = #selector(toggleActivityLogFailuresOnly)
        activityLogFailuresOnlyCheckbox.translatesAutoresizingMaskIntoConstraints = false
        activityLogSelectedSessionCheckbox.target = self
        activityLogSelectedSessionCheckbox.action = #selector(toggleActivityLogSelectedSessionFilter)
        activityLogSelectedSessionCheckbox.translatesAutoresizingMaskIntoConstraints = false

        renameField.placeholderString = "输入新名称，留空可恢复为未 rename 状态"
        renameField.translatesAutoresizingMaskIntoConstraints = false
        renameField.isEnabled = false
        saveRenameButton.isEnabled = false
        archiveSessionButton.isEnabled = false
        restoreSessionButton.isEnabled = false
        deleteSessionButton.isEnabled = false
        migrateSessionProviderButton.isEnabled = false
        migrateAllSessionsProviderButton.isEnabled = false
        archiveSessionButton.contentTintColor = .systemOrange
        restoreSessionButton.contentTintColor = .systemBlue
        deleteSessionButton.contentTintColor = .systemRed
        migrateSessionProviderButton.contentTintColor = .systemPurple
        migrateAllSessionsProviderButton.contentTintColor = .systemPurple
        saveRenameButton.toolTip = "保存当前 session 的名称"
        archiveSessionButton.toolTip = "按 Codex 原生语义归档当前 session"
        restoreSessionButton.toolTip = "恢复当前已归档 session"
        deleteSessionButton.toolTip = "从本地状态中彻底删除当前 session"
        migrateSessionProviderButton.toolTip = "将当前选中 session 迁移到当前 config.toml 中的 model_provider"
        migrateAllSessionsProviderButton.toolTip = "将本地所有 session 迁移到当前 config.toml 中的 model_provider"

        let renameRow = NSStackView(views: [renameField, saveRenameButton, archiveSessionButton, restoreSessionButton, deleteSessionButton])
        renameRow.orientation = .horizontal
        renameRow.spacing = 8
        renameRow.alignment = .centerY
        saveRenameButton.setContentHuggingPriority(.required, for: .horizontal)
        archiveSessionButton.setContentHuggingPriority(.required, for: .horizontal)
        restoreSessionButton.setContentHuggingPriority(.required, for: .horizontal)
        deleteSessionButton.setContentHuggingPriority(.required, for: .horizontal)

        let migrationRow = NSStackView(views: [migrateSessionProviderButton, migrateAllSessionsProviderButton])
        migrationRow.orientation = .horizontal
        migrationRow.spacing = 8
        migrationRow.alignment = .centerY
        migrateSessionProviderButton.setContentHuggingPriority(.required, for: .horizontal)
        migrateAllSessionsProviderButton.setContentHuggingPriority(.required, for: .horizontal)

        let sessionScopeRow = NSStackView(views: [sessionScopeControl, sessionSearchField, sessionPromptSearchCheckbox])
        sessionScopeRow.orientation = .horizontal
        sessionScopeRow.spacing = 8
        sessionScopeRow.alignment = .centerY
        sessionScopeControl.setContentHuggingPriority(.required, for: .horizontal)
        sessionScopeControl.setContentCompressionResistancePriority(.required, for: .horizontal)
        sessionPromptSearchCheckbox.setContentHuggingPriority(.required, for: .horizontal)
        sessionPromptSearchCheckbox.setContentCompressionResistancePriority(.required, for: .horizontal)
        sessionSearchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sessionSearchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sessionSearchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

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
        let sessionStatusTopStack = NSStackView(views: [sessionScopeRow, sessionStatusScrollView])
        sessionStatusTopStack.orientation = .vertical
        sessionStatusTopStack.spacing = 8
        sessionStatusTopStack.alignment = .leading
        sessionStatusTopStack.distribution = .fill
        sessionStatusTopStack.translatesAutoresizingMaskIntoConstraints = false
        sessionScopeRow.widthAnchor.constraint(equalTo: sessionStatusTopStack.widthAnchor).isActive = true
        sessionStatusScrollView.widthAnchor.constraint(equalTo: sessionStatusTopStack.widthAnchor).isActive = true

        let sessionStatusBottomStack = NSStackView(views: [renameRow, migrationRow, sessionDetailScrollView])
        sessionStatusBottomStack.orientation = .vertical
        sessionStatusBottomStack.spacing = 8
        sessionStatusBottomStack.alignment = .leading
        sessionStatusBottomStack.distribution = .fill
        sessionStatusBottomStack.translatesAutoresizingMaskIntoConstraints = false
        renameRow.widthAnchor.constraint(equalTo: sessionStatusBottomStack.widthAnchor).isActive = true
        migrationRow.widthAnchor.constraint(equalTo: sessionStatusBottomStack.widthAnchor).isActive = true
        sessionDetailScrollView.widthAnchor.constraint(equalTo: sessionStatusBottomStack.widthAnchor).isActive = true

        renameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        sessionScopeRow.setContentHuggingPriority(.required, for: .vertical)
        sessionScopeRow.setContentCompressionResistancePriority(.required, for: .vertical)
        renameRow.setContentHuggingPriority(.required, for: .vertical)
        renameRow.setContentCompressionResistancePriority(.required, for: .vertical)
        migrationRow.setContentHuggingPriority(.required, for: .vertical)
        migrationRow.setContentCompressionResistancePriority(.required, for: .vertical)
        sessionStatusScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        sessionStatusScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        sessionDetailScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        sessionDetailScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        sessionStatusSplitView.isVertical = false
        sessionStatusSplitView.dividerStyle = .thin
        sessionStatusSplitView.translatesAutoresizingMaskIntoConstraints = false
        sessionStatusSplitView.delegate = self
        let sessionStatusTopPane = makeSplitPane(contentView: sessionStatusTopStack, minHeight: 110)
        let sessionStatusBottomPane = makeSplitPane(contentView: sessionStatusBottomStack, minHeight: 138)
        sessionStatusSplitView.addArrangedSubview(sessionStatusTopPane)
        sessionStatusSplitView.addArrangedSubview(sessionStatusBottomPane)
        sessionStatusSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        sessionStatusSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        let sessionStatusMinHeight = CGFloat(110 + 138) + sessionStatusSplitView.dividerThickness
        sessionStatusSplitView.heightAnchor.constraint(greaterThanOrEqualToConstant: sessionStatusMinHeight).isActive = true
        let sessionStatusPanel = makePanel(title: "Session Status", metaLabel: sessionStatusMetaLabel, contentView: sessionStatusSplitView)
        let logFilterControls = NSStackView(views: [activityLogSearchField, activityLogFailuresOnlyCheckbox, activityLogSelectedSessionCheckbox, exportSessionLogButton, clearLogButton, saveLogButton])
        logFilterControls.orientation = .horizontal
        logFilterControls.spacing = 6
        logFilterControls.alignment = .centerY
        logFilterControls.distribution = .fill
        activityLogSearchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        activityLogSearchField.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        activityLogSearchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        activityLogSearchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        activityLogFailuresOnlyCheckbox.setContentHuggingPriority(.required, for: .horizontal)
        activityLogFailuresOnlyCheckbox.setContentCompressionResistancePriority(.required, for: .horizontal)
        activityLogSelectedSessionCheckbox.setContentHuggingPriority(.required, for: .horizontal)
        activityLogSelectedSessionCheckbox.setContentCompressionResistancePriority(.required, for: .horizontal)
        exportSessionLogButton.setContentHuggingPriority(.required, for: .horizontal)
        exportSessionLogButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        clearLogButton.setContentHuggingPriority(.required, for: .horizontal)
        saveLogButton.setContentHuggingPriority(.required, for: .horizontal)
        exportSessionLogButton.toolTip = "导出当前选中 Session 相关日志"
        clearLogButton.toolTip = "清空当前日志显示"
        saveLogButton.toolTip = "保存当前日志到文件"
        let logPanel = makePanel(title: "Activity Log", metaLabel: activityLogMetaLabel, contentView: outputScrollView, headerAccessoryView: logFilterControls)
        let activeLoopsPane = makeSplitPane(contentView: activeLoopsPanel, minWidth: 220, minHeight: 100)
        let sessionStatusPane = makeSplitPane(contentView: sessionStatusPanel, minWidth: 180, minHeight: 100)
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

        updateActivityLogMetaLabel()
        updateActivityLogControls()
    }

    private func configureTextView(_ textView: NSTextView, inset: NSSize) {
        textView.frame = NSRect(x: 0, y: 0, width: 0, height: 0)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
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
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    }

    private func configureLoopsTable() {
        let columns: [(identifier: String, title: String, width: CGFloat)] = [
            ("state", "Status", 88),
            ("result", "Result", 96),
            ("reason", "Reason", 138),
            ("target", "Target", 88),
            ("interval", "Interval", 72),
            ("forceSend", "Mode", 72),
            ("nextRun", "Next Run", 120),
            ("message", "Message", 120),
            ("lastLog", "Last Result", 180)
        ]

        activeLoopsTableView.headerView = NSTableHeaderView()
        activeLoopsTableView.usesAlternatingRowBackgroundColors = true
        activeLoopsTableView.allowsEmptySelection = true
        activeLoopsTableView.allowsMultipleSelection = false
        activeLoopsTableView.delegate = self
        activeLoopsTableView.dataSource = self
        activeLoopsTableView.rowHeight = tableBaseRowHeight
        activeLoopsTableView.columnAutoresizingStyle = .noColumnAutoresizing

        for column in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.identifier))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.identifier, ascending: column.identifier != defaultLoopSortKey)
            tableColumn.minWidth = loopColumnMinimumWidth(column.identifier)
            if column.identifier == "lastLog" {
                tableColumn.resizingMask = [.autoresizingMask, .userResizingMask]
            } else {
                tableColumn.resizingMask = .userResizingMask
            }
            activeLoopsTableView.addTableColumn(tableColumn)
        }

        activeLoopsScrollView.documentView = activeLoopsTableView
        activeLoopsTableView.sortDescriptors = [NSSortDescriptor(key: defaultLoopSortKey, ascending: true)]
    }

    private func configureSessionStatusTable() {
        let columns: [(identifier: String, title: String, width: CGFloat)] = [
            ("name", "Name", 96),
            ("type", "Type", 74),
            ("threadID", "Session ID", 160),
            ("status", "Status", 96),
            ("terminalState", "Terminal", 92),
            ("tty", "TTY", 72),
            ("updatedAt", "Updated", 118),
            ("reason", "原因", 180)
        ]

        let headerView = SessionStatusHeaderView()
        headerView.filterDelegate = self
        sessionStatusTableView.headerView = headerView
        sessionStatusTableView.usesAlternatingRowBackgroundColors = true
        sessionStatusTableView.allowsEmptySelection = true
        sessionStatusTableView.allowsMultipleSelection = false
        sessionStatusTableView.delegate = self
        sessionStatusTableView.dataSource = self
        sessionStatusTableView.rowHeight = tableBaseRowHeight
        sessionStatusTableView.target = self
        sessionStatusTableView.doubleAction = #selector(handleSessionStatusDoubleClick)
        sessionStatusTableView.columnAutoresizingStyle = .noColumnAutoresizing

        for column in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.identifier))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.identifier, ascending: column.identifier == defaultSessionSortKey ? false : true)
            tableColumn.minWidth = sessionColumnMinimumWidth(column.identifier)
            if column.identifier == "reason" {
                tableColumn.resizingMask = [.autoresizingMask, .userResizingMask]
            } else {
                tableColumn.resizingMask = .userResizingMask
            }
            sessionStatusTableView.addTableColumn(tableColumn)
        }

        sessionStatusScrollView.documentView = sessionStatusTableView
        sessionStatusTableView.sortDescriptors = [NSSortDescriptor(key: defaultSessionSortKey, ascending: false)]
    }

    private func loopColumnMinimumWidth(_ identifier: String) -> CGFloat {
        switch identifier {
        case "state", "result", "interval", "forceSend", "reason", "target", "message", "nextRun", "lastLog":
            return 2.5
        default:
            return 2.5
        }
    }

    private func loopColumnMaximumWidth(_ identifier: String) -> CGFloat {
        switch identifier {
        case "state":
            return 132
        case "result":
            return 150
        case "reason":
            return 260
        case "target":
            return 220
        case "interval", "forceSend":
            return 90
        case "nextRun":
            return 190
        case "message":
            return 280
        case "lastLog":
            return 520
        default:
            return 240
        }
    }

    private func sessionColumnMinimumWidth(_ identifier: String) -> CGFloat {
        switch identifier {
        case "name", "type", "status", "terminalState", "tty", "threadID", "updatedAt", "reason":
            return 2.5
        default:
            return 2.5
        }
    }

    private func sessionColumnMaximumWidth(_ identifier: String) -> CGFloat {
        switch identifier {
        case "name":
            return 220
        case "type":
            return 120
        case "threadID":
            return 320
        case "status":
            return 150
        case "terminalState":
            return 150
        case "tty":
            return 120
        case "updatedAt":
            return 180
        case "reason":
            return 460
        default:
            return 240
        }
    }

    private func preferredTargetValue(for session: SessionSnapshot) -> String {
        let actualName = sessionActualName(session)
        if !actualName.isEmpty {
            return actualName
        }
        return session.threadID
    }

    private func loopLogField(_ line: String, key: String) -> String? {
        let pattern = "\(key): "
        guard let range = line.range(of: pattern) else { return nil }
        let suffix = line[range.upperBound...]
        let value = suffix.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func localizedProbeStatus(_ status: String) -> String {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase {
        case "idle_stable":
            return "空闲稳定"
        case "interrupted_idle":
            return "中断后空闲"
        case "idle_with_residual_input":
            return "空闲但有残留输入"
        case "busy_turn_open":
            return "回合进行中"
        case "post_finalizing":
            return "正在收尾"
        case "busy_with_stream_issue":
            return "忙碌且流异常"
        case "interrupted_or_aborting":
            return "中断或终止中"
        case "idle_prompt_visible_rollout_stale":
            return "提示符已回到可见但回合状态滞后"
        case "archived":
            return "已归档"
        case "unknown":
            return "未知"
        case "":
            return ""
        default:
            return status
        }
    }

    private func localizedSendReason(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let mappings: [String: String] = [
            "sent": "已发送",
            "forced_sent": "强制发送成功",
            "queued_pending_feedback": "消息已排队",
            "verification_pending": "等待确认",
            "request_still_processing": "请求仍在处理",
            "request_already_inflight": "相同请求已在队列中",
            "ambiguous_target": "目标对应多个同名 Session",
            "tty_unavailable": "TTY 不可用",
            "tty_focus_failed": "TTY 聚焦失败",
            "terminal_focus_script_launch_failed": "Terminal 聚焦脚本启动失败",
            "keyboard_event_source_failed": "键盘事件源创建失败",
            "keyboard_event_creation_failed": "键盘事件创建失败",
            "probe_failed": "状态探测失败",
            "not_sendable": "当前状态不可发送",
            "send_interrupted": "发送过程被中断",
            "send_unverified": "发送后未看到确认",
            "send_unverified_after_tty_fallback": "TTY 回退后仍未确认",
            "invalid_request": "请求内容无效",
            "missing_accessibility_permission": "缺少辅助功能权限",
            "stopped_by_user": "已手动停止",
            "start_failed": "启动失败",
            "loop_conflict_active_session": "同一 Session 已有其他运行中的 Loop"
        ]

        return mappings[trimmed] ?? trimmed
    }

    private func localizedLoopTerminalState(_ state: String) -> String {
        switch state.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase {
        case "prompt_ready":
            return "提示符就绪"
        case "prompt_with_input":
            return "提示符上有输入"
        case "queued_messages_pending":
            return "消息已排队待处理"
        case "no_visible_prompt":
            return "未看到可用提示符"
        case "busy":
            return "忙碌"
        case "unavailable":
            return "TTY 不可达"
        case "archived":
            return "已归档"
        case "unknown":
            return "未知"
        case "":
            return ""
        default:
            return state
        }
    }

    private func loopLastOutcome(_ loop: LoopSnapshot) -> (status: String, reason: String, probeStatus: String, terminalState: String, line: String) {
        let line = loop.lastLogLine
        return (
            status: loopLogField(line, key: "status")?.localizedLowercase ?? "",
            reason: loopLogField(line, key: "reason")?.localizedLowercase ?? "",
            probeStatus: loopLogField(line, key: "probe_status")?.localizedLowercase ?? "",
            terminalState: loopLogField(line, key: "terminal_state")?.localizedLowercase ?? "",
            line: line
        )
    }

    private func detailedNotSendableLabel(probeStatus: String, terminalState: String) -> String {
        switch probeStatus {
        case "busy_turn_open":
            return "会话忙碌"
        case "post_finalizing":
            return "会话收尾中"
        case "busy_with_stream_issue":
            return "会话忙碌且流异常"
        case "interrupted_or_aborting":
            return "会话中断处理中"
        case "idle_prompt_visible_rollout_stale":
            return "回合状态滞后"
        case "idle_with_residual_input":
            return terminalState == "prompt_with_input" ? "提示符残留输入" : "残留输入"
        default:
            break
        }

        switch terminalState {
        case "queued_messages_pending":
            return "消息排队中"
        case "no_visible_prompt":
            return "未看到可用提示符"
        case "unavailable":
            return "TTY 不可用"
        default:
            return "当前状态不可发送"
        }
    }

    private func loopResultLabel(_ loop: LoopSnapshot) -> String {
        if loop.stopped == "yes" {
            return "已停止"
        }
        if loop.paused == "yes" {
            return "已暂停"
        }

        let outcome = loopLastOutcome(loop)
        let normalizedLine = outcome.line.localizedLowercase

        if outcome.status == "success" {
            return "成功"
        }
        if outcome.status == "accepted" {
            if outcome.reason == "verification_pending" {
                return "等待确认"
            }
            if outcome.reason == "queued_pending_feedback" {
                return "消息排队中"
            }
            return "已受理"
        }
        if outcome.reason == "not_sendable" {
            return detailedNotSendableLabel(probeStatus: outcome.probeStatus, terminalState: outcome.terminalState)
        }
        if outcome.reason == "tty_unavailable" {
            return "TTY 不可用"
        }
        if outcome.reason == "tty_focus_failed" {
            return "TTY 聚焦失败"
        }
        if outcome.reason == "ambiguous_target" {
            return "目标不唯一"
        }
        if normalizedLine.contains("辅助功能权限") || outcome.reason == "missing_accessibility_permission" {
            return "权限缺失"
        }
        if normalizedLine.hasPrefix("deferred:") {
            return "待重试"
        }
        if !outcome.reason.isEmpty {
            let localized = localizedSendReason(outcome.reason)
            if localized != outcome.reason || !localized.isEmpty {
                return localized
            }
        }
        if outcome.status == "failed" || normalizedLine.contains("status=failed") {
            return "失败"
        }
        if !outcome.line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "未知"
        }
        return "等待"
    }

    private func loopStateLabel(_ loop: LoopSnapshot) -> String {
        if loop.stopped == "yes" {
            return "停止"
        }
        if loop.paused == "yes" {
            return "暂停"
        }

        let result = loopResultLabel(loop)
        switch result {
        case "成功":
            return "健康"
        case "等待确认":
            return "待确认"
        case "消息排队中", "已受理":
            return "排队"
        case "待重试":
            return "待重试"
        case "会话忙碌", "会话收尾中", "会话忙碌且流异常", "会话中断处理中", "回合状态滞后":
            return "忙碌"
        case "提示符残留输入", "残留输入":
            return "待清理"
        case "TTY 不可用", "TTY 聚焦失败", "权限缺失", "目标不唯一", "失败":
            return "失败"
        default:
            if !loop.lastLogLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "未知"
            }
            return "等待"
        }
    }

    private func loopResultReasonLabel(_ loop: LoopSnapshot) -> String {
        if loop.stopped == "yes" {
            return localizedSendReason(loop.stoppedReason)
        }
        if loop.paused == "yes" {
            return localizedSendReason(loop.pauseReason.isEmpty ? loop.failureReason : loop.pauseReason)
        }
        let outcome = loopLastOutcome(loop)
        let baseReason = localizedSendReason(outcome.reason)
        let probeLabel = localizedProbeStatus(outcome.probeStatus)
        let terminalLabel = localizedLoopTerminalState(outcome.terminalState)

        let fragments = [baseReason, probeLabel, terminalLabel].filter { !$0.isEmpty }
        if !fragments.isEmpty {
            return fragments.joined(separator: " | ")
        }
        if loop.lastLogLine.localizedCaseInsensitiveContains("辅助功能权限") {
            return localizedSendReason("missing_accessibility_permission")
        }
        return ""
    }

    private func loopResultColor(_ loop: LoopSnapshot) -> NSColor {
        switch loopResultLabel(loop) {
        case "成功":
            return .systemGreen
        case "消息排队中", "等待确认", "已受理", "待重试":
            return .systemYellow
        case "已停止":
            return .secondaryLabelColor
        case "会话忙碌", "会话收尾中", "会话忙碌且流异常", "会话中断处理中", "回合状态滞后", "提示符残留输入", "残留输入":
            return .systemOrange
        case "TTY 不可用", "TTY 聚焦失败", "权限缺失", "目标不唯一", "已暂停", "失败":
            return .systemRed
        default:
            return .secondaryLabelColor
        }
    }

    private func loopStateColor(_ loop: LoopSnapshot) -> NSColor {
        switch loopStateLabel(loop) {
        case "健康":
            return .systemGreen
        case "排队", "待确认", "待重试":
            return .systemYellow
        case "忙碌", "待清理":
            return .systemOrange
        case "暂停", "失败":
            return .systemRed
        case "停止":
            return .secondaryLabelColor
        default:
            return .secondaryLabelColor
        }
    }

    private func loopStateSortRank(_ loop: LoopSnapshot) -> Int {
        switch loopStateLabel(loop) {
        case "健康":
            return 0
        case "排队":
            return 1
        case "待重试":
            return 2
        case "等待":
            return 3
        case "未知":
            return 4
        case "暂停":
            return 5
        case "停止":
            return 6
        case "失败":
            return 7
        default:
            return 8
        }
    }

    private func stringValueForLoopColumn(_ identifier: String, loop: LoopSnapshot) -> String {
        switch identifier {
        case "state":
            return "● \(loopStateLabel(loop))"
        case "result":
            return "● \(loopResultLabel(loop))"
        case "reason":
            return loopResultReasonLabel(loop)
        case "target":
            return loop.target
        case "interval":
            return "\(loop.intervalSeconds)s"
        case "forceSend":
            return loop.forceSend == "yes" ? "force" : "idle"
        case "nextRun":
            if loop.stopped == "yes" {
                return "-"
            }
            return formatEpoch(loop.nextRunEpoch)
        case "message":
            return loop.message
        case "lastLog":
            return loop.lastLogLine
        default:
            return ""
        }
    }

    private func stringValueForSessionColumn(_ identifier: String, session: SessionSnapshot) -> String {
        switch identifier {
        case "name":
            return sessionActualName(session)
        case "type":
            return sessionTypeLabel(session)
        case "threadID":
            return session.threadID
        case "status":
            return "● \(localizedSessionStatusLabel(session))"
        case "terminalState":
            return localizedTerminalState(session.terminalState)
        case "tty":
            return session.tty.isEmpty ? "-" : session.tty
        case "updatedAt":
            return formatEpoch(session.updatedAtEpoch)
        case "reason":
            return localizedSessionReason(session.reason)
        default:
            return ""
        }
    }

    private func stringValueForTableCell(tableView: NSTableView, identifier: String, row: Int) -> String {
        if tableView == activeLoopsTableView {
            guard row < loopSnapshots.count else {
                return identifier == activeLoopsTableView.tableColumns.first?.identifier.rawValue ? (loopWarnings.first ?? "Warning") : ""
            }
            return stringValueForLoopColumn(identifier, loop: loopSnapshots[row])
        }

        guard row < sessionSnapshots.count else {
            return ""
        }
        return stringValueForSessionColumn(identifier, session: sessionSnapshots[row])
    }

    private func shouldWrapRow(_ row: Int, in tableView: NSTableView) -> Bool {
        row >= 0 && row == tableView.selectedRow
    }

    private func tableColumnMaximumWidth(tableView: NSTableView, identifier: String) -> CGFloat {
        if tableView == activeLoopsTableView {
            return loopColumnMaximumWidth(identifier)
        }
        return sessionColumnMaximumWidth(identifier)
    }

    private func headerWidthPadding(for tableColumn: NSTableColumn, in tableView: NSTableView) -> CGFloat {
        if tableView == sessionStatusTableView {
            switch tableColumn.identifier.rawValue {
            case "type", "status", "terminalState", "tty":
                return 56
            default:
                return 30
            }
        }
        return 24
    }

    private func measuredTextWidth(_ text: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: tableCellFont]
        return ceil((text as NSString).size(withAttributes: attributes).width)
    }

    private func adjustTableColumnWidths(_ tableView: NSTableView) {
        guard !tableView.tableColumns.isEmpty else { return }

        for column in tableView.tableColumns {
            let identifier = column.identifier.rawValue
            let headerWidth = measuredTextWidth(column.title) + headerWidthPadding(for: column, in: tableView) + tableCellHorizontalPadding
            let rowCount = tableView == activeLoopsTableView ? loopSnapshots.count : sessionSnapshots.count
            var widest = headerWidth

            if rowCount > 0 {
                for row in 0..<rowCount {
                    let value = stringValueForTableCell(tableView: tableView, identifier: identifier, row: row)
                    widest = max(widest, measuredTextWidth(value) + tableCellHorizontalPadding)
                }
            }

            let clampedWidth = min(max(widest, column.minWidth), tableColumnMaximumWidth(tableView: tableView, identifier: identifier))
            if abs(column.width - clampedWidth) > 0.5 {
                column.width = clampedWidth
            }
        }
    }

    private func autoSizeActiveLoopsColumnsIfNeeded() {
        guard !didAutoSizeActiveLoopsColumns,
              !loopSnapshots.isEmpty else { return }
        adjustTableColumnWidths(activeLoopsTableView)
        didAutoSizeActiveLoopsColumns = true
    }

    private func autoSizeSessionColumnsIfNeeded() {
        guard !didAutoSizeSessionColumns,
              !sessionSnapshots.isEmpty else { return }
        adjustTableColumnWidths(sessionStatusTableView)
        didAutoSizeSessionColumns = true
    }

    private func measuredWrappedHeight(for text: String, width: CGFloat) -> CGFloat {
        guard width > 0 else { return tableBaseRowHeight }
        let attributes: [NSAttributedString.Key: Any] = [.font: tableCellFont]
        let boundingRect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        return ceil(boundingRect.height) + tableCellVerticalPadding
    }

    private func wrappedRowHeight(for row: Int, in tableView: NSTableView) -> CGFloat {
        guard shouldWrapRow(row, in: tableView) else { return tableBaseRowHeight }

        var requiredHeight = tableBaseRowHeight
        for column in tableView.tableColumns {
            let availableWidth = column.width - tableCellHorizontalPadding
            guard availableWidth > 12 else { continue }
            let value = stringValueForTableCell(tableView: tableView, identifier: column.identifier.rawValue, row: row)
            guard !value.isEmpty else { continue }
            requiredHeight = max(requiredHeight, measuredWrappedHeight(for: value, width: availableWidth))
        }

        return min(max(requiredHeight, tableBaseRowHeight), tableWrappedRowHeightCap)
    }

    private func refreshTableWrapping(_ tableView: NSTableView) {
        guard tableView.numberOfRows > 0 else { return }
        let rowIndexes = IndexSet(integersIn: 0..<tableView.numberOfRows)
        let columnIndexes = IndexSet(integersIn: 0..<tableView.numberOfColumns)
        tableView.noteHeightOfRows(withIndexesChanged: rowIndexes)
        tableView.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
    }

    private func currentSessionListMode() -> SessionListMode {
        sessionScopeControl.selectedSegment == 1 ? .archived : .active
    }

    private func sessionScopeText(for mode: SessionListMode) -> String {
        mode == .archived ? "已归档" : "普通"
    }

    private func requestedSessionScopeText() -> String {
        sessionScopeText(for: currentSessionListMode())
    }

    private func displayedSessionScopeText() -> String {
        sessionScopeText(for: displayedSessionListMode)
    }

    private func sessionEmptyStateText() -> String {
        switch displayedSessionListMode {
        case .active:
            return "视图: 普通 | 未加载 session 状态。点击“检测状态”开始扫描。"
        case .archived:
            return "视图: 已归档 | 未加载归档 session。点击“检测状态”读取列表。"
        }
    }

    private func currentSessionSearchQuery() -> String {
        sessionSearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isSessionPromptSearchEnabled() -> Bool {
        sessionPromptSearchCheckbox.state == .on
    }

    private func invalidateSessionSearch(resetPromptCache: Bool = false) {
        sessionSearchRevision += 1
        isSessionPromptSearchRunning = false
        sessionPromptSearchCompletedRevision = nil
        sessionPromptSearchMatchedThreadIDs.removeAll()
        sessionPromptSearchProgressCompleted = 0
        sessionPromptSearchProgressTotal = 0
        if resetPromptCache {
            sessionPromptSearchCacheLock.lock()
            sessionPromptSearchCache.removeAll()
            sessionPromptSearchCacheLock.unlock()
        }
        updateSessionFilterHeaderIndicators()
    }

    private func fastSessionMatchesQuery(_ session: SessionSnapshot, normalizedQuery: String) -> Bool {
        guard !normalizedQuery.isEmpty else { return true }
        let candidates = [
            sessionActualName(session),
            sessionTypeLabel(session),
            session.provider,
            session.threadID,
            sessionEffectiveTarget(session),
            session.preview,
            localizedSessionStatusLabel(session),
            localizedSessionReason(session.reason)
        ]
        return candidates.contains { candidate in
            candidate.localizedLowercase.contains(normalizedQuery)
        }
    }

    private func matchesSessionFilters(_ session: SessionSnapshot) -> Bool {
        let statusValue = localizedSessionStatusLabel(session)
        if !selectedSessionStatusFilters.isEmpty && !selectedSessionStatusFilters.contains(statusValue) {
            return false
        }

        let terminalValue = localizedTerminalState(session.terminalState)
        if !selectedSessionTerminalFilters.isEmpty && !selectedSessionTerminalFilters.contains(terminalValue) {
            return false
        }

        let ttyValue = session.tty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "-" : session.tty
        if !selectedSessionTTYFilters.isEmpty && !selectedSessionTTYFilters.contains(ttyValue) {
            return false
        }

        return true
    }

    private func sessionStatusOptionBaseOrder() -> [String] {
        ["空闲", "中断后空闲", "运行中", "状态滞后", "残留输入", "消息排队", "未知", "断联", "已归档"]
    }

    private func sessionTerminalOptionBaseOrder() -> [String] {
        ["可发送", "忙碌", "有残留输入", "不可达", "已归档", "未知"]
    }

    private func sessionFilterOptions(for kind: SessionFilterKind) -> [String] {
        switch kind {
        case .status:
            let base = sessionStatusOptionBaseOrder()
            guard !allSessionSnapshots.isEmpty else { return base }
            let seen = Set(allSessionSnapshots.map(localizedSessionStatusLabel(_:)))
            let extras = seen.subtracting(base).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return base + extras
        case .terminal:
            let base = sessionTerminalOptionBaseOrder()
            guard !allSessionSnapshots.isEmpty else { return base }
            let seen = Set(allSessionSnapshots.map { localizedTerminalState($0.terminalState) })
            let extras = seen.subtracting(base).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return base + extras
        case .tty:
            var ttyValues = Set(allSessionSnapshots.map { snapshot in
                let tty = snapshot.tty.trimmingCharacters(in: .whitespacesAndNewlines)
                return tty.isEmpty ? "-" : tty
            })
            ttyValues.insert("-")
            return ttyValues.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    private func selectedFilterValues(for kind: SessionFilterKind) -> Set<String> {
        switch kind {
        case .status:
            return selectedSessionStatusFilters
        case .terminal:
            return selectedSessionTerminalFilters
        case .tty:
            return selectedSessionTTYFilters
        }
    }

    private func setSelectedFilterValues(_ values: Set<String>, for kind: SessionFilterKind) {
        switch kind {
        case .status:
            selectedSessionStatusFilters = values
        case .terminal:
            selectedSessionTerminalFilters = values
        case .tty:
            selectedSessionTTYFilters = values
        }
        updateSessionFilterHeaderIndicators()
    }

    private func sessionFilterKind(for columnIdentifier: String) -> SessionFilterKind? {
        switch columnIdentifier {
        case "status":
            return .status
        case "terminalState":
            return .terminal
        case "tty":
            return .tty
        default:
            return nil
        }
    }

    private func updateSessionFilterHeaderIndicators() {
        sessionStatusTableView.headerView?.needsDisplay = true
    }

    func sessionHeaderSupportsFilter(for columnIdentifier: String) -> Bool {
        sessionFilterKind(for: columnIdentifier) != nil
    }

    func sessionHeaderFilterIsActive(for columnIdentifier: String) -> Bool {
        guard let kind = sessionFilterKind(for: columnIdentifier) else { return false }
        return !selectedFilterValues(for: kind).isEmpty
    }

    func sessionHeaderFilterIsShown(for columnIdentifier: String) -> Bool {
        isSessionFilterPanelShown() && sessionFilterPanelColumnIdentifier == columnIdentifier
    }

    func toggleSessionHeaderFilter(for columnIdentifier: String, columnRect: NSRect, in headerView: NSTableHeaderView) {
        guard let kind = sessionFilterKind(for: columnIdentifier) else { return }

        if isSessionFilterPanelShown(),
           sessionFilterPanelKind == kind,
           sessionFilterPanelColumnIdentifier == columnIdentifier {
            closeSessionFilterPanel()
            return
        }

        sessionFilterPanelKind = kind
        sessionFilterPanelColumnIdentifier = columnIdentifier
        sessionFilterPanelHeaderView = headerView

        let width = max(columnRect.width + 26, 180)
        rebuildSessionFilterPanel(kind: kind)

        guard let panel = sessionFilterPanel,
              let window = headerView.window else { return }
        let height = panel.frame.height
        let headerRectInWindow = headerView.convert(columnRect, to: nil)
        let headerRectOnScreen = window.convertToScreen(headerRectInWindow)
        let origin = NSPoint(x: headerRectOnScreen.minX, y: headerRectOnScreen.maxY - 1)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
        panel.orderFront(nil)
        installSessionFilterOutsideMonitors(headerView: headerView)
        updateSessionFilterHeaderIndicators()
    }

    private func scheduleSessionSearchRefresh(resetPromptCache: Bool = false) {
        sessionSearchDebounceTimer?.invalidate()
        invalidateSessionSearch(resetPromptCache: resetPromptCache)
        sessionSearchDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.renderSessionSnapshots(
                scannedCount: self.lastSessionRenderScannedCount,
                totalCount: self.lastSessionRenderTotalCount,
                isComplete: self.lastSessionRenderIsComplete
            )
        }
    }

    private func sessionSearchSummary() -> String? {
        let query = currentSessionSearchQuery()
        guard !query.isEmpty else { return nil }
        var parts = ["搜索: \(query)", "命中: \(sessionSnapshots.count)"]
        if isSessionPromptSearchEnabled() {
            if isSessionScanRunning {
                parts.append("近提示词检索待扫描完成后继续")
            } else if isSessionPromptSearchRunning {
                parts.append("近提示词检索: \(sessionPromptSearchProgressCompleted)/\(sessionPromptSearchProgressTotal)")
            } else if sessionPromptSearchCompletedRevision == sessionSearchRevision {
                parts.append("近提示词已检索")
            }
        }
        return parts.joined(separator: " | ")
    }

    private func updateSessionStatusMetaLabel() {
        if allSessionSnapshots.isEmpty {
            if isSessionScanRunning, let scannedCount = lastSessionRenderScannedCount, let totalCount = lastSessionRenderTotalCount {
                var parts = ["视图: \(displayedSessionScopeText())", "正在扫描 \(scannedCount)/\(totalCount)…"]
                if let searchSummary = sessionSearchSummary() {
                    parts.append(searchSummary)
                }
                sessionStatusMetaLabel.stringValue = parts.joined(separator: " | ")
            } else {
                sessionStatusMetaLabel.stringValue = sessionEmptyStateText()
            }
            return
        }

        var parts = ["视图: \(displayedSessionScopeText())", "已加载: \(allSessionSnapshots.count)"]
        if let scannedCount = lastSessionRenderScannedCount, let totalCount = lastSessionRenderTotalCount {
            let progressText = lastSessionRenderIsComplete ? "已扫描: \(scannedCount)/\(totalCount)" : "扫描中: \(scannedCount)/\(totalCount)"
            parts.append(progressText)
            parts.append("总数: \(totalCount)")
        }
        if let searchSummary = sessionSearchSummary() {
            parts.append(searchSummary)
        }
        parts.append("刷新: \(Self.timestampFormatter.string(from: Date()))")
        sessionStatusMetaLabel.stringValue = parts.joined(separator: " | ")
    }

    private func rebuildDisplayedSessionSnapshots(preserveSelectionThreadID: String?) {
        let query = currentSessionSearchQuery()
        let normalizedQuery = query.localizedLowercase
        let fastMatches: [SessionSnapshot]
        if normalizedQuery.isEmpty {
            fastMatches = allSessionSnapshots
        } else {
            fastMatches = allSessionSnapshots.filter { fastSessionMatchesQuery($0, normalizedQuery: normalizedQuery) }
        }

        var matchedThreadIDs = Set(fastMatches.map(\.threadID))
        if !normalizedQuery.isEmpty, isSessionPromptSearchEnabled() {
            matchedThreadIDs.formUnion(sessionPromptSearchMatchedThreadIDs)
        }

        if normalizedQuery.isEmpty {
            sessionSnapshots = allSessionSnapshots
        } else {
            sessionSnapshots = allSessionSnapshots.filter { matchedThreadIDs.contains($0.threadID) }
        }

        sessionSnapshots = sessionSnapshots.filter(matchesSessionFilters(_:))

        applySessionSorting()
        sessionStatusTableView.reloadData()
        autoSizeSessionColumnsIfNeeded()
        restoreSessionSelection(preferredThreadID: preserveSelectionThreadID)
        refreshTableWrapping(sessionStatusTableView)
        updateSessionStatusMetaLabel()

        guard !normalizedQuery.isEmpty,
              isSessionPromptSearchEnabled(),
              !isSessionScanRunning,
              !isSessionPromptSearchRunning,
              sessionPromptSearchCompletedRevision != sessionSearchRevision else {
            return
        }

        startSessionPromptSearch(query: normalizedQuery, revision: sessionSearchRevision, snapshots: allSessionSnapshots)
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

    private func selectedLoopSnapshot() -> LoopSnapshot? {
        let selectedRow = activeLoopsTableView.selectedRow
        guard selectedRow >= 0, selectedRow < loopSnapshots.count else { return nil }
        return loopSnapshots[selectedRow]
    }

    private func selectedSessionSnapshot() -> SessionSnapshot? {
        let selectedRow = sessionStatusTableView.selectedRow
        guard selectedRow >= 0, selectedRow < sessionSnapshots.count else { return nil }
        return sessionSnapshots[selectedRow]
    }

    private func updateLoopActionButtons() {
        guard let loop = selectedLoopSnapshot() else {
            stopButton.isEnabled = false
            resumeLoopButton.isEnabled = false
            deleteLoopButton.isEnabled = false
            return
        }
        stopButton.isEnabled = (loop.stopped != "yes")
        resumeLoopButton.isEnabled = (loop.paused == "yes" || loop.stopped == "yes")
        deleteLoopButton.isEnabled = true
    }

    private func restoreLoopSelection(preferredTarget: String?) {
        let selectionTarget = preferredTarget ?? preferredLoopSelectionTarget
        guard let selectionTarget else {
            isProgrammaticLoopSelectionChange = true
            activeLoopsTableView.deselectAll(nil)
            isProgrammaticLoopSelectionChange = false
            updateLoopActionButtons()
            return
        }

        guard let row = loopSnapshots.firstIndex(where: { $0.target == selectionTarget }) else {
            isProgrammaticLoopSelectionChange = true
            activeLoopsTableView.deselectAll(nil)
            isProgrammaticLoopSelectionChange = false
            preferredLoopSelectionTarget = nil
            updateLoopActionButtons()
            return
        }

        isProgrammaticLoopSelectionChange = true
        activeLoopsTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isProgrammaticLoopSelectionChange = false
        activeLoopsTableView.scrollRowToVisible(row)
        preferredLoopSelectionTarget = selectionTarget
        updateLoopActionButtons()
    }

    private func selectedSessionThreadID() -> String? {
        selectedSessionSnapshot()?.threadID
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
            case "state":
                orderedAscending = loopStateSortRank(lhs) < loopStateSortRank(rhs)
            case "result":
                orderedAscending = loopResultLabel(lhs).localizedStandardCompare(loopResultLabel(rhs)) == .orderedAscending
            case "reason":
                orderedAscending = loopResultReasonLabel(lhs).localizedStandardCompare(loopResultReasonLabel(rhs)) == .orderedAscending
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
        case "state":
            return loopStateLabel(lhs) == loopStateLabel(rhs)
        case "result":
            return loopResultLabel(lhs) == loopResultLabel(rhs)
        case "reason":
            return loopResultReasonLabel(lhs) == loopResultReasonLabel(rhs)
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
            case "type":
                orderedAscending = sessionTypeLabel(lhs).localizedStandardCompare(sessionTypeLabel(rhs)) == .orderedAscending
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
        case "type":
            return sessionTypeLabel(lhs) == sessionTypeLabel(rhs)
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

    private func sessionStatusColor(_ session: SessionSnapshot) -> NSColor {
        if session.isArchived {
            return .systemBlue
        }
        if session.terminalState == "unavailable" && shouldCollapseUnavailableTerminalIntoDisconnectedStatus(session) {
            return .systemRed
        }
        switch session.status {
        case let status where status.hasPrefix("active"):
            return .systemOrange
        case "busy_turn_open", "post_finalizing", "busy_with_stream_issue", "interrupted_or_aborting":
            return .systemOrange
        case "idle_stable", "interrupted_idle":
            return .systemGreen
        case "idle_with_residual_input", "queued_messages_visible", "queued_messages_pending", "rollout_stale", "idle_prompt_visible_rollout_stale":
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
            "Type: \(sessionTypeLabel(session))",
            "Provider: \(session.provider.isEmpty ? "-" : session.provider)",
            "Archived: \(session.isArchived ? "yes" : "no")",
            "Status: \(localizedSessionStatusLabel(session))",
            "Terminal: \(localizedTerminalState(session.terminalState))",
            "TTY: \(session.tty.isEmpty ? "-" : session.tty)",
            "Updated: \(formatEpoch(session.updatedAtEpoch))",
            "原因: \(localizedSessionReason(session.reason))"
        ]
        if !session.parentThreadID.isEmpty {
            lines.append("Parent Session ID: \(session.parentThreadID)")
        }
        if !session.agentNickname.isEmpty {
            lines.append("Agent Nickname: \(session.agentNickname)")
        }
        if !session.agentRole.isEmpty {
            lines.append("Agent Role: \(session.agentRole)")
        }
        let preview = session.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preview.isEmpty {
            lines.append("Preview: \(preview)")
        }
        return lines.joined(separator: "\n")
    }

    private func localizedSendStatusLabel(_ status: String) -> String {
        switch status {
        case "success":
            return "成功"
        case "accepted":
            return "已受理"
        case "failed":
            return "失败"
        default:
            return status.isEmpty ? "-" : status
        }
    }

    private func matchingLoopSnapshots(for session: SessionSnapshot) -> [LoopSnapshot] {
        let candidates = Set(sessionPossibleTargets(session))
        guard !candidates.isEmpty else { return [] }
        return loopSnapshots.filter { candidates.contains($0.target.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func recentSendResults(for session: SessionSnapshot, maxItems: Int = 6, scanLimit: Int = 180) -> [SendResultSnapshot] {
        let candidates = Set(sessionPossibleTargets(session))
        guard !candidates.isEmpty else { return [] }

        let directoryURL = URL(fileURLWithPath: resultRequestDirectoryPath, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let sortedFiles = files
            .filter { $0.pathExtension == "json" }
            .sorted {
                let lhsDate = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }

        var results: [SendResultSnapshot] = []
        for fileURL in sortedFiles.prefix(scanLimit) {
            guard let data = try? Data(contentsOf: fileURL),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let target = (object["target"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard candidates.contains(target) else { continue }

            let updatedAtEpoch = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
                .timeIntervalSince1970 ?? 0
            results.append(
                SendResultSnapshot(
                    target: target,
                    status: object["status"] as? String ?? "",
                    reason: object["reason"] as? String ?? "",
                    forceSend: object["force_send"] as? Bool ?? false,
                    detail: object["detail"] as? String ?? "",
                    probeStatus: object["probe_status"] as? String ?? "",
                    terminalState: object["terminal_state"] as? String ?? "",
                    updatedAtEpoch: updatedAtEpoch
                )
            )

            if results.count >= maxItems {
                break
            }
        }

        return results
    }

    private func recentSendStatsText(for results: [SendResultSnapshot]) -> String {
        guard !results.isEmpty else {
            return "最近发送统计\n暂无匹配该 session 的发送结果。"
        }

        let successCount = results.filter { $0.status == "success" }.count
        let acceptedCount = results.filter { $0.status == "accepted" }.count
        let failedResults = results.filter { $0.status == "failed" }
        let failedCount = failedResults.count

        var reasonCounts: [String: Int] = [:]
        for result in failedResults {
            let key = localizedSendReason(result.reason)
            reasonCounts[key, default: 0] += 1
        }

        let topReasons = reasonCounts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
                }
                return lhs.value > rhs.value
            }
            .prefix(3)
            .map { "\($0.key) (\($0.value))" }
            .joined(separator: "，")

        let latest = results[0]
        var lines = [
            "最近发送统计",
            "共 \(results.count) 次 | 成功 \(successCount) | 已受理 \(acceptedCount) | 失败 \(failedCount)",
            "最近一次: \(localizedSendStatusLabel(latest.status)) | \(localizedSendReason(latest.reason)) | \(formatEpoch(String(Int(latest.updatedAtEpoch))))"
        ]
        if !topReasons.isEmpty {
            lines.append("失败原因: \(topReasons)")
        }
        return lines.joined(separator: "\n")
    }

    private func recentSendResultsText(for results: [SendResultSnapshot]) -> String {
        guard !results.isEmpty else {
            return "最近发送结果\n暂无匹配该 session 的发送记录。"
        }

        return results.enumerated().map { index, result in
            var lines = [
                "结果 \(index + 1)",
                "时间: \(formatEpoch(String(Int(result.updatedAtEpoch))))",
                "Target: \(result.target)",
                "状态: \(localizedSendStatusLabel(result.status))",
                "原因: \(localizedSendReason(result.reason))",
                "模式: \(result.forceSend ? "force" : "idle")"
            ]
            if !result.probeStatus.isEmpty {
                lines.append("Probe: \(result.probeStatus)")
            }
            if !result.terminalState.isEmpty {
                lines.append("Terminal: \(localizedTerminalState(result.terminalState))")
            }
            if !result.detail.isEmpty {
                lines.append("Detail: \(result.detail)")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private func loopOccupancyText(for session: SessionSnapshot) -> String {
        let loops = matchingLoopSnapshots(for: session)
        guard !loops.isEmpty else {
            return "相关 Loop\n无"
        }

        return (["相关 Loop"] + loops.map { loop in
            let nextRun = loop.stopped == "yes" ? "-" : formatEpoch(loop.nextRunEpoch)
            let reason = loopResultReasonLabel(loop)
            var lines = [
                "Target: \(loop.target)",
                "状态: \(loopStateLabel(loop)) | 结果: \(loopResultLabel(loop))",
                "间隔: \(loop.intervalSeconds)s | 模式: \(loop.forceSend == "yes" ? "force" : "idle") | 下次: \(nextRun)"
            ]
            if !reason.isEmpty {
                lines.append("原因: \(reason)")
            }
            return lines.joined(separator: "\n")
        }).joined(separator: "\n\n")
    }

    private func recentUserMessageEntries(for session: SessionSnapshot, limit: Int? = nil) -> [(timestamp: String, message: String)]? {
        guard !session.rolloutPath.isEmpty else {
            return nil
        }

        let rolloutURL = URL(fileURLWithPath: session.rolloutPath)
        guard let data = try? Data(contentsOf: rolloutURL),
              let text = String(data: data, encoding: .utf8) else {
            return nil
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

        if let limit, entries.count > limit {
            return Array(entries.suffix(limit))
        }
        return entries
    }

    private func recentPromptSearchCorpus(for session: SessionSnapshot) -> String {
        sessionPromptSearchCacheLock.lock()
        if let cached = sessionPromptSearchCache[session.threadID] {
            sessionPromptSearchCacheLock.unlock()
            return cached
        }
        sessionPromptSearchCacheLock.unlock()

        let corpus = recentUserMessageEntries(for: session, limit: sessionPromptSearchEntryLimit)?
            .map(\.message)
            .joined(separator: "\n") ?? ""

        sessionPromptSearchCacheLock.lock()
        sessionPromptSearchCache[session.threadID] = corpus
        sessionPromptSearchCacheLock.unlock()
        return corpus
    }

    private func startSessionPromptSearch(query: String, revision: Int, snapshots: [SessionSnapshot]) {
        isSessionPromptSearchRunning = true
        sessionPromptSearchProgressCompleted = 0
        sessionPromptSearchProgressTotal = snapshots.count
        updateSessionStatusMetaLabel()

        DispatchQueue.global(qos: .utility).async {
            var matchedThreadIDs = Set<String>()

            for (index, session) in snapshots.enumerated() {
                if revision != self.sessionSearchRevision {
                    return
                }

                let corpus = self.recentPromptSearchCorpus(for: session).localizedLowercase
                if !corpus.isEmpty, corpus.contains(query) {
                    matchedThreadIDs.insert(session.threadID)
                }

                if (index + 1) % 8 == 0 || index + 1 == snapshots.count {
                    let completed = index + 1
                    DispatchQueue.main.async {
                        guard revision == self.sessionSearchRevision else { return }
                        self.sessionPromptSearchProgressCompleted = completed
                        self.updateSessionStatusMetaLabel()
                    }
                }
            }

            DispatchQueue.main.async {
                guard revision == self.sessionSearchRevision else { return }
                self.isSessionPromptSearchRunning = false
                self.sessionPromptSearchCompletedRevision = revision
                self.sessionPromptSearchMatchedThreadIDs = matchedThreadIDs
                self.sessionPromptSearchProgressCompleted = snapshots.count
                self.rebuildDisplayedSessionSnapshots(preserveSelectionThreadID: self.selectedSessionThreadID())
            }
        }
    }

    private func loadPromptHistoryText(for session: SessionSnapshot) -> String {
        guard !session.rolloutPath.isEmpty else {
            return "未找到 rollout 路径，无法读取提示词历史。"
        }

        guard FileManager.default.fileExists(atPath: session.rolloutPath) else {
            return "读取 rollout 文件失败：\(session.rolloutPath)"
        }
        guard let entries = recentUserMessageEntries(for: session, limit: sessionPromptSearchEntryLimit),
              !entries.isEmpty else {
            return "没有找到用户提示词历史。"
        }

        return entries.enumerated().map { index, entry in
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
            migrateSessionProviderButton.isEnabled = false
            migrateAllSessionsProviderButton.isEnabled = currentConfiguredModelProvider() != nil
            sessionDetailView.string = "选中一条 session 后，这里会显示完整信息、最近发送结果、相关 Loop 和提示词历史。"
            sessionDetailView.scrollToBeginningOfDocument(nil)
            updateActivityLogControls()
            if isFilteringActivityLogBySelectedSession {
                refreshActivityLogView(scrollToEnd: false)
            }
            return
        }

        let session = sessionSnapshots[selectedRow]
        renameField.stringValue = session.name
        renameField.isEnabled = !session.isArchived
        saveRenameButton.isEnabled = !session.isArchived
        archiveSessionButton.isEnabled = !session.isArchived
        restoreSessionButton.isEnabled = session.isArchived
        deleteSessionButton.isEnabled = true
        migrateSessionProviderButton.isEnabled = currentConfiguredModelProvider() != nil
        migrateAllSessionsProviderButton.isEnabled = currentConfiguredModelProvider() != nil
        renameField.placeholderString = session.isArchived
            ? "已归档 session 需先恢复后再改名"
            : "输入新名称，留空可恢复为未 rename 状态"
        let sendResults = recentSendResults(for: session)
        let initialDetailText = [
            sessionDetailText(for: session),
            recentSendStatsText(for: sendResults),
            loopOccupancyText(for: session),
            "最近发送结果\n加载中…",
            "提示词历史\n加载中…"
        ].joined(separator: "\n\n")
        sessionDetailView.string = initialDetailText
        sessionDetailView.scrollToBeginningOfDocument(nil)
        updateActivityLogControls()
        if isFilteringActivityLogBySelectedSession {
            refreshActivityLogView(scrollToEnd: false)
        }

        sessionDetailLoadGeneration += 1
        let generation = sessionDetailLoadGeneration
        let threadID = session.threadID

        DispatchQueue.global(qos: .utility).async {
            let historyText = self.loadPromptHistoryText(for: session)
            let sendResults = self.recentSendResults(for: session)
            let detailText = [
                self.sessionDetailText(for: session),
                self.recentSendStatsText(for: sendResults),
                self.loopOccupancyText(for: session),
                self.recentSendResultsText(for: sendResults),
                "提示词历史\n\(historyText)"
            ].joined(separator: "\n\n")

            DispatchQueue.main.async {
                guard self.sessionDetailLoadGeneration == generation else { return }
                guard self.sessionStatusTableView.selectedRow >= 0, self.sessionStatusTableView.selectedRow < self.sessionSnapshots.count else { return }
                guard self.sessionSnapshots[self.sessionStatusTableView.selectedRow].threadID == threadID else { return }
                self.sessionDetailView.string = detailText
                self.sessionDetailView.scrollToBeginningOfDocument(nil)
            }
        }
    }

    private func currentConfiguredModelProvider() -> String? {
        guard let text = try? String(contentsOfFile: codexConfigPath, encoding: .utf8) else {
            return nil
        }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("model_provider") else { continue }
            guard let equalsIndex = line.firstIndex(of: "=") else { continue }
            let rawValue = line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmed = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private func sessionProviderPlan(threadID: String, targetProvider: String) -> [String: String]? {
        let result = runStandardHelper(arguments: ["thread-provider-plan", "-t", threadID, "-p", targetProvider])
        guard result.status == 0 else { return nil }
        return parseStructuredHelperFields(result.stdout)
    }

    private func allSessionProviderPlan(targetProvider: String) -> [String: String]? {
        let result = runStandardHelper(arguments: ["thread-provider-plan-all", "-p", targetProvider])
        guard result.status == 0 else { return nil }
        return parseStructuredHelperFields(result.stdout)
    }

    private func migrateSessionProvider(threadID: String, targetProvider: String, includeFamily: Bool) -> (success: Bool, detail: String) {
        var arguments = ["thread-provider-migrate", "-t", threadID, "-p", targetProvider]
        if includeFamily {
            arguments.append("--family")
        }
        let result = runStandardHelper(arguments: arguments)
        if result.status == 0 {
            return (true, result.stdout)
        }
        return (false, [result.stderr, result.stdout].first { !$0.isEmpty } ?? "迁移 provider 失败")
    }

    private func migrateAllSessionsProvider(targetProvider: String) -> (success: Bool, detail: String) {
        let result = runStandardHelper(arguments: ["thread-provider-migrate-all", "-p", targetProvider])
        if result.status == 0 {
            return (true, result.stdout)
        }
        return (false, [result.stderr, result.stdout].first { !$0.isEmpty } ?? "迁移全部 session provider 失败")
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

        if !didApplyInitialSessionStatusSplitRatio,
           sessionStatusSplitView.subviews.count == 2,
           sessionStatusSplitView.bounds.height > sessionStatusSplitView.dividerThickness {
            setSessionStatusSplitRatio(0.56)
            didApplyInitialSessionStatusSplitRatio = true
            lastSessionStatusSplitHeight = sessionStatusSplitView.bounds.height
        }

        if !didApplyInitialContentSplitRatio,
           contentSplitView.subviews.count == 2,
           contentSplitView.bounds.height > contentSplitView.dividerThickness {
            setContentSplitRatio(0.62)
            didApplyInitialContentSplitRatio = true
            lastContentSplitHeight = contentSplitView.bounds.height
        }
    }

    private func forceInitialTopSplitRatioAfterAppearIfNeeded() {
        guard !didForceInitialTopSplitRatioAfterAppear else { return }
        didForceInitialTopSplitRatioAfterAppear = true

        let applyHalfWidth: () -> Void = { [weak self] in
            guard let self else { return }
            guard self.topSplitView.subviews.count == 2,
                  self.topSplitView.bounds.width > self.topSplitView.dividerThickness else {
                return
            }
            self.setTopSplitRatio(0.5)
            self.didApplyInitialTopSplitRatio = true
            self.lastTopSplitWidth = self.topSplitView.bounds.width
        }

        DispatchQueue.main.async(execute: applyHalfWidth)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: applyHalfWidth)
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

    private func preserveSessionStatusSplitRatioOnResizeIfNeeded() {
        guard sessionStatusSplitView.subviews.count == 2 else { return }
        let currentHeight = sessionStatusSplitView.bounds.height
        guard currentHeight > sessionStatusSplitView.dividerThickness else { return }

        defer { lastSessionStatusSplitHeight = currentHeight }

        guard didApplyInitialSessionStatusSplitRatio else { return }
        guard abs(currentHeight - lastSessionStatusSplitHeight) > 0.5 else { return }
        setSessionStatusSplitRatio(sessionStatusSplitRatio)
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

    private func setSessionStatusSplitRatio(_ ratio: CGFloat) {
        guard sessionStatusSplitView.subviews.count == 2 else { return }
        let availableHeight = sessionStatusSplitView.bounds.height - sessionStatusSplitView.dividerThickness
        guard availableHeight > 0 else { return }

        let clampedRatio = min(max(ratio, 0.28), 0.82)
        isApplyingSessionStatusSplitRatio = true
        sessionStatusSplitView.setPosition(availableHeight * clampedRatio, ofDividerAt: 0)
        sessionStatusSplitRatio = clampedRatio
        isApplyingSessionStatusSplitRatio = false
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

    private func updateSessionStatusSplitRatioFromCurrentLayout() {
        guard !isApplyingSessionStatusSplitRatio else { return }
        guard didApplyInitialSessionStatusSplitRatio else { return }
        guard sessionStatusSplitView.subviews.count == 2 else { return }
        let availableHeight = sessionStatusSplitView.bounds.height - sessionStatusSplitView.dividerThickness
        guard availableHeight > 0 else { return }
        let currentTopHeight = sessionStatusSplitView.subviews[0].frame.height
        sessionStatusSplitRatio = min(max(currentTopHeight / availableHeight, 0.28), 0.82)
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
        metaLabel?.maximumNumberOfLines = 1
        metaLabel?.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metaLabel?.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let headerViews = [titleStack, headerAccessoryView].compactMap { $0 }
        let headerStack = NSStackView(views: headerViews)
        headerStack.orientation = .horizontal
        headerStack.spacing = 8
        headerStack.alignment = .firstBaseline
        headerStack.distribution = .fill

        titleStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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

    private func configureSessionFilterPopover() {
        sessionFilterStackView.orientation = .vertical
        sessionFilterStackView.alignment = .leading
        sessionFilterStackView.spacing = 6
        sessionFilterStackView.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        sessionFilterStackView.translatesAutoresizingMaskIntoConstraints = false

        let contentViewController = NSViewController()
        sessionFilterContainerView.frame = NSRect(x: 0, y: 0, width: 240, height: 10)
        sessionFilterContainerView.wantsLayer = true
        sessionFilterContainerView.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        sessionFilterContainerView.layer?.cornerRadius = 8
        sessionFilterContainerView.layer?.borderWidth = 1
        sessionFilterContainerView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        sessionFilterContainerView.addSubview(sessionFilterStackView)
        NSLayoutConstraint.activate([
            sessionFilterStackView.leadingAnchor.constraint(equalTo: sessionFilterContainerView.leadingAnchor),
            sessionFilterStackView.trailingAnchor.constraint(equalTo: sessionFilterContainerView.trailingAnchor),
            sessionFilterStackView.topAnchor.constraint(equalTo: sessionFilterContainerView.topAnchor),
            sessionFilterStackView.bottomAnchor.constraint(equalTo: sessionFilterContainerView.bottomAnchor)
        ])
        contentViewController.view = sessionFilterContainerView

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 10),
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
        sessionFilterPanel = panel
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

    private func installTableSelectionOutsideMonitor() {
        removeTableSelectionOutsideMonitor()
        tableSelectionOutsideLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.handleTableSelectionMouseDown(event)
            return event
        }
    }

    private func removeTableSelectionOutsideMonitor() {
        if let tableSelectionOutsideLocalMonitor {
            NSEvent.removeMonitor(tableSelectionOutsideLocalMonitor)
            self.tableSelectionOutsideLocalMonitor = nil
        }
    }

    private func viewContainsWindowPoint(_ view: NSView?, windowPoint: NSPoint) -> Bool {
        guard let view else { return false }
        let point = view.convert(windowPoint, from: nil)
        return view.bounds.contains(point)
    }

    private func anyViewContainsWindowPoint(_ views: [NSView], windowPoint: NSPoint) -> Bool {
        views.contains { viewContainsWindowPoint($0, windowPoint: windowPoint) }
    }

    private func handleTableSelectionMouseDown(_ event: NSEvent) {
        guard let window = view.window, event.window == window else { return }

        let windowPoint = event.locationInWindow
        let activeScrollView = activeLoopsTableView.enclosingScrollView
        let sessionScrollView = sessionStatusTableView.enclosingScrollView
        let isInActiveLoopActionArea = anyViewContainsWindowPoint(
            [stopButton, resumeLoopButton, deleteLoopButton],
            windowPoint: windowPoint
        )
        let isInSessionActionArea = anyViewContainsWindowPoint(
            [saveRenameButton, archiveSessionButton, restoreSessionButton, deleteSessionButton, migrateSessionProviderButton, migrateAllSessionsProviderButton, exportSessionLogButton],
            windowPoint: windowPoint
        )
        let isInActiveLoopsArea = viewContainsWindowPoint(activeScrollView, windowPoint: windowPoint) || viewContainsWindowPoint(activeLoopsTableView.headerView, windowPoint: windowPoint)
        let isInSessionStatusArea = viewContainsWindowPoint(sessionScrollView, windowPoint: windowPoint) || viewContainsWindowPoint(sessionStatusTableView.headerView, windowPoint: windowPoint)

        if isInActiveLoopActionArea {
            if sessionStatusTableView.selectedRow >= 0 {
                sessionStatusTableView.deselectAll(nil)
                updateSessionDetailView()
            }
            return
        }

        if isInSessionActionArea {
            if activeLoopsTableView.selectedRow >= 0 {
                preferredLoopSelectionTarget = nil
                isProgrammaticLoopSelectionChange = true
                activeLoopsTableView.deselectAll(nil)
                isProgrammaticLoopSelectionChange = false
                updateLoopActionButtons()
                refreshTableWrapping(activeLoopsTableView)
            }
            return
        }

        if isInActiveLoopsArea {
            if sessionStatusTableView.selectedRow >= 0 {
                sessionStatusTableView.deselectAll(nil)
                updateSessionDetailView()
            }
            let pointInActiveTable = activeLoopsTableView.convert(windowPoint, from: nil)
            if !activeLoopsTableView.bounds.contains(pointInActiveTable) || activeLoopsTableView.row(at: pointInActiveTable) < 0 {
                preferredLoopSelectionTarget = nil
                isProgrammaticLoopSelectionChange = true
                activeLoopsTableView.deselectAll(nil)
                isProgrammaticLoopSelectionChange = false
                updateLoopActionButtons()
                refreshTableWrapping(activeLoopsTableView)
            }
            return
        }

        if isInSessionStatusArea {
            if activeLoopsTableView.selectedRow >= 0 {
                preferredLoopSelectionTarget = nil
                isProgrammaticLoopSelectionChange = true
                activeLoopsTableView.deselectAll(nil)
                isProgrammaticLoopSelectionChange = false
                updateLoopActionButtons()
                refreshTableWrapping(activeLoopsTableView)
            }
            let pointInSessionTable = sessionStatusTableView.convert(windowPoint, from: nil)
            if !sessionStatusTableView.bounds.contains(pointInSessionTable) || sessionStatusTableView.row(at: pointInSessionTable) < 0 {
                sessionStatusTableView.deselectAll(nil)
                updateSessionDetailView()
                refreshTableWrapping(sessionStatusTableView)
            }
            return
        }

        var didChangeSelection = false
        if activeLoopsTableView.selectedRow >= 0 {
            preferredLoopSelectionTarget = nil
            isProgrammaticLoopSelectionChange = true
            activeLoopsTableView.deselectAll(nil)
            isProgrammaticLoopSelectionChange = false
            updateLoopActionButtons()
            refreshTableWrapping(activeLoopsTableView)
            didChangeSelection = true
        }
        if sessionStatusTableView.selectedRow >= 0 {
            sessionStatusTableView.deselectAll(nil)
            updateSessionDetailView()
            refreshTableWrapping(sessionStatusTableView)
            didChangeSelection = true
        }
        if didChangeSelection {
            view.window?.makeFirstResponder(nil)
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

    private func isSessionFilterPanelShown() -> Bool {
        sessionFilterPanel?.isVisible == true
    }

    private func sessionFilterItems(for kind: SessionFilterKind) -> [String] {
        ["__all__"] + sessionFilterOptions(for: kind)
    }

    @objc
    private func handleSessionFilterCheckbox(_ sender: NSButton) {
        guard let item = sender.identifier?.rawValue else { return }
        toggleSessionFilterSelection(item: item)
    }

    private func makeSessionFilterCheckbox(item: String, selected: Bool) -> NSButton {
        let button = NSButton(checkboxWithTitle: item == "__all__" ? "全部" : item, target: self, action: #selector(handleSessionFilterCheckbox(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(item)
        button.state = selected ? .on : .off
        button.setButtonType(.switch)
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 18).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        return button
    }

    private func toggleSessionFilterSelection(item: String) {
        guard let kind = sessionFilterPanelKind else { return }
        if item == "__all__" {
            setSelectedFilterValues([], for: kind)
        } else {
            var selections = selectedFilterValues(for: kind)
            if selections.contains(item) {
                selections.remove(item)
            } else {
                selections.insert(item)
            }
            setSelectedFilterValues(selections, for: kind)
        }

        rebuildSessionFilterPanel(kind: kind)
        renderSessionSnapshots(
            scannedCount: lastSessionRenderScannedCount,
            totalCount: lastSessionRenderTotalCount,
            isComplete: lastSessionRenderIsComplete
        )
    }

    private func closeSessionFilterPanel() {
        sessionFilterPanel?.orderOut(nil)
        sessionFilterPanelKind = nil
        sessionFilterPanelColumnIdentifier = nil
        sessionFilterPanelHeaderView = nil
        if let sessionFilterOutsideLocalMonitor {
            NSEvent.removeMonitor(sessionFilterOutsideLocalMonitor)
            self.sessionFilterOutsideLocalMonitor = nil
        }
        if let sessionFilterOutsideGlobalMonitor {
            NSEvent.removeMonitor(sessionFilterOutsideGlobalMonitor)
            self.sessionFilterOutsideGlobalMonitor = nil
        }
        updateSessionFilterHeaderIndicators()
    }

    private func installSessionFilterOutsideMonitors(headerView: NSTableHeaderView) {
        if let sessionFilterOutsideLocalMonitor {
            NSEvent.removeMonitor(sessionFilterOutsideLocalMonitor)
            self.sessionFilterOutsideLocalMonitor = nil
        }
        if let sessionFilterOutsideGlobalMonitor {
            NSEvent.removeMonitor(sessionFilterOutsideGlobalMonitor)
            self.sessionFilterOutsideGlobalMonitor = nil
        }

        sessionFilterOutsideLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, self.isSessionFilterPanelShown() else { return event }
            if let window = event.window, window == self.sessionFilterPanel {
                return event
            }

            let eventLocation = NSEvent.mouseLocation
            if let panel = self.sessionFilterPanel, panel.frame.contains(eventLocation) {
                return event
            }

            if let window = headerView.window,
               let columnIdentifier = self.sessionFilterPanelColumnIdentifier,
               let columnIndex = headerView.tableView?.column(withIdentifier: NSUserInterfaceItemIdentifier(columnIdentifier)),
               columnIndex >= 0 {
                let activeColumnRect = headerView.headerRect(ofColumn: columnIndex)
                let activeColumnRectInWindow = headerView.convert(activeColumnRect, to: nil)
                let activeColumnRectOnScreen = window.convertToScreen(activeColumnRectInWindow)
                if activeColumnRectOnScreen.contains(eventLocation) {
                    return event
                }
            }

            self.closeSessionFilterPanel()
            return event
        }

        sessionFilterOutsideGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.closeSessionFilterPanel()
            }
        }
    }

    private func rebuildSessionFilterPanel(kind: SessionFilterKind) {
        sessionFilterPanelKind = kind
        sessionFilterStackView.arrangedSubviews.forEach { view in
            sessionFilterStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let width = max(sessionFilterPanel?.frame.width ?? 220, 180)

        let items = sessionFilterItems(for: kind)
        let selectedValues = selectedFilterValues(for: kind)
        for item in items {
            let isSelected = item == "__all__" ? selectedValues.isEmpty : selectedValues.contains(item)
            let checkbox = makeSessionFilterCheckbox(item: item, selected: isSelected)
            sessionFilterStackView.addArrangedSubview(checkbox)
        }

        let rowHeight: CGFloat = 18
        let verticalPadding = sessionFilterStackView.edgeInsets.top + sessionFilterStackView.edgeInsets.bottom
        let contentHeight = max(verticalPadding + (CGFloat(items.count) * rowHeight) + (CGFloat(max(items.count - 1, 0)) * sessionFilterStackView.spacing), 44)
        sessionFilterContainerView.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
        sessionFilterPanel?.contentViewController?.view.frame = sessionFilterContainerView.frame
        sessionFilterPanel?.setContentSize(NSSize(width: width, height: contentHeight))
        updateSessionFilterHeaderIndicators()
    }

    private func makeHistoryArrowButton(action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.bezelStyle = .rounded
        button.image = chevronDownImage(pointSize: 11, weight: .medium)
        button.imagePosition = .imageOnly
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

    private func currentActivityLogQuery() -> String {
        activityLogSearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isActivityLogFailuresOnlyEnabled() -> Bool {
        activityLogFailuresOnlyCheckbox.state == .on
    }

    private func displayedActivityLogEntries() -> [ActivityLogEntry] {
        let normalizedQuery = currentActivityLogQuery().localizedLowercase
        let selectedSession = isFilteringActivityLogBySelectedSession ? selectedSessionSnapshot() : nil

        return activityLogEntries.filter { entry in
            if isActivityLogFailuresOnlyEnabled(), !entry.isFailure {
                return false
            }
            if !normalizedQuery.isEmpty, !entry.normalizedText.contains(normalizedQuery) {
                return false
            }
            if let selectedSession, !activityLogEntry(entry, matches: selectedSession) {
                return false
            }
            return true
        }
    }

    private func activityLogEntry(_ entry: ActivityLogEntry, matches session: SessionSnapshot) -> Bool {
        var candidates = sessionPossibleTargets(session)
        candidates.append(session.threadID)
        let tty = session.tty.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tty.isEmpty {
            candidates.append(tty)
            candidates.append("/dev/\(tty)")
        }

        let normalizedText = entry.normalizedText
        for rawCandidate in candidates {
            let candidate = rawCandidate.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
            guard !candidate.isEmpty else { continue }

            let anchoredPatterns = [
                "target: \(candidate)",
                "target=\(candidate)",
                "thread_id: \(candidate)",
                "thread_id=\(candidate)",
                "session id: \(candidate)",
                "session id=\(candidate)",
                "tty: \(candidate)",
                "tty=\(candidate)",
                "/dev/\(candidate)",
                " -t \(candidate)",
                "'\(candidate)'"
            ]
            if anchoredPatterns.contains(where: { normalizedText.contains($0) }) {
                return true
            }

            if candidate.count >= 12 || candidate.contains("-") || candidate.contains("/") {
                if normalizedText.contains(candidate) {
                    return true
                }
            }
        }

        return false
    }

    private func renderedActivityLogText(for entries: [ActivityLogEntry]) -> String {
        entries.map(\.renderedText).joined()
    }

    private func updateActivityLogMetaLabel(displayedCount: Int? = nil) {
        let shown = displayedCount ?? displayedActivityLogEntries().count
        let total = activityLogEntries.count
        guard total > 0 else {
            var emptyText = "显示 0 / 0"
            if isFilteringActivityLogBySelectedSession {
                emptyText += " | 当前 Session"
            }
            activityLogMetaLabel.stringValue = emptyText
            return
        }

        var parts = ["显示 \(shown) / \(total)"]
        if isActivityLogFailuresOnlyEnabled() {
            parts.append("仅失败")
        }
        if isFilteringActivityLogBySelectedSession {
            if let session = selectedSessionSnapshot() {
                let title = sessionActualName(session)
                parts.append("当前 Session: \(title.isEmpty ? session.threadID : title)")
            } else {
                parts.append("当前 Session: 未选择")
            }
        }
        let query = currentActivityLogQuery()
        if !query.isEmpty {
            parts.append("筛选: \(query)")
        }
        activityLogMetaLabel.stringValue = parts.joined(separator: " | ")
    }

    private func refreshActivityLogView(scrollToEnd: Bool) {
        let entries = displayedActivityLogEntries()
        outputView.string = renderedActivityLogText(for: entries)
        outputView.needsDisplay = true
        if scrollToEnd {
            outputView.scrollToEndOfDocument(nil)
        } else {
            outputView.scrollToBeginningOfDocument(nil)
        }
        updateActivityLogMetaLabel(displayedCount: entries.count)
        updateActivityLogControls()
    }

    private func updateActivityLogControls() {
        let hasSelection = selectedSessionSnapshot() != nil
        exportSessionLogButton.isEnabled = hasSelection
        activityLogSelectedSessionCheckbox.state = isFilteringActivityLogBySelectedSession ? .on : .off
        activityLogSelectedSessionCheckbox.isEnabled = hasSelection || isFilteringActivityLogBySelectedSession
    }

    private func defaultSessionLogFilename(for session: SessionSnapshot) -> String {
        let preferred = sessionActualName(session).isEmpty ? session.threadID : sessionActualName(session)
        let sanitized = preferred
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "codex_taskmaster_session_log_\(sanitized)_\(Self.logFilenameFormatter.string(from: Date())).log"
    }

    private func setButtonsEnabled(_ enabled: Bool) {
        [sendButton, startButton, refreshLoopsButton, stopAllButton].forEach { $0.isEnabled = enabled }
        detectStatusButton.isEnabled = true
        if enabled {
            updateLoopActionButtons()
            updateSessionDetailView()
        } else {
            stopButton.isEnabled = false
            resumeLoopButton.isEnabled = false
            deleteLoopButton.isEnabled = false
            saveRenameButton.isEnabled = false
            archiveSessionButton.isEnabled = false
            restoreSessionButton.isEnabled = false
            deleteSessionButton.isEnabled = false
            migrateSessionProviderButton.isEnabled = false
            migrateAllSessionsProviderButton.isEnabled = false
        }
    }

    private func updateDetectStatusButtonState() {
        detectStatusButton.title = isSessionScanRunning ? "停止检测" : "检测状态"
        detectStatusButton.isEnabled = true
    }

    private func appendOutput(_ text: String) {
        let timestamp = Date()
        let prefix = Self.timestampFormatter.string(from: timestamp)
        let normalized = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : "  \($0)" }
            .joined(separator: "\n")
        let line = "[\(prefix)]\n\(normalized)\n\n"
        let normalizedText = text.localizedLowercase
        let isFailure = normalizedText.contains("status=failed")
            || normalizedText.contains("stderr:")
            || normalizedText.contains("发送请求失败")
            || normalizedText.contains("失败")
        activityLogEntries.append(
            ActivityLogEntry(
                timestamp: timestamp,
                sourceText: text,
                renderedText: line,
                normalizedText: normalizedText,
                isFailure: isFailure
            )
        )
        refreshActivityLogView(scrollToEnd: true)
    }

    @objc
    private func clearActivityLog() {
        activityLogEntries.removeAll()
        refreshActivityLogView(scrollToEnd: false)
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
                try renderedActivityLogText(for: displayedActivityLogEntries()).write(to: url, atomically: true, encoding: .utf8)
                setStatus("日志已保存到 \(url.lastPathComponent)", key: "general")
            } catch {
                NSSound.beep()
                appendOutput("stderr: 保存日志失败: \(error.localizedDescription)")
                setStatus("保存日志失败", key: "general")
            }
        }
    }

    @objc
    private func exportSelectedSessionLogs() {
        guard let session = selectedSessionSnapshot() else {
            appendOutput("请先选择一条 Session，再导出相关日志。")
            setStatus("请选择一个 Session", key: "general")
            NSSound.beep()
            return
        }

        let matchingEntries = activityLogEntries.filter { activityLogEntry($0, matches: session) }
        guard !matchingEntries.isEmpty else {
            appendOutput("当前选中的 Session 暂无匹配日志可导出。")
            setStatus("当前 Session 暂无日志", key: "general")
            NSSound.beep()
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = defaultSessionLogFilename(for: session)

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try renderedActivityLogText(for: matchingEntries).write(to: url, atomically: true, encoding: .utf8)
                setStatus("已导出当前 Session 日志", key: "general")
            } catch {
                NSSound.beep()
                appendOutput("stderr: 导出当前 Session 日志失败: \(error.localizedDescription)")
                setStatus("导出 Session 日志失败", key: "general")
            }
        }
    }

    @objc
    private func toggleActivityLogFailuresOnly() {
        refreshActivityLogView(scrollToEnd: false)
    }

    @objc
    private func toggleActivityLogSelectedSessionFilter() {
        if activityLogSelectedSessionCheckbox.state == .on {
            guard selectedSessionSnapshot() != nil else {
                activityLogSelectedSessionCheckbox.state = .off
                setStatus("请先选择一个 Session，再启用当前 Session 日志过滤", key: "general")
                NSSound.beep()
                return
            }
            isFilteringActivityLogBySelectedSession = true
        } else {
            isFilteringActivityLogBySelectedSession = false
        }
        refreshActivityLogView(scrollToEnd: false)
    }

    private func setStatus(_ text: String, key: String = "general") {
        setStatus(text, key: key, color: nil)
    }

    private func setStatus(_ text: String, key: String, color: NSColor?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        statusSegmentClearWorkItems[key]?.cancel()
        statusSegmentClearWorkItems.removeValue(forKey: key)

        if trimmed.isEmpty {
            statusSegments.removeValue(forKey: key)
            statusSegmentColors.removeValue(forKey: key)
        } else {
            statusSegments[key] = trimmed
            statusSegmentColors[key] = resolvedStatusColor(text: trimmed, key: key, explicitColor: color)
            if let delay = statusAutoClearDelay(for: trimmed, key: key) {
                scheduleStatusAutoClear(key: key, expectedText: trimmed, delay: delay)
            }
        }

        refreshVisibleStatusLabel()
    }

    private func resolvedStatusColor(text: String, key: String, explicitColor: NSColor?) -> NSColor {
        if let explicitColor {
            return explicitColor
        }

        if isStatusProgress(text) {
            return .systemBlue
        }
        if isStatusFailure(text) {
            return .systemRed
        }
        if isStatusWarning(text) {
            return .systemOrange
        }
        if isStatusSuccess(text) {
            return .systemGreen
        }
        return key == "general" ? .secondaryLabelColor : .tertiaryLabelColor
    }

    private func statusAutoClearDelay(for text: String, key: String) -> TimeInterval? {
        if isStatusProgress(text) {
            return nil
        }

        switch key {
        case "send":
            if isStatusFailure(text) {
                return 12
            }
            if text.contains("待确认") || text.contains("已受理") || text.contains("已排队") {
                return 9
            }
            if isStatusSuccess(text) {
                return 5
            }
            return 7
        case "action":
            if isStatusFailure(text) {
                return 10
            }
            if isStatusWarning(text) {
                return 7
            }
            if isStatusSuccess(text) {
                return 4
            }
            return 6
        case "scan":
            if isStatusFailure(text) {
                return 10
            }
            if isStatusSuccess(text) {
                return 4
            }
            return 6
        case "general":
            if isStatusFailure(text) {
                return 10
            }
            if isStatusWarning(text) {
                return 8
            }
            return 4
        default:
            if isStatusFailure(text) {
                return 10
            }
            if isStatusSuccess(text) {
                return 4
            }
            return 6
        }
    }

    private func scheduleStatusAutoClear(key: String, expectedText: String, delay: TimeInterval) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.statusSegments[key] == expectedText else { return }
            self.statusSegments.removeValue(forKey: key)
            self.statusSegmentColors.removeValue(forKey: key)
            self.statusSegmentClearWorkItems.removeValue(forKey: key)
            self.refreshVisibleStatusLabel()
        }
        statusSegmentClearWorkItems[key] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func isStatusProgress(_ text: String) -> Bool {
        text.contains("执行中") || text.contains("保存名称中") || text.contains("归档 Session 中") ||
        text.contains("恢复归档中") || text.contains("彻底删除中") || text.contains("读取已归档 session 中")
    }

    private func isStatusFailure(_ text: String) -> Bool {
        text.contains("失败") || text.contains("缺少辅助功能权限") || text.contains("目标不唯一")
    }

    private func isStatusWarning(_ text: String) -> Bool {
        text.contains("已受理") || text.contains("待确认") || text.contains("已排队") ||
        text.contains("已取消") || text.contains("请选择") || text.contains("无效")
    }

    private func isStatusSuccess(_ text: String) -> Bool {
        text.contains("完成") || text.contains("已加载") || text.contains("已保存") ||
        text.contains("已清空") || text.contains("已填入") || text.contains("Ready") ||
        text.contains("已停止")
    }

    private func refreshVisibleStatusLabel() {
        let orderedKeys = ["send", "action", "scan", "general"]
        if let winningKey = orderedKeys.first(where: { statusSegments[$0]?.isEmpty == false }),
           let winningText = statusSegments[winningKey] {
            statusLabel.stringValue = winningText
            statusLabel.textColor = statusSegmentColors[winningKey] ?? .secondaryLabelColor
            return
        }

        if let fallback = statusSegments
            .filter({ !$0.value.isEmpty && !orderedKeys.contains($0.key) })
            .sorted(by: { $0.key < $1.key })
            .first {
            statusLabel.stringValue = fallback.value
            statusLabel.textColor = statusSegmentColors[fallback.key] ?? .secondaryLabelColor
            return
        }

        statusLabel.stringValue = "Ready"
        statusLabel.textColor = .secondaryLabelColor
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
            self?.sendRequestCoordinator.processPendingRequests()
        }
        if let requestTimer {
            RunLoop.main.add(requestTimer, forMode: .common)
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
                    stopped: current["stopped"] ?? "no",
                    stoppedReason: current["stopped_reason"] ?? "",
                    paused: current["paused"] ?? "no",
                    failureCount: current["failure_count"] ?? "0",
                    failureReason: current["failure_reason"] ?? "",
                    pauseReason: current["pause_reason"] ?? "",
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
            if line == "no active loops" || line == "no loops" {
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

    private func maybeShowLoopAmbiguityAlerts(_ loops: [LoopSnapshot]) {
        var currentSignatures: Set<String> = []
        for loop in loops {
            let reasons = [loop.stoppedReason, loop.pauseReason, loop.failureReason]
            let hasAmbiguousReason = reasons.contains { $0 == "ambiguous_target" }
            let logMentionsAmbiguous = loop.lastLogLine.contains("ambiguous_target")
            guard hasAmbiguousReason || logMentionsAmbiguous else { continue }
            let detail = loop.lastLogLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "target=\(loop.target) | reason=ambiguous_target"
                : loop.lastLogLine
            let signature = "\(loop.target)|\(detail)"
            currentSignatures.insert(signature)
            guard !announcedLoopAmbiguitySignatures.contains(signature) else { continue }
            appendOutput("警告：循环目标 \(loop.target) 当前匹配到多个同名 Session，请改用 Session ID，或先为它们设置不同名称。")
            setStatus("检测到目标不唯一: \(loop.target)", key: "general", color: .systemRed)
        }
        announcedLoopAmbiguitySignatures = currentSignatures
    }

    private func parseSessionCountOutput(_ output: String) -> Int? {
        Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func formatEpoch(_ rawValue: String) -> String {
        guard let epoch = TimeInterval(rawValue) else { return rawValue }
        return Self.loopTimeFormatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    private func renderSessionSnapshots(scannedCount: Int? = nil, totalCount: Int? = nil, isComplete: Bool = true) {
        let selectedThreadID = selectedSessionThreadID()
        lastSessionRenderScannedCount = scannedCount
        lastSessionRenderTotalCount = totalCount
        lastSessionRenderIsComplete = isComplete
        rebuildDisplayedSessionSnapshots(preserveSelectionThreadID: selectedThreadID)
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

    private func showAmbiguousTargetAlert(target: String, detail: String, actionName: String, throttled: Bool) {
        let normalizedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "目标不唯一"
        alert.informativeText = "存在多个同名 Session，无法直接\(actionName)。请改用 Session ID，或先为它们设置不同名称。\n\n\(normalizedDetail)"
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }

    @discardableResult
    private func saveStoppedLoopEntry(target: String, interval: String, message: String, forceSend: Bool, reason: String) -> Bool {
        if loopSnapshots.contains(where: { $0.target == target && $0.stopped != "yes" }) {
            return false
        }
        var arguments = ["loop-save-stopped", "-t", target, "-i", interval, "-m", message, "-r", reason]
        if forceSend {
            arguments.append("-f")
        }
        let result = runStandardHelper(arguments: arguments)
        if result.status != 0 {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            if !detail.isEmpty {
                appendOutput("stderr: \(detail)")
            }
            return false
        }
        return true
    }

    private func isAmbiguousTargetError(_ detail: String) -> Bool {
        detail.contains("found multiple matching sessions for target") ||
        detail.contains("found multiple matching thread titles for target") ||
        detail.contains("found multiple matching Terminal ttys for target")
    }

    private func validateUniqueTarget(_ target: String, actionName: String) -> Bool {
        lastTargetValidationFailureReason = nil
        lastTargetValidationFailureDetail = ""
        let result = runStandardHelper(arguments: ["resolve-thread-id", "-t", target])
        guard result.status == 0 else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            if isAmbiguousTargetError(detail) {
                lastTargetValidationFailureReason = "ambiguous_target"
                lastTargetValidationFailureDetail = detail
                showAmbiguousTargetAlert(target: target, detail: detail, actionName: actionName, throttled: false)
                appendOutput("已阻止\(actionName)：目标 \(target) 匹配到多个 Session。")
                setStatus("目标不唯一", key: "general", color: .systemRed)
                return false
            }
            lastTargetValidationFailureReason = "start_failed"
            lastTargetValidationFailureDetail = detail
            appendOutput("stderr: \(detail)")
            setStatus("\(actionName)前校验失败", key: "general", color: .systemRed)
            NSSound.beep()
            return false
        }
        return true
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

    private func sendStatusContextText(probeStatus: String?, terminalState: String?) -> String {
        let probeLabel = localizedProbeStatus(probeStatus ?? "")
        let terminalLabel = localizedLoopTerminalState(terminalState ?? "")
        let parts = [probeLabel, terminalLabel].filter { !$0.isEmpty }
        return parts.joined(separator: " | ")
    }

    private func sendOutcomeStatusText(kind: String, target: String, reason: String, probeStatus: String?, terminalState: String?) -> String {
        let localizedReason = localizedSendReason(reason)
        let contextText = sendStatusContextText(probeStatus: probeStatus, terminalState: terminalState)
        let suffix = [localizedReason, contextText].filter { !$0.isEmpty }.joined(separator: " | ")
        switch kind {
        case "success":
            return suffix.isEmpty ? "发送成功: \(target)" : "发送成功: \(target) | \(suffix)"
        case "accepted":
            return suffix.isEmpty ? "发送已受理: \(target)" : "发送已受理: \(target) | \(suffix)"
        case "failed":
            return suffix.isEmpty ? "发送失败: \(target)" : "发送失败: \(target) | \(suffix)"
        default:
            return "发送状态更新: \(target)"
        }
    }

    private func isStructuredSendHelperResult(_ text: String) -> Bool {
        parseStructuredSendHelperResult(text) != nil
    }

    private func parseStructuredSendHelperResult(_ text: String) -> [String: String]? {
        guard let fields = parseStructuredHelperFields(text),
              fields["target"] != nil else {
            return nil
        }
        return fields
    }

    private func parseStructuredHelperFields(_ text: String) -> [String: String]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var fields: [String: String] = [:]
        for rawLine in trimmed.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let range = line.range(of: ": ") else { continue }
            let key = String(line[..<range.lowerBound])
            let value = String(line[range.upperBound...])
            fields[key] = value
        }

        guard fields["status"] != nil, fields["reason"] != nil else {
            return nil
        }
        return fields
    }

    private func showSessionActionBlockedAlert(actionLabel: String, session: SessionSnapshot, detail: String, ambiguous: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = ambiguous ? "无法\(actionLabel)目标不唯一的活跃 Session" : "无法\(actionLabel)仍在运行的 Session"
        let sessionName = sessionActualName(session)
        let nameLine = sessionName.isEmpty ? "-" : sessionName
        let cleanedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultDetail = ambiguous
            ? "这个 session 仍然对应多个活跃 Terminal/Codex 目标，当前无法安全\(actionLabel)。请先关闭重复打开的 session，再重试。"
            : "这个 session 仍然有活跃的 Terminal/Codex 进程，当前不允许\(actionLabel)。请先关闭对应 Terminal 标签页或结束该 session，再重试。"
        alert.informativeText = """
        Session ID: \(session.threadID)
        Name: \(nameLine)

        \(cleanedDetail.isEmpty ? defaultDetail : cleanedDetail)
        """
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    private func runHelper(arguments: [String], actionName: String) {
        persistDefaults()
        setStatus("", key: "send")
        setButtonsEnabled(false)
        setStatus("\(actionName)执行中…", key: "action")
        appendOutput("执行 \(actionName): \(arguments.joined(separator: " "))")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.runStandardHelper(arguments: arguments)

            DispatchQueue.main.async {
                let accepted = (actionName == "发送一次") && result.status == 2
                if !result.stdout.isEmpty {
                    self.appendOutput(result.stdout)
                }
                let structuredSendResult =
                    actionName == "发送一次" ? self.parseStructuredSendHelperResult(result.stderr) : nil
                if !result.stderr.isEmpty {
                    if structuredSendResult == nil {
                        self.appendOutput(accepted ? result.stderr : "stderr: \(result.stderr)")
                    }
                }

                if result.status == 0 || accepted {
                    if actionName == "发送一次" || actionName == "开始循环" {
                        self.recordCurrentInputsInHistory()
                    }
                    self.setStatus(accepted ? "\(actionName)已受理" : "\(actionName)完成", key: "action")
                } else {
                    if let structuredSendResult,
                       structuredSendResult["reason"] == "ambiguous_target" {
                        let detail = structuredSendResult["detail"] ?? result.stderr
                        let target = structuredSendResult["target"] ?? self.currentTarget()
                        self.showAmbiguousTargetAlert(target: target, detail: detail, actionName: actionName, throttled: false)
                    }
                    self.setStatus("\(actionName)失败", key: "action", color: .systemRed)
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
            return loopSnapshots.filter { targets.contains($0.target) && $0.stopped != "yes" }
        }

        return loopSnapshots.filter { $0.target == trimmedTarget && $0.stopped != "yes" }
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
                if startResult.status != 0, failureText != nil {
                    _ = self.saveStoppedLoopEntry(target: target, interval: interval, message: message, forceSend: forceSend, reason: "start_failed")
                    self.appendOutput("已将开始失败的循环保留为停止状态。")
                }
                if startResult.status == 0 {
                    self.recordCurrentInputsInHistory()
                    self.setStatus("开始循环完成", key: "action")
                } else {
                    self.setStatus("开始循环失败", key: "action", color: .systemRed)
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
        let stoppedMode = activeSessionScanMode ?? displayedSessionListMode

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
            renderSessionSnapshots(scannedCount: allSessionSnapshots.count, totalCount: sessionScanTotal, isComplete: false)
            sessionStatusMetaLabel.stringValue += " | 已停止"
        } else {
            sessionStatusMetaLabel.stringValue = "视图: \(sessionScopeText(for: stoppedMode)) | 检测已停止。"
            sessionStatusTableView.reloadData()
        }
        activeSessionScanMode = nil
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
                    self.resumeLoopButton.isEnabled = false
                    self.deleteLoopButton.isEnabled = false
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
                        self.activeLoopsMetaLabel.stringValue = self.loopWarnings.first ?? "No loops."
                    } else {
                        let warningSuffix = self.loopWarnings.isEmpty ? "" : " | warnings: \(self.loopWarnings.count)"
                        self.activeLoopsMetaLabel.stringValue = "Loops: \(self.loopSnapshots.count)\(warningSuffix)"
                    }
                    self.maybeShowLoopAmbiguityAlerts(self.loopSnapshots)
                } else {
                    self.loopSnapshots = []
                    self.loopWarnings = [errText.isEmpty ? "Failed to load active loops." : errText]
                    self.activeLoopsMetaLabel.stringValue = self.loopWarnings.first ?? "Failed to load active loops."
                }
                self.activeLoopsTableView.reloadData()
                self.autoSizeActiveLoopsColumnsIfNeeded()
                self.restoreLoopSelection(preferredTarget: nil)
                self.refreshTableWrapping(self.activeLoopsTableView)
                self.updateLoopActionButtons()
                if self.sessionStatusTableView.selectedRow >= 0 {
                    self.updateSessionDetailView()
                }
            }
        }
    }

    private func refreshSessionStatuses() {
        setStatus("", key: "send")
        if isSessionScanRunning {
            stopSessionStatusScan()
            return
        }

        if currentSessionListMode() == .archived {
            refreshArchivedSessions()
            return
        }

        activeSessionScanMode = .active
        displayedSessionListMode = .active
        isSessionScanRunning = true
        sessionScanShouldStop = false
        sessionScanGeneration += 1
        let generation = sessionScanGeneration
        sessionScanTotal = 0
        updateDetectStatusButtonState()
        setStatus("检测状态执行中…", key: "scan")
        appendOutput("执行 检测状态: session-count + probe-all batches")
        invalidateSessionSearch(resetPromptCache: true)
        allSessionSnapshots = []
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
                    self.activeSessionScanMode = nil
                    self.updateDetectStatusButtonState()
                    self.allSessionSnapshots = []
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
                    self.activeSessionScanMode = nil
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

                let batchSnapshots = parseProbeAllOutput(batchResult.stdout)
                scannedCount = min(totalCount, offset + batchSize)

                DispatchQueue.main.async {
                    guard self.sessionScanGeneration == generation else { return }
                    self.allSessionSnapshots = mergeSessionSnapshots(existing: self.allSessionSnapshots, newSnapshots: batchSnapshots)
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
                self.activeSessionScanMode = nil
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
        activeSessionScanMode = .archived
        displayedSessionListMode = .archived
        isSessionScanRunning = true
        sessionScanShouldStop = false
        sessionScanGeneration += 1
        let generation = sessionScanGeneration
        sessionScanTotal = 0
        updateDetectStatusButtonState()
        setStatus("读取已归档 session 中…", key: "scan")
        appendOutput("执行 检测状态: thread-list --archived")
        invalidateSessionSearch(resetPromptCache: true)
        allSessionSnapshots = []
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
                self.activeSessionScanMode = nil
                self.updateDetectStatusButtonState()

                if result.status != 0 {
                    self.allSessionSnapshots = []
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

                let snapshots = parseThreadListOutput(result.stdout, archived: true)
                self.allSessionSnapshots = snapshots
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
        guard validateUniqueTarget(target, actionName: "发送") else {
            NSSound.beep()
            return
        }
        guard sendRequestCoordinator.ensurePermission(prompt: true) else {
            appendOutput("Codex Taskmaster 缺少辅助功能权限，无法发送按键。请在 系统设置 > 隐私与安全性 > 辅助功能 中允许它。")
            setStatus("缺少辅助功能权限", key: "general", color: .systemRed)
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
        guard validateUniqueTarget(target, actionName: "开始循环") else {
            let reason = lastTargetValidationFailureReason ?? "start_failed"
            _ = saveStoppedLoopEntry(target: target, interval: interval, message: currentMessage(), forceSend: isForceSendEnabled(), reason: reason)
            setStatus("开始循环失败", key: "action", color: .systemRed)
            refreshLoopsSnapshot()
            NSSound.beep()
            return
        }
        guard sendRequestCoordinator.ensurePermission(prompt: true) else {
            appendOutput("Codex Taskmaster 缺少辅助功能权限，无法处理循环发送。请在 系统设置 > 隐私与安全性 > 辅助功能 中允许它。")
            setStatus("缺少辅助功能权限", key: "general", color: .systemRed)
            _ = saveStoppedLoopEntry(target: target, interval: interval, message: currentMessage(), forceSend: isForceSendEnabled(), reason: "missing_accessibility_permission")
            setStatus("开始循环失败", key: "action", color: .systemRed)
            refreshLoopsSnapshot()
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
    private func toggleSessionPromptSearch() {
        scheduleSessionSearchRefresh()
    }

    @objc
    private func changeSessionScope() {
        let requestedMode = currentSessionListMode()
        if isSessionScanRunning {
            let activeMode = activeSessionScanMode ?? displayedSessionListMode
            sessionScopeControl.selectedSegment = activeMode == .archived ? 1 : 0
            setStatus("请等待当前检测完成或手动停止后再切换", key: "scan", color: .systemOrange)
            appendOutput("检测状态仍在进行中，已保持当前视图为\(sessionScopeText(for: activeMode))。")
            return
        }

        guard requestedMode != displayedSessionListMode else {
            setStatus("当前视图切换为\(displayedSessionScopeText())", key: "scan")
            return
        }

        invalidateSessionSearch(resetPromptCache: true)
        sessionStatusTableView.reloadData()
        updateSessionDetailView()
        setStatus("已切换到\(requestedSessionScopeText())视图，点击“检测状态”刷新", key: "scan", color: .systemOrange)
        appendOutput("已切换 Session Status 视图到\(requestedSessionScopeText())；当前列表仍显示上次\(displayedSessionScopeText())检测结果，点击“检测状态”后刷新。")
    }

    @objc
    private func stopLoop() {
        guard let loop = selectedLoopSnapshot() else {
            appendOutput("请先在 Active Loops 中选择一条循环任务。")
            setStatus("请选择一个循环任务")
            NSSound.beep()
            return
        }
        guard loop.stopped != "yes" else {
            appendOutput("当前选中的循环已经是停止状态。")
            setStatus("当前循环已停止", key: "action")
            NSSound.beep()
            return
        }
        targetField.stringValue = loop.target
        runHelper(arguments: ["stop", "-t", loop.target], actionName: "停止当前")
    }

    @objc
    private func stopAllLoops() {
        runHelper(arguments: ["stop", "--all"], actionName: "全部停止")
    }

    @objc
    private func resumeSelectedLoop() {
        guard let loop = selectedLoopSnapshot() else {
            appendOutput("请先在 Active Loops 中选择一条循环任务。")
            setStatus("请选择一个循环任务")
            NSSound.beep()
            return
        }
        guard loop.paused == "yes" || loop.stopped == "yes" else {
            appendOutput("当前选中的循环既不是暂停状态，也不是停止状态。")
            setStatus("当前循环不可恢复", key: "action")
            NSSound.beep()
            return
        }

        guard validateUniqueTarget(loop.target, actionName: "恢复当前") else {
            setStatus("恢复当前失败", key: "action", color: .systemRed)
            refreshLoopsSnapshot()
            NSSound.beep()
            return
        }

        guard sendRequestCoordinator.ensurePermission(prompt: true) else {
            appendOutput("Codex Taskmaster 缺少辅助功能权限，无法恢复循环发送。请在 系统设置 > 隐私与安全性 > 辅助功能 中允许它。")
            setStatus("缺少辅助功能权限", key: "general", color: .systemRed)
            setStatus("恢复当前失败", key: "action", color: .systemRed)
            NSSound.beep()
            return
        }

        targetField.stringValue = loop.target
        runHelper(arguments: ["loop-resume", "-t", loop.target], actionName: "恢复当前")
    }

    @objc
    private func deleteSelectedLoop() {
        guard let loop = selectedLoopSnapshot() else {
            appendOutput("请先在 Active Loops 中选择一条循环任务。")
            setStatus("请选择一个循环任务")
            NSSound.beep()
            return
        }

        targetField.stringValue = loop.target
        runHelper(arguments: ["loop-delete", "-t", loop.target], actionName: "删除当前")
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
        migrateSessionProviderButton.isEnabled = false
        migrateAllSessionsProviderButton.isEnabled = false
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
                self.migrateSessionProviderButton.isEnabled = self.currentConfiguredModelProvider() != nil && self.sessionStatusTableView.selectedRow >= 0
                self.migrateAllSessionsProviderButton.isEnabled = self.currentConfiguredModelProvider() != nil

                if result.success {
                    if let index = self.allSessionSnapshots.firstIndex(where: { $0.threadID == session.threadID }) {
                        let previous = self.allSessionSnapshots[index]
                        self.allSessionSnapshots[index] = SessionSnapshot(
                            name: newName,
                            target: newName.isEmpty ? previous.threadID : newName,
                            threadID: previous.threadID,
                            provider: previous.provider,
                            source: previous.source,
                            parentThreadID: previous.parentThreadID,
                            agentNickname: previous.agentNickname,
                            agentRole: previous.agentRole,
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
                    self.invalidateSessionSearch()
                    self.renderSessionSnapshots(
                        scannedCount: self.lastSessionRenderScannedCount,
                        totalCount: self.lastSessionRenderTotalCount,
                        isComplete: self.lastSessionRenderIsComplete
                    )
                    self.selectSessionRow(threadID: session.threadID)
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
        migrateSessionProviderButton.isEnabled = false
        migrateAllSessionsProviderButton.isEnabled = false
        renameField.isEnabled = false
        setStatus("归档 Session 中…", key: "action")
        appendOutput("执行 归档 Session: thread_id=\(session.threadID)")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.archiveSession(threadID: session.threadID)

            DispatchQueue.main.async {
                if result.success {
                    self.allSessionSnapshots.removeAll { $0.threadID == session.threadID }
                    self.sessionSnapshots.removeAll { $0.threadID == session.threadID }
                    if self.sessionScanTotal > 0 {
                        self.sessionScanTotal = max(0, self.sessionScanTotal - 1)
                    }
                    self.invalidateSessionSearch()
                    self.renderSessionSnapshots(
                        scannedCount: self.allSessionSnapshots.count,
                        totalCount: self.sessionScanTotal > 0 ? self.sessionScanTotal : self.allSessionSnapshots.count,
                        isComplete: true
                    )
                    self.setStatus("归档 Session 完成", key: "action")
                    self.appendOutput("已归档 session: \(session.threadID)")
                    self.refreshLoopsSnapshot()
                } else {
                    if let fields = self.parseStructuredHelperFields(result.error) {
                        let reason = fields["reason"] ?? ""
                        if reason == "session_archive_live" || reason == "session_archive_live_ambiguous" {
                            let detail = fields["detail"] ?? result.error
                            self.showSessionActionBlockedAlert(actionLabel: "归档", session: session, detail: detail, ambiguous: reason == "session_archive_live_ambiguous")
                        }
                    }
                    self.renameField.isEnabled = self.sessionStatusTableView.selectedRow >= 0
                    self.saveRenameButton.isEnabled = self.sessionStatusTableView.selectedRow >= 0
                    self.archiveSessionButton.isEnabled = self.sessionStatusTableView.selectedRow >= 0
                    self.restoreSessionButton.isEnabled = false
                    self.deleteSessionButton.isEnabled = self.sessionStatusTableView.selectedRow >= 0
                    self.migrateSessionProviderButton.isEnabled = self.currentConfiguredModelProvider() != nil && self.sessionStatusTableView.selectedRow >= 0
                    self.migrateAllSessionsProviderButton.isEnabled = self.currentConfiguredModelProvider() != nil
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
        migrateSessionProviderButton.isEnabled = false
        migrateAllSessionsProviderButton.isEnabled = false
        renameField.isEnabled = false
        setStatus("恢复归档中…", key: "action")
        appendOutput("执行 恢复归档: thread_id=\(session.threadID)")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.unarchiveSession(threadID: session.threadID)

            DispatchQueue.main.async {
                if result.success {
                    self.allSessionSnapshots.removeAll { $0.threadID == session.threadID }
                    self.sessionSnapshots.removeAll { $0.threadID == session.threadID }
                    if self.sessionScanTotal > 0 {
                        self.sessionScanTotal = max(0, self.sessionScanTotal - 1)
                    }
                    self.invalidateSessionSearch()
                    self.renderSessionSnapshots(
                        scannedCount: self.allSessionSnapshots.count,
                        totalCount: self.sessionScanTotal > 0 ? self.sessionScanTotal : self.allSessionSnapshots.count,
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
                    self.migrateSessionProviderButton.isEnabled = self.currentConfiguredModelProvider() != nil && self.sessionStatusTableView.selectedRow >= 0
                    self.migrateAllSessionsProviderButton.isEnabled = self.currentConfiguredModelProvider() != nil
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
        migrateSessionProviderButton.isEnabled = false
        migrateAllSessionsProviderButton.isEnabled = false
        renameField.isEnabled = false
        setStatus("彻底删除中…", key: "action")
        appendOutput("执行 彻底删除: thread_id=\(session.threadID)")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.deleteSessionPermanently(threadID: session.threadID)

            DispatchQueue.main.async {
                if result.success {
                    self.allSessionSnapshots.removeAll { $0.threadID == session.threadID }
                    self.sessionSnapshots.removeAll { $0.threadID == session.threadID }
                    if self.sessionScanTotal > 0 {
                        self.sessionScanTotal = max(0, self.sessionScanTotal - 1)
                    }
                    self.invalidateSessionSearch()
                    self.renderSessionSnapshots(
                        scannedCount: self.allSessionSnapshots.count,
                        totalCount: self.sessionScanTotal > 0 ? self.sessionScanTotal : self.allSessionSnapshots.count,
                        isComplete: true
                    )
                    self.setStatus("彻底删除完成", key: "action")
                    self.appendOutput(result.detail.isEmpty ? "已彻底删除 session: \(session.threadID)" : result.detail)
                    self.refreshLoopsSnapshot()
                } else {
                    if let fields = self.parseStructuredHelperFields(result.detail) {
                        let reason = fields["reason"] ?? ""
                        if reason == "session_delete_live" || reason == "session_delete_live_ambiguous" {
                            let detail = fields["detail"] ?? result.detail
                            self.showSessionActionBlockedAlert(actionLabel: "删除", session: session, detail: detail, ambiguous: reason == "session_delete_live_ambiguous")
                        }
                    }
                    self.updateSessionDetailView()
                    self.setStatus("彻底删除失败", key: "action")
                    self.appendOutput("stderr: \(result.detail)")
                    NSSound.beep()
                }
            }
        }
    }

    @objc
    private func migrateSelectedSessionToCurrentProvider() {
        guard let session = selectedSessionSnapshot() else {
            appendOutput("请先选择一条 session，再迁移 provider。")
            setStatus("请选择一个 session")
            NSSound.beep()
            return
        }
        guard let targetProvider = currentConfiguredModelProvider() else {
            appendOutput("未能从 ~/.codex/config.toml 读取当前 model_provider。")
            setStatus("当前 provider 未配置", key: "action")
            NSSound.beep()
            return
        }

        guard let plan = sessionProviderPlan(threadID: session.threadID, targetProvider: targetProvider) else {
            appendOutput("读取 session provider 迁移计划失败。")
            setStatus("读取迁移计划失败", key: "action")
            NSSound.beep()
            return
        }

        let isSubagent = (plan["is_subagent"] ?? "no") == "yes"
        let familyCount = Int(plan["family_count"] ?? "1") ?? 1
        let familyMigrateNeeded = Int(plan["family_migrate_needed_count"] ?? "0") ?? 0
        let currentProvider = plan["current_provider"] ?? session.provider
        let directChildCount = Int(plan["direct_child_count"] ?? "0") ?? 0

        var includeFamily = false
        if isSubagent || directChildCount > 0 {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "迁移相关 Session 到当前 Provider？"
            alert.informativeText = """
            当前 Provider: \(targetProvider)
            选中 Session 当前 Provider: \(currentProvider.isEmpty ? "-" : currentProvider)
            Session ID: \(session.threadID)
            Type: \(sessionTypeLabel(session))

            这条 session \(isSubagent ? "属于子 agent 会话" : "存在子 agent 会话")。
            相关会话总数: \(familyCount)
            需要迁移的相关会话数: \(familyMigrateNeeded)

            你可以只迁移当前这一条，也可以递归迁移整组相关 session。
            """
            alert.addButton(withTitle: "迁移相关")
            alert.addButton(withTitle: "仅迁移当前")
            alert.addButton(withTitle: "取消")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                includeFamily = true
            } else if response != .alertSecondButtonReturn {
                return
            }
        } else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "迁移当前 Session 到当前 Provider？"
            alert.informativeText = """
            当前 Provider: \(targetProvider)
            选中 Session 当前 Provider: \(currentProvider.isEmpty ? "-" : currentProvider)
            Session ID: \(session.threadID)
            Type: \(sessionTypeLabel(session))
            """
            alert.addButton(withTitle: "迁移")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
        }

        setButtonsEnabled(false)
        setStatus("迁移 Session Provider 中…", key: "action")
        appendOutput("执行 迁移 Session Provider: thread_id=\(session.threadID) target_provider=\(targetProvider) scope=\(includeFamily ? "family" : "current")")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.migrateSessionProvider(threadID: session.threadID, targetProvider: targetProvider, includeFamily: includeFamily)
            DispatchQueue.main.async {
                self.setButtonsEnabled(true)
                if result.success {
                    self.setStatus("迁移 Session Provider 完成", key: "action")
                    self.appendOutput(result.detail)
                    self.detectStatuses()
                } else {
                    self.setStatus("迁移 Session Provider 失败", key: "action")
                    self.appendOutput("stderr: \(result.detail)")
                    NSSound.beep()
                }
            }
        }
    }

    @objc
    private func migrateAllSessionsToCurrentProvider() {
        guard let targetProvider = currentConfiguredModelProvider() else {
            appendOutput("未能从 ~/.codex/config.toml 读取当前 model_provider。")
            setStatus("当前 provider 未配置", key: "action")
            NSSound.beep()
            return
        }
        guard let plan = allSessionProviderPlan(targetProvider: targetProvider) else {
            appendOutput("读取全部 session provider 迁移计划失败。")
            setStatus("读取迁移计划失败", key: "action")
            NSSound.beep()
            return
        }

        let migrateNeeded = Int(plan["migrate_needed_count"] ?? "0") ?? 0
        let totalThreads = Int(plan["total_threads"] ?? "0") ?? 0
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "将所有 Session 迁移到当前 Provider？"
        alert.informativeText = """
        当前 Provider: \(targetProvider)
        本地 Session 总数: \(totalThreads)
        需要迁移的 Session 数: \(migrateNeeded)

        这会直接改写本地 state_5.sqlite 中的 threads.model_provider。
        不会改写 source，也不会重写 rollout 文件。
        """
        alert.addButton(withTitle: "全部迁移")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        setButtonsEnabled(false)
        setStatus("迁移全部 Session Provider 中…", key: "action")
        appendOutput("执行 全部迁移 Session Provider: target_provider=\(targetProvider)")

        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.migrateAllSessionsProvider(targetProvider: targetProvider)
            DispatchQueue.main.async {
                self.setButtonsEnabled(true)
                if result.success {
                    self.setStatus("迁移全部 Session Provider 完成", key: "action")
                    self.appendOutput(result.detail)
                    self.detectStatuses()
                } else {
                    self.setStatus("迁移全部 Session Provider 失败", key: "action")
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
            textField.font = tableCellFont
            textField.lineBreakMode = .byTruncatingTail
            textField.maximumNumberOfLines = 1
            textField.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            cellView.addSubview(textField)
            cellView.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: tableCellHorizontalPadding / 2),
                textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -(tableCellHorizontalPadding / 2)),
                textField.topAnchor.constraint(equalTo: cellView.topAnchor, constant: tableCellVerticalPadding / 2),
                textField.bottomAnchor.constraint(equalTo: cellView.bottomAnchor, constant: -(tableCellVerticalPadding / 2))
            ])
        }

        textField.textColor = .labelColor
        let wrapsText = shouldWrapRow(row, in: tableView)
        textField.lineBreakMode = wrapsText ? .byWordWrapping : .byTruncatingTail
        textField.maximumNumberOfLines = wrapsText ? 0 : 1
        textField.toolTip = nil

        if tableView == activeLoopsTableView {
            if row >= loopSnapshots.count {
                textField.textColor = .systemOrange
                textField.stringValue = tableColumn == activeLoopsTableView.tableColumns.first ? (loopWarnings.first ?? "Warning") : ""
                textField.toolTip = textField.stringValue
                return cellView
            }

            let loop = loopSnapshots[row]
            let columnID = tableColumn.identifier.rawValue
            textField.stringValue = stringValueForLoopColumn(columnID, loop: loop)
            if columnID == "state" {
                textField.textColor = loopStateColor(loop)
            } else if columnID == "result" {
                textField.textColor = loopResultColor(loop)
            }
            textField.toolTip = textField.stringValue
            return cellView
        }

        let session = sessionSnapshots[row]
        let columnID = tableColumn.identifier.rawValue
        textField.stringValue = stringValueForSessionColumn(columnID, session: session)
        switch columnID {
        case "status":
            textField.textColor = sessionStatusColor(session)
        default:
            break
        }
        textField.toolTip = textField.stringValue
        return cellView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView else { return }
        if tableView == activeLoopsTableView {
            let selectedRow = tableView.selectedRow
            if selectedRow >= 0, selectedRow < loopSnapshots.count {
                let selectedTarget = loopSnapshots[selectedRow].target
                preferredLoopSelectionTarget = selectedTarget
                if !isProgrammaticLoopSelectionChange {
                    targetField.stringValue = selectedTarget
                }
            } else {
                preferredLoopSelectionTarget = nil
            }
            updateLoopActionButtons()
            refreshTableWrapping(activeLoopsTableView)
            return
        }
        if tableView == sessionStatusTableView {
            refreshTableWrapping(sessionStatusTableView)
            updateSessionDetailView()
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if tableView == activeLoopsTableView {
            guard row < loopSnapshots.count else { return tableBaseRowHeight }
            return wrappedRowHeight(for: row, in: tableView)
        }
        if tableView == sessionStatusTableView {
            guard row < sessionSnapshots.count else { return tableBaseRowHeight }
            return wrappedRowHeight(for: row, in: tableView)
        }
        return tableBaseRowHeight
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        if tableView == activeLoopsTableView {
            applyLoopSorting()
            activeLoopsTableView.reloadData()
            adjustTableColumnWidths(activeLoopsTableView)
            didAutoSizeActiveLoopsColumns = true
            refreshTableWrapping(activeLoopsTableView)
            return
        }
        if tableView == sessionStatusTableView {
            applySessionSorting()
            sessionStatusTableView.reloadData()
            adjustTableColumnWidths(sessionStatusTableView)
            didAutoSizeSessionColumns = true
            refreshTableWrapping(sessionStatusTableView)
            updateSessionDetailView()
        }
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView else { return }
        if tableView == activeLoopsTableView || tableView == sessionStatusTableView {
            refreshTableWrapping(tableView)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field == intervalField else { return }
        _ = validateAndCommitIntervalField(showAlert: true)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field == sessionSearchField {
            scheduleSessionSearchRefresh()
            return
        }
        if field == activityLogSearchField {
            refreshActivityLogView(scrollToEnd: false)
        }
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let splitView = notification.object as? NSSplitView else { return }
        if splitView == topSplitView {
            let widthDelta = abs(topSplitView.bounds.width - lastTopSplitWidth)
            if widthDelta <= 0.5 {
                updateTopSplitRatioFromCurrentLayout()
            }
        } else if splitView == sessionStatusSplitView {
            let heightDelta = abs(sessionStatusSplitView.bounds.height - lastSessionStatusSplitHeight)
            if heightDelta <= 0.5 {
                updateSessionStatusSplitRatioFromCurrentLayout()
            }
        } else if splitView == contentSplitView {
            let heightDelta = abs(contentSplitView.bounds.height - lastContentSplitHeight)
            if heightDelta <= 0.5 {
                updateContentSplitRatioFromCurrentLayout()
            }
        }
    }

    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        guard splitView == topSplitView || splitView == sessionStatusSplitView || splitView == contentSplitView else {
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
            let minLeading: CGFloat = 220
            let minTrailing: CGFloat = 180
            return min(max(proposedPosition, minLeading), availableWidth - minTrailing)
        }

        if splitView == sessionStatusSplitView {
            let availableHeight = splitView.bounds.height - splitView.dividerThickness
            guard availableHeight > 0 else { return proposedPosition }
            let minTop: CGFloat = 110
            let minBottom: CGFloat = 92
            return min(max(proposedPosition, minTop), availableHeight - minBottom)
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
