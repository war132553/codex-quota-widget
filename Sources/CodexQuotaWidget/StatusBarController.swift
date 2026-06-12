import AppKit

final class StatusBarController: NSObject {
    var onRequestRefresh: (() -> Void)?
    var onToggleFloatingWidget: (() -> Bool)?
    var onStartClaudeAutoRefresh: ((TimeInterval) -> ClaudeRefreshStatus)?
    var onPauseClaudeAutoRefresh: (() -> ClaudeRefreshStatus)?
    var onQuit: (() -> Void)?

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panelController = QuotaDashboardPanelController()
    private var snapshot: QuotaSnapshot?
    private var claudeRateLimit: ClaudeRateLimitSnapshot?
    private var claudeRefreshStatus = ClaudeRefreshStatus(
        isClaudeDesktopRunning: false,
        isAutoRefreshEnabled: false,
        selectedAutoRefreshDuration: nil,
        autoRefreshEndsAt: nil,
        nextRefreshAt: nil,
        isRefreshing: false,
        lastError: nil,
        consecutiveFailureCount: 0
    )
    private var isCodexRunning = false
    private var isFloatingWidgetShown = false
    private var lastPanelRenderKey: String?

    override init() {
        super.init()
        setupItem()
        render(
            snapshot: nil,
            claudeRateLimit: nil,
            claudeRefreshStatus: claudeRefreshStatus,
            isCodexRunning: false,
            isFloatingWidgetShown: false
        )
    }

    func render(
        snapshot: QuotaSnapshot?,
        claudeRateLimit: ClaudeRateLimitSnapshot?,
        claudeRefreshStatus: ClaudeRefreshStatus,
        isCodexRunning: Bool,
        isFloatingWidgetShown: Bool
    ) {
        self.snapshot = snapshot
        self.claudeRateLimit = claudeRateLimit
        self.claudeRefreshStatus = claudeRefreshStatus
        self.isCodexRunning = isCodexRunning
        self.isFloatingWidgetShown = isFloatingWidgetShown

        if let button = item.button {
            button.title = title(for: snapshot, claudeRateLimit: claudeRateLimit, isCodexRunning: isCodexRunning)
            button.toolTip = tooltip(for: snapshot, claudeRateLimit: claudeRateLimit, isCodexRunning: isCodexRunning)
        }

        let panelRenderKey = renderKey(
            snapshot: snapshot,
            claudeRateLimit: claudeRateLimit,
            claudeRefreshStatus: claudeRefreshStatus,
            isCodexRunning: isCodexRunning,
            isFloatingWidgetShown: isFloatingWidgetShown
        )
        if panelRenderKey != lastPanelRenderKey {
            lastPanelRenderKey = panelRenderKey
            panelController.render(
                codexCard: codexCard(for: snapshot, isCodexRunning: isCodexRunning),
            claudeCard: claudeCard(for: claudeRateLimit),
            isCodexRunning: isCodexRunning,
            claudeUpdatedAt: claudeRateLimit?.updatedAt,
            claudeRefreshStatus: claudeRefreshStatus,
                isFloatingWidgetShown: isFloatingWidgetShown,
                onRefreshClaude: { [weak self] in self?.onRequestRefresh?() },
                onStartClaudeAutoRefresh: { [weak self] duration in
                    guard let self else { return }
                    self.claudeRefreshStatus = self.onStartClaudeAutoRefresh?(duration) ?? self.claudeRefreshStatus
                },
                onPauseClaudeAutoRefresh: { [weak self] in
                    guard let self else { return }
                    self.claudeRefreshStatus = self.onPauseClaudeAutoRefresh?() ?? self.claudeRefreshStatus
                },
                onToggleFloatingWidget: { [weak self] in
                    guard let self else { return }
                    self.isFloatingWidgetShown = self.onToggleFloatingWidget?() ?? self.isFloatingWidgetShown
                },
                onQuit: { [weak self] in self?.onQuit?() }
            )
        }
    }

