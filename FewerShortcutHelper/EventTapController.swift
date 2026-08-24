import AppKit
import ApplicationServices
import Carbon
import FewerCore

struct InputEventRuntimeStatus: Sendable {
    var isEventTapActive = false
    var isScrollEngineActive = false
    var isGestureEngineActive = false
    var isKeycastActive = false
    var detectedScrollDevice: ScrollInputDevice?
    var emergencyDisabled = false
    var lastError: String?
}

final class InputEventCoordinator: NSObject, @unchecked Sendable {
    private struct GestureSession {
        let identifier: UUID
        let button: Int64
        let initialLocation: CGPoint
        let initialPoint: GesturePoint
        let bundleIdentifier: String?
        let startedAt: Date
        var recognizer: MouseGestureRecognizer
        var hasExceededClickTolerance: Bool
    }

    private let stateLock = NSLock()
    private var eventTap: CFMachPort?
    private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private var startRequested = false
    private var circuitBreaker = EventTapCircuitBreaker()
    private var runtimeStatus = InputEventRuntimeStatus()
    private var settingsSnapshot = InputEnhancementSettings.default
    private var gestureSession: GestureSession?
    private var lastScrollBundleIdentifier: String?
    private var temporaryAllKeys = false
    private var keycastSuppressed = false
    private var inputSuppressed = false
    private var keycastSessionEnabled = true
    private var sessionLocked = false
    private var finderShortcutEnabled = false
    private var inputModuleEnabled = true
    private var cutTransactionPasteboardChangeCount: Int?
    private var frontmostBundleIdentifier: String?
    private var mainDisplayHeight: CGFloat = 0
    private var pendingGestureHUDUpdate: (point: CGPoint, directions: [MouseGestureDirection])?
    private var gestureHUDUpdateToken: UUID?

    private let bridge = PasteboardCutBridge()
    private let finderSettingsStore = try? SharedSettingsStore()
    private let inputSettingsStore = InputEnhancementStore()
    @MainActor private lazy var scrollEngine: SmoothScrollEngine = {
        let engine = SmoothScrollEngine()
        engine.activityChanged = { [weak self] active in
            self?.updateRuntimeStatus { $0.isScrollEngineActive = active }
        }
        return engine
    }()
    @MainActor private lazy var gestureHUD = GestureHUDController()
    @MainActor private lazy var keycastPanel: KeycastPanelController = {
        let panel = KeycastPanelController()
        panel.visibilityChanged = { [weak self] visible in
            self?.updateRuntimeStatus { $0.isKeycastActive = visible }
        }
        panel.customPositionChanged = { [weak self] position in
            self?.saveKeycastCustomPosition(position)
        }
        return panel
    }()

