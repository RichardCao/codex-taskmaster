import AppKit
import ApplicationServices
import UniformTypeIdentifiers

private let userHomeDirectory = NSHomeDirectory()
private let autoRefreshInterval: TimeInterval = 3
private let requestPollInterval: TimeInterval = 0.5
private let stateDirectoryPath = "\(userHomeDirectory)/.codex-terminal-sender"
private let pendingRequestDirectoryPath = "\(stateDirectoryPath)/requests/pending"
private let processingRequestDirectoryPath = "\(stateDirectoryPath)/requests/processing"
private let resultRequestDirectoryPath = "\(stateDirectoryPath)/requests/results"
private let loopsDirectoryPath = "\(stateDirectoryPath)/loops"
private let runtimeDirectoryPath = "\(stateDirectoryPath)/runtime"
private let loopLogDirectoryPath = "\(runtimeDirectoryPath)/loop-logs"
private let userLoopStateDirectoryPath = "\(runtimeDirectoryPath)/user-loop-state"
private let legacyLoopStateDirectoryPath = "\(runtimeDirectoryPath)/loop-state"
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

final class RatioSplitView: NSView {
    var dividerThickness: CGFloat = 10 {
        didSet { needsLayout = true }
    }

    var minLeadingWidth: CGFloat = 120 {
        didSet { needsLayout = true }
    }

    var minTrailingWidth: CGFloat = 120 {
        didSet { needsLayout = true }
    }

    var ratio: CGFloat = 0.5 {
        didSet { needsLayout = true }
    }

    private var leadingView: NSView?
    private var trailingView: NSView?
    private var isDraggingDivider = false

    func configure(leading: NSView, trailing: NSView) {
        leadingView?.removeFromSuperview()
        trailingView?.removeFromSuperview()
        leadingView = leading
        trailingView = trailing

        [leading, trailing].forEach { view in
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }

        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let leadingView, let trailingView else { return }

        let availableWidth = max(0, bounds.width - dividerThickness)
        let clamped = clampedRatio(for: ratio)
        if abs(clamped - ratio) > 0.0001 {
            ratio = clamped
            return
        }

        let leadingWidth = floor(availableWidth * clamped)
        let trailingWidth = max(0, availableWidth - leadingWidth)
        let fullHeight = bounds.height

        leadingView.frame = NSRect(x: 0, y: 0, width: leadingWidth, height: fullHeight)
        trailingView.frame = NSRect(x: leadingWidth + dividerThickness, y: 0, width: trailingWidth, height: fullHeight)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = dividerRect
        guard !rect.isEmpty else { return }

        NSColor.windowBackgroundColor.setFill()
        rect.fill()

        let lineThickness: CGFloat = 1
        let lineRect = NSRect(
            x: rect.midX - (lineThickness / 2),
            y: rect.minY + 2,
            width: lineThickness,
            height: max(0, rect.height - 4)
        )

        NSColor.tertiaryLabelColor.withAlphaComponent(0.22).setFill()
        lineRect.fill()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(dividerRect.insetBy(dx: -4, dy: 0), cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard dividerRect.insetBy(dx: -4, dy: 0).contains(point) else {
            super.mouseDown(with: event)
            return
        }

        isDraggingDivider = true
        updateRatio(for: point.x)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingDivider else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        updateRatio(for: point.x)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDraggingDivider else {
            super.mouseUp(with: event)
            return
        }
        isDraggingDivider = false
        let point = convert(event.locationInWindow, from: nil)
        updateRatio(for: point.x)
    }

    private var dividerRect: NSRect {
        guard bounds.width > dividerThickness else { return .zero }
        let availableWidth = max(0, bounds.width - dividerThickness)
        let leadingWidth = floor(availableWidth * clampedRatio(for: ratio))
        return NSRect(x: leadingWidth, y: 0, width: dividerThickness, height: bounds.height)
    }

    private func updateRatio(for leadingWidth: CGFloat) {
        let availableWidth = bounds.width - dividerThickness
        guard availableWidth > 0 else { return }
        ratio = clampedRatio(for: leadingWidth / availableWidth)
    }

    private func clampedRatio(for ratio: CGFloat) -> CGFloat {
        let availableWidth = bounds.width - dividerThickness
        guard availableWidth > 0 else { return min(max(ratio, 0), 1) }

        let minRatio = min(0.5, minLeadingWidth / availableWidth)
        let maxRatio = max(0.5, 1 - (minTrailingWidth / availableWidth))
        return min(max(ratio, minRatio), maxRatio)
    }
}

final class VerticalRatioSplitView: NSView {
    var dividerThickness: CGFloat = 10 {
        didSet { needsLayout = true }
    }

    var minTopHeight: CGFloat = 126 {
        didSet { needsLayout = true }
    }

    var minBottomHeight: CGFloat = 90 {
        didSet { needsLayout = true }
    }

    var ratio: CGFloat = 0.66 {
        didSet { needsLayout = true }
    }