    private func renderKey(
        snapshot: QuotaSnapshot?,
        claudeRateLimit: ClaudeRateLimitSnapshot?,
        claudeRefreshStatus: ClaudeRefreshStatus,
        isCodexRunning: Bool,
        isFloatingWidgetShown: Bool
    ) -> String {
        var parts: [String] = []
        parts.append(isCodexRunning.description)
        parts.append(isFloatingWidgetShown.description)
        parts.append(snapshot?.sourceFileName ?? "-")
        parts.append(snapshot?.planType ?? "-")
        parts.append(percentKey(snapshot?.primary.remainingPercent))
        parts.append(resetKey(snapshot?.primary.resetsAt))
        parts.append(percentKey(snapshot?.secondary?.remainingPercent))
        parts.append(resetKey(snapshot?.secondary?.resetsAt))
        parts.append(claudeRateLimit?.sourceFileName ?? "-")
        parts.append(claudeRateLimit?.updatedAt.timeIntervalSince1970.description ?? "-")
        parts.append(percentKey(claudeRateLimit?.fiveHour.usedPercent))
        parts.append(resetKey(claudeRateLimit?.fiveHour.resetsAt))
        parts.append(percentKey(claudeRateLimit?.sevenDay.usedPercent))
        parts.append(resetKey(claudeRateLimit?.sevenDay.resetsAt))
        parts.append(claudeRefreshStatus.isClaudeDesktopRunning.description)
        parts.append(claudeRefreshStatus.isAutoRefreshEnabled.description)
        parts.append(claudeRefreshStatus.selectedAutoRefreshDuration?.description ?? "-")
        parts.append(claudeRefreshStatus.autoRefreshEndsAt?.timeIntervalSince1970.description ?? "-")
        parts.append(claudeRefreshStatus.nextRefreshAt?.timeIntervalSince1970.description ?? "-")
        parts.append(claudeRefreshStatus.isAutoRefreshEnabled ? "\(Int(Date().timeIntervalSince1970 / 60))" : "-")
        parts.append(claudeRefreshStatus.isRefreshing.description)
        parts.append(claudeRefreshStatus.lastError ?? "-")
        return parts.joined(separator: "|")
    }

    private func percentKey(_ value: Double?) -> String {
        guard let value else { return "-" }
        return "\(Int(value.rounded()))"
    }

    private func resetKey(_ date: Date?) -> String {
        guard let date else { return "-" }
        return "\(Int(date.timeIntervalSince1970 / 60))"
    }

    func toggleDashboardPanel() {
        guard let button = item.button else {
            return
        }
        panelController.toggle(relativeTo: button)
    }