    override init() {
        super.init()
        reloadSettings()
        reloadModulePreferences()
        reloadFinderSettings()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSettingsDidChange),
            name: AppGroupConstants.inputEnhancementSettingsDidChangeNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(cutTransactionDidChange),
            name: AppGroupConstants.cutTransactionDidChangeNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(featureSettingsDidChange),
            name: AppGroupConstants.featureSettingsDidChangeNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(modulePreferencesDidChange),
            name: AppGroupConstants.modulePreferencesDidChangeNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputCommandReceived(_:)),
            name: AppGroupConstants.inputEnhancementControlNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationContextDidChange),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(sessionDidLock),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(sessionDidUnlock),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        refreshFrontmostApplication()
        refreshDisplayLayout()
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    func start() {
        guard AXIsProcessTrusted() else { return }
        stateLock.lock()
        guard !startRequested, eventTap == nil else {
            stateLock.unlock()
            return
        }
        startRequested = true
        stateLock.unlock()
        let thread = Thread { [weak self] in self?.runEventTapLoop() }
        thread.name = "com.number47.fewer.input-event-tap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
    }

    func stop() {
        stateLock.lock()
        let runLoop = tapRunLoop
        startRequested = false
        stateLock.unlock()
        if let runLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
                self?.clearTransientState(replayGesture: true)
                CFRunLoopStop(runLoop)
            }
            CFRunLoopWakeUp(runLoop)
        } else {
            clearTransientState(replayGesture: true)
        }
    }

    func status() -> InputEventRuntimeStatus {
        stateLock.lock()
        defer { stateLock.unlock() }
        return runtimeStatus
    }

    func refreshCachedState() {
        let pasteboardChangeCount = bridge.validTransactionPasteboardChangeCount()
        stateLock.lock()
        cutTransactionPasteboardChangeCount = pasteboardChangeCount
        stateLock.unlock()
        refreshFrontmostApplication()
    }

    fileprivate func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if SyntheticInputEventFilter.shouldIgnore(
            userData: event.getIntegerValueField(.eventSourceUserData),
            marker: syntheticInputEventMarker
        ) {
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            handleTapDisabled(type: type)
            return Unmanaged.passUnretained(event)
        }

        let settings = currentSettings()
        let bundleIdentifier = cachedFrontmostBundleIdentifier()
        if isEmergencyShortcut(type: type, event: event) {
            emergencyDisable()
            return nil
        }
        if isInputModuleEnabled() {
            if handleKeycastToggle(type: type, event: event, settings: settings) {
                return nil
            }
            observeKeycast(type: type, event: event, settings: settings, bundleIdentifier: bundleIdentifier)
            if let consume = handleGesture(
                type: type,
                event: event,
                settings: settings,
                bundleIdentifier: bundleIdentifier
            ) {
                return consume ? nil : Unmanaged.passUnretained(event)
            }
            if type == .scrollWheel,
               handleScroll(event: event, settings: settings, bundleIdentifier: bundleIdentifier) {
                return nil
            }
        }
        return type == .keyDown ? handleFinderShortcut(event: event) : Unmanaged.passUnretained(event)
    }

    private func runEventTapLoop() {
        autoreleasepool {
            let pointer = Unmanaged.passUnretained(self).toOpaque()
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask(),
                callback: inputEventTapCallback,
                userInfo: pointer
            ) else {
                updateRuntimeStatus {
                    $0.isEventTapActive = false
                    $0.lastError = "无法创建输入事件监听，请检查辅助功能和输入监控权限。"
                }
                stateLock.lock()
                startRequested = false
                stateLock.unlock()
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            let runLoop = CFRunLoopGetCurrent()
            stateLock.lock()
            eventTap = tap
            tapRunLoop = runLoop
            runtimeStatus.isEventTapActive = true
            runtimeStatus.lastError = nil
            stateLock.unlock()
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            stateLock.lock()
            eventTap = nil
            tapRunLoop = nil
            runtimeStatus.isEventTapActive = false
            startRequested = false
            stateLock.unlock()
        }
    }

    private func eventMask() -> CGEventMask {
        let types: [CGEventType] = [
            .keyDown, .flagsChanged, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel,
        ]
        return types.reduce(0) { $0 | CGEventMask(1 << $1.rawValue) }
    }

    private func handleTapDisabled(type: CGEventType) {
        clearTransientState(replayGesture: true)
        stateLock.lock()
        let shouldFuse = circuitBreaker.recordFailure()
        let tap = eventTap
        let runLoop = tapRunLoop
        runtimeStatus.isEventTapActive = !shouldFuse
        runtimeStatus.lastError = shouldFuse
            ? "输入监听连续失败，已熔断并保留系统原生输入。"
            : (type == .tapDisabledByTimeout ? "输入监听超时，正在恢复。" : "输入监听被系统停用，正在恢复。")
        stateLock.unlock()
        if !shouldFuse, let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            updateRuntimeStatus { $0.isEventTapActive = true }
        } else if shouldFuse {
            scheduleCircuitBreakerRecovery(runLoop: runLoop)
        }
    }

    private func handleScroll(
        event: CGEvent,
        settings: InputEnhancementSettings,
        bundleIdentifier: String?
    ) -> Bool {
        stateLock.lock()
        let shouldBypass = inputSuppressed
        stateLock.unlock()
        guard !shouldBypass, bundleIdentifier != "com.number47.fewer" else {
            Task { @MainActor [weak self] in self?.scrollEngine.cancel() }
            return false
        }
        if lastScrollBundleIdentifier != bundleIdentifier {
            lastScrollBundleIdentifier = bundleIdentifier
            Task { @MainActor [weak self] in self?.scrollEngine.cancel() }
        }
        let snapshot = ScrollEventSnapshot(
            isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
            scrollPhase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
            momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase),
            verticalDelta: scrollDelta(event, axis: 1),
            horizontalDelta: scrollDelta(event, axis: 2)
        )
        let resolved = settings.resolvedScrollSettings(for: bundleIdentifier)
        let result = ScrollEventProcessor.process(snapshot, settings: resolved)
        updateRuntimeStatus { $0.detectedScrollDevice = result.device }
        guard let resolved, result.device == ScrollInputDevice.mouse else { return false }
        let changed = result.shouldConsumeOriginal
            || result.verticalDelta != snapshot.verticalDelta
            || result.horizontalDelta != snapshot.horizontalDelta
        guard changed else { return false }
        let displayID = displayID(at: event.location)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.scrollEngine.enqueue(
                vertical: result.verticalDelta,
                horizontal: result.horizontalDelta,
                settings: resolved,
                displayID: displayID
            )
            self.updateRuntimeStatus { $0.isScrollEngineActive = self.scrollEngine.isActive }
        }
        return true
    }

    private func scrollDelta(_ event: CGEvent, axis: Int) -> Double {
        let fixedField: CGEventField = axis == 1 ? .scrollWheelEventFixedPtDeltaAxis1 : .scrollWheelEventFixedPtDeltaAxis2
        let pointField: CGEventField = axis == 1 ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2
        let lineField: CGEventField = axis == 1 ? .scrollWheelEventDeltaAxis1 : .scrollWheelEventDeltaAxis2
        return ScrollDeltaReader.pixelDelta(
            fixedPtDelta: event.getDoubleValueField(fixedField),
            pointDelta: Int(event.getIntegerValueField(pointField)),
            lineDelta: Int(event.getIntegerValueField(lineField))
        )
    }

    private func displayID(at point: CGPoint) -> CGDirectDisplayID? {
        var display = CGDirectDisplayID()
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0 else { return nil }
        return display
    }

    private func handleGesture(
        type: CGEventType,
        event: CGEvent,
        settings: InputEnhancementSettings,
        bundleIdentifier: String?
    ) -> Bool? {
        if type == .keyDown,
           event.getIntegerValueField(.keyboardEventKeycode) == 53,
           gestureSession != nil {
            cancelGesture(replayClick: true)
            return true
        }
        if let session = gestureSession,
           let cancellationReason = MouseGestureSessionPolicy.cancellationReason(
               startedAt: session.startedAt,
               now: Date(),
               startedBundleIdentifier: session.bundleIdentifier,
               currentBundleIdentifier: bundleIdentifier
           ) {
            cancelGesture(replayClick: cancellationReason == .timedOut)
        }
        if let activeSession = gestureSession, isMouseDown(type) {
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            return button == activeSession.button ? true : nil
        }
        if isMouseDown(type) {
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            let hasRule = settings.gestureRules.contains {
                $0.isEnabled && $0.triggerButton == button
                    && ($0.bundleIdentifier == nil || $0.bundleIdentifier == bundleIdentifier)
            }
            stateLock.lock()
            let shouldBypass = inputSuppressed
            stateLock.unlock()
            guard hasRule,
                  !settings.emergencyDisabled,
                  !shouldBypass,
                  bundleIdentifier != "com.number47.fewer",
                  !settings.gestureExcludedBundleIdentifiers.contains(bundleIdentifier ?? "")
            else { return nil }
            cancelPendingGestureHUDUpdate()
            let point = appKitPoint(from: event.location)
            var recognizer = MouseGestureRecognizer()
            recognizer.begin(at: GesturePoint(x: point.x, y: point.y))
            let identifier = UUID()
            gestureSession = GestureSession(
                identifier: identifier,
                button: button,
                initialLocation: event.location,
                initialPoint: GesturePoint(x: point.x, y: point.y),
                bundleIdentifier: bundleIdentifier,
                startedAt: Date(),
                recognizer: recognizer,
                hasExceededClickTolerance: false
            )
            scheduleGestureTimeout(identifier: identifier)
            updateRuntimeStatus { $0.isGestureEngineActive = true }
            let hudPoint = event.location
            Task { @MainActor [weak self] in self?.gestureHUD.begin(at: hudPoint) }
            return true
        }
        guard var session = gestureSession else { return nil }
        if isMouseDragged(type) {
            guard event.getIntegerValueField(.mouseEventButtonNumber) == session.button else { return nil }
            let point = appKitPoint(from: event.location)
            let currentPoint = GesturePoint(x: point.x, y: point.y)
            session.hasExceededClickTolerance = session.hasExceededClickTolerance
                || MouseGestureClickTolerance.isExceeded(from: session.initialPoint, to: currentPoint)
            _ = session.recognizer.append(currentPoint)
            gestureSession = session
            queueGestureHUDUpdate(point: event.location, directions: session.recognizer.directions)
            return true
        }
        if isMouseUp(type), event.getIntegerValueField(.mouseEventButtonNumber) == session.button {
            let rule = session.recognizer.matchingRule(
                in: settings.gestureRules,
                triggerButton: session.button,
                bundleIdentifier: bundleIdentifier
            )
            let completion = MouseGestureCompletionPolicy.completion(
                rule: rule,
                hasExceededClickTolerance: session.hasExceededClickTolerance
            )
            gestureSession = nil
            cancelPendingGestureHUDUpdate()
            updateRuntimeStatus { $0.isGestureEngineActive = false }
            Task { @MainActor [weak self] in self?.gestureHUD.hide() }
            switch completion {
            case let .executeAction(action):
                InputActionExecutor.execute(action)
            case .replayClick:
                replayClick(for: session)
            case .none:
                break
            }
            return true
        }
        return nil
    }

    private func observeKeycast(
        type: CGEventType,
        event: CGEvent,
        settings: InputEnhancementSettings,
        bundleIdentifier: String?
    ) {
        stateLock.lock()
        let isSuppressed = keycastSuppressed
        let isSessionEnabled = keycastSessionEnabled
        let isLocked = sessionLocked
        stateLock.unlock()
        let excluded = settings.keycast.excludedBundleIdentifiers.contains(bundleIdentifier ?? "")
        let secure = IsSecureEventInputEnabled()
        guard settings.keycast.isEnabled,
              !settings.emergencyDisabled,
              !isSuppressed,
              isSessionEnabled,
              !isLocked,
              !secure,
              !excluded
        else {
            if secure || excluded || isLocked {
                Task { @MainActor [weak self] in self?.keycastPanel.clear() }
            }
            return
        }
        if type == .keyDown {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let modifiers = shortcutModifiers(from: event.flags)
            guard KeycastEventFilter.shouldDisplay(
                keyCode: keyCode,
                modifiers: modifiers,
                mode: settings.keycast.mode,
                temporaryAllKeys: temporaryAllKeysSnapshot(),
                secureInputEnabled: secure,
                isExcludedApplication: excluded
            ) else {
                return
            }
            let keyLabel = NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.uppercased()
            let text = KeycastEventFilter.displayString(
                keyCode: keyCode,
                modifiers: modifiers,
                keyLabel: keyLabel
            )
            updateRuntimeStatus { $0.isKeycastActive = true }
            Task { @MainActor [weak self] in self?.keycastPanel.show(text: text, settings: settings.keycast) }
        } else if settings.keycast.showsMouseClicks, isMouseDown(type) {
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            let text = switch button {
            case 0: "左键"
            case 1: "右键"
            case 2: "中键"
            default: "鼠标键 \(button + 1)"
            }
            Task { @MainActor [weak self] in self?.keycastPanel.show(text: text, settings: settings.keycast) }
        }
    }

    private func handleFinderShortcut(event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return Unmanaged.passUnretained(event)
        }
        let key: ShortcutKey = switch event.getIntegerValueField(.keyboardEventKeycode) {
        case 7: .x
        case 9: .v
        default: .other
        }
        guard key != .other else { return Unmanaged.passUnretained(event) }
        let frontmostBundleID = cachedFrontmostBundleIdentifier()
        let modifiers = shortcutModifiers(from: event.flags)
        stateLock.lock()
        let isEnabled = finderShortcutEnabled
        let expectedPasteboardChangeCount = cutTransactionPasteboardChangeCount
        stateLock.unlock()
        guard frontmostBundleID == "com.apple.finder",
              isEnabled,
              modifiers == .command
        else { return Unmanaged.passUnretained(event) }
        let decision = FinderShortcutRouter.decision(
            frontmostBundleID: frontmostBundleID,
            isEnabled: isEnabled,
            isAccessibilityTrusted: AXIsProcessTrusted(),
            key: key,
            modifiers: modifiers,
            hasValidCutTransaction: key == .v
                && expectedPasteboardChangeCount == NSPasteboard.general.changeCount
        )
        switch decision {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .captureCut:
            InputActionExecutor.postShortcut(keyCode: 8, flags: .maskCommand)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, bridge] in
                bridge.captureFinderCopy()
                self?.refreshCachedState()
            }
            return nil
        case .performFinderMovePaste:
            InputActionExecutor.postShortcut(keyCode: 9, flags: [.maskCommand, .maskAlternate])
            return nil
        }
    }

    private func isEmergencyShortcut(type: CGEventType, event: CGEvent) -> Bool {
        type == .keyDown
            && event.getIntegerValueField(.keyboardEventKeycode) == 53
            && event.flags.contains([.maskControl, .maskAlternate, .maskCommand])
    }

    private func handleKeycastToggle(
        type: CGEventType,
        event: CGEvent,
        settings: InputEnhancementSettings
    ) -> Bool {
        guard type == .keyDown,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
              settings.keycast.isEnabled,
              let shortcut = settings.keycast.toggleShortcut,
              InputShortcutSafety.isAllowedGlobalToggle(shortcut),
              UInt16(event.getIntegerValueField(.keyboardEventKeycode)) == shortcut.keyCode,
              shortcutModifiers(from: event.flags) == shortcut.modifiers
        else { return false }
        stateLock.lock()
        keycastSessionEnabled.toggle()
        let enabled = keycastSessionEnabled
        stateLock.unlock()
        if !enabled { Task { @MainActor [weak self] in self?.keycastPanel.clear() } }
        return true
    }

    private func emergencyDisable() {
        var settings = currentSettings()
        settings.emergencyDisabled = true
        setSettings(settings)
        try? inputSettingsStore.save(settings)
        clearTransientState(replayGesture: true)
        updateRuntimeStatus { $0.emergencyDisabled = true }
        DistributedNotificationCenter.default().postNotificationName(
            AppGroupConstants.inputEnhancementSettingsDidChangeNotification,
            object: nil,
            userInfo: ["reason": "emergency"],
            deliverImmediately: true
        )
    }

    private func clearTransientState(replayGesture: Bool) {
        if gestureSession != nil { cancelGesture(replayClick: replayGesture) }
        cancelPendingGestureHUDUpdate()
        lastScrollBundleIdentifier = nil
        stateLock.lock()
        temporaryAllKeys = false
        stateLock.unlock()
        Task { @MainActor [weak self] in
            self?.scrollEngine.cancel()
            self?.gestureHUD.hide()
            self?.keycastPanel.clear(resetTemporaryMode: true)
        }
        updateRuntimeStatus {
            $0.isScrollEngineActive = false
            $0.isGestureEngineActive = false
            $0.isKeycastActive = false
        }
    }

    private func cancelGesture(replayClick shouldReplayClick: Bool) {
        guard let session = gestureSession else { return }
        gestureSession = nil
        cancelPendingGestureHUDUpdate()
        if shouldReplayClick,
           MouseGestureCompletionPolicy.completion(
               rule: nil,
               hasExceededClickTolerance: session.hasExceededClickTolerance
           ) == .replayClick {
            replayClick(for: session)
        }
        Task { @MainActor [weak self] in self?.gestureHUD.hide() }
        updateRuntimeStatus { $0.isGestureEngineActive = false }
    }

    private func replayClick(for session: GestureSession) {
        guard let button = CGMouseButton(rawValue: UInt32(session.button)) else { return }
        InputActionExecutor.postMouseClick(button: button, at: session.initialLocation)
    }

    @objc private func inputSettingsDidChange() { reloadSettings() }

    @objc private func featureSettingsDidChange() { reloadFinderSettings() }

    @objc private func modulePreferencesDidChange() {
        reloadModulePreferences()
        reloadFinderSettings()
    }

    @objc private func cutTransactionDidChange() { refreshCachedState() }

    @objc private func inputCommandReceived(_ notification: Notification) {
        if notification.userInfo?["command"] as? String == "screenshot-active",
           let enabled = notification.userInfo?["enabled"] as? Bool {
            stateLock.lock()
            keycastSuppressed = enabled
            inputSuppressed = enabled
            stateLock.unlock()
            if enabled { scheduleTransientReset(replayGesture: false) }
            return
        }
        if notification.userInfo?["command"] as? String == "keycast-positioning",
           let enabled = notification.userInfo?["enabled"] as? Bool {
            let keycast = currentSettings().keycast
            Task { @MainActor [weak self] in
                self?.keycastPanel.setPositioning(enabled, settings: keycast)
            }
            return
        }
        guard notification.userInfo?["command"] as? String == "temporary-all-keys",
              let enabled = notification.userInfo?["enabled"] as? Bool
        else { return }
        stateLock.lock()
        temporaryAllKeys = enabled
        stateLock.unlock()
        Task { @MainActor [weak self] in self?.keycastPanel.setTemporaryAllKeys(enabled) }
    }

    private func reloadSettings() {
        let settings = inputSettingsStore.load()
        setSettings(settings)
        updateRuntimeStatus { $0.emergencyDisabled = settings.emergencyDisabled }
        if settings.emergencyDisabled { scheduleTransientReset() }
    }

    private func saveKeycastCustomPosition(_ position: KeycastNormalizedPosition) {
        var settings = currentSettings()
        guard settings.keycast.position != .custom || settings.keycast.customPosition != position else { return }
        settings.keycast.position = .custom
        settings.keycast.customPosition = position
        setSettings(settings)
        try? inputSettingsStore.save(settings)
        DistributedNotificationCenter.default().postNotificationName(
            AppGroupConstants.inputEnhancementSettingsDidChangeNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private func reloadFinderSettings() {
        let enabled = (finderSettingsStore?.load().settings.shortcutHelperEnabled ?? false)
            && ModulePreferencesStore().isEnabled(moduleID: "finder")
        stateLock.lock()
        finderShortcutEnabled = enabled
        stateLock.unlock()
    }

    private func reloadModulePreferences() {
        let enabled = ModulePreferencesStore().isEnabled(moduleID: "input")
        stateLock.lock()
        inputModuleEnabled = enabled
        stateLock.unlock()
        if !enabled { scheduleTransientReset(replayGesture: false) }
    }

    private func refreshFrontmostApplication() {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        stateLock.lock()
        frontmostBundleIdentifier = bundleID
        stateLock.unlock()
    }

    private func refreshDisplayLayout() {
        let height = CGDisplayBounds(CGMainDisplayID()).height
        stateLock.lock()
        mainDisplayHeight = height
        stateLock.unlock()
    }

    private func cachedFrontmostBundleIdentifier() -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return frontmostBundleIdentifier
    }

    private func cachedMainDisplayHeight() -> CGFloat {
        stateLock.lock()
        defer { stateLock.unlock() }
        return mainDisplayHeight
    }

    private func currentSettings() -> InputEnhancementSettings {
        stateLock.lock()
        defer { stateLock.unlock() }
        return settingsSnapshot
    }

    private func setSettings(_ settings: InputEnhancementSettings) {
        stateLock.lock()
        settingsSnapshot = settings
        stateLock.unlock()
    }

    private func updateRuntimeStatus(_ update: (inout InputEventRuntimeStatus) -> Void) {
        stateLock.lock()
        update(&runtimeStatus)
        stateLock.unlock()
    }

    @objc private func applicationContextDidChange() {
        refreshFrontmostApplication()
        scheduleTransientReset(replayGesture: false)
    }

    @objc private func systemDidWake() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.start() }
    }

    @objc private func screenConfigurationDidChange() {
        refreshDisplayLayout()
        scheduleTransientReset(replayGesture: false)
    }

    @objc private func sessionDidLock() {
        stateLock.lock()
        sessionLocked = true
        stateLock.unlock()
        scheduleTransientReset(replayGesture: false)
    }

    @objc private func sessionDidUnlock() {
        stateLock.lock()
        sessionLocked = false
        stateLock.unlock()
    }

    private func scheduleTransientReset(replayGesture: Bool = true) {
        stateLock.lock()
        let runLoop = tapRunLoop
        stateLock.unlock()
        guard let runLoop else {
            clearTransientState(replayGesture: replayGesture)
            return
        }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            self?.clearTransientState(replayGesture: replayGesture)
        }
        CFRunLoopWakeUp(runLoop)
    }

    private func scheduleGestureTimeout(identifier: UUID) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let runLoop = self.tapRunLoop
            self.stateLock.unlock()
            guard let runLoop else { return }
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
                guard let self,
                      let session = self.gestureSession,
                      session.identifier == identifier
                else { return }
                let activeBundleIdentifier = self.cachedFrontmostBundleIdentifier()
                self.cancelGesture(replayClick: session.bundleIdentifier == activeBundleIdentifier)
            }
            CFRunLoopWakeUp(runLoop)
        }
    }

    private func queueGestureHUDUpdate(point: CGPoint, directions: [MouseGestureDirection]) {
        stateLock.lock()
        pendingGestureHUDUpdate = (point, directions)
        guard gestureHUDUpdateToken == nil else {
            stateLock.unlock()
            return
        }
        let token = UUID()
        gestureHUDUpdateToken = token
        stateLock.unlock()

        Task { @MainActor [weak self] in
            guard let self,
                  let update = self.dequeueGestureHUDUpdate(token: token)
            else { return }
            self.gestureHUD.append(point: update.point, directions: update.directions)
        }
    }

    private func dequeueGestureHUDUpdate(token: UUID) -> (point: CGPoint, directions: [MouseGestureDirection])? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard gestureHUDUpdateToken == token else { return nil }
        gestureHUDUpdateToken = nil
        defer { pendingGestureHUDUpdate = nil }
        return pendingGestureHUDUpdate
    }

    private func cancelPendingGestureHUDUpdate() {
        stateLock.lock()
        pendingGestureHUDUpdate = nil
        gestureHUDUpdateToken = nil
        stateLock.unlock()
    }

    private func temporaryAllKeysSnapshot() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return temporaryAllKeys
    }

    private func scheduleCircuitBreakerRecovery(runLoop: CFRunLoop?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self.circuitBreaker.reset()
            self.startRequested = false
            let rl = self.tapRunLoop
            let tap = self.eventTap
            self.stateLock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            if let rl {
                CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) {
                    CFRunLoopStop(rl)
                }
                CFRunLoopWakeUp(rl)
            }
        }
    }

    private func isInputModuleEnabled() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return inputModuleEnabled
    }

    private func shortcutModifiers(from flags: CGEventFlags) -> ShortcutModifiers {
        var modifiers: ShortcutModifiers = []
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        return modifiers
    }

    private func appKitPoint(from quartzPoint: CGPoint) -> CGPoint {
        let height = cachedMainDisplayHeight()
        return CGPoint(x: quartzPoint.x, y: height - quartzPoint.y)
    }

    private func isMouseDown(_ type: CGEventType) -> Bool {
        type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
    }

    private func isMouseUp(_ type: CGEventType) -> Bool {
        type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp
    }

    private func isMouseDragged(_ type: CGEventType) -> Bool {
        type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged
    }
}

private let inputEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let coordinator = Unmanaged<InputEventCoordinator>.fromOpaque(userInfo).takeUnretainedValue()
    return coordinator.process(type: type, event: event)
}