    private var topView: NSView?
    private var bottomView: NSView?
    private var isDraggingDivider = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        autoresizesSubviews = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(top: NSView, bottom: NSView) {
        topView?.removeFromSuperview()
        bottomView?.removeFromSuperview()
        topView = top
        bottomView = bottom

        [top, bottom].forEach { view in
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }

        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let topView, let bottomView else { return }

        let availableHeight = max(0, bounds.height - dividerThickness)
        let clamped = clampedRatio(for: ratio)
        let topHeight = floor(availableHeight * clamped)
        let bottomHeight = max(0, availableHeight - topHeight)
        let fullWidth = bounds.width

        bottomView.frame = NSRect(x: 0, y: 0, width: fullWidth, height: bottomHeight)
        topView.frame = NSRect(x: 0, y: bottomHeight + dividerThickness, width: fullWidth, height: topHeight)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = dividerRect
        guard !rect.isEmpty else { return }

        NSColor.windowBackgroundColor.setFill()
        rect.fill()

        let lineThickness: CGFloat = 1
        let lineRect = NSRect(
            x: rect.minX + 2,
            y: rect.midY - (lineThickness / 2),
            width: max(0, rect.width - 4),
            height: lineThickness
        )

        NSColor.tertiaryLabelColor.withAlphaComponent(0.22).setFill()
        lineRect.fill()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(dividerRect.insetBy(dx: 0, dy: -4), cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard dividerRect.insetBy(dx: 0, dy: -4).contains(point) else {
            super.mouseDown(with: event)
            return
        }

        isDraggingDivider = true
        updateRatio(forY: point.y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingDivider else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        updateRatio(forY: point.y)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDraggingDivider else {
            super.mouseUp(with: event)
            return
        }
        isDraggingDivider = false
        let point = convert(event.locationInWindow, from: nil)
        updateRatio(forY: point.y)
    }

    private var dividerRect: NSRect {
        guard bounds.height > dividerThickness else { return .zero }
        let availableHeight = max(0, bounds.height - dividerThickness)
        let topHeight = floor(availableHeight * clampedRatio(for: ratio))
        let bottomHeight = max(0, availableHeight - topHeight)
        return NSRect(x: 0, y: bottomHeight, width: bounds.width, height: dividerThickness)
    }

    private func updateRatio(forY y: CGFloat) {
        let availableHeight = bounds.height - dividerThickness
        guard availableHeight > 0 else { return }
        let topHeight = availableHeight - y
        ratio = clampedRatio(for: topHeight / availableHeight)
    }

    private func clampedRatio(for proposedRatio: CGFloat) -> CGFloat {
        let availableHeight = bounds.height - dividerThickness
        guard availableHeight > 0 else { return min(max(proposedRatio, 0), 1) }

        let effectiveMinTop = min(minTopHeight, availableHeight)
        let effectiveMinBottom = min(minBottomHeight, max(0, availableHeight - effectiveMinTop))
        let minRatio = effectiveMinTop / availableHeight
        let maxRatio = 1 - (effectiveMinBottom / availableHeight)
        return min(max(proposedRatio, minRatio), maxRatio)
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
        do {
            let result = try SubprocessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", """
                tell application "Terminal"
                  try
                    return tty of selected tab of front window
                  on error
                    return ""
                  end try
                end tell
                """]
            )
            return result.trimmedStdout
        } catch {
            return ""
        }
    }
}

final class CodexTaskmasterApp: NSObject, NSApplicationDelegate {
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
        let helperService = HelperCommandService(helperPath: resolvedHelperPath())
        _ = helperService.run(arguments: ["stop", "--all"])
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
        contentViewController.loadViewIfNeeded()
        let minimumContentSize = contentViewController.minimumWindowContentSize
        let initialContentWidth = max(980, minimumContentSize.width)
        let initialContentHeight = max(760, minimumContentSize.height)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: initialContentWidth, height: initialContentHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Taskmaster"
        window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: minimumContentSize)).size
        window.contentMinSize = minimumContentSize
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
        static let baseTopPaneMinHeight: CGFloat = 210
        static let baseBottomPaneMinHeight: CGFloat = 106
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
    private lazy var helperService = HelperCommandService(helperPath: helperPath)
    private lazy var sessionCommandService = SessionCommandService(helperService: helperService)
    private lazy var sessionScanService = SessionScanService(helperService: helperService)
    private lazy var loopCommandService = LoopCommandService(helperService: helperService)

    private enum SessionListMode {
        case active
        case archived
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

    private struct SessionScanControlState {
        var generation = 0
        var shouldStop = false
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
    private let sessionStatusSplitView = VerticalRatioSplitView()
    private let topActionButtonRow = NSStackView()
    private let sessionScopeRow = NSStackView()
    private let sessionRenameRow = NSStackView()
    private let sessionMigrationRow = NSStackView()
    private let topSplitView = RatioSplitView()
    private let contentSplitView = AdjustableSplitView()
    private let activeLoopsPanelView = NSView()
    private let sessionStatusPanelView = NSView()
    private let outputView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "就绪")
    private let activeLoopsMetaLabel = NSTextField(labelWithString: "暂无循环。")
    private let activeLoopsWarningLabel = NSTextField(labelWithString: "")
    private let sessionStatusMetaLabel = NSTextField(labelWithString: sessionStatusInitialMetaText())
    private let activityLogMetaLabel = NSTextField(labelWithString: "显示 0 / 0")
    private var refreshTimer: Timer?
    private var requestTimer: Timer?
    private var loopSnapshots: [LoopSnapshot] = []
    private var sessionSnapshots: [SessionSnapshot] = []
    private var allSessionSnapshots: [SessionSnapshot] = []
    private var activityLogEntries: [ActivityLogEntry] = []
    private var loopWarnings: [String] = []
    private var configuredModelProvider: String?
    private var preferredLoopSelectionIdentifier: String?
    private var targetHistory: [String] = []
    private var messageHistory: [String] = []
    private var isSessionScanRunning = false
    private var sessionScanTotal = 0
    private var displayedSessionListMode: SessionListMode = .active
    private var activeSessionScanMode: SessionListMode?
    private var statusSegments: [String: String] = [:]
    private var statusSegmentColors: [String: NSColor] = [:]
    private var statusSegmentClearWorkItems: [String: DispatchWorkItem] = [:]
    private let defaultLoopSortKey = "nextRun"
    private let defaultSessionSortKey = "updatedAt"
    private var lastValidIntervalValue = "600"
    private var sessionStatusSplitRatio: CGFloat = 0.66
    private var contentSplitRatio: CGFloat = 0.62
    private var topPaneMinimumHeight: CGFloat = LayoutMetrics.baseTopPaneMinHeight
    private var bottomPaneMinimumHeight: CGFloat = LayoutMetrics.baseBottomPaneMinHeight
    private(set) var minimumWindowContentSize = NSSize(width: 760, height: 630)
    private var didApplyInitialContentSplitRatio = false
    private var lastContentSplitHeight: CGFloat = 0
    private var isApplyingContentSplitRatio = false
    private let sessionScanProcessLock = NSLock()
    private var currentSessionScanProcess: Process?
    private var sessionDetailLoadGeneration = 0
    private var lastSessionDetailThreadID: String?
    private var lastSessionDetailText = ""
    private var sessionSearchDebounceTimer: Timer?
    private var sessionSearchRevision = 0
    private var isSessionPromptSearchRunning = false
    private var sessionPromptSearchCompletedRevision: Int?
    private var sessionPromptSearchMatchedThreadIDs = Set<String>()
    private var sessionPromptSearchProgressCompleted = 0
    private var sessionPromptSearchProgressTotal = 0
    private var sessionPromptSearchCache: [String: String] = [:]
    private let sessionPromptSearchCacheLock = NSLock()
    private let sessionPromptSearchRevisionLock = NSLock()
    private var sessionPromptSearchRevisionState = 0
    private var lastSessionRenderScannedCount: Int?
    private var lastSessionRenderTotalCount: Int?
    private var lastSessionRenderIsComplete = true
    private let tableCellFont = NSFont.systemFont(ofSize: 12)
    private let tableCellHorizontalPadding: CGFloat = 12
    private let tableCellVerticalPadding: CGFloat = 6
    private let tableBaseRowHeight: CGFloat = 24
    private let tableWrappedRowHeightCap: CGFloat = 110
    private var sessionFilterSelections = SessionFilterSelections()
    private let sessionFilterContainerView = NSView()
    private let sessionFilterStackView = NSStackView()
    private let sessionScanControlLock = NSLock()
    private var sessionScanControlState = SessionScanControlState()
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
    private var isRefreshingLoopsSnapshot = false
    private var pendingLoopSnapshotRefresh = false
    private var sessionStatusRefreshTimer: Timer?
    private let sessionStatusConnectedRefreshInterval: TimeInterval = 15
    private let sessionStatusDisconnectedRefreshInterval: TimeInterval = 60
    private lazy var sessionStatusRefreshCoordinator = SessionStatusRefreshCoordinator(
        connectedRefreshInterval: sessionStatusConnectedRefreshInterval,
        disconnectedRefreshInterval: sessionStatusDisconnectedRefreshInterval
    )
    private let sessionStatusRefreshSchedulerInterval: TimeInterval = 2
    private let sessionStatusRefreshMaxConcurrentJobs = 4

    private lazy var sendButton = makeButton(title: "发送一次", action: #selector(sendOnce))
    private lazy var startButton = makeButton(title: "开始循环", action: #selector(startLoop))
    private lazy var refreshLoopsButton = makeButton(title: "刷新循环", action: #selector(refreshLoopsAction))
    private lazy var detectStatusButton = makeButton(title: "检测会话", action: #selector(detectStatuses))
    private lazy var refreshSessionStatusButton = makeButton(title: "刷新状态", action: #selector(refreshSessionStatusesAction))
    private lazy var stopButton = makeButton(title: "停止当前", action: #selector(stopLoop))
    private lazy var resumeLoopButton = makeButton(title: "恢复当前", action: #selector(resumeSelectedLoop))
    private lazy var deleteLoopButton = makeButton(title: "删除当前", action: #selector(deleteSelectedLoop))
    private lazy var stopAllButton = makeButton(title: "全部停止", action: #selector(stopAllLoops))
    private lazy var saveRenameButton = makeButton(title: "保存", action: #selector(saveSessionRename))
    private lazy var archiveSessionButton = makeButton(title: "归档", action: #selector(archiveSelectedSession))
    private lazy var restoreSessionButton = makeButton(title: "恢复", action: #selector(restoreSelectedSession))
    private lazy var deleteSessionButton = makeButton(title: "删除", action: #selector(deleteSelectedSession))
    private lazy var migrateSessionProviderButton = makeButton(title: sessionProviderMigrationButtonTitle(), action: #selector(migrateSelectedSessionToCurrentProvider))
    private lazy var migrateAllSessionsProviderButton = makeButton(title: allSessionProviderMigrationButtonTitle(), action: #selector(migrateAllSessionsToCurrentProvider))
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
            let result = self.runStandardHelper(arguments: arguments)
            return (status: result.status, stdout: result.stdout, stderr: result.stderr)
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
                        formattedSendOutcomeStatusText(
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
                    self?.scheduleLoopSnapshotRefresh()
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
        sessionStatusMetaLabel.stringValue = sessionEmptyStateText(isArchived: displayedSessionListMode == .archived)
        updateDetectStatusButtonState()
        stopButton.isEnabled = false
        resumeLoopButton.isEnabled = false
        deleteLoopButton.isEnabled = false
        installTableSelectionOutsideMonitor()
        appendOutput("Codex Taskmaster 已就绪。")
        appendOutput("循环列表会每 \(Int(autoRefreshInterval)) 秒自动刷新一次。")
        refreshConfiguredModelProviderCache()
        scheduleLoopSnapshotRefresh()
        startAutoRefresh()
        startRequestPump()
        startSessionStatusRefreshTimer()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyInitialSplitRatiosIfNeeded()
        preserveContentSplitRatioOnResizeIfNeeded()
    }

    deinit {
        stopBackgroundTimers()
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

        [sendButton, startButton, refreshLoopsButton, detectStatusButton, refreshSessionStatusButton, stopButton, resumeLoopButton, deleteLoopButton, stopAllButton].forEach {
            topActionButtonRow.addArrangedSubview($0)
        }
        topActionButtonRow.orientation = .horizontal
        topActionButtonRow.spacing = 8
        topActionButtonRow.alignment = .centerY

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let headerStack = NSStackView(views: [formGrid, topActionButtonRow, statusLabel])
        headerStack.orientation = .vertical
        headerStack.spacing = 8
        headerStack.alignment = .leading
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.setContentHuggingPriority(.required, for: .vertical)
        headerStack.setContentCompressionResistancePriority(.required, for: .vertical)
        view.addSubview(headerStack)
        headerStack.heightAnchor.constraint(equalToConstant: LayoutMetrics.headerHeight).isActive = true
        topActionButtonRow.widthAnchor.constraint(lessThanOrEqualTo: headerStack.widthAnchor).isActive = true
        formGrid.setContentHuggingPriority(.required, for: .vertical)
        topActionButtonRow.setContentHuggingPriority(.required, for: .vertical)
        statusLabel.setContentHuggingPriority(.required, for: .vertical)
        formGrid.setContentCompressionResistancePriority(.required, for: .vertical)
        topActionButtonRow.setContentCompressionResistancePriority(.required, for: .vertical)
        statusLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        configureLoopsTable()
        activeLoopsScrollView.borderType = .bezelBorder
        activeLoopsScrollView.hasVerticalScroller = true
        activeLoopsScrollView.hasHorizontalScroller = true
        activeLoopsScrollView.autohidesScrollers = false
        activeLoopsScrollView.drawsBackground = true
        activeLoopsScrollView.translatesAutoresizingMaskIntoConstraints = false
        activeLoopsScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true

        configureSessionStatusTable()
        sessionStatusScrollView.borderType = .bezelBorder
        sessionStatusScrollView.hasVerticalScroller = true
        sessionStatusScrollView.hasHorizontalScroller = true
        sessionStatusScrollView.autohidesScrollers = false
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

        renameField.placeholderString = sessionRenamePlaceholderText(isArchived: false)
        renameField.translatesAutoresizingMaskIntoConstraints = false
        disableSelectedSessionActionControls()
        archiveSessionButton.contentTintColor = .systemOrange
        restoreSessionButton.contentTintColor = .systemBlue
        deleteSessionButton.contentTintColor = .systemRed
        migrateSessionProviderButton.contentTintColor = .systemPurple
        migrateAllSessionsProviderButton.contentTintColor = .systemPurple
        saveRenameButton.toolTip = sessionRenameTooltipText()
        archiveSessionButton.toolTip = "按 Codex 原生语义归档当前 session"
        restoreSessionButton.toolTip = archivedSessionRestoreTooltipText()
        deleteSessionButton.toolTip = "从本地状态中彻底删除当前 session"
        migrateSessionProviderButton.toolTip = sessionProviderMigrationTooltipText()
        migrateAllSessionsProviderButton.toolTip = allSessionProviderMigrationTooltipText()

        [renameField, saveRenameButton, archiveSessionButton, restoreSessionButton, deleteSessionButton].forEach {
            sessionRenameRow.addArrangedSubview($0)
        }
        sessionRenameRow.orientation = .horizontal
        sessionRenameRow.spacing = 8
        sessionRenameRow.alignment = .centerY
        renameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        renameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        saveRenameButton.setContentHuggingPriority(.required, for: .horizontal)
        saveRenameButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        archiveSessionButton.setContentHuggingPriority(.required, for: .horizontal)
        archiveSessionButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        restoreSessionButton.setContentHuggingPriority(.required, for: .horizontal)
        restoreSessionButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        deleteSessionButton.setContentHuggingPriority(.required, for: .horizontal)
        deleteSessionButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        [migrateSessionProviderButton, migrateAllSessionsProviderButton].forEach {
            sessionMigrationRow.addArrangedSubview($0)
        }
        sessionMigrationRow.orientation = .horizontal
        sessionMigrationRow.spacing = 8
        sessionMigrationRow.alignment = .centerY
        migrateSessionProviderButton.setContentHuggingPriority(.required, for: .horizontal)
        migrateSessionProviderButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        migrateAllSessionsProviderButton.setContentHuggingPriority(.required, for: .horizontal)
        migrateAllSessionsProviderButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        [sessionScopeControl, sessionSearchField, sessionPromptSearchCheckbox].forEach {
            sessionScopeRow.addArrangedSubview($0)
        }
        sessionScopeRow.orientation = .horizontal
        sessionScopeRow.spacing = 8
        sessionScopeRow.alignment = .centerY
        sessionScopeControl.setContentHuggingPriority(.required, for: .horizontal)
        sessionScopeControl.setContentCompressionResistancePriority(.required, for: .horizontal)
        sessionPromptSearchCheckbox.setContentHuggingPriority(.required, for: .horizontal)
        sessionPromptSearchCheckbox.setContentCompressionResistancePriority(.required, for: .horizontal)
        sessionSearchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sessionSearchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sessionSearchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true

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

        activeLoopsWarningLabel.font = .systemFont(ofSize: 11, weight: .regular)
        activeLoopsWarningLabel.textColor = .systemOrange
        activeLoopsWarningLabel.lineBreakMode = .byWordWrapping
        activeLoopsWarningLabel.maximumNumberOfLines = 0
        activeLoopsWarningLabel.isHidden = true
        activeLoopsWarningLabel.translatesAutoresizingMaskIntoConstraints = false

        let activeLoopsContentStack = NSStackView(views: [activeLoopsWarningLabel, activeLoopsScrollView])
        activeLoopsContentStack.orientation = .vertical
        activeLoopsContentStack.spacing = 6
        activeLoopsContentStack.alignment = .leading
        activeLoopsContentStack.distribution = .fill
        activeLoopsContentStack.translatesAutoresizingMaskIntoConstraints = false
        activeLoopsWarningLabel.widthAnchor.constraint(equalTo: activeLoopsContentStack.widthAnchor).isActive = true
        activeLoopsScrollView.widthAnchor.constraint(equalTo: activeLoopsContentStack.widthAnchor).isActive = true
        activeLoopsWarningLabel.setContentHuggingPriority(.required, for: .vertical)
        activeLoopsWarningLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        activeLoopsScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        activeLoopsScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let activeLoopsPanel = makePanel(title: "循环列表", metaLabel: activeLoopsMetaLabel, contentView: activeLoopsContentStack, reusePanelView: activeLoopsPanelView)
        let sessionStatusTopStack = NSStackView(views: [sessionScopeRow, sessionStatusScrollView])
        sessionStatusTopStack.orientation = .vertical
        sessionStatusTopStack.spacing = 8
        sessionStatusTopStack.alignment = .leading
        sessionStatusTopStack.distribution = .fill
        sessionStatusTopStack.translatesAutoresizingMaskIntoConstraints = false
        sessionStatusTopStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sessionStatusTopStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sessionScopeRow.widthAnchor.constraint(equalTo: sessionStatusTopStack.widthAnchor).isActive = true
        sessionStatusScrollView.widthAnchor.constraint(equalTo: sessionStatusTopStack.widthAnchor).isActive = true

        let sessionStatusBottomStack = NSStackView(views: [sessionRenameRow, sessionMigrationRow, sessionDetailScrollView])
        sessionStatusBottomStack.orientation = .vertical
        sessionStatusBottomStack.spacing = 8
        sessionStatusBottomStack.alignment = .leading
        sessionStatusBottomStack.distribution = .fill
        sessionStatusBottomStack.translatesAutoresizingMaskIntoConstraints = false
        sessionStatusBottomStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sessionStatusBottomStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sessionRenameRow.widthAnchor.constraint(equalTo: sessionStatusBottomStack.widthAnchor).isActive = true
        sessionMigrationRow.widthAnchor.constraint(equalTo: sessionStatusBottomStack.widthAnchor).isActive = true
        sessionDetailScrollView.widthAnchor.constraint(equalTo: sessionStatusBottomStack.widthAnchor).isActive = true

        renameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        renameField.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
        sessionScopeRow.setContentHuggingPriority(.required, for: .vertical)
        sessionScopeRow.setContentCompressionResistancePriority(.required, for: .vertical)
        sessionRenameRow.setContentHuggingPriority(.required, for: .vertical)
        sessionRenameRow.setContentCompressionResistancePriority(.required, for: .vertical)
        sessionMigrationRow.setContentHuggingPriority(.required, for: .vertical)
        sessionMigrationRow.setContentCompressionResistancePriority(.required, for: .vertical)
        sessionStatusScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        sessionStatusScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        sessionStatusScrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sessionStatusScrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sessionDetailScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        sessionDetailScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        sessionDetailScrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sessionDetailScrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let topActionRowMinimumHeight = ceil(max(topActionButtonRow.fittingSize.height, sendButton.fittingSize.height))
        topActionButtonRow.heightAnchor.constraint(greaterThanOrEqualToConstant: topActionRowMinimumHeight).isActive = true

        let sessionScopeRowMinimumHeight = ceil(sessionScopeRow.fittingSize.height)
        let sessionRenameRowMinimumHeight = ceil(max(sessionRenameRow.fittingSize.height, saveRenameButton.fittingSize.height, renameField.fittingSize.height))
        let sessionMigrationRowMinimumHeight = ceil(max(sessionMigrationRow.fittingSize.height, migrateSessionProviderButton.fittingSize.height))
        let sessionTableMinimumHeight = ceil(max(sessionStatusScrollView.fittingSize.height, 90))
        let sessionDetailMinimumHeight = ceil(max(sessionDetailScrollView.fittingSize.height, 52))
        let sessionStatusTopMinimumHeight = sessionScopeRowMinimumHeight + sessionStatusTopStack.spacing + sessionTableMinimumHeight
        let sessionStatusBottomMinimumHeight = sessionRenameRowMinimumHeight + sessionStatusBottomStack.spacing + sessionMigrationRowMinimumHeight + sessionStatusBottomStack.spacing + sessionDetailMinimumHeight
        let sessionStatusSplitMinimumHeight = sessionStatusTopMinimumHeight + sessionStatusBottomMinimumHeight + sessionStatusSplitView.dividerThickness

        sessionStatusSplitView.translatesAutoresizingMaskIntoConstraints = false
        let sessionStatusTopPane = makeSplitPane(contentView: sessionStatusTopStack, minHeight: sessionStatusTopMinimumHeight)
        let sessionStatusBottomPane = makeSplitPane(contentView: sessionStatusBottomStack, minHeight: sessionStatusBottomMinimumHeight)
        sessionStatusSplitView.minTopHeight = sessionStatusTopMinimumHeight
        sessionStatusSplitView.minBottomHeight = sessionStatusBottomMinimumHeight
        sessionStatusSplitView.ratio = sessionStatusSplitRatio
        sessionStatusSplitView.configure(top: sessionStatusTopPane, bottom: sessionStatusBottomPane)
        sessionStatusSplitView.heightAnchor.constraint(greaterThanOrEqualToConstant: sessionStatusSplitMinimumHeight).isActive = true
        let sessionStatusPanel = makePanel(title: "会话状态", metaLabel: sessionStatusMetaLabel, contentView: sessionStatusSplitView, reusePanelView: sessionStatusPanelView)
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
        exportSessionLogButton.toolTip = "导出当前选中会话相关日志"
        clearLogButton.toolTip = "清空当前日志显示"
        saveLogButton.toolTip = "保存当前日志到文件"
        let logPanel = makePanel(title: "运行日志", metaLabel: activityLogMetaLabel, contentView: outputScrollView, headerAccessoryView: logFilterControls)
        let activeLoopsPanelMinimumHeight = ceil(max(activeLoopsPanel.fittingSize.height, 100))
        let sessionStatusPanelMinimumHeight = ceil(max(sessionStatusPanel.fittingSize.height, sessionStatusSplitMinimumHeight))
        topPaneMinimumHeight = max(LayoutMetrics.baseTopPaneMinHeight, activeLoopsPanelMinimumHeight, sessionStatusPanelMinimumHeight)
        bottomPaneMinimumHeight = max(LayoutMetrics.baseBottomPaneMinHeight, ceil(logPanel.fittingSize.height))
        minimumWindowContentSize = NSSize(
            width: 760,
            height: LayoutMetrics.headerOuterMargin
                + LayoutMetrics.headerHeight
                + LayoutMetrics.headerToContentSpacing
                + topPaneMinimumHeight
                + contentSplitView.dividerThickness
                + bottomPaneMinimumHeight
                + LayoutMetrics.contentBottomMargin
        )

        let activeLoopsPane = makeSplitPane(contentView: activeLoopsPanel, minWidth: 120, minHeight: activeLoopsPanelMinimumHeight)
        let sessionStatusPane = makeSplitPane(contentView: sessionStatusPanel, minWidth: 120, minHeight: sessionStatusPanelMinimumHeight)
        let topContentPane = makeSplitPane(contentView: topSplitView, minHeight: topPaneMinimumHeight)
        let logPane = makeSplitPane(contentView: logPanel, minHeight: bottomPaneMinimumHeight)
        topSplitView.translatesAutoresizingMaskIntoConstraints = false
        topSplitView.minLeadingWidth = 120
        topSplitView.minTrailingWidth = 120
        topSplitView.ratio = 0.5
        topSplitView.configure(leading: activeLoopsPane, trailing: sessionStatusPane)

        contentSplitView.isVertical = false
        contentSplitView.dividerStyle = .thin
        contentSplitView.translatesAutoresizingMaskIntoConstraints = false
        contentSplitView.delegate = self
        contentSplitView.addArrangedSubview(topContentPane)
        contentSplitView.addArrangedSubview(logPane)
        contentSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        contentSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        view.addSubview(contentSplitView)
        let minimumContentHeight = topPaneMinimumHeight + bottomPaneMinimumHeight + contentSplitView.dividerThickness
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
            ("state", "状态", 88),
            ("result", "结果", 96),
            ("reason", "原因", 138),
            ("target", "目标", 88),
            ("interval", "间隔", 72),
            ("forceSend", "模式", 72),
            ("nextRun", "下次执行", 120),
            ("message", "消息", 120),
            ("lastLog", "最近结果", 180),
            ("tailSpacer", "", 6)
        ]

        activeLoopsTableView.headerView = NSTableHeaderView()
        activeLoopsTableView.usesAlternatingRowBackgroundColors = true
        activeLoopsTableView.allowsEmptySelection = true
        activeLoopsTableView.allowsMultipleSelection = false
        activeLoopsTableView.delegate = self
        activeLoopsTableView.dataSource = self
        activeLoopsTableView.rowHeight = tableBaseRowHeight
        activeLoopsTableView.columnAutoresizingStyle = .noColumnAutoresizing
        activeLoopsTableView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        activeLoopsTableView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for column in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.identifier))
            tableColumn.title = column.title
            tableColumn.width = column.width
            if column.identifier != "tailSpacer" {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.identifier, ascending: column.identifier != defaultLoopSortKey)
            }
            tableColumn.minWidth = loopColumnMinimumWidth(column.identifier)
            tableColumn.maxWidth = loopColumnMaximumWidth(column.identifier)
            tableColumn.resizingMask = column.identifier == "tailSpacer" ? [] : .userResizingMask
            activeLoopsTableView.addTableColumn(tableColumn)
        }

        activeLoopsScrollView.documentView = activeLoopsTableView
        activeLoopsTableView.sortDescriptors = [NSSortDescriptor(key: defaultLoopSortKey, ascending: true)]
        synchronizeScrollableTableWidth(activeLoopsTableView)
    }

    private func configureSessionStatusTable() {
        let columns: [(identifier: String, title: String, width: CGFloat)] = [
            ("name", "名称", 52),
            ("type", "类型", 40),
            ("provider", "Provider", 52),
            ("threadID", "会话 ID", 88),
            ("status", "状态", 52),
            ("terminalState", "终端", 52),
            ("tty", "TTY", 40),
            ("updatedAt", "更新时间", 74),
            ("reason", "原因", 88),
            ("tailSpacer", "", 6)
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
        sessionStatusTableView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sessionStatusTableView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for column in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.identifier))
            tableColumn.title = column.title
            tableColumn.width = column.width
            if column.identifier != "tailSpacer" {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.identifier, ascending: column.identifier == defaultSessionSortKey ? false : true)
            }
            tableColumn.minWidth = sessionColumnMinimumWidth(column.identifier)
            tableColumn.maxWidth = sessionColumnMaximumWidth(column.identifier)
            tableColumn.resizingMask = column.identifier == "tailSpacer" ? [] : .userResizingMask
            sessionStatusTableView.addTableColumn(tableColumn)
        }

        sessionStatusScrollView.documentView = sessionStatusTableView
        sessionStatusTableView.sortDescriptors = [NSSortDescriptor(key: defaultSessionSortKey, ascending: false)]
        synchronizeScrollableTableWidth(sessionStatusTableView)
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
        case "tailSpacer":
            return 6
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
        case "tailSpacer":
            return 6
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

    private func stringValueForTableCell(tableView: NSTableView, identifier: String, row: Int) -> String {
        if tableView == activeLoopsTableView {
            guard row < loopSnapshots.count else { return "" }
            return formattedLoopTableCellValue(
                identifier: identifier,
                loop: loopSnapshots[row],
                allLoops: loopSnapshots,
                formatEpoch: formatEpoch(_:)
            )
        }

        guard row < sessionSnapshots.count else {
            return ""
        }
        return formattedSessionTableCellValue(
            identifier: identifier,
            session: sessionSnapshots[row],
            formatEpoch: formatEpoch(_:)
        )
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
            if identifier == "tailSpacer" {
                if abs(column.width - 6) > 0.5 {
                    column.width = 6
                }
                continue
            }
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

        synchronizeScrollableTableWidth(tableView)
    }

    private func synchronizeScrollableTableWidth(_ tableView: NSTableView) {
        let totalWidth = tableView.tableColumns.reduce(CGFloat(0)) { partial, column in
            partial + column.width
        } + CGFloat(max(0, tableView.tableColumns.count - 1)) * tableView.intercellSpacing.width
        let targetWidth = max(totalWidth, tableView.enclosingScrollView?.contentView.bounds.width ?? 0)
        var frame = tableView.frame
        if abs(frame.width - targetWidth) > 0.5 {
            frame.size.width = targetWidth
            tableView.frame = frame
        }
        if let headerView = tableView.headerView {
            var headerFrame = headerView.frame
            if abs(headerFrame.width - targetWidth) > 0.5 {
                headerFrame.size.width = targetWidth
                headerView.frame = headerFrame
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

    private func currentSessionSearchQuery() -> String {
        sessionSearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isSessionPromptSearchEnabled() -> Bool {
        sessionPromptSearchCheckbox.state == .on
    }

    private func invalidateSessionSearch(resetPromptCache: Bool = false) {
        sessionSearchRevision += 1
        sessionPromptSearchRevisionLock.lock()
        sessionPromptSearchRevisionState = sessionSearchRevision
        sessionPromptSearchRevisionLock.unlock()
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

    private func invalidatePromptSearchCache(threadIDs: [String]) {
        let validThreadIDs = Array(Set(threadIDs.filter { !$0.isEmpty }))
        guard !validThreadIDs.isEmpty else { return }

        sessionPromptSearchCacheLock.lock()
        for threadID in validThreadIDs {
            sessionPromptSearchCache.removeValue(forKey: threadID)
        }
        sessionPromptSearchCacheLock.unlock()
    }

    private func isCurrentSessionPromptSearchRevision(_ revision: Int) -> Bool {
        sessionPromptSearchRevisionLock.lock()
        defer { sessionPromptSearchRevisionLock.unlock() }
        return sessionPromptSearchRevisionState == revision
    }

    private func matchesSessionFilters(_ session: SessionSnapshot) -> Bool {
        sessionMatchesFilterValues(
            session,
            providerFilters: sessionFilterSelections.provider,
            typeFilters: sessionFilterSelections.type,
            statusFilters: sessionFilterSelections.status,
            terminalFilters: sessionFilterSelections.terminal,
            ttyFilters: sessionFilterSelections.tty
        )
    }

    private func sessionFilterOptions(for kind: SessionFilterKind) -> [String] {
        sessionFilterOptionsForKind(kind, from: allSessionSnapshots)
    }

    private func selectedFilterValues(for kind: SessionFilterKind) -> Set<String> {
        sessionFilterSelections.values(for: kind)
    }

    private func setSelectedFilterValues(_ values: Set<String>, for kind: SessionFilterKind) {
        sessionFilterSelections.setValues(values, for: kind)
        updateSessionFilterHeaderIndicators()
    }

    private func sessionFilterKind(for columnIdentifier: String) -> SessionFilterKind? {
        SessionFilterKind(columnIdentifier: columnIdentifier)
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
        formattedSessionSearchSummary(
            query: currentSessionSearchQuery(),
            hitCount: sessionSnapshots.count,
            promptSearchEnabled: isSessionPromptSearchEnabled(),
            sessionScanRunning: isSessionScanRunning,
            promptSearchRunning: isSessionPromptSearchRunning,
            promptSearchCompleted: sessionPromptSearchCompletedRevision == sessionSearchRevision,
            promptSearchProgressCompleted: sessionPromptSearchProgressCompleted,
            promptSearchProgressTotal: sessionPromptSearchProgressTotal
        )
    }

    private func updateSessionStatusMetaLabel() {
        sessionStatusMetaLabel.stringValue = formattedSessionStatusMetaText(
            allSessionCount: allSessionSnapshots.count,
            scopeText: sessionScopeDisplayText(isArchived: displayedSessionListMode == .archived),
            emptyStateText: sessionEmptyStateText(isArchived: displayedSessionListMode == .archived),
            sessionScanRunning: isSessionScanRunning,
            scannedCount: lastSessionRenderScannedCount,
            totalCount: lastSessionRenderTotalCount,
            isComplete: lastSessionRenderIsComplete,
            searchSummary: sessionSearchSummary(),
            refreshText: Self.timestampFormatter.string(from: Date())
        )
    }

    private func loadedActiveSessionSnapshotsForStatusRefresh() -> [SessionSnapshot] {
        guard displayedSessionListMode == .active else { return [] }
        return allSessionSnapshots.filter { !$0.isArchived }
    }

    private func applyRefreshedSessionSnapshots(_ refreshedSnapshots: [SessionSnapshot], preserveSelectionThreadID: String?) {
        guard !refreshedSnapshots.isEmpty else { return }

        invalidatePromptSearchCache(threadIDs: threadIDsNeedingPromptCacheInvalidation(previous: allSessionSnapshots, refreshed: refreshedSnapshots))
        allSessionSnapshots = overlaySessionSnapshots(existing: allSessionSnapshots, refreshed: refreshedSnapshots)
        sessionStatusRefreshCoordinator.prune(to: allSessionSnapshots)
        renderSessionSnapshots(
            scannedCount: lastSessionRenderScannedCount ?? allSessionSnapshots.count,
            totalCount: lastSessionRenderTotalCount ?? allSessionSnapshots.count,
            isComplete: lastSessionRenderIsComplete
        )
        restoreSessionSelection(preferredThreadID: preserveSelectionThreadID)
    }

    private func probeSessionStatusRefreshSnapshots(
        _ snapshots: [SessionSnapshot],
        collectFailures: Bool = true,
        completion: @escaping (_ refreshedSnapshots: [SessionSnapshot], _ failedThreadIDs: [String]) -> Void
    ) {
        guard !snapshots.isEmpty else {
            completion([], [])
            return
        }

        let semaphore = DispatchSemaphore(value: sessionStatusRefreshMaxConcurrentJobs)
        let group = DispatchGroup()
        let resultLock = NSLock()
        var refreshedSnapshots: [SessionSnapshot] = []
        var failedThreadIDs: [String] = []

        for snapshot in snapshots {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                semaphore.wait()
                defer {
                    semaphore.signal()
                    group.leave()
                }

                guard case let .success(refreshed) = self.sessionScanService.probeSession(threadID: snapshot.threadID) else {
                    guard collectFailures else { return }
                    resultLock.lock()
                    failedThreadIDs.append(snapshot.threadID)
                    resultLock.unlock()
                    return
                }

                let merged = mergeSessionSnapshotAfterStatusRefresh(previous: snapshot, refreshed: refreshed)
                resultLock.lock()
                refreshedSnapshots.append(merged)
                resultLock.unlock()
            }
        }

        group.notify(queue: .main) {
            completion(refreshedSnapshots, failedThreadIDs)
        }
    }

    private func refreshLoadedSessionStatusesInBackground(showProgress: Bool) {
        guard !isSessionScanRunning else {
            if showProgress {
                setStatus(sessionStatusRefreshBlockedByScanText(), key: "scan", color: .systemOrange)
            }
            return
        }

        guard displayedSessionListMode == .active else {
            refreshArchivedSessionsInBackground(showProgress: showProgress)
            return
        }

        let snapshots = loadedActiveSessionSnapshotsForStatusRefresh()
        guard !snapshots.isEmpty else {
            if showProgress {
                refreshSessionStatuses()
            }
            return
        }

        let claimedSnapshots = sessionStatusRefreshCoordinator.claim(snapshots, requireDue: false, referenceDate: Date())
        guard !claimedSnapshots.isEmpty else {
            if showProgress {
                setStatus(sessionStatusRefreshAlreadyRunningText(), key: "scan", color: .systemOrange)
            }
            return
        }

        if showProgress {
            setStatus(sessionStatusRefreshRunningText(), key: "scan")
        }

        let preservedSelectionThreadID = selectedSessionThreadID()
        probeSessionStatusRefreshSnapshots(claimedSnapshots, collectFailures: true) { refreshedSnapshots, failedThreadIDs in
            let completionDate = Date()
            for resolved in resolveClaimedSessionRefreshSnapshots(claimed: claimedSnapshots, refreshed: refreshedSnapshots) {
                self.sessionStatusRefreshCoordinator.scheduleNext(for: resolved, from: completionDate)
            }

            guard self.displayedSessionListMode == .active, !self.isSessionScanRunning else {
                if showProgress {
                    let resultKind = sessionStatusRefreshResultKind(failedCount: failedThreadIDs.count, totalCount: claimedSnapshots.count)
                    self.applySessionStatusRefreshResult(resultKind)
                }
                return
            }

            self.applyRefreshedSessionSnapshots(refreshedSnapshots, preserveSelectionThreadID: preservedSelectionThreadID)
            if showProgress {
                let resultKind = sessionStatusRefreshResultKind(failedCount: failedThreadIDs.count, totalCount: claimedSnapshots.count)
                self.applySessionStatusRefreshResult(resultKind)
            }
        }
    }

    private func refreshArchivedSessionsInBackground(showProgress: Bool) {
        guard !isSessionScanRunning else {
            if showProgress {
                setStatus(sessionStatusRefreshBlockedByScanText(), key: "scan", color: .systemOrange)
            }
            return
        }

        if showProgress {
            setStatus(sessionStatusRefreshRunningText(), key: "scan")
        }

        let preservedSelectionThreadID = selectedSessionThreadID()
        DispatchQueue.global(qos: .utility).async {
            let result = self.sessionScanService.threadListArchived()
            DispatchQueue.main.async {
                guard self.displayedSessionListMode == .archived, !self.isSessionScanRunning else {
                    if showProgress {
                        switch result {
                        case .success:
                            self.applySessionStatusRefreshResult(.success)
                        case .failure:
                            self.applySessionStatusRefreshResult(.failure)
                        }
                    }
                    return
                }

                guard case let .success(snapshots) = result else {
                    if showProgress {
                        self.applySessionStatusRefreshResult(.failure)
                    }
                    return
                }

                self.allSessionSnapshots = snapshots
                self.sessionScanTotal = self.allSessionSnapshots.count
                self.sessionStatusRefreshCoordinator.clear()
                self.renderSessionSnapshots(
                    scannedCount: self.allSessionSnapshots.count,
                    totalCount: self.allSessionSnapshots.count,
                    isComplete: true
                )
                self.restoreSessionSelection(preferredThreadID: preservedSelectionThreadID)
                if showProgress {
                    self.applySessionStatusRefreshResult(.success)
                }
            }
        }
    }

    private func finishSessionScanUIState() {
        isSessionScanRunning = false
        activeSessionScanMode = nil
        updateDetectStatusButtonState()
    }

    private func disableSelectedSessionActionButtons() {
        saveRenameButton.isEnabled = false
        archiveSessionButton.isEnabled = false
        restoreSessionButton.isEnabled = false
        deleteSessionButton.isEnabled = false
        migrateSessionProviderButton.isEnabled = false
        migrateAllSessionsProviderButton.isEnabled = false
    }

    private func disableSelectedSessionActionControls() {
        disableSelectedSessionActionButtons()
        renameField.isEnabled = false
    }

    private func handleSessionSelectionRequired(logText: String) {
        appendOutput(logText)
        setStatus(sessionSelectionRequiredStatusText())
        NSSound.beep()
    }

    private func withSelectedSession(
        logText: String,
        _ body: (SessionSnapshot) -> Void
    ) {
        guard let session = selectedSessionSnapshot() else {
            handleSessionSelectionRequired(logText: logText)
            return
        }
        body(session)
    }

    private func handleLoopSelectionRequired() {
        appendOutput(loopSelectionRequiredLogText())
        setStatus(loopSelectionRequiredStatusText())
        NSSound.beep()
    }

    private func handleLoopActionBlocked(logText: String, statusText: String) {
        appendOutput(logText)
        setStatus(statusText, key: "action")
        NSSound.beep()
    }

    private func handleStoppedLoopBlocked() {
        handleLoopActionBlocked(
            logText: stoppedLoopBlockedLogText(),
            statusText: stoppedLoopBlockedStatusText()
        )
    }

    private func handleResumeLoopBlocked() {
        handleLoopActionBlocked(
            logText: resumeLoopBlockedLogText(),
            statusText: resumeLoopBlockedStatusText()
        )
    }

    private func handleAccessibilityPermissionDenied(
        logText: String,
        actionStatusText: String? = nil,
        sideEffect: (() -> Void)? = nil
    ) {
        appendOutput(logText)
        setStatus(accessibilityPermissionDeniedStatusText(), key: "general", color: .systemRed)
        sideEffect?()
        if let actionStatusText {
            setStatus(actionStatusText, key: "action", color: .systemRed)
        }
        NSSound.beep()
    }

    private func ensureAccessibilityPermission(
        logText: String,
        actionStatusText: String? = nil,
        sideEffect: (() -> Void)? = nil
    ) -> Bool {
        guard sendRequestCoordinator.ensurePermission(prompt: true) else {
            handleAccessibilityPermissionDenied(
                logText: logText,
                actionStatusText: actionStatusText,
                sideEffect: sideEffect
            )
            return false
        }
        return true
    }

    private func handleEmptyMessageRequired() {
        appendOutput(emptyMessageRequiredLogText())
        setStatus(emptyMessageRequiredStatusText())
        NSSound.beep()
    }

    private func handleLoopMessageValidationFailure() {
        if currentMessage().isEmpty {
            handleEmptyMessageRequired()
        }
    }

    private func beginLoopActionValidation(statusText: String) {
        setButtonsEnabled(false)
        setStatus(statusText, key: "action")
    }

    private func performValidatedLoopAction(
        target: String,
        actionName: String,
        validationStatusText: String,
        onInvalid: @escaping () -> Void,
        onValid: @escaping () -> Void
    ) {
        beginLoopActionValidation(statusText: validationStatusText)
        validateUniqueTargetAsync(target: target, actionName: actionName) { isValid in
            guard isValid else {
                onInvalid()
                return
            }
            onValid()
        }
    }

    private func performValidatedLoopAction(
        target: String,
        actionName: String,
        validationStatusText: String,
        failureStatusText: String,
        failureSideEffect: (() -> Void)? = nil,
        onValid: @escaping () -> Void
    ) {
        performValidatedLoopAction(
            target: target,
            actionName: actionName,
            validationStatusText: validationStatusText
        ) {
            self.handleLoopValidationFailure(
                statusText: failureStatusText,
                sideEffect: failureSideEffect
            )
        } onValid: {
            onValid()
        }
    }

    private func handleLoopValidationFailure(
        statusText: String,
        sideEffect: (() -> Void)? = nil
    ) {
        sideEffect?()
        setStatus(statusText, key: "action", color: .systemRed)
        setButtonsEnabled(true)
    }

    private func saveStoppedLoopForStartFailure(
        target: String,
        interval: String,
        reason: String
    ) {
        saveCurrentLoopAsStoppedAsync(target: target, interval: interval, reason: reason)
    }

    private func currentLoopMessageOptions() -> (message: String, forceSend: Bool) {
        (currentMessage(), isForceSendEnabled())
    }

    private func runLoopTargetAction(
        actionName: String,
        commandName: String,
        loop: LoopSnapshot,
        invoke: @escaping (String, String?, @escaping (HelperCommandResult) -> Void) -> Void
    ) {
        targetField.stringValue = loop.target
        let target = loop.target
        let trimmedLoopID = loop.loopID.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayArguments = trimmedLoopID.isEmpty ? [commandName, "-t", target] : [commandName, "-k", trimmedLoopID]
        runHelper(actionName: actionName, displayArguments: displayArguments) { completion in
            invoke(target, trimmedLoopID.isEmpty ? nil : trimmedLoopID, completion)
        }
    }

    private func removeSessionSnapshots(threadIDs: [String]) {
        let deletedSet = Set(threadIDs)
        guard !deletedSet.isEmpty else { return }
        let deletedCount = deletedSet.count
        allSessionSnapshots.removeAll { deletedSet.contains($0.threadID) }
        sessionSnapshots.removeAll { deletedSet.contains($0.threadID) }
        if sessionScanTotal > 0 {
            sessionScanTotal = max(0, sessionScanTotal - deletedCount)
        }
        invalidateSessionSearch()
        renderSessionSnapshots(
            scannedCount: allSessionSnapshots.count,
            totalCount: sessionScanTotal > 0 ? sessionScanTotal : allSessionSnapshots.count,
            isComplete: true
        )
    }

    private func beginActionExecution(
        disableUI: () -> Void,
        runningStatusText: String,
        startLogText: String
    ) {
        disableUI()
        setStatus(runningStatusText, key: "action")
        appendOutput(startLogText)
    }

    private func beginSelectedSessionAction(runningStatusText: String, startLogText: String) {
        beginActionExecution(
            disableUI: disableSelectedSessionActionControls,
            runningStatusText: runningStatusText,
            startLogText: startLogText
        )
    }

    private func beginSessionDeletePlanLoading() {
        setButtonsEnabled(false)
        setStatus(sessionDeletePlanLoadingStatusText(), key: "action")
    }

    private func finishSessionDeletePlanLoading() {
        setButtonsEnabled(true)
    }

    private func handleSessionDeletePlanLoadingFailure() {
        setStatus(sessionDeletePlanLoadingFailureStatusText(), key: "action")
        appendOutput(sessionDeletePlanLoadingFailureLogText())
        NSSound.beep()
    }

    private func handleSessionDeleteCancelled() {
        setStatus(sessionDeleteCancelledStatusText(), key: "action")
    }

    private func resolvedSessionDeleteThreadIDs(
        threadID: String,
        deletionPlan: (includeDescendants: Bool, descendantIDs: [String])
    ) -> (displayed: [String], ordered: [String]) {
        let displayed = deletionPlan.includeDescendants ? ([threadID] + deletionPlan.descendantIDs) : [threadID]
        let ordered = deletionPlan.includeDescendants ? (deletionPlan.descendantIDs.reversed() + [threadID]) : [threadID]
        return (displayed, ordered)
    }

    private func showSessionDeleteBlockedAlertIfNeeded(
        session: SessionSnapshot,
        detail: String,
        failedFields: [String: String]?
    ) {
        guard let failedFields else { return }
        let reason = failedFields["reason"] ?? ""
        guard reason == "session_delete_live" || reason == "session_delete_live_ambiguous" else {
            return
        }
        let blockedDetail = failedFields["detail"] ?? detail
        showSessionActionBlockedAlert(
            actionLabel: "删除",
            session: session,
            detail: blockedDetail,
            ambiguous: reason == "session_delete_live_ambiguous"
        )
    }

    private func showSessionArchiveBlockedAlertIfNeeded(
        session: SessionSnapshot,
        error: String
    ) {
        guard let fields = parseStructuredKeyValueFields(error) else { return }
        let reason = fields["reason"] ?? ""
        guard reason == "session_archive_live" || reason == "session_archive_live_ambiguous" else {
            return
        }
        let detail = fields["detail"] ?? error
        showSessionActionBlockedAlert(
            actionLabel: "归档",
            session: session,
            detail: detail,
            ambiguous: reason == "session_archive_live_ambiguous"
        )
    }

    private func failSessionArchiveAction(
        session: SessionSnapshot,
        error: String
    ) {
        showSessionArchiveBlockedAlertIfNeeded(session: session, error: error)
        handleActionExecutionFailure(
            statusText: sessionArchiveFailureStatusText(),
            detail: error
        )
    }

    private func failSessionDeleteAction(
        session: SessionSnapshot,
        detail: String,
        failedFields: [String: String]?
    ) {
        showSessionDeleteBlockedAlertIfNeeded(
            session: session,
            detail: detail,
            failedFields: failedFields
        )
        updateSessionDetailView()
        handleActionExecutionFailure(
            statusText: sessionDeleteFailureStatusText(),
            detail: detail
        )
    }

    private func performSessionDeleteAction(
        session: SessionSnapshot,
        threadIDs: (displayed: [String], ordered: [String])
    ) {
        beginSelectedSessionAction(
            runningStatusText: sessionDeleteRunningStatusText(),
            startLogText: sessionDeleteStartLogText(threadIDs: threadIDs.displayed)
        )

        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.deleteSessionsRecursively(threadIDs: threadIDs.ordered)

            DispatchQueue.main.async {
                if result.success {
                    self.completeSelectedSessionRemovalAction(
                        threadIDs: threadIDs.ordered,
                        completionStatusText: sessionDeleteCompletionStatusText(),
                        completionLogText: sessionDeleteCompletionLogText(detail: result.detail, deletedThreadIDs: threadIDs.ordered)
                    )
                } else {
                    self.failSessionDeleteAction(
                        session: session,
                        detail: result.detail,
                        failedFields: result.failedFields
                    )
                }
            }
        }
    }

    private func loadAndExecuteSessionDelete(
        session: SessionSnapshot,
        matchingLoopTargets: [String]
    ) {
        beginSessionDeletePlanLoading()

        sessionFamilyPlanAsync(threadID: session.threadID) { familyPlan in
            self.sessionDeletePlanAsync(threadID: session.threadID) { deletePlan in
                self.finishSessionDeletePlanLoading()

                guard let deletePlan else {
                    self.handleSessionDeletePlanLoadingFailure()
                    return
                }

                guard let deletionPlan = self.promptForSessionDeletion(
                    session: session,
                    matchingLoopTargets: matchingLoopTargets,
                    familyPlan: familyPlan,
                    deletePlan: deletePlan
                ) else {
                    self.handleSessionDeleteCancelled()
                    return
                }

                let threadIDs = self.resolvedSessionDeleteThreadIDs(
                    threadID: session.threadID,
                    deletionPlan: deletionPlan
                )
                self.performSessionDeleteAction(session: session, threadIDs: threadIDs)
            }
        }
    }

    private func performSessionRenameExecution(
        session: SessionSnapshot,
        newName: String
    ) {
        beginSelectedSessionAction(
            runningStatusText: sessionRenameRunningStatusText(),
            startLogText: sessionRenameStartLogText(threadID: session.threadID, newName: newName)
        )

        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.updateSessionName(threadID: session.threadID, newName: newName)

            DispatchQueue.main.async {
                self.restoreSelectedSessionActionControls(selectedSessionIsArchived: false)

                if result.success {
                    self.completeSessionRenameAction(
                        threadID: session.threadID,
                        newName: newName
                    )
                } else {
                    self.failSelectedSessionAction(
                        statusText: sessionRenameFailureStatusText(),
                        detail: result.error,
                        selectedSessionIsArchived: false
                    )
                }
            }
        }
    }

    private func renamedSessionSnapshot(from previous: SessionSnapshot, newName: String) -> SessionSnapshot {
        SessionSnapshot(
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

    private func completeSessionRenameAction(
        threadID: String,
        newName: String
    ) {
        if let index = allSessionSnapshots.firstIndex(where: { $0.threadID == threadID }) {
            let previous = allSessionSnapshots[index]
            allSessionSnapshots[index] = renamedSessionSnapshot(from: previous, newName: newName)
        }
        invalidateSessionSearch()
        renderSessionSnapshots(
            scannedCount: lastSessionRenderScannedCount,
            totalCount: lastSessionRenderTotalCount,
            isComplete: lastSessionRenderIsComplete
        )
        selectSessionRow(threadID: threadID)
        setStatus(sessionRenameCompletionStatusText(), key: "action")
        appendOutput(sessionRenameCompletionLogText(newName: newName))
    }

    private func completeSelectedSessionRemovalAction(
        threadIDs: [String],
        completionStatusText: String,
        completionLogText: String
    ) {
        removeSessionSnapshots(threadIDs: threadIDs)
        setStatus(completionStatusText, key: "action")
        appendOutput(completionLogText)
        scheduleLoopSnapshotRefresh()
    }

    private func performSelectedSessionRemovalAction(
        threadID: String,
        selectedSessionIsArchived: Bool,
        runningStatusText: String,
        startLogText: String,
        completionStatusText: String,
        completionLogText: String,
        failureStatusText: String,
        beforeFailure: ((String) -> Void)? = nil,
        work: @escaping () -> (success: Bool, error: String)
    ) {
        beginSelectedSessionAction(
            runningStatusText: runningStatusText,
            startLogText: startLogText
        )

        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()

            DispatchQueue.main.async {
                if result.success {
                    self.completeSelectedSessionRemovalAction(
                        threadIDs: [threadID],
                        completionStatusText: completionStatusText,
                        completionLogText: completionLogText
                    )
                } else {
                    beforeFailure?(result.error)
                    self.failSelectedSessionAction(
                        statusText: failureStatusText,
                        detail: result.error,
                        selectedSessionIsArchived: selectedSessionIsArchived
                    )
                }
            }
        }
    }

    private func restoreSelectedSessionActionControls(selectedSessionIsArchived: Bool) {
        let hasSelection = hasSelectedSession()
        renameField.isEnabled = hasSelection && !selectedSessionIsArchived
        saveRenameButton.isEnabled = hasSelection && !selectedSessionIsArchived
        archiveSessionButton.isEnabled = hasSelection && !selectedSessionIsArchived
        restoreSessionButton.isEnabled = hasSelection && selectedSessionIsArchived
        deleteSessionButton.isEnabled = hasSelection
        updateProviderMigrationButtons()
    }

    private func handleActionExecutionFailure(statusText: String, detail: String) {
        setStatus(statusText, key: "action")
        appendStderrDetailIfPresent(detail)
        NSSound.beep()
    }

    private func applyActionExecutionResult(
        success: Bool,
        detail: String,
        completionStatusText: String,
        failureStatusText: String,
        finishUI: () -> Void,
        onSuccess: () -> Void
    ) {
        finishUI()
        if success {
            setStatus(completionStatusText, key: "action")
            appendOutput(detail)
            onSuccess()
        } else {
            handleActionExecutionFailure(statusText: failureStatusText, detail: detail)
        }
    }

    private func failSelectedSessionAction(
        statusText: String,
        detail: String,
        selectedSessionIsArchived: Bool
    ) {
        restoreSelectedSessionActionControls(selectedSessionIsArchived: selectedSessionIsArchived)
        handleActionExecutionFailure(statusText: statusText, detail: detail)
    }

    private func handleSelectedSessionActionBlocked(logText: String, statusText: String) {
        appendOutput(logText)
        setStatus(statusText, key: "action")
        NSSound.beep()
    }

    private func appendStderrDetailIfPresent(_ detail: String) {
        guard !detail.isEmpty else { return }
        appendOutput("stderr: \(detail)")
    }

    private func handleProviderMigrationMissingProvider() {
        finishProviderMigrationInteraction()
        appendOutput(sessionProviderMissingLogText())
        handleActionExecutionFailure(statusText: sessionProviderMissingStatusText(), detail: "")
    }

    private func handleProviderMigrationPlanFailure(logText: String) {
        appendOutput(logText)
        handleActionExecutionFailure(statusText: sessionProviderMigrationPlanFailureStatusText(), detail: "")
    }

    private func handleProviderMigrationCancelled(statusText: String) {
        setStatus(statusText, key: "action")
    }

    private func beginProviderMigrationLoading() {
        setButtonsEnabled(false)
        setStatus(sessionProviderLoadingStatusText(), key: "action")
    }

    private func withProviderMigrationTargetProvider(
        _ body: @escaping (String) -> Void
    ) {
        beginProviderMigrationLoading()
        refreshConfiguredModelProviderCache(updateButtons: false) { targetProvider in
            guard let targetProvider else {
                self.handleProviderMigrationMissingProvider()
                return
            }
            self.beginProviderMigrationPlanLoading()
            body(targetProvider)
        }
    }

    private func beginProviderMigrationPlanLoading() {
        setStatus(sessionProviderMigrationPlanLoadingStatusText(), key: "action")
    }

    private func finishProviderMigrationPlanLoading() {
        finishProviderMigrationInteraction()
    }

    private func resolvedProviderMigrationPlan(
        _ plan: [String: String]?,
        failureLogText: String
    ) -> [String: String]? {
        finishProviderMigrationPlanLoading()
        guard let plan else {
            handleProviderMigrationPlanFailure(logText: failureLogText)
            return nil
        }
        return plan
    }

    private func finishProviderMigrationInteraction() {
        setButtonsEnabled(true)
        updateProviderMigrationButtons()
    }

    private func handleProviderMigrationNoop(informativeText: String, logText: String) {
        showAlert(
            style: .informational,
            title: sessionProviderMigrationNoopAlertTitle(),
            informativeText: informativeText,
            buttonTitles: ["确定"]
        )
        appendOutput(logText)
        setStatus(noMigrationNeededStatusText(), key: "action")
    }

    private func promptForSessionProviderMigration(
        session: SessionSnapshot,
        targetProvider: String,
        currentProviderDisplay: String,
        isSubagent: Bool,
        familyCount: Int,
        familyMigrateNeeded: Int,
        directChildCount: Int
    ) -> Bool? {
        if isSubagent || directChildCount > 0 {
            let response = runAlert(
                style: .warning,
                title: sessionProviderMigrationRelatedAlertTitle(),
                informativeText: sessionProviderMigrationRelatedAlertText(
                    targetProvider: targetProvider,
                    currentProviderDisplay: currentProviderDisplay,
                    threadID: session.threadID,
                    typeLabel: sessionTypeLabel(session),
                    isSubagent: isSubagent,
                    familyCount: familyCount,
                    familyMigrateNeeded: familyMigrateNeeded
                ),
                buttonTitles: ["迁移相关", "仅迁移当前", "取消"]
            )
            if response == .alertFirstButtonReturn {
                return true
            }
            if response == .alertSecondButtonReturn {
                return false
            }
            handleProviderMigrationCancelled(statusText: sessionProviderMigrationCancelledStatusText())
            return nil
        }

        guard runAlert(
            style: .informational,
            title: sessionProviderMigrationCurrentAlertTitle(),
            informativeText: sessionProviderMigrationCurrentAlertText(
                targetProvider: targetProvider,
                currentProviderDisplay: currentProviderDisplay,
                threadID: session.threadID,
                typeLabel: sessionTypeLabel(session)
            ),
            buttonTitles: ["迁移", "取消"]
        ) == .alertFirstButtonReturn else {
            handleProviderMigrationCancelled(statusText: sessionProviderMigrationCancelledStatusText())
            return nil
        }
        return false
    }

    private func confirmAllSessionProviderMigration(
        targetProvider: String,
        totalThreads: Int,
        migrateNeeded: Int
    ) -> Bool {
        guard runAlert(
            style: .warning,
            title: allSessionProviderMigrationAlertTitle(),
            informativeText: allSessionProviderMigrationAlertText(
                targetProvider: targetProvider,
                totalThreads: totalThreads,
                migrateNeeded: migrateNeeded
            ),
            buttonTitles: ["全部迁移", "取消"],
            destructiveFirstButton: true
        ) == .alertFirstButtonReturn else {
            handleProviderMigrationCancelled(statusText: allSessionProviderMigrationCancelledStatusText())
            return false
        }
        return true
    }

    private func confirmSessionArchive(session: SessionSnapshot, matchingLoopTargets: [String]) -> Bool {
        runAlert(
            style: .warning,
            title: sessionArchiveAlertTitle(),
            informativeText: sessionArchiveAlertText(
                threadID: session.threadID,
                target: sessionEffectiveTarget(session),
                matchingLoopTargets: matchingLoopTargets
            ),
            buttonTitles: ["归档", "取消"],
            destructiveFirstButton: true
        ) == .alertFirstButtonReturn
    }

    private func confirmSessionRestore(session: SessionSnapshot) -> Bool {
        runAlert(
            style: .informational,
            title: sessionRestoreAlertTitle(),
            informativeText: sessionRestoreAlertText(
                threadID: session.threadID,
                name: sessionActualName(session).isEmpty ? "-" : sessionActualName(session)
            ),
            buttonTitles: ["恢复", "取消"]
        ) == .alertFirstButtonReturn
    }

    private func beginProviderMigrationExecution(runningStatusText: String, startLogText: String) {
        beginActionExecution(
            disableUI: { self.setButtonsEnabled(false) },
            runningStatusText: runningStatusText,
            startLogText: startLogText
        )
    }

    private func performProviderMigrationExecution(
        runningStatusText: String,
        startLogText: String,
        completionStatusText: String,
        failureStatusText: String,
        work: @escaping () -> (success: Bool, detail: String)
    ) {
        beginProviderMigrationExecution(
            runningStatusText: runningStatusText,
            startLogText: startLogText
        )
        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()
            DispatchQueue.main.async {
                self.applyProviderMigrationExecutionResult(
                    success: result.success,
                    detail: result.detail,
                    completionStatusText: completionStatusText,
                    failureStatusText: failureStatusText
                )
            }
        }
    }

    private func applyProviderMigrationExecutionResult(
        success: Bool,
        detail: String,
        completionStatusText: String,
        failureStatusText: String
    ) {
        applyActionExecutionResult(
            success: success,
            detail: detail,
            completionStatusText: completionStatusText,
            failureStatusText: failureStatusText,
            finishUI: finishProviderMigrationInteraction
        ) {
            self.detectStatuses()
        }
    }

    private func loadAndExecuteSelectedSessionProviderMigration(
        session: SessionSnapshot,
        targetProvider: String
    ) {
        sessionProviderPlanAsync(threadID: session.threadID, targetProvider: targetProvider) { plan in
            guard let plan = self.resolvedProviderMigrationPlan(
                plan,
                failureLogText: sessionProviderMigrationPlanFailureLogText()
            ) else { return }

            let isSubagent = (plan["is_subagent"] ?? "no") == "yes"
            let familyCount = Int(plan["family_count"] ?? "1") ?? 1
            let familyMigrateNeeded = Int(plan["family_migrate_needed_count"] ?? "0") ?? 0
            let currentProvider = plan["current_provider"] ?? session.provider
            let directChildCount = Int(plan["direct_child_count"] ?? "0") ?? 0
            let currentProviderDisplay = currentProvider.isEmpty ? "-" : currentProvider

            if currentProvider == targetProvider && familyMigrateNeeded == 0 {
                self.handleProviderMigrationNoop(
                    informativeText: sessionProviderMigrationNoopAlertText(
                        currentProviderDisplay: currentProviderDisplay,
                        targetProvider: targetProvider,
                        familyCount: familyCount
                    ),
                    logText: sessionProviderMigrationNoopLogText(targetProvider: targetProvider)
                )
                return
            }

            guard let includeFamily = self.promptForSessionProviderMigration(
                session: session,
                targetProvider: targetProvider,
                currentProviderDisplay: currentProviderDisplay,
                isSubagent: isSubagent,
                familyCount: familyCount,
                familyMigrateNeeded: familyMigrateNeeded,
                directChildCount: directChildCount
            ) else { return }

            self.performProviderMigrationExecution(
                runningStatusText: sessionProviderMigrationRunningStatusText(),
                startLogText: sessionProviderMigrationStartLogText(
                    threadID: session.threadID,
                    targetProvider: targetProvider,
                    includeFamily: includeFamily
                ),
                completionStatusText: sessionProviderMigrationCompletionStatusText(),
                failureStatusText: sessionProviderMigrationFailureStatusText()
            ) {
                self.migrateSessionProvider(
                    threadID: session.threadID,
                    targetProvider: targetProvider,
                    includeFamily: includeFamily
                )
            }
        }
    }

    private func loadAndExecuteAllSessionProviderMigration(targetProvider: String) {
        allSessionProviderPlanAsync(targetProvider: targetProvider) { plan in
            guard let plan = self.resolvedProviderMigrationPlan(
                plan,
                failureLogText: allSessionProviderMigrationPlanFailureLogText()
            ) else { return }

            let migrateNeeded = Int(plan["migrate_needed_count"] ?? "0") ?? 0
            let totalThreads = Int(plan["total_threads"] ?? "0") ?? 0

            if migrateNeeded == 0 {
                self.handleProviderMigrationNoop(
                    informativeText: allSessionProviderMigrationNoopAlertText(
                        targetProvider: targetProvider,
                        totalThreads: totalThreads
                    ),
                    logText: allSessionProviderMigrationNoopLogText(targetProvider: targetProvider)
                )
                return
            }

            guard self.confirmAllSessionProviderMigration(
                targetProvider: targetProvider,
                totalThreads: totalThreads,
                migrateNeeded: migrateNeeded
            ) else { return }

            self.performProviderMigrationExecution(
                runningStatusText: allSessionProviderMigrationRunningStatusText(),
                startLogText: allSessionProviderMigrationStartLogText(targetProvider: targetProvider),
                completionStatusText: allSessionProviderMigrationCompletionStatusText(),
                failureStatusText: allSessionProviderMigrationFailureStatusText()
            ) {
                self.migrateAllSessionsProvider(targetProvider: targetProvider)
            }
        }
    }

    private func applySessionStatusRefreshResult(_ resultKind: SessionStatusRefreshResultKind) {
        switch resultKind {
        case .success:
            setStatus(resultKind.text, key: "scan")
        case .failure:
            setStatus(resultKind.text, key: "scan", color: .systemRed)
        case .partialFailure:
            setStatus(resultKind.text, key: "scan", color: .systemOrange)
        }
    }

    private func scheduleDueSessionStatusRefreshes() {
        guard !isSessionScanRunning, displayedSessionListMode == .active else { return }
        let dueSnapshots = sessionStatusRefreshCoordinator.claim(
            loadedActiveSessionSnapshotsForStatusRefresh(),
            requireDue: true,
            referenceDate: Date()
        )
        guard !dueSnapshots.isEmpty else { return }

        let preservedSelectionThreadID = selectedSessionThreadID()
        probeSessionStatusRefreshSnapshots(dueSnapshots, collectFailures: false) { refreshedSnapshots, _ in
            let completionDate = Date()
            for resolved in resolveClaimedSessionRefreshSnapshots(claimed: dueSnapshots, refreshed: refreshedSnapshots) {
                self.sessionStatusRefreshCoordinator.scheduleNext(for: resolved, from: completionDate)
            }

            guard self.displayedSessionListMode == .active, !self.isSessionScanRunning else { return }
            self.applyRefreshedSessionSnapshots(refreshedSnapshots, preserveSelectionThreadID: preservedSelectionThreadID)
        }
    }

    private func rebuildDisplayedSessionSnapshots(preserveSelectionThreadID: String?) {
        let query = currentSessionSearchQuery()
        let normalizedQuery = query.localizedLowercase
        let fastMatches: [SessionSnapshot]
        if normalizedQuery.isEmpty {
            fastMatches = allSessionSnapshots
        } else {
            fastMatches = allSessionSnapshots.filter { sessionFastMatchesQuery($0, normalizedQuery: normalizedQuery) }
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

    private func selectedLoopSnapshot() -> LoopSnapshot? {
        let selectedRow = activeLoopsTableView.selectedRow
        guard selectedRow >= 0, selectedRow < loopSnapshots.count else { return nil }
        return loopSnapshots[selectedRow]
    }

    private func selectedLoopTarget() -> String? {
        selectedLoopSnapshot()?.target
    }

    private func selectedLoopSelectionIdentifier() -> String? {
        selectedLoopSnapshot().map(loopSelectionIdentifier(_:))
    }

    private func selectedLoopSnapshotForAction() -> LoopSnapshot? {
        guard let loop = selectedLoopSnapshot() else {
            handleLoopSelectionRequired()
            return nil
        }
        return loop
    }

    private func selectedSessionSnapshot() -> SessionSnapshot? {
        let selectedRow = sessionStatusTableView.selectedRow
        guard selectedRow >= 0, selectedRow < sessionSnapshots.count else { return nil }
        return sessionSnapshots[selectedRow]
    }

    private func hasSelectedSession() -> Bool {
        selectedSessionSnapshot() != nil
    }

    private func updateLoopActionButtons() {
        guard let loop = selectedLoopSnapshot() else {
            stopButton.isEnabled = false
            resumeLoopButton.isEnabled = false
            deleteLoopButton.isEnabled = false
            return
        }
        stopButton.isEnabled = !loop.isStopped
        resumeLoopButton.isEnabled = (loop.isPaused || loop.isStopped)
        deleteLoopButton.isEnabled = true
    }

    private func restoreLoopSelection(preferredIdentifier: String?) {
        let selectionIdentifier = preferredIdentifier ?? preferredLoopSelectionIdentifier
        guard let selectionIdentifier else {
            isProgrammaticLoopSelectionChange = true
            activeLoopsTableView.deselectAll(nil)
            isProgrammaticLoopSelectionChange = false
            updateLoopActionButtons()
            return
        }

        guard let row = loopSnapshots.firstIndex(where: { loopSelectionIdentifier($0) == selectionIdentifier }) else {
            isProgrammaticLoopSelectionChange = true
            activeLoopsTableView.deselectAll(nil)
            isProgrammaticLoopSelectionChange = false
            preferredLoopSelectionIdentifier = nil
            updateLoopActionButtons()
            return
        }

        isProgrammaticLoopSelectionChange = true
        activeLoopsTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isProgrammaticLoopSelectionChange = false
        activeLoopsTableView.scrollRowToVisible(row)
        preferredLoopSelectionIdentifier = selectionIdentifier
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
                orderedAscending = (lhs.isForceSendEnabled ? 1 : 0) < (rhs.isForceSendEnabled ? 1 : 0)
            case "nextRun":
                orderedAscending = (lhs.nextRunTimeInterval ?? 0) < (rhs.nextRunTimeInterval ?? 0)
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
                orderedAscending = sessionTerminalDisplayValue(lhs).localizedStandardCompare(sessionTerminalDisplayValue(rhs)) == .orderedAscending
            case "tty":
                orderedAscending = sessionTTYDisplayValue(lhs).localizedStandardCompare(sessionTTYDisplayValue(rhs)) == .orderedAscending
            case "updatedAt":
                orderedAscending = (lhs.updatedAtTimeInterval ?? 0) < (rhs.updatedAtTimeInterval ?? 0)
            case "reason":
                orderedAscending = localizedSessionReason(lhs.reason).localizedStandardCompare(localizedSessionReason(rhs.reason)) == .orderedAscending
            default:
                orderedAscending = (lhs.updatedAtTimeInterval ?? 0) < (rhs.updatedAtTimeInterval ?? 0)
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
            return sessionTerminalDisplayValue(lhs) == sessionTerminalDisplayValue(rhs)
        case "tty":
            return sessionTTYDisplayValue(lhs) == sessionTTYDisplayValue(rhs)
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
        if session.terminalStateKind == .unavailable && shouldCollapseUnavailableTerminalIntoDisconnectedStatus(session) {
            return .systemRed
        }
        switch session.statusKind {
        case .active:
            return .systemOrange
        case .busyTurnOpen, .postFinalizing, .busyWithStreamIssue, .interruptedOrAborting:
            return .systemOrange
        case .idleStable, .interruptedIdle:
            return .systemGreen
        case .idleWithResidualInput, .queuedMessagesVisible, .queuedMessagesPending, .rolloutStale, .idlePromptVisibleRolloutStale:
            return .systemYellow
        default:
            return .secondaryLabelColor
        }
    }

    private func matchingLoopSnapshots(for session: SessionSnapshot) -> [LoopSnapshot] {
        let candidates = Set(sessionPossibleTargets(session))
        guard !candidates.isEmpty else { return [] }
        return loopSnapshots.filter { candidates.contains($0.target.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func recentSendResults(for session: SessionSnapshot, maxItems: Int = 6) -> [SendResultSnapshot] {
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
        for fileURL in sortedFiles {
            guard let data = try? Data(contentsOf: fileURL) else {
                continue
            }

            let updatedAtEpoch = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
                .timeIntervalSince1970 ?? 0
            guard let snapshot = parseStoredSendResultSnapshot(data: data, updatedAtEpoch: updatedAtEpoch),
                  candidates.contains(snapshot.target) else {
                continue
            }
            results.append(snapshot)

            if results.count >= maxItems {
                break
            }
        }

        return results
    }

    private func recentUserMessageEntries(for session: SessionSnapshot, limit: Int? = nil) -> [RecentUserMessageEntry]? {
        guard !session.rolloutPath.isEmpty else {
            return nil
        }

        let rolloutURL = URL(fileURLWithPath: session.rolloutPath)
        guard let data = try? Data(contentsOf: rolloutURL),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        return parseRecentUserMessageEntries(from: text, limit: limit)
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
                if !self.isCurrentSessionPromptSearchRevision(revision) {
                    return
                }

                let corpus = self.recentPromptSearchCorpus(for: session).localizedLowercase
                if !corpus.isEmpty, corpus.contains(query) {
                    matchedThreadIDs.insert(session.threadID)
                }

                if (index + 1) % 8 == 0 || index + 1 == snapshots.count {
                    let completed = index + 1
                    DispatchQueue.main.async {
                        guard self.isCurrentSessionPromptSearchRevision(revision) else { return }
                        self.sessionPromptSearchProgressCompleted = completed
                        self.updateSessionStatusMetaLabel()
                    }
                }
            }

            DispatchQueue.main.async {
                guard self.isCurrentSessionPromptSearchRevision(revision) else { return }
                self.isSessionPromptSearchRunning = false
                self.sessionPromptSearchCompletedRevision = revision
                self.sessionPromptSearchMatchedThreadIDs = matchedThreadIDs
                self.sessionPromptSearchProgressCompleted = snapshots.count
                self.rebuildDisplayedSessionSnapshots(preserveSelectionThreadID: self.selectedSessionThreadID())
            }
        }
    }

    private func beginSessionScanControl() -> Int {
        sessionScanControlLock.lock()
        defer { sessionScanControlLock.unlock() }
        sessionScanControlState.generation += 1
        sessionScanControlState.shouldStop = false
        return sessionScanControlState.generation
    }

    private func stopSessionScanControl() {
        sessionScanControlLock.lock()
        defer { sessionScanControlLock.unlock() }
        sessionScanControlState.generation += 1
        sessionScanControlState.shouldStop = true
    }

    private func isCurrentSessionScan(_ generation: Int) -> Bool {
        sessionScanControlLock.lock()
        defer { sessionScanControlLock.unlock() }
        return sessionScanControlState.generation == generation
    }

    private func shouldAbortSessionScan(_ generation: Int) -> Bool {
        sessionScanControlLock.lock()
        defer { sessionScanControlLock.unlock() }
        return sessionScanControlState.shouldStop || sessionScanControlState.generation != generation
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

    private func formattedSessionDetailSection(for session: SessionSnapshot) -> String {
        formattedSessionDetailText(session: session, updatedText: formatEpoch(session.updatedAtEpoch))
    }

    private func formattedSessionDetailPreview(for session: SessionSnapshot, sendResults: [SendResultSnapshot]) -> String {
        formattedSessionDetailPreviewDocument(
            sessionDetailText: formattedSessionDetailSection(for: session),
            sendStatsText: formattedRecentSendStatsText(results: sendResults, formatEpoch: formatEpoch(_:)),
            loopOccupancyText: formattedLoopOccupancyText(loops: matchingLoopSnapshots(for: session), formatEpoch: formatEpoch(_:))
        )
    }

    private func composedSessionDetailDocument(for session: SessionSnapshot, sendResults: [SendResultSnapshot], historyText: String) -> String {
        formattedSessionDetailDocument(
            sessionDetailText: formattedSessionDetailSection(for: session),
            sendStatsText: formattedRecentSendStatsText(results: sendResults, formatEpoch: formatEpoch(_:)),
            loopOccupancyText: formattedLoopOccupancyText(loops: matchingLoopSnapshots(for: session), formatEpoch: formatEpoch(_:)),
            sendResultsText: formattedRecentSendResultsText(results: sendResults, formatEpoch: formatEpoch(_:)),
            historyText: historyText
        )
    }

    private func updateSessionDetailView() {
        guard let session = selectedSessionSnapshot() else {
            renameField.stringValue = ""
            disableSelectedSessionActionControls()
            migrateAllSessionsProviderButton.isEnabled = configuredModelProvider != nil
            let emptyDetailText = "选中一条 session 后，这里会显示完整信息、最近发送结果、相关 Loop 和提示词历史。"
            if sessionDetailView.string != emptyDetailText {
                sessionDetailView.string = emptyDetailText
                sessionDetailView.scrollToBeginningOfDocument(nil)
            }
            lastSessionDetailThreadID = nil
            lastSessionDetailText = emptyDetailText
            updateActivityLogControls()
            if isFilteringActivityLogBySelectedSession {
                refreshActivityLogView(scrollToEnd: false)
            }
            return
        }
        renameField.stringValue = session.name
        restoreSelectedSessionActionControls(selectedSessionIsArchived: session.isArchived)
        renameField.placeholderString = sessionRenamePlaceholderText(isArchived: session.isArchived)
        let sendResults = recentSendResults(for: session)
        let initialDetailText = formattedSessionDetailPreview(for: session, sendResults: sendResults)
        let shouldResetForInitialText = lastSessionDetailThreadID != session.threadID || lastSessionDetailText != initialDetailText
        if sessionDetailView.string != initialDetailText {
            sessionDetailView.string = initialDetailText
        }
        if shouldResetForInitialText {
            sessionDetailView.scrollToBeginningOfDocument(nil)
        }
        lastSessionDetailThreadID = session.threadID
        lastSessionDetailText = initialDetailText
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
            let detailText = self.composedSessionDetailDocument(for: session, sendResults: sendResults, historyText: historyText)

            DispatchQueue.main.async {
                guard self.sessionDetailLoadGeneration == generation else { return }
                guard self.sessionStatusTableView.selectedRow >= 0, self.sessionStatusTableView.selectedRow < self.sessionSnapshots.count else { return }
                guard self.sessionSnapshots[self.sessionStatusTableView.selectedRow].threadID == threadID else { return }
                let shouldResetForDetailText = self.lastSessionDetailThreadID != threadID || self.lastSessionDetailText != detailText
                if self.sessionDetailView.string != detailText {
                    self.sessionDetailView.string = detailText
                }
                if shouldResetForDetailText {
                    self.sessionDetailView.scrollToBeginningOfDocument(nil)
                }
                self.lastSessionDetailThreadID = threadID
                self.lastSessionDetailText = detailText
            }
        }
    }

    private func updateProviderMigrationButtons() {
        let hasProvider = configuredModelProvider != nil
        let hasSelection = sessionStatusTableView.selectedRow >= 0
        migrateSessionProviderButton.isEnabled = hasProvider && hasSelection
        migrateAllSessionsProviderButton.isEnabled = hasProvider
    }

    private func refreshConfiguredModelProviderCache(
        updateButtons: Bool = true,
        completion: ((String?) -> Void)? = nil
    ) {
        sessionCommandService.configuredModelProviderAsync { provider in
            self.configuredModelProvider = provider
            if updateButtons {
                self.updateProviderMigrationButtons()
            }
            completion?(provider)
        }
    }

    private func sessionProviderPlanAsync(threadID: String, targetProvider: String, completion: @escaping ([String: String]?) -> Void) {
        sessionCommandService.sessionProviderPlanAsync(threadID: threadID, targetProvider: targetProvider, completion: completion)
    }

    private func allSessionProviderPlanAsync(targetProvider: String, completion: @escaping ([String: String]?) -> Void) {
        sessionCommandService.allSessionProviderPlanAsync(targetProvider: targetProvider, completion: completion)
    }

    private func migrateSessionProvider(threadID: String, targetProvider: String, includeFamily: Bool) -> (success: Bool, detail: String) {
        sessionCommandService.migrateSessionProvider(threadID: threadID, targetProvider: targetProvider, includeFamily: includeFamily)
    }

    private func migrateAllSessionsProvider(targetProvider: String) -> (success: Bool, detail: String) {
        sessionCommandService.migrateAllSessionsProvider(targetProvider: targetProvider)
    }

    private func updateSessionName(threadID: String, newName: String) -> (success: Bool, error: String) {
        sessionCommandService.updateSessionName(threadID: threadID, newName: newName)
    }

    private func archiveSession(threadID: String) -> (success: Bool, error: String) {
        sessionCommandService.archiveSession(threadID: threadID)
    }

    private func unarchiveSession(threadID: String) -> (success: Bool, error: String) {
        sessionCommandService.unarchiveSession(threadID: threadID)
    }

    private func deleteSessionPermanently(threadID: String) -> (success: Bool, fields: [String: String]?, detail: String) {
        sessionCommandService.deleteSession(threadID: threadID)
    }

    private func sessionDeletePlanAsync(threadID: String, completion: @escaping ([String: String]?) -> Void) {
        sessionCommandService.sessionDeletePlanAsync(threadID: threadID, completion: completion)
    }

    private func sessionFamilyPlanAsync(threadID: String, completion: @escaping ([String: String]?) -> Void) {
        sessionCommandService.sessionFamilyPlanAsync(threadID: threadID, completion: completion)
    }

    private func promptForSessionDeletion(
        session: SessionSnapshot,
        matchingLoopTargets: [String],
        familyPlan: [String: String]?,
        deletePlan: [String: String]?
    ) -> (includeDescendants: Bool, descendantIDs: [String])? {
        let parentThreadID = familyPlan?["parent_thread_id"] ?? "-"
        let directChildCount = Int(familyPlan?["direct_child_count"] ?? "0") ?? 0
        let descendantIDs = (familyPlan?["descendant_ids"] ?? "")
            .split(separator: ",")
            .map { String($0) }
            .filter { !$0.isEmpty }
        let descendantCount = Int(familyPlan?["descendant_count"] ?? "\(descendantIDs.count)") ?? descendantIDs.count
        let rolloutPath = deletePlan?["rollout_path"] ?? session.rolloutPath
        let rolloutExists = (deletePlan?["rollout_exists"] ?? "no") == "yes"
        let stateLogRows = Int(deletePlan?["state_log_rows"] ?? "0") ?? 0
        let logsDBRows = Int(deletePlan?["logs_db_rows"] ?? "0") ?? 0
        let dynamicToolRows = Int(deletePlan?["dynamic_tool_rows"] ?? "0") ?? 0
        let stage1OutputRows = Int(deletePlan?["stage1_output_rows"] ?? "0") ?? 0
        let sessionIndexEntries = Int(deletePlan?["session_index_entries"] ?? "0") ?? 0

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = sessionDeleteAlertTitle()
        alert.informativeText = sessionDeleteAlertText(
            threadID: session.threadID,
            name: sessionActualName(session).isEmpty ? "-" : sessionActualName(session),
            rolloutPath: rolloutPath,
            stateLogRows: stateLogRows,
            dynamicToolRows: dynamicToolRows,
            stage1OutputRows: stage1OutputRows,
            logsDBRows: logsDBRows,
            sessionIndexEntries: sessionIndexEntries,
            rolloutExists: rolloutExists,
            parentThreadID: parentThreadID,
            directChildCount: directChildCount,
            descendantCount: descendantCount,
            matchingLoopTargets: matchingLoopTargets
        )
        if descendantCount > 0 {
            alert.addButton(withTitle: "删除当前和子会话")
            alert.addButton(withTitle: "只删当前")
            alert.addButton(withTitle: "取消")
        } else {
            alert.addButton(withTitle: "删除")
            alert.addButton(withTitle: "取消")
        }
        alert.buttons.first?.hasDestructiveAction = true

        let response = alert.runModal()
        if descendantCount > 0 {
            if response == .alertFirstButtonReturn {
                return (true, descendantIDs)
            }
            if response == .alertSecondButtonReturn {
                return (false, descendantIDs)
            }
            return nil
        }

        guard response == .alertFirstButtonReturn else {
            return nil
        }
        return (false, [])
    }

    private func deleteSessionsRecursively(threadIDs: [String]) -> (success: Bool, detail: String, failedFields: [String: String]?) {
        var deletedIDs: [String] = []
        var resultLines: [String] = []
        for threadID in threadIDs {
            let result = deleteSessionPermanently(threadID: threadID)
            if !result.success {
                let prefix = deletedIDs.isEmpty ? "" : "已删除: \(deletedIDs.joined(separator: ",")) | "
                return (false, prefix + result.detail, result.fields)
            }
            deletedIDs.append(threadID)
            if let fields = result.fields,
               let completedSteps = fields["completed_steps"],
               !completedSteps.isEmpty {
                resultLines.append("\(threadID): \(completedSteps)")
            } else {
                resultLines.append(threadID)
            }
        }
        return (true, resultLines.joined(separator: " | "), nil)
    }

    private func selectSessionRow(threadID: String) {
        guard let row = sessionSnapshots.firstIndex(where: { $0.threadID == threadID }) else { return }
        sessionStatusTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        sessionStatusTableView.scrollRowToVisible(row)
    }

    private func applyInitialSplitRatiosIfNeeded() {
        if !didApplyInitialContentSplitRatio,
           contentSplitView.subviews.count == 2,
           contentSplitView.bounds.height > contentSplitView.dividerThickness {
            setContentSplitRatio(0.62)
            didApplyInitialContentSplitRatio = true
            lastContentSplitHeight = contentSplitView.bounds.height
        }
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

    private func updateContentSplitRatioFromCurrentLayout() {
        guard !isApplyingContentSplitRatio else { return }
        guard didApplyInitialContentSplitRatio else { return }
        guard contentSplitView.subviews.count == 2 else { return }
        let availableHeight = contentSplitView.bounds.height - contentSplitView.dividerThickness
        guard availableHeight > 0 else { return }
        let currentTopHeight = contentSplitView.subviews[0].frame.height
        contentSplitRatio = min(max(currentTopHeight / availableHeight, 0.18), 0.88)
    }

    private func makePanel(title: String, metaLabel: NSTextField?, contentView: NSView, headerAccessoryView: NSView? = nil, reusePanelView: NSView? = nil) -> NSView {
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
        contentView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        contentView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let panelView = reusePanelView ?? NSView()
        panelView.translatesAutoresizingMaskIntoConstraints = false
        panelView.addSubview(headerStack)
        panelView.addSubview(contentView)
        panelView.setContentHuggingPriority(.defaultLow, for: .vertical)
        panelView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        panelView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        panelView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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
            self?.handleTableSelectionMouseDown(event) ?? event
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

    private func handleTableSelectionMouseDown(_ event: NSEvent) -> NSEvent? {
        guard let window = view.window, event.window == window else { return event }

        let windowPoint = event.locationInWindow
        let activeScrollView = activeLoopsTableView.enclosingScrollView
        let sessionScrollView = sessionStatusTableView.enclosingScrollView
        let selectedLoopIdentifierBeforeClick = selectedLoopSelectionIdentifier()
        let selectedSessionThreadIDBeforeClick = selectedSessionThreadID()
        let isInActiveLoopActionArea = anyViewContainsWindowPoint(
            [stopButton, resumeLoopButton, deleteLoopButton],
            windowPoint: windowPoint
        )
        let isInSessionActionArea = anyViewContainsWindowPoint(
            [saveRenameButton, archiveSessionButton, restoreSessionButton, deleteSessionButton, migrateSessionProviderButton, migrateAllSessionsProviderButton, exportSessionLogButton],
            windowPoint: windowPoint
        )
        let pointInActiveTable = activeLoopsTableView.convert(windowPoint, from: nil)
        let pointInSessionTable = sessionStatusTableView.convert(windowPoint, from: nil)
        let isInActiveTableBody = activeLoopsTableView.bounds.contains(pointInActiveTable)
        let isInSessionTableBody = sessionStatusTableView.bounds.contains(pointInSessionTable)
        let isInActiveTableEmptyArea = isInActiveTableBody && activeLoopsTableView.row(at: pointInActiveTable) < 0
        let isInSessionTableEmptyArea = isInSessionTableBody && sessionStatusTableView.row(at: pointInSessionTable) < 0
        let isInActiveHeader = viewContainsWindowPoint(activeLoopsTableView.headerView, windowPoint: windowPoint)
        let isInSessionHeader = viewContainsWindowPoint(sessionStatusTableView.headerView, windowPoint: windowPoint)
        let isInActiveLoopsArea = anyViewContainsWindowPoint([activeLoopsPanelView, activeScrollView, activeLoopsTableView.headerView].compactMap { $0 }, windowPoint: windowPoint)
        let isInSessionStatusArea = anyViewContainsWindowPoint([sessionStatusPanelView, sessionScrollView, sessionStatusTableView.headerView].compactMap { $0 }, windowPoint: windowPoint)

        if isInActiveLoopActionArea {
            if sessionStatusTableView.selectedRow >= 0 {
                sessionStatusTableView.deselectAll(nil)
                updateSessionDetailView()
            }
            return event
        }

        if isInSessionActionArea {
            if activeLoopsTableView.selectedRow >= 0 {
                preferredLoopSelectionIdentifier = nil
                isProgrammaticLoopSelectionChange = true
                activeLoopsTableView.deselectAll(nil)
                isProgrammaticLoopSelectionChange = false
                updateLoopActionButtons()
                refreshTableWrapping(activeLoopsTableView)
            }
            return event
        }

        if isInActiveLoopsArea {
            if sessionStatusTableView.selectedRow >= 0 {
                sessionStatusTableView.deselectAll(nil)
                updateSessionDetailView()
            }
            if isInActiveHeader || isInActiveTableEmptyArea {
                if let selectedLoopIdentifierBeforeClick {
                    DispatchQueue.main.async { [weak self] in
                        self?.restoreLoopSelection(preferredIdentifier: selectedLoopIdentifierBeforeClick)
                    }
                }
            }
            return event
        }

        if isInSessionStatusArea {
            if activeLoopsTableView.selectedRow >= 0 {
                preferredLoopSelectionIdentifier = nil
                isProgrammaticLoopSelectionChange = true
                activeLoopsTableView.deselectAll(nil)
                isProgrammaticLoopSelectionChange = false
                updateLoopActionButtons()
                refreshTableWrapping(activeLoopsTableView)
            }
            if isInSessionHeader || isInSessionTableEmptyArea {
                if let selectedSessionThreadIDBeforeClick {
                    DispatchQueue.main.async { [weak self] in
                        self?.restoreSessionSelection(preferredThreadID: selectedSessionThreadIDBeforeClick)
                    }
                }
            }
            return event
        }

        var didChangeSelection = false
        if activeLoopsTableView.selectedRow >= 0 {
            preferredLoopSelectionIdentifier = nil
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
        return event
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

    @objc
    private func handleSessionFilterCheckbox(_ sender: NSButton) {
        guard let item = sender.identifier?.rawValue else { return }
        toggleSessionFilterSelection(item: item)
    }

    private func makeSessionFilterCheckbox(item: String, selected: Bool) -> NSButton {
        let button = NSButton(checkboxWithTitle: sessionFilterItemTitle(item), target: self, action: #selector(handleSessionFilterCheckbox(_:)))
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
        let selections = toggledSessionFilterValues(selectedFilterValues(for: kind), item: item)
        setSelectedFilterValues(selections, for: kind)

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

        let items = sessionFilterPanelItems(options: sessionFilterOptions(for: kind))
        let selectedValues = selectedFilterValues(for: kind)
        for item in items {
            let isSelected = isSessionFilterItemSelected(item, selectedValues: selectedValues)
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
        let hasSelection = hasSelectedSession()
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
        refreshSessionStatusButton.isEnabled = true
        if enabled {
            updateLoopActionButtons()
        } else {
            stopButton.isEnabled = false
            resumeLoopButton.isEnabled = false
            deleteLoopButton.isEnabled = false
            disableSelectedSessionActionButtons()
        }
    }

    private func updateDetectStatusButtonState() {
        detectStatusButton.title = detectSessionButtonTitle(isRunning: isSessionScanRunning)
        detectStatusButton.isEnabled = true
        refreshSessionStatusButton.isEnabled = true
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
        withSelectedSession(logText: "请先选择一条 Session，再导出相关日志。") { session in
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
    }

    @objc
    private func toggleActivityLogFailuresOnly() {
        refreshActivityLogView(scrollToEnd: false)
    }

    @objc
    private func toggleActivityLogSelectedSessionFilter() {
        if activityLogSelectedSessionCheckbox.state == .on {
            guard hasSelectedSession() else {
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
            statusSegmentColors[key] = color ?? statusColor(for: resolvedStatusPresentationTone(text: trimmed, key: key))
            if let delay = statusAutoClearDelay(text: trimmed, key: key) {
                scheduleStatusAutoClear(key: key, expectedText: trimmed, delay: delay)
            }
        }

        refreshVisibleStatusLabel()
    }

    private func statusColor(for tone: StatusPresentationTone) -> NSColor {
        switch tone {
        case .neutralPrimary:
            return .secondaryLabelColor
        case .neutralSecondary:
            return .tertiaryLabelColor
        case .progress:
            return .systemBlue
        case .failure:
            return .systemRed
        case .warning:
            return .systemOrange
        case .success:
            return .systemGreen
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

    private func refreshVisibleStatusLabel() {
        if let visibleSegment = resolvedVisibleStatusSegment(segments: statusSegments) {
            statusLabel.stringValue = visibleSegment.text
            statusLabel.textColor = statusSegmentColors[visibleSegment.key] ?? .secondaryLabelColor
            return
        }

        statusLabel.stringValue = defaultVisibleStatusText()
        statusLabel.textColor = .secondaryLabelColor
    }

    private func startAutoRefresh() {
        installRepeatingTimer(&refreshTimer, interval: autoRefreshInterval) { [weak self] in
            self?.requestLoopSnapshotRefresh()
        }
    }

    private func startRequestPump() {
        installRepeatingTimer(&requestTimer, interval: requestPollInterval) { [weak self] in
            self?.sendRequestCoordinator.processPendingRequests()
        }
    }

    private func startSessionStatusRefreshTimer() {
        installRepeatingTimer(&sessionStatusRefreshTimer, interval: sessionStatusRefreshSchedulerInterval) { [weak self] in
            self?.scheduleDueSessionStatusRefreshes()
        }
    }

    private func installRepeatingTimer(_ timer: inout Timer?, interval: TimeInterval, handler: @escaping () -> Void) {
        timer?.invalidate()
        let repeatingTimer = Timer(timeInterval: interval, repeats: true) { _ in
            handler()
        }
        timer = repeatingTimer
        RunLoop.main.add(repeatingTimer, forMode: .common)
    }

    private func stopBackgroundTimers() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        requestTimer?.invalidate()
        requestTimer = nil
        sessionStatusRefreshTimer?.invalidate()
        sessionStatusRefreshTimer = nil
    }

    private func updateActiveLoopsWarningDisplay() {
        let warningText = loopWarnings.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        activeLoopsWarningLabel.stringValue = warningText
        activeLoopsWarningLabel.toolTip = warningText.isEmpty ? nil : warningText
        activeLoopsWarningLabel.isHidden = warningText.isEmpty
    }

    private func applyLoopSnapshotResult(loops: [LoopSnapshot], warnings: [String], failureMessage: String? = nil) {
        loopSnapshots = mergeLoopSnapshots(previous: loopSnapshots, incoming: loops)
        loopWarnings = warnings
        applyLoopSorting()

        if let failureMessage, !failureMessage.isEmpty {
            activeLoopsMetaLabel.stringValue = failureMessage
        } else {
            activeLoopsMetaLabel.stringValue = loops.isEmpty ? "循环: 0" : "循环: \(loops.count)"
        }

        updateActiveLoopsWarningDisplay()
        activeLoopsTableView.reloadData()
        autoSizeActiveLoopsColumnsIfNeeded()
        restoreLoopSelection(preferredIdentifier: nil)
        refreshTableWrapping(activeLoopsTableView)
        updateLoopActionButtons()
    }

    private func maybeShowLoopAmbiguityAlerts(_ loops: [LoopSnapshot]) {
        var currentSignatures: Set<String> = []
        for loop in loops {
            let reasons = [loop.stoppedReasonKind, loop.pauseReasonKind, loop.failureReasonKind]
            let hasAmbiguousReason = reasons.contains { $0 == .ambiguousTarget }
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

    private func formatEpoch(_ rawValue: String) -> String {
        guard let epoch = TimeInterval(rawValue) else { return rawValue }
        return Self.loopTimeFormatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    private func formatEpoch(_ epoch: TimeInterval) -> String {
        guard epoch > 0 else { return "0" }
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
        showAlert(
            style: .warning,
            title: ambiguousTargetAlertTitle(),
            informativeText: ambiguousTargetAlertText(actionName: actionName, detail: detail),
            buttonTitles: ["确定"]
        )
    }

    private func showRuntimePermissionAlert(actionName: String, detail: String) {
        showAlert(
            style: .warning,
            title: runtimePermissionAlertTitle(actionName: actionName),
            informativeText: runtimePermissionAlertText(
                actionName: actionName,
                runtimeDirectoryPath: runtimeDirectoryPath,
                userLoopStateDirectoryPath: userLoopStateDirectoryPath,
                legacyLoopStateDirectoryPath: legacyLoopStateDirectoryPath,
                detail: detail
            ),
            buttonTitles: ["确定"]
        )
    }

    private func runtimePermissionIssueForAction(requiresLoopState: Bool) -> String? {
        taskMasterRuntimePermissionIssueForAction(
            paths: RuntimePermissionPaths(
                stateDirectoryPath: stateDirectoryPath,
                pendingRequestDirectoryPath: pendingRequestDirectoryPath,
                processingRequestDirectoryPath: processingRequestDirectoryPath,
                resultRequestDirectoryPath: resultRequestDirectoryPath,
                runtimeDirectoryPath: runtimeDirectoryPath,
                loopsDirectoryPath: loopsDirectoryPath,
                loopLogDirectoryPath: loopLogDirectoryPath,
                userLoopStateDirectoryPath: userLoopStateDirectoryPath,
                legacyLoopStateDirectoryPath: legacyLoopStateDirectoryPath
            ),
            requiresLoopState: requiresLoopState
        )
    }

    private func preflightRuntimePermissions(actionName: String, requiresLoopState: Bool) -> Bool {
        guard let issue = runtimePermissionIssueForAction(requiresLoopState: requiresLoopState) else {
            return true
        }

        appendOutput("已阻止\(actionName)：\(issue)")
        setStatus("\(actionName)失败", key: "action", color: .systemRed)
        showRuntimePermissionAlert(actionName: actionName, detail: issue)
        NSSound.beep()
        return false
    }

    @discardableResult
    private func saveStoppedLoopEntry(target: String, interval: String, message: String, forceSend: Bool, reason: String) -> Bool {
        if loopSnapshots.contains(where: { $0.target == target && !$0.isStopped }) {
            return false
        }
        let success = loopCommandService.saveStoppedLoopEntry(
            target: target,
            interval: interval,
            message: message,
            forceSend: forceSend,
            reason: reason
        )
        if !success {
            appendOutput("stderr: 保存停止态 loop 失败: \(target)")
            return false
        }
        return success
    }

    private func saveStoppedLoopEntryAsync(target: String, interval: String, message: String, forceSend: Bool, reason: String, completion: ((Bool) -> Void)? = nil) {
        loopCommandService.saveStoppedLoopEntryAsync(
            target: target,
            interval: interval,
            message: message,
            forceSend: forceSend,
            reason: reason,
            completion: completion
        )
    }

    private func saveCurrentLoopAsStoppedAsync(target: String, interval: String, reason: String) {
        let options = currentLoopMessageOptions()
        saveStoppedLoopEntryAsync(
            target: target,
            interval: interval,
            message: options.message,
            forceSend: options.forceSend,
            reason: reason
        ) { _ in
            self.scheduleLoopSnapshotRefresh()
        }
    }

    private func isAmbiguousTargetError(_ detail: String) -> Bool {
        detail.contains("found multiple matching sessions for target") ||
        detail.contains("found multiple matching thread titles for target") ||
        detail.contains("found multiple matching Terminal ttys for target")
    }

    private func handleUniqueTargetValidationResult(_ result: HelperCommandResult, target: String, actionName: String) -> Bool {
        lastTargetValidationFailureReason = nil
        lastTargetValidationFailureDetail = ""
        guard result.status == 0 else {
            let detail = result.primaryDetail ?? ""
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

    private func validateUniqueTargetAsync(target: String, actionName: String, completion: @escaping (Bool) -> Void) {
        lastTargetValidationFailureReason = nil
        lastTargetValidationFailureDetail = ""
        loopCommandService.validateUniqueTargetAsync(target: target) { result in
            completion(self.handleUniqueTargetValidationResult(result, target: target, actionName: actionName))
        }
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

    private func showSessionActionBlockedAlert(actionLabel: String, session: SessionSnapshot, detail: String, ambiguous: Bool) {
        showAlert(
            style: .warning,
            title: sessionActionBlockedAlertTitle(actionLabel: actionLabel, ambiguous: ambiguous),
            informativeText: sessionActionBlockedAlertText(
                actionLabel: actionLabel,
                session: session,
                detail: detail,
                ambiguous: ambiguous
            ),
            buttonTitles: ["知道了"]
        )
    }

    private func runAlert(
        style: NSAlert.Style,
        title: String,
        informativeText: String,
        buttonTitles: [String],
        destructiveFirstButton: Bool = false
    ) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = informativeText
        buttonTitles.forEach { alert.addButton(withTitle: $0) }
        if destructiveFirstButton {
            alert.buttons.first?.hasDestructiveAction = true
        }
        return alert.runModal()
    }

    private func showAlert(
        style: NSAlert.Style,
        title: String,
        informativeText: String,
        buttonTitles: [String],
        destructiveFirstButton: Bool = false
    ) {
        _ = runAlert(
            style: style,
            title: title,
            informativeText: informativeText,
            buttonTitles: buttonTitles,
            destructiveFirstButton: destructiveFirstButton
        )
    }

    private func scheduleLoopSnapshotRefresh(after delay: TimeInterval = 0) {
        guard delay > 0 else {
            requestLoopSnapshotRefresh()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.requestLoopSnapshotRefresh()
        }
    }

    private func scheduleLoopSnapshotRefreshes(after delays: [TimeInterval]) {
        for delay in delays {
            scheduleLoopSnapshotRefresh(after: delay)
        }
    }

    private func runHelper(
        actionName: String,
        displayArguments: [String],
        execution: @escaping (@escaping (HelperCommandResult) -> Void) -> Void
    ) {
        persistDefaults()
        setStatus("", key: "send")
        setButtonsEnabled(false)
        setStatus("\(actionName)执行中…", key: "action")
        appendOutput("执行 \(actionName): \(displayArguments.joined(separator: " "))")

        execution { result in
            let plan = helperExecutionPlan(
                actionName: actionName,
                displayArguments: displayArguments,
                result: result,
                loopSnapshots: self.loopSnapshots,
                currentTarget: self.currentTarget()
            )
            if !result.stdout.isEmpty {
                self.appendOutput(result.stdout)
            }
            let structuredSendResult =
                actionName == "发送一次" ? parseStructuredSendHelperResult(result.stderr) : nil
            if !result.stderr.isEmpty {
                if structuredSendResult == nil {
                    self.appendOutput(plan.isAccepted ? result.stderr : "stderr: \(result.stderr)")
                }
            }

            if plan.isSuccessful {
                if plan.shouldRecordHistory {
                    self.recordCurrentInputsInHistory()
                }
                if let optimisticSnapshot = plan.optimisticLoopSnapshot {
                    self.loopSnapshots = applyingOptimisticLoopSnapshot(optimisticSnapshot, to: self.loopSnapshots)
                    self.applyLoopSorting()
                    self.activeLoopsMetaLabel.stringValue = self.loopSnapshots.isEmpty ? "循环: 0" : "循环: \(self.loopSnapshots.count)"
                    self.activeLoopsTableView.reloadData()
                    self.autoSizeActiveLoopsColumnsIfNeeded()
                    self.restoreLoopSelection(preferredIdentifier: optimisticSnapshot.loopID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "target:\(optimisticSnapshot.target)" : loopSelectionIdentifier(optimisticSnapshot))
                    self.refreshTableWrapping(self.activeLoopsTableView)
                    self.updateLoopActionButtons()
                }
                if !plan.optimisticRefreshDelays.isEmpty {
                    self.scheduleLoopSnapshotRefreshes(after: plan.optimisticRefreshDelays)
                }
                if let deletedTarget = plan.deletedLoopTarget {
                    self.loopSnapshots.removeAll { $0.target == deletedTarget }
                    if self.preferredLoopSelectionIdentifier == "target:\(deletedTarget)" {
                        self.preferredLoopSelectionIdentifier = nil
                    }
                    self.activeLoopsTableView.reloadData()
                    self.updateLoopActionButtons()
                    self.refreshTableWrapping(self.activeLoopsTableView)
                }
                self.setStatus(plan.actionStatusText, key: "action")
            } else {
                if let ambiguous = plan.failurePresentation?.ambiguousTarget {
                    self.showAmbiguousTargetAlert(target: ambiguous.target, detail: ambiguous.detail, actionName: actionName, throttled: false)
                } else if let permissionIssue = plan.failurePresentation?.permissionIssue {
                    self.showRuntimePermissionAlert(actionName: actionName, detail: permissionIssue)
                }
                self.setStatus(plan.actionStatusText, key: "action", color: .systemRed)
            }
            self.setButtonsEnabled(true)
            self.scheduleLoopSnapshotRefresh()
        }
    }

    private func runHelper(arguments: [String], actionName: String) {
        runHelper(actionName: actionName, displayArguments: arguments) { completion in
            self.loopCommandService.runCommandAsync(arguments: arguments, completion: completion)
        }
    }

    private func runStandardHelper(arguments: [String]) -> HelperCommandResult {
        helperService.run(arguments: arguments)
    }

    private func sessionScanProcessCallbacks() -> HelperCommandProcessCallbacks {
        HelperCommandProcessCallbacks(
            onProcessStarted: { [weak self] process in
                guard let self else { return }
                self.sessionScanProcessLock.lock()
                self.currentSessionScanProcess = process
                self.sessionScanProcessLock.unlock()
            },
            onProcessFinished: { [weak self] process in
                guard let self else { return }
                self.sessionScanProcessLock.lock()
                if self.currentSessionScanProcess === process {
                    self.currentSessionScanProcess = nil
                }
                self.sessionScanProcessLock.unlock()
            }
        )
    }

    private func conflictingLoops(for target: String) -> [LoopSnapshot] {
        runningLoopConflicts(for: target, sessionSnapshots: sessionSnapshots, loopSnapshots: loopSnapshots)
    }

    private func promptToReplaceExistingLoops(conflicts: [LoopSnapshot], target: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = loopConflictAlertTitle()
        alert.informativeText = loopConflictAlertText(target: target, conflicts: conflicts)
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

        let displayArguments = taskMasterHelperDisplayArguments(
            base: ["start", "-t", target, "-i", interval, "-m", message],
            forceSend: forceSend
        )
        appendOutput("执行 开始循环: \(displayArguments.joined(separator: " "))")
        appendOutput("检测到循环冲突，先停止旧循环: \(conflicts.map(\.target).joined(separator: ", "))")

        DispatchQueue.global(qos: .userInitiated).async {
            var failureText: String?

            for conflict in conflicts {
                let stopArguments = conflict.loopID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? ["stop", "-t", conflict.target]
                    : ["stop", "-k", conflict.loopID]
                let stopResult = self.loopCommandService.runCommand(arguments: stopArguments)
                if stopResult.status != 0 {
                    failureText = stopResult.primaryDetail ?? "停止旧循环失败"
                    break
                }
            }

            let startResult: HelperCommandResult
            if let failureText {
                startResult = HelperCommandResult(status: 1, stdout: "", stderr: failureText)
            } else {
                startResult = self.loopCommandService.startLoop(
                    target: target,
                    interval: interval,
                    message: message,
                    forceSend: forceSend
                )
            }

            DispatchQueue.main.async {
                if !startResult.stdout.isEmpty {
                    self.appendOutput(startResult.stdout)
                }
                if !startResult.stderr.isEmpty {
                    self.appendOutput("stderr: \(startResult.stderr)")
                }
                if startResult.status != 0, failureText != nil {
                    self.saveStoppedLoopEntryAsync(target: target, interval: interval, message: message, forceSend: forceSend, reason: "start_failed") { _ in
                        self.appendOutput("已将开始失败的循环保留为停止状态。")
                        self.scheduleLoopSnapshotRefresh()
                    }
                }
                if startResult.status == 0 {
                    self.recordCurrentInputsInHistory()
                    self.setStatus("开始循环完成", key: "action")
                } else {
                    self.setStatus("开始循环失败", key: "action", color: .systemRed)
                }
                self.setButtonsEnabled(true)
                self.scheduleLoopSnapshotRefresh()
            }
        }
    }

    private func stopSessionStatusScan() {
        guard isSessionScanRunning else { return }
        stopSessionScanControl()
        let stoppedMode = activeSessionScanMode ?? displayedSessionListMode

        sessionScanProcessLock.lock()
        let process = currentSessionScanProcess
        sessionScanProcessLock.unlock()

        if let process, process.isRunning {
            process.terminate()
        }

        finishSessionScanUIState()
        setStatus(sessionScanStoppedStatusText(), key: "scan")
        appendOutput(sessionScanStoppedLogText())
        if sessionScanTotal > 0 {
            renderSessionSnapshots(scannedCount: allSessionSnapshots.count, totalCount: sessionScanTotal, isComplete: false)
            sessionStatusMetaLabel.stringValue += " | 已停止"
        } else {
            sessionStatusMetaLabel.stringValue = sessionScanStoppedMetaText(isArchived: stoppedMode == .archived)
            sessionStatusTableView.reloadData()
        }
    }

    private func requestLoopSnapshotRefresh() {
        if isRefreshingLoopsSnapshot {
            pendingLoopSnapshotRefresh = true
            return
        }
        refreshLoopsSnapshot()
    }

    private func finishLoopSnapshotRefresh() {
        isRefreshingLoopsSnapshot = false
        let shouldRefreshAgain = pendingLoopSnapshotRefresh
        pendingLoopSnapshotRefresh = false
        if shouldRefreshAgain {
            scheduleLoopSnapshotRefresh()
        }
    }

    private func refreshLoopsSnapshot() {
        guard !isRefreshingLoopsSnapshot else {
            pendingLoopSnapshotRefresh = true
            return
        }
        isRefreshingLoopsSnapshot = true
        loopCommandService.loopStatusAsync { decoded, failureMessage in
            if let decoded {
                self.applyLoopSnapshotResult(loops: decoded.loops, warnings: decoded.warnings)
                self.maybeShowLoopAmbiguityAlerts(decoded.loops)
            } else {
                self.applyLoopSnapshotResult(
                    loops: [],
                    warnings: [failureMessage ?? "Failed to load active loops."],
                    failureMessage: "加载循环失败"
                )
            }
            self.finishLoopSnapshotRefresh()
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
        let generation = beginSessionScanControl()
        sessionScanTotal = 0
        sessionStatusRefreshCoordinator.clear()
        updateDetectStatusButtonState()
        setStatus(sessionScanRunningStatusText(), key: "scan")
        appendOutput(sessionScanStartLogText())
        invalidateSessionSearch(resetPromptCache: true)
        sessionStatusMetaLabel.stringValue = sessionScanPreparingMetaText()

        DispatchQueue.global(qos: .userInitiated).async {
            let processCallbacks = self.sessionScanProcessCallbacks()
            let countResult = self.sessionScanService.sessionCount(processCallbacks: processCallbacks)

            if self.shouldAbortSessionScan(generation) {
                return
            }

            guard case let .success(totalCount) = countResult else {
                let failureDetail: String
                switch countResult {
                case let .failure(error):
                    failureDetail = error.detail
                case .success:
                    failureDetail = ""
                }
                DispatchQueue.main.async {
                    guard self.isCurrentSessionScan(generation) else { return }
                    self.finishSessionScanUIState()
                    self.sessionStatusMetaLabel.stringValue = sessionScanFailureMetaText(detail: failureDetail)
                    self.setStatus(sessionScanFailureStatusText(), key: "scan", color: .systemRed)
                    self.appendStderrDetailIfPresent(failureDetail)
                }
                return
            }

            DispatchQueue.main.async {
                guard self.isCurrentSessionScan(generation) else { return }
                self.sessionScanTotal = totalCount
                if totalCount == 0 {
                    self.finishSessionScanUIState()
                    self.allSessionSnapshots = []
                    self.sessionSnapshots = []
                    self.sessionStatusMetaLabel.stringValue = sessionScanEmptyMetaText()
                    self.sessionStatusTableView.reloadData()
                    self.setStatus(sessionScanCompletionStatusText(), key: "scan")
                } else {
                    self.sessionStatusMetaLabel.stringValue = sessionScanProgressMetaText(scannedCount: 0, totalCount: totalCount)
                    self.sessionStatusTableView.reloadData()
                }
            }

            guard totalCount > 0 else { return }

            var offset = 0
            var scannedCount = 0
            var encounteredFailure = false
            var failureDetail = ""
            var pendingSnapshots: [SessionSnapshot] = []

            while offset < totalCount {
                if self.shouldAbortSessionScan(generation) {
                    return
                }
                let batchSize = offset == 0 ? min(sessionProbeInitialBatchSize, totalCount) : min(sessionProbeBatchSize, totalCount - offset)
                let batchResult = self.sessionScanService.probeAllBatch(
                    limit: batchSize,
                    offset: offset,
                    processCallbacks: processCallbacks
                )

                if self.shouldAbortSessionScan(generation) {
                    return
                }

                guard case let .success(batchSnapshots) = batchResult else {
                    encounteredFailure = true
                    switch batchResult {
                    case let .failure(error):
                        failureDetail = error.detail
                    case .success:
                        failureDetail = ""
                    }
                    break
                }

                scannedCount = min(totalCount, offset + batchSize)
                pendingSnapshots = mergeSessionSnapshots(existing: pendingSnapshots, newSnapshots: batchSnapshots)

                DispatchQueue.main.async {
                    guard self.isCurrentSessionScan(generation) else { return }
                    self.allSessionSnapshots = pendingSnapshots
                    self.renderSessionSnapshots(scannedCount: scannedCount, totalCount: totalCount, isComplete: scannedCount >= totalCount)
                    if scannedCount < totalCount {
                        self.setStatus(sessionScanProgressStatusText(scannedCount: scannedCount, totalCount: totalCount), key: "scan")
                    }
                }

                offset += batchSize
            }

            DispatchQueue.main.async {
                guard self.isCurrentSessionScan(generation) else { return }
                self.finishSessionScanUIState()

                if encounteredFailure {
                    self.renderSessionSnapshots(scannedCount: scannedCount, totalCount: totalCount, isComplete: false)
                    self.sessionStatusMetaLabel.stringValue += sessionScanPartialFailureSuffix()
                    self.setStatus(sessionScanPartialFailureStatusText(), key: "scan", color: .systemOrange)
                    self.appendStderrDetailIfPresent(failureDetail)
                    return
                }

                self.renderSessionSnapshots(scannedCount: scannedCount, totalCount: totalCount, isComplete: true)
                self.sessionStatusRefreshCoordinator.prune(to: self.allSessionSnapshots)
                let completionDate = Date()
                for snapshot in self.loadedActiveSessionSnapshotsForStatusRefresh() {
                    self.sessionStatusRefreshCoordinator.scheduleNext(for: snapshot, from: completionDate)
                }
                self.setStatus(sessionScanCompletionStatusText(), key: "scan")
                self.appendOutput(sessionScanCompletionLogText(count: self.sessionSnapshots.count))
            }
        }
    }

    private func refreshArchivedSessions() {
        activeSessionScanMode = .archived
        displayedSessionListMode = .archived
        isSessionScanRunning = true
        let generation = beginSessionScanControl()
        sessionScanTotal = 0
        sessionStatusRefreshCoordinator.clear()
        updateDetectStatusButtonState()
        setStatus(archivedSessionLoadingStatusText(), key: "scan")
        appendOutput(archivedSessionStartLogText())
        invalidateSessionSearch(resetPromptCache: true)
        sessionStatusMetaLabel.stringValue = archivedSessionLoadingMetaText()

        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.sessionScanService.threadListArchived(processCallbacks: self.sessionScanProcessCallbacks())

            if self.shouldAbortSessionScan(generation) {
                return
            }

            DispatchQueue.main.async {
                guard self.isCurrentSessionScan(generation) else { return }
                self.finishSessionScanUIState()

                guard case let .success(snapshots) = result else {
                    let failureDetail: String
                    switch result {
                    case let .failure(error):
                        failureDetail = error.detail
                    case .success:
                        failureDetail = ""
                    }
                    self.sessionStatusMetaLabel.stringValue = archivedSessionFailureMetaText(detail: failureDetail)
                    self.setStatus(archivedSessionFailureStatusText(), key: "scan")
                    self.appendStderrDetailIfPresent(failureDetail)
                    return
                }

                self.allSessionSnapshots = snapshots
                self.sessionScanTotal = snapshots.count
                self.renderSessionSnapshots(scannedCount: snapshots.count, totalCount: snapshots.count, isComplete: true)
                self.setStatus(archivedSessionCompletionStatusText(), key: "scan")
                self.appendOutput(archivedSessionCompletionLogText(count: snapshots.count))
            }
        }
    }

    @objc
    private func sendOnce() {
        guard let target = validateTarget(), !currentMessage().isEmpty else {
            handleLoopMessageValidationFailure()
            return
        }
        guard preflightRuntimePermissions(actionName: "发送一次", requiresLoopState: false) else {
            return
        }
        guard ensureAccessibilityPermission(
            logText: "Codex Taskmaster 缺少辅助功能权限，无法发送按键。请在 系统设置 > 隐私与安全性 > 辅助功能 中允许它。"
        ) else {
            return
        }
        performValidatedLoopAction(
            target: target,
            actionName: "发送",
            validationStatusText: "发送一次校验中…"
        ) {
            self.setButtonsEnabled(true)
        } onValid: {
            let options = self.currentLoopMessageOptions()
            let displayArguments = taskMasterHelperDisplayArguments(
                base: ["send", "-t", target, "-m", options.message],
                forceSend: options.forceSend
            )
            self.runHelper(actionName: "发送一次", displayArguments: displayArguments) { completion in
                self.loopCommandService.sendMessageAsync(
                    target: target,
                    message: options.message,
                    forceSend: options.forceSend,
                    completion: completion
                )
            }
        }
    }

    @objc
    private func startLoop() {
        guard let target = validateTarget(), let interval = validateInterval(), !currentMessage().isEmpty else {
            handleLoopMessageValidationFailure()
            return
        }
        guard preflightRuntimePermissions(actionName: "开始循环", requiresLoopState: true) else {
            return
        }
        guard ensureAccessibilityPermission(
            logText: "Codex Taskmaster 缺少辅助功能权限，无法处理循环发送。请在 系统设置 > 隐私与安全性 > 辅助功能 中允许它。",
            actionStatusText: "开始循环失败",
            sideEffect: {
                self.saveStoppedLoopForStartFailure(
                    target: target,
                    interval: interval,
                    reason: "missing_accessibility_permission"
                )
            }
        ) else {
            return
        }
        performValidatedLoopAction(
            target: target,
            actionName: "开始循环",
            validationStatusText: "开始循环校验中…",
            failureStatusText: "开始循环失败",
            failureSideEffect: {
                let reason = self.lastTargetValidationFailureReason ?? "start_failed"
                self.saveStoppedLoopForStartFailure(
                    target: target,
                    interval: interval,
                    reason: reason
                )
            }
        ) {
            let options = self.currentLoopMessageOptions()
            let conflicts = self.conflictingLoops(for: target)
            if !conflicts.isEmpty {
                self.setButtonsEnabled(true)
                guard self.promptToReplaceExistingLoops(conflicts: conflicts, target: target) else {
                    self.appendOutput("已取消开始循环：检测到互斥循环未替换。")
                    self.setStatus("开始循环已取消", key: "action")
                    return
                }
                self.runLoopReplacement(
                    target: target,
                    interval: interval,
                    message: options.message,
                    forceSend: options.forceSend,
                    conflicts: conflicts
                )
                return
            }
            let displayArguments = taskMasterHelperDisplayArguments(
                base: ["start", "-t", target, "-i", interval, "-m", options.message],
                forceSend: options.forceSend
            )
            self.runHelper(actionName: "开始循环", displayArguments: displayArguments) { completion in
                self.loopCommandService.startLoopAsync(
                    target: target,
                    interval: interval,
                    message: options.message,
                    forceSend: options.forceSend,
                    completion: completion
                )
            }
        }
    }

    @objc
    private func refreshLoopsAction() {
        appendOutput("刷新循环列表。")
        scheduleLoopSnapshotRefresh()
    }

    @objc
    private func detectStatuses() {
        refreshSessionStatuses()
    }

    @objc
    private func refreshSessionStatusesAction() {
        if displayedSessionListMode == .archived {
            refreshArchivedSessionsInBackground(showProgress: true)
            return
        }
        refreshLoadedSessionStatusesInBackground(showProgress: true)
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
            let activeScopeText = sessionScopeDisplayText(isArchived: activeMode == .archived)
            setStatus(sessionScopeChangeBlockedStatusText(), key: "scan", color: .systemOrange)
            appendOutput(sessionScopeChangeBlockedLogText(activeScopeText: activeScopeText))
            return
        }

        guard requestedMode != displayedSessionListMode else {
            setStatus(sessionScopeAlreadySelectedStatusText(scopeText: sessionScopeDisplayText(isArchived: displayedSessionListMode == .archived)), key: "scan")
            return
        }

        invalidateSessionSearch(resetPromptCache: true)
        sessionStatusTableView.reloadData()
        updateSessionDetailView()
        let requestedScopeText = sessionScopeDisplayText(isArchived: requestedMode == .archived)
        let displayedScopeText = sessionScopeDisplayText(isArchived: displayedSessionListMode == .archived)
        setStatus(sessionScopeChangedStatusText(requestedScopeText: requestedScopeText), key: "scan", color: .systemOrange)
        appendOutput(sessionScopeChangedLogText(requestedScopeText: requestedScopeText, displayedScopeText: displayedScopeText))
    }

    @objc
    private func stopLoop() {
        guard let loop = selectedLoopSnapshotForAction() else { return }
        guard !loop.isStopped else {
            handleStoppedLoopBlocked()
            return
        }
        runLoopTargetAction(actionName: "停止当前", commandName: "stop", loop: loop) { target, loopID, completion in
            self.loopCommandService.stopLoopAsync(target: target, loopID: loopID, completion: completion)
        }
    }

    @objc
    private func stopAllLoops() {
        runHelper(actionName: "全部停止", displayArguments: ["stop", "--all"]) { completion in
            self.loopCommandService.stopAllLoopsAsync(completion: completion)
        }
    }

    @objc
    private func resumeSelectedLoop() {
        guard let loop = selectedLoopSnapshotForAction() else { return }
        guard loop.isPaused || loop.isStopped else {
            handleResumeLoopBlocked()
            return
        }
        guard preflightRuntimePermissions(actionName: "恢复当前", requiresLoopState: true) else {
            return
        }

        guard ensureAccessibilityPermission(
            logText: "Codex Taskmaster 缺少辅助功能权限，无法恢复循环发送。请在 系统设置 > 隐私与安全性 > 辅助功能 中允许它。",
            actionStatusText: "恢复当前失败"
        ) else {
            return
        }

        targetField.stringValue = loop.target
        performValidatedLoopAction(
            target: loop.target,
            actionName: "恢复当前",
            validationStatusText: "恢复当前校验中…",
            failureStatusText: "恢复当前失败",
            failureSideEffect: {
                self.scheduleLoopSnapshotRefresh()
            }
        ) {
            self.runLoopTargetAction(actionName: "恢复当前", commandName: "loop-resume", loop: loop) { target, loopID, completion in
                self.loopCommandService.resumeLoopAsync(target: target, loopID: loopID, completion: completion)
            }
        }
    }

    @objc
    private func deleteSelectedLoop() {
        guard let loop = selectedLoopSnapshotForAction() else { return }
        runLoopTargetAction(actionName: "删除当前", commandName: "loop-delete", loop: loop) { target, loopID, completion in
            self.loopCommandService.deleteLoopAsync(target: target, loopID: loopID, completion: completion)
        }
    }

    @objc
    private func handleSessionStatusDoubleClick() {
        let clickedRow = sessionStatusTableView.clickedRow
        guard clickedRow >= 0, clickedRow < sessionSnapshots.count else { return }
        let session = sessionSnapshots[clickedRow]
        let value = preferredTargetValue(for: session)
        targetField.stringValue = value
        addHistoryValue(value, kind: .target)
        let usedName = !sessionActualName(session).isEmpty
        setStatus(sessionStatusFillTargetStatusText(value: value))
        appendOutput(sessionStatusFillTargetLogText(value: value, usedName: usedName))
    }

    @objc
    private func saveSessionRename() {
        withSelectedSession(logText: sessionRenameSelectionRequiredLogText()) { session in
            guard !session.isArchived else {
                handleSelectedSessionActionBlocked(
                    logText: archivedSessionRenameBlockedLogText(),
                    statusText: sessionRenameArchivedBlockedStatusText()
                )
                return
            }
            let newName = renameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            performSessionRenameExecution(session: session, newName: newName)
        }
    }

    @objc
    private func archiveSelectedSession() {
        withSelectedSession(logText: sessionArchiveSelectionRequiredLogText()) { session in
            guard !session.isArchived else {
                handleSelectedSessionActionBlocked(
                    logText: sessionArchiveAlreadyArchivedLogText(),
                    statusText: sessionArchiveAlreadyArchivedStatusText()
                )
                return
            }
            let matchingLoopTargets = loopTargetsAffectingSession(session, loopSnapshots: loopSnapshots)
            guard confirmSessionArchive(session: session, matchingLoopTargets: matchingLoopTargets) else {
                return
            }

            performSelectedSessionRemovalAction(
                threadID: session.threadID,
                selectedSessionIsArchived: false,
                runningStatusText: sessionArchiveRunningStatusText(),
                startLogText: sessionArchiveStartLogText(threadID: session.threadID),
                completionStatusText: sessionArchiveCompletionStatusText(),
                completionLogText: archivedSessionCompletionLogText(threadID: session.threadID),
                failureStatusText: sessionArchiveFailureStatusText(),
                beforeFailure: { error in
                    self.failSessionArchiveAction(session: session, error: error)
                }
            ) {
                self.archiveSession(threadID: session.threadID)
            }
        }
    }

    @objc
    private func restoreSelectedSession() {
        withSelectedSession(logText: archivedSessionRestoreSelectionRequiredLogText()) { session in
            guard session.isArchived else {
                handleSelectedSessionActionBlocked(
                    logText: sessionRestoreNonArchivedSelectionLogText(),
                    statusText: archivedSessionRestoreSelectionRequiredStatusText()
                )
                return
            }

            guard confirmSessionRestore(session: session) else {
                return
            }

            performSelectedSessionRemovalAction(
                threadID: session.threadID,
                selectedSessionIsArchived: true,
                runningStatusText: sessionRestoreRunningStatusText(),
                startLogText: sessionRestoreStartLogText(threadID: session.threadID),
                completionStatusText: sessionRestoreCompletionStatusText(),
                completionLogText: sessionRestoreCompletionLogText(threadID: session.threadID),
                failureStatusText: sessionRestoreFailureStatusText()
            ) {
                self.unarchiveSession(threadID: session.threadID)
            }
        }
    }

    @objc
    private func deleteSelectedSession() {
        withSelectedSession(logText: sessionDeleteSelectionRequiredLogText()) { session in
            let matchingLoopTargets = loopTargetsAffectingSession(session, loopSnapshots: loopSnapshots)
            self.loadAndExecuteSessionDelete(
                session: session,
                matchingLoopTargets: matchingLoopTargets
            )
        }
    }

    @objc
    private func migrateSelectedSessionToCurrentProvider() {
        withSelectedSession(logText: sessionProviderMigrationSelectionRequiredLogText()) { session in
            withProviderMigrationTargetProvider { targetProvider in
                self.loadAndExecuteSelectedSessionProviderMigration(
                    session: session,
                    targetProvider: targetProvider
                )
            }
        }
    }

    @objc
    private func migrateAllSessionsToCurrentProvider() {
        withProviderMigrationTargetProvider { targetProvider in
            self.loadAndExecuteAllSessionProviderMigration(targetProvider: targetProvider)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == activeLoopsTableView {
            return loopSnapshots.count
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
            guard row < loopSnapshots.count else { return cellView }
            let loop = loopSnapshots[row]
            let columnID = tableColumn.identifier.rawValue
            textField.stringValue = formattedLoopTableCellValue(
                identifier: columnID,
                loop: loop,
                allLoops: loopSnapshots,
                formatEpoch: formatEpoch(_:)
            )
            if columnID == "state" {
                textField.textColor = loopStateColor(loop)
            } else if columnID == "result" {
                textField.textColor = loopResultColor(loop)
            }
            textField.toolTip = columnID == "target"
                ? formattedLoopTargetToolTip(loop: loop, allLoops: loopSnapshots)
                : textField.stringValue
            return cellView
        }

        let session = sessionSnapshots[row]
        let columnID = tableColumn.identifier.rawValue
        textField.stringValue = formattedSessionTableCellValue(
            identifier: columnID,
            session: session,
            formatEpoch: formatEpoch(_:)
        )
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
                let selectedLoop = loopSnapshots[selectedRow]
                let selectedTarget = selectedLoop.target
                preferredLoopSelectionIdentifier = loopSelectionIdentifier(selectedLoop)
                if !isProgrammaticLoopSelectionChange {
                    targetField.stringValue = selectedTarget
                }
            } else {
                preferredLoopSelectionIdentifier = nil
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
            let preservedIdentifier = selectedLoopSelectionIdentifier()
            applyLoopSorting()
            activeLoopsTableView.reloadData()
            adjustTableColumnWidths(activeLoopsTableView)
            didAutoSizeActiveLoopsColumns = true
            restoreLoopSelection(preferredIdentifier: preservedIdentifier)
            refreshTableWrapping(activeLoopsTableView)
            return
        }
        if tableView == sessionStatusTableView {
            let preservedThreadID = selectedSessionThreadID()
            applySessionSorting()
            sessionStatusTableView.reloadData()
            adjustTableColumnWidths(sessionStatusTableView)
            didAutoSizeSessionColumns = true
            restoreSessionSelection(preferredThreadID: preservedThreadID)
            refreshTableWrapping(sessionStatusTableView)
            updateSessionDetailView()
        }
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView else { return }
        if tableView == activeLoopsTableView || tableView == sessionStatusTableView {
            synchronizeScrollableTableWidth(tableView)
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
        if splitView == contentSplitView {
            let heightDelta = abs(contentSplitView.bounds.height - lastContentSplitHeight)
            if heightDelta <= 0.5 {
                updateContentSplitRatioFromCurrentLayout()
            }
        }
    }

    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        guard splitView == contentSplitView else {
            return proposedEffectiveRect
        }

        if splitView.isVertical {
            return drawnRect.insetBy(dx: -5, dy: 0)
        }
        return drawnRect.insetBy(dx: 0, dy: -6)
    }

    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView == contentSplitView {
            let availableHeight = splitView.bounds.height - splitView.dividerThickness
            guard availableHeight > 0 else { return proposedPosition }
            let minTop = topPaneMinimumHeight
            let minBottom = bottomPaneMinimumHeight
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