    private func setupItem() {
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "Codex quota")
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            button.target = self
            button.action = #selector(handleStatusItemClick)
        }
    }

    @objc
    private func handleStatusItemClick() {
        toggleDashboardPanel()
    }

    private func title(
        for snapshot: QuotaSnapshot?,
        claudeRateLimit: ClaudeRateLimitSnapshot?,
        isCodexRunning: Bool
    ) -> String {
        let claudeTitle = claudeTitle(for: claudeRateLimit)
        guard isCodexRunning else {
            return claudeTitle.map { "Codex -- -- · \($0)" } ?? "Codex -- -- · Claude -- --"
        }
        guard let snapshot else {
            return claudeTitle.map { "Codex ... ... · \($0)" } ?? "Codex ... ..."
        }

        let windows = normalizedWindows(from: snapshot)
        let fiveHour = percentText(windows.fiveHour)
        let sevenDay = percentText(windows.sevenDay)
        let codexTitle = "Codex \(fiveHour) \(sevenDay)"
        return claudeTitle.map { "\(codexTitle) · \($0)" } ?? codexTitle
    }

    private func tooltip(
        for snapshot: QuotaSnapshot?,
        claudeRateLimit: ClaudeRateLimitSnapshot?,
        isCodexRunning: Bool
    ) -> String {
        guard isCodexRunning else {
            return claudeRateLimit == nil ? "Codex 未运行 · Claude 暂无数据" : "Claude Code rate limits"
        }
        guard let snapshot else {
            return "等待 Codex 额度数据"
        }
        return "Codex quota · \(snapshot.sourceFileName)"
    }

    private func menu(
        for snapshot: QuotaSnapshot?,
        claudeRateLimit: ClaudeRateLimitSnapshot?,
        claudeRefreshStatus: ClaudeRefreshStatus,
        isCodexRunning: Bool
    ) -> NSMenu {
        let menu = NSMenu()

        menu.addItem(infoItem(statusLine(for: snapshot, isCodexRunning: isCodexRunning), style: .header))

        if let snapshot {
            menu.addItem(panelItem(
                title: "Codex",
                rows: codexRows(from: snapshot),
                footer: "来源: \(snapshot.sourceFileName) · 套餐: \(snapshot.planType ?? "unknown")"
            ))
        }

        menu.addItem(.separator())
        if let claudeRateLimit {
            menu.addItem(panelItem(
                title: "Claude Code",
                rows: claudeRows(from: claudeRateLimit),
                footer: "来源: \(claudeRateLimit.sourceFileName) · 更新: \(relativeAge(claudeRateLimit.updatedAt))"
            ))
        } else {
            menu.addItem(infoItem("Claude Code 限额", style: .header))
            menu.addItem(infoItem("暂无 Claude 限额数据", style: .secondary))
        }

        menu.addItem(infoItem(
            "Claude Desktop: \(claudeRefreshStatus.isClaudeDesktopRunning ? "运行中" : "未运行")",
            style: claudeRefreshStatus.isClaudeDesktopRunning ? .secondary : .warning
        ))

        if claudeRefreshStatus.isRefreshing {
            menu.addItem(infoItem("刷新: 进行中", style: .secondary))
        } else if claudeRefreshStatus.isAutoRefreshEnabled {
            menu.addItem(infoItem("自动刷新: 运行中 · 截止 \(clockText(claudeRefreshStatus.autoRefreshEndsAt)) · 下次 \(relativeFutureText(claudeRefreshStatus.nextRefreshAt))", style: .secondary))
        } else {
            menu.addItem(infoItem("自动刷新: 已暂停", style: .secondary))
        }

        if let lastError = claudeRefreshStatus.lastError {
            menu.addItem(infoItem("错误: \(lastError)", style: .warning))
        }

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "立即刷新 Claude 限额", action: #selector(handleRefresh), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = !claudeRefreshStatus.isRefreshing && claudeRefreshStatus.isClaudeDesktopRunning
        menu.addItem(refreshItem)

        let autoItem = NSMenuItem(
            title: claudeRefreshStatus.isAutoRefreshEnabled ? "暂停 Claude 自动刷新" : "启动 Claude 自动刷新 1 小时",
            action: claudeRefreshStatus.isAutoRefreshEnabled ? #selector(handlePauseClaudeAutoRefresh) : #selector(handleStartClaudeAutoRefresh),
            keyEquivalent: ""
        )
        autoItem.target = self
        autoItem.isEnabled = !claudeRefreshStatus.isRefreshing && claudeRefreshStatus.isClaudeDesktopRunning
        menu.addItem(autoItem)

        menu.addItem(.separator())

        let showWidgetItem = NSMenuItem(
            title: isFloatingWidgetShown ? "隐藏悬浮胶囊" : "显示悬浮胶囊",
            action: #selector(handleToggleFloatingWidget),
            keyEquivalent: ""
        )
        showWidgetItem.target = self
        showWidgetItem.isEnabled = true
        menu.addItem(showWidgetItem)

        return menu
    }

    private func statusLine(for snapshot: QuotaSnapshot?, isCodexRunning: Bool) -> String {
        guard isCodexRunning else {
            return "Codex 未运行"
        }
        guard snapshot != nil else {
            return "等待额度数据"
        }
        return "Codex 额度"
    }

    private enum InfoStyle {
        case normal
        case header
        case secondary
        case warning
    }

    private func infoItem(_ title: String, style: InfoStyle = .normal) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = true

        let font: NSFont
        let color: NSColor
        switch style {
        case .normal:
            font = .systemFont(ofSize: NSFont.systemFontSize)
            color = .labelColor
        case .header:
            font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            color = .labelColor
        case .secondary:
            font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            color = .secondaryLabelColor
        case .warning:
            font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            color = .systemOrange
        }

        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: font,
                .foregroundColor: color,
            ]
        )
        return item
    }

    private func percentText(_ quota: WindowQuota?) -> String {
        guard let quota else {
            return "--%"
        }
        return "\(Int(quota.remainingPercent.rounded()))%"
    }

    private func resetText(_ date: Date?) -> String {
        guard let date else {
            return "--"
        }

        let remainingSeconds = Int(date.timeIntervalSinceNow)
        guard remainingSeconds > 0 else {
            return "已重置"
        }

        let hours = remainingSeconds / 3_600
        let minutes = (remainingSeconds % 3_600) / 60
        if hours >= 24 {
            return "\(hours / 24)d \(hours % 24)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private func clockText(_ date: Date?) -> String {
        guard let date else {
            return "--"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func relativeFutureText(_ date: Date?) -> String {
        guard let date else {
            return "--"
        }
        let seconds = Int(date.timeIntervalSinceNow)
        if seconds <= 0 {
            return "现在"
        }
        let minutes = seconds / 60
        if minutes > 0 {
            return "\(minutes)m 后"
        }
        return "\(seconds)s 后"
    }

    private func relativeAge(_ date: Date?) -> String {
        guard let date else {
            return "--"
        }

        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 {
            return "\(seconds)s 前"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m 前"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h 前"
        }
        return "\(hours / 24)d 前"
    }

    private func normalizedWindows(from snapshot: QuotaSnapshot) -> (fiveHour: WindowQuota?, sevenDay: WindowQuota?) {
        let windows = [snapshot.primary, snapshot.secondary].compactMap { $0 }
        let fiveHour = windows.first { $0.label == "5h" }
        let sevenDay = windows.first { $0.label == "7d" }
        return (fiveHour, sevenDay)
    }

    private func claudeTitle(for snapshot: ClaudeRateLimitSnapshot?) -> String? {
        guard let snapshot else {
            return nil
        }
        return "Claude \(claudePercentText(snapshot.fiveHour)) \(claudePercentText(snapshot.sevenDay))"
    }

    private func claudePercentText(_ quota: ClaudeRateLimitWindow) -> String {
        guard let remainingPercent = claudeRemainingPercent(quota) else {
            return "--%"
        }
        return "\(Int(remainingPercent.rounded()))%"
    }

    private func claudeRemainingPercent(_ quota: ClaudeRateLimitWindow) -> Double? {
        quota.usedPercent.map { min(max(100 - $0, 0), 100) }
    }

    private func codexRows(from snapshot: QuotaSnapshot) -> [QuotaPanelRow] {
        let windows = normalizedWindows(from: snapshot)
        return [
            QuotaPanelRow(
                title: "5 小时额度",
                primaryText: windows.fiveHour.map { "剩余 \(Int($0.remainingPercent.rounded()))%" } ?? "--",
                resetText: "重置 \(resetText(windows.fiveHour?.resetsAt))",
                usedPercent: windows.fiveHour?.remainingPercent
            ),
            QuotaPanelRow(
                title: "7 天额度",
                primaryText: windows.sevenDay.map { "剩余 \(Int($0.remainingPercent.rounded()))%" } ?? "--",
                resetText: "重置 \(resetText(windows.sevenDay?.resetsAt))",
                usedPercent: windows.sevenDay?.remainingPercent
            ),
        ]
    }

    private func emptyRows() -> [QuotaPanelRow] {
        [
            QuotaPanelRow(title: "5 小时额度", primaryText: "--", resetText: "重置 --", usedPercent: nil),
            QuotaPanelRow(title: "7 天额度", primaryText: "--", resetText: "重置 --", usedPercent: nil),
        ]
    }

    private func codexCard(for snapshot: QuotaSnapshot?, isCodexRunning: Bool) -> QuotaCardModel {
        guard let snapshot else {
            return QuotaCardModel(
                title: "Codex",
                subtitle: isCodexRunning ? "等待额度数据" : "Codex 未运行",
                rows: emptyRows(),
                footer: "来源: --"
            )
        }

        return QuotaCardModel(
            title: "Codex",
            subtitle: snapshot.planType ?? "unknown",
            rows: codexRows(from: snapshot),
            footer: "来源: \(snapshot.sourceFileName)"
        )
    }

    private func claudeRows(from snapshot: ClaudeRateLimitSnapshot) -> [QuotaPanelRow] {
        [
            QuotaPanelRow(
                title: "5 小时额度",
                primaryText: "剩余 \(claudePercentText(snapshot.fiveHour))",
                resetText: "重置 \(resetText(snapshot.fiveHour.resetsAt))",
                usedPercent: claudeRemainingPercent(snapshot.fiveHour)
            ),
            QuotaPanelRow(
                title: "7 天额度",
                primaryText: "剩余 \(claudePercentText(snapshot.sevenDay))",
                resetText: "重置 \(resetText(snapshot.sevenDay.resetsAt))",
                usedPercent: claudeRemainingPercent(snapshot.sevenDay)
            ),
        ]
    }

    private func claudeCard(for snapshot: ClaudeRateLimitSnapshot?) -> QuotaCardModel {
        guard let snapshot else {
            return QuotaCardModel(
                title: "Claude Code",
                subtitle: "暂无限额数据",
                rows: emptyRows(),
                footer: "来源: --"
            )
        }

        return QuotaCardModel(
            title: "Claude Code",
            subtitle: snapshot.sourceFileName,
            rows: claudeRows(from: snapshot),
            footer: ""
        )
    }

    private func panelItem(title: String, rows: [QuotaPanelRow], footer: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = QuotaPanelView(title: title, rows: rows, footer: footer)
        return item
    }

    @objc
    private func handleRefresh() {
        onRequestRefresh?()
    }

    @objc
    private func handleToggleFloatingWidget() {
        isFloatingWidgetShown = onToggleFloatingWidget?() ?? isFloatingWidgetShown
        render(
            snapshot: snapshot,
            claudeRateLimit: claudeRateLimit,
            claudeRefreshStatus: claudeRefreshStatus,
            isCodexRunning: isCodexRunning,
            isFloatingWidgetShown: isFloatingWidgetShown
        )
    }

    @objc
    private func handleStartClaudeAutoRefresh() {
        claudeRefreshStatus = onStartClaudeAutoRefresh?(60 * 60) ?? claudeRefreshStatus
        render(
            snapshot: snapshot,
            claudeRateLimit: claudeRateLimit,
            claudeRefreshStatus: claudeRefreshStatus,
            isCodexRunning: isCodexRunning,
            isFloatingWidgetShown: isFloatingWidgetShown
        )
    }

    @objc
    private func handlePauseClaudeAutoRefresh() {
        claudeRefreshStatus = onPauseClaudeAutoRefresh?() ?? claudeRefreshStatus
        render(
            snapshot: snapshot,
            claudeRateLimit: claudeRateLimit,
            claudeRefreshStatus: claudeRefreshStatus,
            isCodexRunning: isCodexRunning,
            isFloatingWidgetShown: isFloatingWidgetShown
        )
    }
}

private struct QuotaPanelRow {
    let title: String
    let primaryText: String
    let resetText: String
    let usedPercent: Double?
}

private struct QuotaCardModel {
    let title: String
    let subtitle: String
    let rows: [QuotaPanelRow]
    let footer: String
}

private struct RuntimeBadgeModel {
    let text: String
    let color: NSColor
}

private enum DashboardColors {
    static let background = NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.09, alpha: 1)
    static let card = NSColor(calibratedRed: 0.09, green: 0.105, blue: 0.14, alpha: 1)
    static let cardBorder = NSColor.white.withAlphaComponent(0.08)
    static let primaryText = NSColor.white.withAlphaComponent(0.94)
    static let secondaryText = NSColor.white.withAlphaComponent(0.62)
    static let tertiaryText = NSColor.white.withAlphaComponent(0.38)
    static let track = NSColor.white.withAlphaComponent(0.09)
}

private final class QuotaDashboardPanelController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let viewController = NSViewController()
    private let contentView = QuotaDashboardView()
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?

    override init() {
        super.init()
        setupPopover()
    }

    func render(
        codexCard: QuotaCardModel,
        claudeCard: QuotaCardModel,
        isCodexRunning: Bool,
        claudeUpdatedAt: Date?,
        claudeRefreshStatus: ClaudeRefreshStatus,
        isFloatingWidgetShown: Bool,
        onRefreshClaude: @escaping () -> Void,
        onStartClaudeAutoRefresh: @escaping (TimeInterval) -> Void,
        onPauseClaudeAutoRefresh: @escaping () -> Void,
        onToggleFloatingWidget: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        contentView.render(
            codexCard: codexCard,
            claudeCard: claudeCard,
            isCodexRunning: isCodexRunning,
            claudeUpdatedAt: claudeUpdatedAt,
            claudeRefreshStatus: claudeRefreshStatus,
            isFloatingWidgetShown: isFloatingWidgetShown,
            onRefreshClaude: onRefreshClaude,
            onStartClaudeAutoRefresh: onStartClaudeAutoRefresh,
            onPauseClaudeAutoRefresh: onPauseClaudeAutoRefresh,
            onToggleFloatingWidget: onToggleFloatingWidget,
            onQuit: onQuit
        )
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        startOutsideClickMonitoring()
    }

    private func setupPopover() {
        viewController.view = contentView
        popover.contentViewController = viewController
        popover.contentSize = NSSize(width: 390, height: 584)
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitoring()
    }

    private func startOutsideClickMonitoring() {
        stopOutsideClickMonitoring()

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.popover.performClose(nil)
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard
                let self,
                self.popover.isShown,
                let popoverWindow = self.contentView.window
            else {
                return event
            }
            if event.window !== popoverWindow {
                self.popover.performClose(nil)
            }
            return event
        }
    }

    private func stopOutsideClickMonitoring() {
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
    }
}

