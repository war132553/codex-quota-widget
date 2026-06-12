import AppKit

final class WidgetWindowController: NSObject, NSWindowDelegate {
    let window: NSPanel
    var onRequestRefresh: (() -> Void)?
    var onOpenDashboard: (() -> Void)?
    var onShowTouchBar: (() -> Void)?
    var onOpenTouchBarSettings: (() -> Void)?
    var onToggleLanguage: (() -> WidgetLanguage)?
    var currentLanguage: (() -> WidgetLanguage)?

    private let stateStore: WidgetStateStore
    private let contentView = WidgetContentView()
    private var hasPlacedWindow = false
    private var currentState = FloatingQuotaState(
        codexSnapshot: nil,
        claudeSnapshot: nil,
        isCodexRunning: false,
        isClaudeDesktopRunning: false
    )

    init(stateStore: WidgetStateStore) {
        self.stateStore = stateStore
        self.window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 154, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init()

        setupWindow()
        setupContent()
        restoreInitialPlacement()
    }

    func show(state: FloatingQuotaState) {
        update(state: state)
        if !hasPlacedWindow {
            restoreInitialPlacement()
        }
        if !window.isVisible {
            window.orderFrontRegardless()
        }
    }

    func hide() {
        window.orderOut(nil)
    }

    func update(state: FloatingQuotaState) {
        currentState = state
        contentView.render(state: state)
        applySize()
    }

    func windowDidMove(_ notification: Notification) {
        let frame = window.frame
        stateStore.update { state in
            state.originX = frame.origin.x
            state.originY = frame.origin.y
        }
    }

    private func setupWindow() {
        window.delegate = self
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = false
        window.isReleasedWhenClosed = false
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func setupContent() {
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.onOpenDashboard = { [weak self] in self?.onOpenDashboard?() }
        contentView.onRequestRefresh = { [weak self] in
            self?.onRequestRefresh?()
        }
        contentView.onShowTouchBar = { [weak self] in
            self?.onShowTouchBar?()
        }
        contentView.onOpenTouchBarSettings = { [weak self] in
            self?.onOpenTouchBarSettings?()
        }
        contentView.onToggleLanguage = { [weak self] in
            self?.onToggleLanguage?() ?? .english
        }
        contentView.currentLanguage = { [weak self] in
            self?.currentLanguage?() ?? .english
        }
        window.contentView = contentView

        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
        ])

        applySize()
    }

    private func restoreInitialPlacement() {
        let state = stateStore.load()
        if let x = state.originX, let y = state.originY {
            window.setFrameOrigin(clampedOrigin(for: NSPoint(x: x, y: y), size: currentSize))
        } else {
            let frame = defaultFrame(for: currentSize)
            window.setFrame(frame, display: false)
        }
        hasPlacedWindow = true
    }

    private var currentSize: NSSize {
        let productCount = visibleProductCount(in: currentState)
        let width = 154
        let height = productCount > 1 ? 54 : 32
        return NSSize(width: width, height: height)
    }

    private func visibleProductCount(in state: FloatingQuotaState) -> Int {
        let codexVisible = state.isCodexRunning || state.codexSnapshot != nil
        let claudeVisible = state.isClaudeDesktopRunning || state.claudeSnapshot != nil
        return max(1, (codexVisible ? 1 : 0) + (claudeVisible ? 1 : 0))
    }

    private func applySize() {
        let newSize = currentSize
        var frame = window.frame
        let deltaHeight = newSize.height - frame.size.height
        frame.origin.y -= deltaHeight
        frame.size = newSize
        frame.origin = clampedOrigin(for: frame.origin, size: frame.size)
        window.setFrame(frame, display: true, animate: true)
    }

    private func defaultFrame(for size: NSSize) -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let visible = screen.visibleFrame
        let x = visible.maxX - size.width - 18
        let y = visible.maxY - size.height - 26
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func clampedOrigin(for origin: NSPoint, size: NSSize) -> NSPoint {
        let screen = screenContaining(point: origin) ?? NSScreen.main ?? NSScreen.screens.first!
        let visible = screen.visibleFrame

        let minX = visible.minX + 8
        let maxX = visible.maxX - size.width - 8
        let minY = visible.minY + 8
        let maxY = visible.maxY - size.height - 8

        return NSPoint(
            x: min(max(origin.x, minX), maxX),
            y: min(max(origin.y, minY), maxY)
        )
    }

    private func screenContaining(point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}

private final class WidgetContentView: NSView {
    var onOpenDashboard: (() -> Void)?
    var onRequestRefresh: (() -> Void)?
    var onShowTouchBar: (() -> Void)?
    var onOpenTouchBarSettings: (() -> Void)?
    var onToggleLanguage: (() -> WidgetLanguage)?
    var currentLanguage: (() -> WidgetLanguage)?
    private var mouseDownWindowOrigin: NSPoint?
    private var suppressNextMouseUp = false

