import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let codexBundleIdentifier = "com.openai.codex"
    private let claudeDesktopBundleIdentifier = "com.anthropic.claudefordesktop"
    private let snapshotService = QuotaSnapshotService()
    private let claudeRateLimitProvider = ClaudeRateLimitProvider()
    private let stateStore = WidgetStateStore()
    private let touchBarController = TouchBarController()
    private let statusBarController = StatusBarController()
    private let refreshQueue = DispatchQueue(label: "com.wendy.codex-quota-widget.refresh")

    private lazy var windowController = WidgetWindowController(stateStore: stateStore)

    private var appObservers: [NSObjectProtocol] = []
    private var refreshTimer: Timer?
    private var codexRunning = false
    private var fastRefreshUntil: Date?
    private var lastSnapshot: QuotaSnapshot?
    private var lastClaudeRateLimit: ClaudeRateLimitSnapshot?
    private var refreshInFlight = false
    private var claudeAutoRefreshEndsAt: Date?
    private var claudeSelectedAutoRefreshDuration: TimeInterval?
    private var claudeNextRefreshAt: Date?
    private var claudeRefreshInFlight = false
    private var claudeLastError: String?
    private var claudeConsecutiveFailureCount = 0
    private var language: WidgetLanguage = .english
    private var showFloatingWidget = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let initialState = stateStore.load()
        language = initialState.language ?? .english
        showFloatingWidget = initialState.showFloatingWidget ?? false
        touchBarController.setLanguage(language)
        windowController.onRequestRefresh = { [weak self] in
            self?.refreshState(reason: "manual-refresh", forceSnapshotReload: true)
        }
        windowController.onOpenDashboard = { [weak self] in
            self?.statusBarController.toggleDashboardPanel()
        }
        statusBarController.onRequestRefresh = { [weak self] in
            self?.refreshState(reason: "status-bar-refresh", forceSnapshotReload: true, claudeRefreshMode: .manual)
        }
        statusBarController.onToggleFloatingWidget = { [weak self] in
            self?.toggleFloatingWidget() ?? false
        }
        statusBarController.onStartClaudeAutoRefresh = { [weak self] duration in
            self?.startClaudeAutoRefresh(duration: duration) ?? ClaudeRefreshStatus.inactive
        }
        statusBarController.onPauseClaudeAutoRefresh = { [weak self] in
            self?.pauseClaudeAutoRefresh() ?? ClaudeRefreshStatus.inactive
        }
        statusBarController.onQuit = {
            NSApp.terminate(nil)
        }
        windowController.onShowTouchBar = { [weak self] in
            self?.touchBarController.showAgain()
        }
        windowController.onOpenTouchBarSettings = { [weak self] in
            self?.openTouchBarSettings()
        }
        windowController.currentLanguage = { [weak self] in
            self?.language ?? .english
        }
        windowController.onToggleLanguage = { [weak self] in
            self?.toggleLanguage() ?? .english
        }
        startMonitoringCodex()
        refreshState(reason: "launch")
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        touchBarController.codexDidExit()
        snapshotService.stop()
        let center = NSWorkspace.shared.notificationCenter
        appObservers.forEach(center.removeObserver(_:))
    }

    private func startMonitoringCodex() {
        let center = NSWorkspace.shared.notificationCenter

        let launchObserver = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleWorkspaceEvent(notification, launched: true)
        }

        let terminateObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleWorkspaceEvent(notification, launched: false)
        }

        appObservers = [launchObserver, terminateObserver]
    }

    private func handleWorkspaceEvent(_ notification: Notification, launched: Bool) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            let bundleIdentifier = app.bundleIdentifier,
            bundleIdentifier == codexBundleIdentifier || bundleIdentifier == claudeDesktopBundleIdentifier
        else {
            return
        }

        if launched, bundleIdentifier == codexBundleIdentifier {
            fastRefreshUntil = Date().addingTimeInterval(120)
        }
        let appName = bundleIdentifier == codexBundleIdentifier ? "codex" : "claude"
        refreshState(reason: "\(appName)-\(launched ? "launch" : "exit")")
    }

    private func scheduleRefreshTimer(cadence: RefreshCadence) {
        if refreshTimer?.timeInterval == cadence.interval {
            return
        }

        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: cadence.interval, repeats: true) { [weak self] _ in
            self?.refreshState(reason: "refresh")
        }
        if let refreshTimer {
            RunLoop.main.add(refreshTimer, forMode: .common)
        }
    }

    private func refreshState(
        reason: String,
        forceSnapshotReload: Bool = false,
        claudeRefreshMode: ClaudeRefreshMode = .none
    ) {
        let running = isCodexRunning()

        if running != codexRunning {
            codexRunning = running
            if running {
                fastRefreshUntil = Date().addingTimeInterval(120)
            }
        }

        if !running {
            touchBarController.codexDidExit()
            statusBarController.render(
                snapshot: nil,
                claudeRateLimit: lastClaudeRateLimit,
                claudeRefreshStatus: currentClaudeRefreshStatus(),
                isCodexRunning: false,
                isFloatingWidgetShown: showFloatingWidget
            )
            snapshotService.stop()
            lastSnapshot = nil
            renderFloatingWidget()
            refreshSnapshot(forceReload: forceSnapshotReload, claudeRefreshMode: resolvedClaudeRefreshMode(claudeRefreshMode))
            scheduleRefreshTimer(cadence: .hidden)
            return
        }

        if reason == "codex-launch" {
            touchBarController.codexDidLaunch()
        }

        renderFloatingWidget()
        touchBarController.show(snapshot: lastSnapshot)
        statusBarController.render(
            snapshot: lastSnapshot,
            claudeRateLimit: lastClaudeRateLimit,
            claudeRefreshStatus: currentClaudeRefreshStatus(),
            isCodexRunning: true,
            isFloatingWidgetShown: showFloatingWidget
        )
        refreshSnapshot(forceReload: forceSnapshotReload, claudeRefreshMode: resolvedClaudeRefreshMode(claudeRefreshMode))
        scheduleRefreshTimer(cadence: currentCadence())

        if reason == "refresh", let fastRefreshUntil, fastRefreshUntil < Date() {
            scheduleRefreshTimer(cadence: .normal)
        }
    }

    private func currentCadence() -> RefreshCadence {
        if let fastRefreshUntil, fastRefreshUntil > Date() {
            return .fast
        }
        return .normal
    }

    private func isCodexRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: codexBundleIdentifier).isEmpty
    }

    private func toggleLanguage() -> WidgetLanguage {
        language = language.toggled
        stateStore.update { state in
            state.language = language
        }
        touchBarController.setLanguage(language)
        touchBarController.showAgain()
        return language
    }

    private func toggleFloatingWidget() -> Bool {
        showFloatingWidget.toggle()
        stateStore.update { state in
            state.showFloatingWidget = showFloatingWidget
        }
        renderFloatingWidget()
        return showFloatingWidget
    }

    private func startClaudeAutoRefresh(duration: TimeInterval) -> ClaudeRefreshStatus {
        claudeSelectedAutoRefreshDuration = duration
        claudeAutoRefreshEndsAt = Date().addingTimeInterval(duration)
        claudeNextRefreshAt = Date()
        claudeLastError = nil
        claudeConsecutiveFailureCount = 0
        refreshState(reason: "claude-auto-start", forceSnapshotReload: false, claudeRefreshMode: .manual)
        return currentClaudeRefreshStatus()
    }

    private func pauseClaudeAutoRefresh() -> ClaudeRefreshStatus {
        claudeAutoRefreshEndsAt = nil
        claudeSelectedAutoRefreshDuration = nil
        claudeNextRefreshAt = nil
        claudeLastError = nil
        refreshState(reason: "claude-auto-pause")
        return currentClaudeRefreshStatus()
    }

    private func renderFloatingWidget() {
        if showFloatingWidget {
            windowController.show(state: FloatingQuotaState(
                codexSnapshot: lastSnapshot,
                claudeSnapshot: lastClaudeRateLimit,
                isCodexRunning: codexRunning,
                isClaudeDesktopRunning: isClaudeDesktopRunning()
            ))
        } else {
            windowController.hide()
        }
    }

    private func openTouchBarSettings() {
        let settingsURLs = [
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.keyboard",
        ]

        for rawURL in settingsURLs {
            guard let url = URL(string: rawURL) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func refreshSnapshot(forceReload: Bool, claudeRefreshMode: ClaudeRefreshMode) {
        if refreshInFlight {
            return
        }

        let effectiveClaudeRefreshMode = allowedClaudeRefreshMode(claudeRefreshMode)

        refreshInFlight = true
        if effectiveClaudeRefreshMode.shouldRequestNetwork {
            claudeRefreshInFlight = true
        }
        statusBarController.render(
            snapshot: codexRunning ? lastSnapshot : nil,
            claudeRateLimit: lastClaudeRateLimit,
            claudeRefreshStatus: currentClaudeRefreshStatus(),
            isCodexRunning: codexRunning,
            isFloatingWidgetShown: showFloatingWidget
        )

        refreshQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.snapshotService.latestSnapshot(forceReload: forceReload)
            let claudeResult: Result<ClaudeRateLimitSnapshot?, ClaudeRateLimitError> = {
                guard effectiveClaudeRefreshMode.shouldRequestNetwork else {
                    return .success(self.claudeRateLimitProvider.latestSnapshot())
                }
                return self.claudeRateLimitProvider.refreshFromOAuthUsage().map(Optional.some)
            }()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshInFlight = false
                self.claudeRefreshInFlight = false

                let claudeRateLimit: ClaudeRateLimitSnapshot?
                switch claudeResult {
                case .success(let snapshot):
                    claudeRateLimit = snapshot
                    if effectiveClaudeRefreshMode.shouldRequestNetwork {
                        self.recordClaudeRefreshSuccess()
                    }
                case .failure(let error):
                    claudeRateLimit = self.claudeRateLimitProvider.latestSnapshot()
                    self.recordClaudeRefreshFailure(error)
                }

                self.lastClaudeRateLimit = claudeRateLimit ?? self.lastClaudeRateLimit
                if self.codexRunning {
                    self.lastSnapshot = snapshot
                    self.touchBarController.show(snapshot: snapshot)
                }
                self.renderFloatingWidget()
                self.statusBarController.render(
                    snapshot: self.codexRunning ? snapshot : nil,
                    claudeRateLimit: self.lastClaudeRateLimit,
                    claudeRefreshStatus: self.currentClaudeRefreshStatus(),
                    isCodexRunning: self.codexRunning,
                    isFloatingWidgetShown: self.showFloatingWidget
                )
            }
        }
    }

    private func resolvedClaudeRefreshMode(_ requested: ClaudeRefreshMode) -> ClaudeRefreshMode {
        if requested.shouldRequestNetwork {
            return requested
        }

        guard
            let endsAt = claudeAutoRefreshEndsAt,
            endsAt > Date()
        else {
            if claudeAutoRefreshEndsAt != nil {
                claudeAutoRefreshEndsAt = nil
                claudeSelectedAutoRefreshDuration = nil
                claudeNextRefreshAt = nil
            }
            return .none
        }

        if let nextRefreshAt = claudeNextRefreshAt, nextRefreshAt <= Date() {
            return .automatic
        }
        return .none
    }

    private func allowedClaudeRefreshMode(_ requested: ClaudeRefreshMode) -> ClaudeRefreshMode {
        guard requested.shouldRequestNetwork else {
            return .none
        }

        guard isClaudeDesktopRunning() else {
            claudeLastError = "Claude Desktop 未运行，已跳过请求"
            claudeRefreshInFlight = false
            if let endsAt = claudeAutoRefreshEndsAt, endsAt > Date() {
                claudeNextRefreshAt = min(Date().addingTimeInterval(5 * 60), endsAt)
            }
            return .none
        }

        return requested
    }

    private func recordClaudeRefreshSuccess() {
        claudeLastError = nil
        claudeConsecutiveFailureCount = 0
        if let endsAt = claudeAutoRefreshEndsAt, endsAt > Date() {
            claudeNextRefreshAt = min(Date().addingTimeInterval(5 * 60), endsAt)
        }
    }

    private func recordClaudeRefreshFailure(_ error: ClaudeRateLimitError) {
        claudeLastError = error.description
        claudeConsecutiveFailureCount += 1

        switch error {
        case .unauthorized:
            claudeAutoRefreshEndsAt = nil
            claudeSelectedAutoRefreshDuration = nil
            claudeNextRefreshAt = nil
        case .rateLimited:
            if claudeConsecutiveFailureCount >= 3 {
                claudeAutoRefreshEndsAt = nil
                claudeSelectedAutoRefreshDuration = nil
                claudeNextRefreshAt = nil
            } else if let endsAt = claudeAutoRefreshEndsAt, endsAt > Date() {
                claudeNextRefreshAt = min(Date().addingTimeInterval(30 * 60), endsAt)
            }
        default:
            if claudeConsecutiveFailureCount >= 3 {
                claudeAutoRefreshEndsAt = nil
                claudeSelectedAutoRefreshDuration = nil
                claudeNextRefreshAt = nil
            } else if let endsAt = claudeAutoRefreshEndsAt, endsAt > Date() {
                claudeNextRefreshAt = min(Date().addingTimeInterval(20 * 60), endsAt)
            }
        }
    }

    private func currentClaudeRefreshStatus() -> ClaudeRefreshStatus {
        let now = Date()
        let isEnabled = claudeAutoRefreshEndsAt.map { $0 > now } ?? false
        return ClaudeRefreshStatus(
            isClaudeDesktopRunning: isClaudeDesktopRunning(),
            isAutoRefreshEnabled: isEnabled,
            selectedAutoRefreshDuration: isEnabled ? claudeSelectedAutoRefreshDuration : nil,
            autoRefreshEndsAt: isEnabled ? claudeAutoRefreshEndsAt : nil,
            nextRefreshAt: isEnabled ? claudeNextRefreshAt : nil,
            isRefreshing: claudeRefreshInFlight,
            lastError: claudeLastError,
            consecutiveFailureCount: claudeConsecutiveFailureCount
        )
    }

    private func isClaudeDesktopRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: claudeDesktopBundleIdentifier).isEmpty
    }
}

private enum ClaudeRefreshMode {
    case none
    case manual
    case automatic

    var shouldRequestNetwork: Bool {
        switch self {
        case .none:
            return false
        case .manual, .automatic:
            return true
        }
    }
}

private extension ClaudeRefreshStatus {
    static let inactive = ClaudeRefreshStatus(
        isClaudeDesktopRunning: false,
        isAutoRefreshEnabled: false,
        selectedAutoRefreshDuration: nil,
        autoRefreshEndsAt: nil,
        nextRefreshAt: nil,
        isRefreshing: false,
        lastError: nil,
        consecutiveFailureCount: 0
    )
}