private final class QuotaDashboardView: NSView {
    private let rootStack = NSStackView()
    private var onRefreshClaude: (() -> Void)?
    private var onStartClaudeAutoRefresh: ((TimeInterval) -> Void)?
    private var onPauseClaudeAutoRefresh: (() -> Void)?
    private var onToggleFloatingWidget: (() -> Void)?
    private var onQuit: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 390, height: 584))
        setupBase()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(
        codexCard: QuotaCardModel,
        claudeCard: QuotaCardModel,
        isCodexRunning: Bool,
        claudeUpdatedAt: Date?,
        claudeRefreshStatus: ClaudeRefreshStatus,
        isFloatingWidgetShown: Bool,
        onRefreshClaude: @escaping () -> Void,
        onStartClaudeAutoRefresh: @escaping (TimeInterval) -> Void,
        onPauseClaudeAutoRefresh: @escaping () -> Void,
        onToggleFloatingWidget: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onRefreshClaude = onRefreshClaude
        self.onStartClaudeAutoRefresh = onStartClaudeAutoRefresh
        self.onPauseClaudeAutoRefresh = onPauseClaudeAutoRefresh
        self.onToggleFloatingWidget = onToggleFloatingWidget
        self.onQuit = onQuit

        rootStack.arrangedSubviews.forEach {
            rootStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        rootStack.addArrangedSubview(headerView())
        rootStack.addArrangedSubview(QuotaCardView(
            model: codexCard,
            accent: .systemBlue,
            badge: RuntimeBadgeModel(
                text: isCodexRunning ? "运行中" : "未运行",
                color: isCodexRunning ? .systemGreen : .tertiaryLabelColor
            ),
            height: 204
        ))
        rootStack.addArrangedSubview(QuotaCardView(
            model: claudeCard,
            accent: .systemPurple,
            badge: RuntimeBadgeModel(
                text: claudeRefreshStatus.isClaudeDesktopRunning ? "运行中" : "未运行",
                color: claudeRefreshStatus.isClaudeDesktopRunning ? .systemGreen : .tertiaryLabelColor
            ),
            actionView: claudeControlView(status: claudeRefreshStatus, updatedAt: claudeUpdatedAt),
            height: 240
        ))
        rootStack.addArrangedSubview(globalSettingsView(isFloatingWidgetShown: isFloatingWidgetShown))
    }

    private func setupBase() {
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = DashboardColors.background.cgColor

        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 8
        rootStack.edgeInsets = NSEdgeInsets(top: 20, left: 16, bottom: 12, right: 16)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 390),
            heightAnchor.constraint(equalToConstant: 584),
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func headerView() -> NSView {
        let title = NSTextField(labelWithString: "额度看板")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textColor = DashboardColors.primaryText

        let subtitle = NSTextField(labelWithString: "本地额度监控")
        subtitle.font = .systemFont(ofSize: 11, weight: .medium)
        subtitle.textColor = DashboardColors.secondaryText

        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 358),
            container.heightAnchor.constraint(equalToConstant: 34),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func claudeControlView(status: ClaudeRefreshStatus, updatedAt: Date?) -> NSView {
        let refreshButton = NSButton(title: status.isRefreshing ? "刷新中..." : "手动刷新", target: self, action: #selector(handleRefreshClaude))
        stylePillButton(refreshButton, color: .systemPurple, filled: true)
        refreshButton.isEnabled = status.isClaudeDesktopRunning && !status.isRefreshing

        let oneHourButton = autoRefreshButton(title: "1h", duration: 60 * 60, action: #selector(handleStartClaudeAutoRefreshOneHour), status: status)
        let twoHourButton = autoRefreshButton(title: "2h", duration: 2 * 60 * 60, action: #selector(handleStartClaudeAutoRefreshTwoHours), status: status)
        let fourHourButton = autoRefreshButton(title: "4h", duration: 4 * 60 * 60, action: #selector(handleStartClaudeAutoRefreshFourHours), status: status)
        let stopButton = NSButton(title: "关闭自动", target: self, action: #selector(handlePauseClaudeAutoRefresh))
        stylePillButton(stopButton, color: .systemOrange, filled: false, minWidth: 72)
        stopButton.isEnabled = status.isAutoRefreshEnabled && !status.isRefreshing

        let buttonRow = NSStackView(views: [refreshButton, oneHourButton, twoHourButton, fourHourButton, stopButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 6
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let statusLine = NSTextField(labelWithString: refreshStatusText(status))
        statusLine.font = .systemFont(ofSize: 10)
        statusLine.textColor = status.lastError == nil ? DashboardColors.secondaryText : .systemOrange
        statusLine.lineBreakMode = .byTruncatingTail
        statusLine.translatesAutoresizingMaskIntoConstraints = false

        let updatedLine = NSTextField(labelWithString: "更新: \(relativeAge(updatedAt))")
        updatedLine.font = .systemFont(ofSize: 10)
        updatedLine.textColor = DashboardColors.tertiaryText
        updatedLine.alignment = .right
        updatedLine.lineBreakMode = .byTruncatingTail
        updatedLine.translatesAutoresizingMaskIntoConstraints = false

        let statusRow = NSStackView(views: [statusLine, updatedLine])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.distribution = .equalSpacing
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(buttonRow)
        container.addSubview(statusRow)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 330),
            container.heightAnchor.constraint(equalToConstant: 50),
            buttonRow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            buttonRow.topAnchor.constraint(equalTo: container.topAnchor),
            buttonRow.heightAnchor.constraint(equalToConstant: 28),
            buttonRow.widthAnchor.constraint(equalToConstant: 330),
            statusRow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusRow.topAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: 8),
            statusRow.widthAnchor.constraint(equalToConstant: 330),
            statusRow.heightAnchor.constraint(equalToConstant: 14),
            statusLine.widthAnchor.constraint(equalToConstant: 250),
            updatedLine.widthAnchor.constraint(equalToConstant: 72),
        ])
        return container
    }

    private func autoRefreshButton(title: String, duration: TimeInterval, action: Selector, status: ClaudeRefreshStatus) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        let selected = status.isAutoRefreshEnabled && status.selectedAutoRefreshDuration == duration
        stylePillButton(button, color: .systemPurple, filled: selected, minWidth: 38)
        button.isEnabled = status.isClaudeDesktopRunning && !status.isRefreshing
        return button
    }

    private func globalSettingsView(isFloatingWidgetShown: Bool) -> NSView {
        let label = NSTextField(labelWithString: "全局设置")
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = DashboardColors.secondaryText

        let floatingButton = NSButton(
            title: isFloatingWidgetShown ? "隐藏悬浮胶囊" : "显示悬浮胶囊",
            target: self,
            action: #selector(handleToggleFloatingWidget)
        )
        stylePillButton(floatingButton, color: .systemBlue, filled: false, minWidth: 96)

        let quitButton = NSButton(title: "退出 App", target: self, action: #selector(handleQuit))
        stylePillButton(quitButton, color: .systemRed, filled: false, minWidth: 76)

        let actions = NSStackView(views: [floatingButton, quitButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        let row = NSStackView(views: [label, actions])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .equalSpacing
        row.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.cornerCurve = .continuous
        container.layer?.backgroundColor = DashboardColors.card.cgColor
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = DashboardColors.cardBorder.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 358),
            container.heightAnchor.constraint(equalToConstant: 40),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func stylePillButton(_ button: NSButton, color: NSColor, filled: Bool, minWidth: CGFloat = 98) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 9
        button.layer?.cornerCurve = .continuous
        button.layer?.backgroundColor = filled
            ? color.cgColor
            : color.withAlphaComponent(0.18).cgColor
        button.contentTintColor = filled ? .white : color
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth).isActive = true
    }

    private func refreshStatusText(_ status: ClaudeRefreshStatus) -> String {
        if let error = status.lastError {
            return error
        }
        if status.isAutoRefreshEnabled {
            let next = status.nextRefreshAt.map(relativeFutureText(_:)) ?? "--"
            let remaining = status.autoRefreshEndsAt.map(relativeFutureText(_:)) ?? "--"
            return "自动刷新运行中 · 剩余 \(remaining) · 下次 \(next)"
        }
        return "自动刷新已暂停；手动刷新只在 Claude Desktop 运行时可用。"
    }

    private func relativeAge(_ date: Date?) -> String {
        guard let date else {
            return "--"
        }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 {
            return "\(seconds)s 前"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m 前"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h 前"
        }
        return "\(hours / 24)d 前"
    }

    private func clockText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func relativeFutureText(_ date: Date) -> String {
        let seconds = Int(date.timeIntervalSinceNow)
        if seconds <= 0 { return "现在" }
        let minutes = seconds / 60
        return minutes > 0 ? "\(minutes)m 后" : "\(seconds)s 后"
    }

    @objc
    private func handleRefreshClaude() {
        onRefreshClaude?()
    }

    @objc
    private func handleStartClaudeAutoRefreshOneHour() {
        onStartClaudeAutoRefresh?(60 * 60)
    }

    @objc
    private func handleStartClaudeAutoRefreshTwoHours() {
        onStartClaudeAutoRefresh?(2 * 60 * 60)
    }

    @objc
    private func handleStartClaudeAutoRefreshFourHours() {
        onStartClaudeAutoRefresh?(4 * 60 * 60)
    }

    @objc
    private func handlePauseClaudeAutoRefresh() {
        onPauseClaudeAutoRefresh?()
    }

    @objc
    private func handleToggleFloatingWidget() {
        onToggleFloatingWidget?()
    }

    @objc
    private func handleQuit() {
        onQuit?()
    }
}

private final class QuotaCardView: NSView {
    init(
        model: QuotaCardModel,
        accent: NSColor,
        badge: RuntimeBadgeModel? = nil,
        actionView: NSView? = nil,
        height: CGFloat = 138
    ) {
        super.init(frame: .zero)
        setup(model: model, accent: accent, badge: badge, actionView: actionView, height: height)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(
        model: QuotaCardModel,
        accent: NSColor,
        badge: RuntimeBadgeModel?,
        actionView: NSView?,
        height: CGFloat
    ) {
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = DashboardColors.card.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = DashboardColors.cardBorder.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: model.title)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = DashboardColors.primaryText
        title.lineBreakMode = .byTruncatingTail

        let trailingStack = NSStackView()
        trailingStack.orientation = .horizontal
        trailingStack.alignment = .centerY
        trailingStack.spacing = 8
        trailingStack.translatesAutoresizingMaskIntoConstraints = false

        if let badge {
            trailingStack.addArrangedSubview(StatusDotView(color: badge.color))

            let badgeLabel = NSTextField(labelWithString: badge.text)
            badgeLabel.font = .systemFont(ofSize: 11, weight: .medium)
            badgeLabel.textColor = DashboardColors.secondaryText
            trailingStack.addArrangedSubview(badgeLabel)
        }

        let subtitle = NSTextField(labelWithString: model.subtitle)
        subtitle.font = .systemFont(ofSize: 11, weight: .medium)
        subtitle.textColor = DashboardColors.tertiaryText
        subtitle.alignment = .right
        subtitle.lineBreakMode = .byTruncatingTail
        trailingStack.addArrangedSubview(subtitle)

        let header = NSStackView(views: [title, trailingStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.distribution = .equalSpacing
        header.translatesAutoresizingMaskIntoConstraints = false

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        model.rows.forEach {
            rows.addArrangedSubview(QuotaPanelRowView(row: $0, accent: accent))
        }

        let stack = NSStackView(views: [header, rows])
        if let actionView {
            stack.addArrangedSubview(actionView)
        }
        if !model.footer.isEmpty {
            let footer = NSTextField(labelWithString: model.footer)
            footer.font = .systemFont(ofSize: 10)
            footer.textColor = DashboardColors.tertiaryText
            footer.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(footer)
        }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 11, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 358),
            heightAnchor.constraint(equalToConstant: height),
            header.heightAnchor.constraint(equalToConstant: 28),
            title.widthAnchor.constraint(greaterThanOrEqualToConstant: 86),
            trailingStack.heightAnchor.constraint(equalToConstant: 22),
            subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

private final class StatusDotView: NSView {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = color.cgColor
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 8),
            heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class QuotaPanelView: NSView {
    private let title: String
    private let rows: [QuotaPanelRow]
    private let footer: String

    init(title: String, rows: [QuotaPanelRow], footer: String) {
        self.title = title
        self.rows = rows
        self.footer = footer
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 0))
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.92).cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        stack.addArrangedSubview(titleLabel)

        rows.forEach { row in
            let view = QuotaPanelRowView(row: row)
            stack.addArrangedSubview(view)
        }

        let footerLabel = NSTextField(labelWithString: footer)
        footerLabel.font = .systemFont(ofSize: 10)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(footerLabel)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 300),
        ])
    }
}