    private let summaryStack = NSStackView()
    private let codexSummaryView = ProductSummaryView(title: "Codex")
    private let claudeSummaryView = ProductSummaryView(title: "Claude")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        self
    }

    func render(state: FloatingQuotaState) {
        layer?.backgroundColor = WidgetColors.backgroundColor.cgColor

        let showCodex = state.isCodexRunning || state.codexSnapshot != nil
        let showClaude = state.isClaudeDesktopRunning || state.claudeSnapshot != nil

        codexSummaryView.isHidden = !showCodex
        claudeSummaryView.isHidden = !showClaude

        if let snapshot = state.codexSnapshot {
            let windows = normalizedWindows(from: snapshot)
            let fiveHour = windows.fiveHour
            let sevenDay = windows.sevenDay

            codexSummaryView.render(
                firstPercent: fiveHour.map { Int($0.remainingPercent.rounded()) },
                firstColor: WidgetColors.color(for: fiveHour?.remainingPercent),
                secondPercent: sevenDay.map { Int($0.remainingPercent.rounded()) },
                secondColor: WidgetColors.color(for: sevenDay?.remainingPercent)
            )
            codexSummaryView.toolTip = "Codex: \(percentText(fiveHour?.remainingPercent)) \(percentText(sevenDay?.remainingPercent))"
        } else {
            codexSummaryView.render(
                firstPercent: nil,
                firstColor: WidgetColors.mutedColor,
                secondPercent: nil,
                secondColor: WidgetColors.mutedColor
            )
            codexSummaryView.toolTip = state.isCodexRunning ? "Codex: 等待额度数据" : "Codex: 未运行"
        }

        if let snapshot = state.claudeSnapshot {
            let fiveHourRemaining = remainingPercent(fromUsed: snapshot.fiveHour.usedPercent)
            let sevenDayRemaining = remainingPercent(fromUsed: snapshot.sevenDay.usedPercent)
            claudeSummaryView.render(
                firstPercent: fiveHourRemaining.map { Int($0.rounded()) },
                firstColor: WidgetColors.color(for: fiveHourRemaining),
                secondPercent: sevenDayRemaining.map { Int($0.rounded()) },
                secondColor: WidgetColors.color(for: sevenDayRemaining)
            )
            claudeSummaryView.toolTip = "Claude: \(percentText(fiveHourRemaining)) \(percentText(sevenDayRemaining))"
        } else {
            claudeSummaryView.render(
                firstPercent: nil,
                firstColor: WidgetColors.mutedColor,
                secondPercent: nil,
                secondColor: WidgetColors.mutedColor
            )
            claudeSummaryView.toolTip = state.isClaudeDesktopRunning ? "Claude: 暂无限额数据" : "Claude: 未运行"
        }
    }

    private func setupViews() {
        summaryStack.orientation = .vertical
        summaryStack.alignment = .leading
        summaryStack.distribution = .equalSpacing
        summaryStack.spacing = 4
        summaryStack.translatesAutoresizingMaskIntoConstraints = false
        [codexSummaryView, claudeSummaryView].forEach { view in
            view.translatesAutoresizingMaskIntoConstraints = false
            summaryStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalToConstant: 136).isActive = true
            view.heightAnchor.constraint(equalToConstant: 20).isActive = true
        }

        addSubview(summaryStack)

        NSLayoutConstraint.activate([
            summaryStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            summaryStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            summaryStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            suppressNextMouseUp = true
            showContextMenu(with: event)
            return
        }

        mouseDownWindowOrigin = window?.frame.origin
    }

    override func mouseUp(with event: NSEvent) {
        if suppressNextMouseUp {
            suppressNextMouseUp = false
            return
        }

        guard isClickWithoutDrag() else {
            return
        }

        if event.clickCount >= 2 {
            onRequestRefresh?()
            return
        }

        onOpenDashboard?()
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(with: event)
    }

    private func isClickWithoutDrag() -> Bool {
        guard
            let downOrigin = mouseDownWindowOrigin,
            let currentOrigin = window?.frame.origin
        else {
            return true
        }
        return abs(currentOrigin.x - downOrigin.x) < 1 && abs(currentOrigin.y - downOrigin.y) < 1
    }

    private func showContextMenu(with event: NSEvent) {
        let menu = NSMenu()
        let dashboardItem = NSMenuItem(title: "打开额度看板", action: #selector(handleContextOpenDashboard), keyEquivalent: "")
        dashboardItem.target = self
        menu.addItem(dashboardItem)

        let refreshItem = NSMenuItem(
            title: "立即更新",
            action: #selector(handleContextRefresh),
            keyEquivalent: ""
        )
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(.separator())

        let touchBarItem = NSMenuItem(
            title: "显示 Touch Bar",
            action: #selector(handleContextShowTouchBar),
            keyEquivalent: ""
        )
        touchBarItem.target = self
        menu.addItem(touchBarItem)

        let touchBarSettingsItem = NSMenuItem(
            title: "打开 Touch Bar 设置...",
            action: #selector(handleContextOpenTouchBarSettings),
            keyEquivalent: ""
        )
        touchBarSettingsItem.target = self
        menu.addItem(touchBarSettingsItem)
        menu.addItem(.separator())

        let languageItem = NSMenuItem(
            title: currentLanguage?().menuTitle ?? WidgetLanguage.english.menuTitle,
            action: #selector(handleContextToggleLanguage),
            keyEquivalent: ""
        )
        languageItem.target = self
        menu.addItem(languageItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc
    private func handleContextOpenDashboard() {
        onOpenDashboard?()
    }

    @objc
    private func handleContextRefresh() {
        onRequestRefresh?()
    }

    @objc
    private func handleContextShowTouchBar() {
        onShowTouchBar?()
    }

    @objc
    private func handleContextOpenTouchBarSettings() {
        onOpenTouchBarSettings?()
    }

    @objc
    private func handleContextToggleLanguage() {
        _ = onToggleLanguage?()
    }

    private func normalizedWindows(from snapshot: QuotaSnapshot) -> (fiveHour: WindowQuota?, sevenDay: WindowQuota?) {
        let windows = [snapshot.primary, snapshot.secondary].compactMap { $0 }
        let fiveHour = windows.first { $0.label == "5h" }
        let sevenDay = windows.first { $0.label == "7d" }
        return (fiveHour, sevenDay)
    }

    private func percentText(_ value: Double?) -> String {
        guard let value else { return "--%" }
        return "\(Int(value.rounded()))%"
    }

    private func remainingPercent(fromUsed usedPercent: Double?) -> Double? {
        usedPercent.map { min(max(100 - $0, 0), 100) }
    }
}

enum WidgetColors {
    static let backgroundColor = NSColor(calibratedRed: 0.07, green: 0.1, blue: 0.15, alpha: 0.94)
    static let mutedColor = NSColor.white.withAlphaComponent(0.45)

    static func color(for remainingPercent: Double?) -> NSColor {
        let value = remainingPercent ?? 0
        switch value {
        case 60...:
            return NSColor(calibratedRed: 0.23, green: 0.79, blue: 0.39, alpha: 1)
        case 30...:
            return NSColor(calibratedRed: 0.97, green: 0.72, blue: 0.22, alpha: 1)
        default:
            return NSColor(calibratedRed: 0.96, green: 0.4, blue: 0.36, alpha: 1)
        }
    }

}

private final class ProductSummaryView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let firstMetricView = MiniMetricView()
    private let secondMetricView = MiniMetricView()

    init(title: String) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        wantsLayer = false
        setupViews()
        render(firstPercent: nil, firstColor: WidgetColors.mutedColor, secondPercent: nil, secondColor: WidgetColors.mutedColor)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(firstPercent: Int?, firstColor: NSColor, secondPercent: Int?, secondColor: NSColor) {
        firstMetricView.render(percent: firstPercent, color: firstColor)
        secondMetricView.render(percent: secondPercent, color: secondColor)
    }

    private func setupViews() {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .white.withAlphaComponent(0.94)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(firstMetricView)
        stack.addArrangedSubview(secondMetricView)
        addSubview(stack)

        NSLayoutConstraint.activate([
            titleLabel.widthAnchor.constraint(equalToConstant: 44),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }
}

private final class MiniMetricView: NSView {
    private let colorDot = DotView()
    private let valueLabel = NSTextField(labelWithString: "--%")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(percent: Int?, color: NSColor) {
        colorDot.fillColor = color
        valueLabel.stringValue = percent.map { "\($0)%" } ?? "--%"
    }

    private func setupViews() {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        valueLabel.textColor = .white
        valueLabel.alignment = .left
        valueLabel.lineBreakMode = .byClipping

        stack.addArrangedSubview(colorDot)
        stack.addArrangedSubview(valueLabel)
        addSubview(stack)

        NSLayoutConstraint.activate([
            colorDot.widthAnchor.constraint(equalToConstant: 6),
            colorDot.heightAnchor.constraint(equalToConstant: 6),
            valueLabel.widthAnchor.constraint(equalToConstant: 30),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: 40),
        ])
    }
}

private final class DotView: NSView {
    var fillColor: NSColor = .white {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        fillColor.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

private enum WidgetFormatter {
    static func timeUntilReset(_ date: Date?) -> String {
        guard let date else { return "--" }
        let delta = Int(date.timeIntervalSinceNow)
        guard delta > 0 else { return "已重置" }

        let hours = delta / 3600
        let minutes = (delta % 3600) / 60

        if hours >= 24 {
            return "\(hours / 24)d \(hours % 24)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    static func relativeAge(_ date: Date?) -> String {
        guard let date else { return "未知" }
        let delta = max(0, Int(-date.timeIntervalSinceNow))
        if delta < 60 {
            return "\(delta)s 前"
        }
        let minutes = delta / 60
        if minutes < 60 {
            return "\(minutes)m 前"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h 前"
        }
        return "\(hours / 24)d 前"
    }
}