private final class QuotaPanelRowView: NSView {
    private let row: QuotaPanelRow
    private let accent: NSColor

    init(row: QuotaPanelRow, accent: NSColor = .systemBlue) {
        self.row = row
        self.accent = accent
        super.init(frame: .zero)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: row.title)
        titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        titleLabel.textColor = DashboardColors.tertiaryText

        let primaryLabel = NSTextField(labelWithString: row.primaryText)
        primaryLabel.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        primaryLabel.textColor = DashboardColors.primaryText
        primaryLabel.lineBreakMode = .byTruncatingTail

        let resetLabel = NSTextField(labelWithString: row.resetText)
        resetLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        resetLabel.textColor = DashboardColors.secondaryText
        resetLabel.alignment = .right
        resetLabel.lineBreakMode = .byTruncatingTail

        let topRow = NSStackView(views: [titleLabel])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 10
        topRow.translatesAutoresizingMaskIntoConstraints = false

        let metricRow = NSStackView(views: [primaryLabel, resetLabel])
        metricRow.orientation = .horizontal
        metricRow.alignment = .lastBaseline
        metricRow.spacing = 10
        metricRow.distribution = .equalSpacing
        metricRow.translatesAutoresizingMaskIntoConstraints = false

        let bar = QuotaProgressBarView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.render(usedPercent: row.usedPercent, accent: accent)

        let stack = NSStackView(views: [topRow, metricRow, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            resetLabel.widthAnchor.constraint(equalToConstant: 128),
            topRow.widthAnchor.constraint(equalToConstant: 330),
            metricRow.widthAnchor.constraint(equalToConstant: 330),
            bar.heightAnchor.constraint(equalToConstant: 6),
            bar.widthAnchor.constraint(equalToConstant: 330),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 52),
        ])
    }
}

private final class QuotaProgressBarView: NSView {
    private var remainingPercent: Double?
    private var accent = NSColor.systemBlue

    func render(usedPercent: Double?, accent: NSColor = .systemBlue) {
        self.remainingPercent = usedPercent
        self.accent = accent
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let trackPath = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
        DashboardColors.track.setFill()
        trackPath.fill()

        guard let remainingPercent else {
            return
        }

        let clamped = min(max(remainingPercent, 0), 100)
        let width = bounds.width * CGFloat(clamped / 100)
        guard width > 0 else {
            return
        }

        let fillRect = NSRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 3, yRadius: 3)
        color(for: clamped).setFill()
        fillPath.fill()
    }

    private func color(for remainingPercent: Double) -> NSColor {
        switch remainingPercent {
        case 60...:
            return accent
        case 30..<60:
            return .systemOrange
        default:
            return .systemRed
        }
    }
}
