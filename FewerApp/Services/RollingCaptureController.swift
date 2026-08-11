import AppKit
import FewerCore
import OSLog
import SwiftUI

enum RollingCaptureMode: Equatable, Sendable {
    case manual
    case automatic(RollingScrollDirection)

    var title: String {
        switch self {
        case .manual: "手动逐步"
        case .automatic(let direction): "自动\(direction.title)"
        }
    }

    var automaticDirection: RollingScrollDirection? {
        guard case .automatic(let direction) = self else { return nil }
        return direction
    }
}

enum RollingCaptureFailure: Equatable {
    case accessibilityUnavailable
    case targetExited
    case captureFailed(String)
    case targetDidNotScroll
    case dimensionChanged
    case unreliableMatch
    case outputLimitExceeded

    var message: String {
        switch self {
        case .accessibilityUnavailable: "手动逐步和自动滚动需要为 FewerShortcutHelper 开启辅助功能权限。"
        case .targetExited: "目标应用已退出，无法继续滚动截图。"
        case .captureFailed(let message): message
        case .targetDidNotScroll: "目标区域没有响应自动滚动。"
        case .dimensionChanged: "选区尺寸或页面缩放发生变化，无法可靠拼接。"
        case .unreliableMatch: "相邻画面重叠不足，无法可靠拼接；已保留当前长图，请返回最后截取位置后重试。"
        case .outputLimitExceeded: "长图已达到 64M 像素、32000 像素高度或 120 帧限制。"
        }
    }
}

/// 单个滚动截图会话的唯一状态源。AppKit 只负责窗口边界，SwiftUI HUD 只读取此对象。
@MainActor
final class RollingCaptureController: ObservableObject {
    @Published private(set) var mode: RollingCaptureMode = .manual
    @Published private(set) var state: RollingCapturePhase = .idle
    @Published private(set) var statusText = "准备滚动截图…"
    @Published private(set) var failure: RollingCaptureFailure?
    @Published private(set) var frameCount = 0
    @Published private(set) var outputHeight = 0
    @Published private(set) var isPerformingStep = false

    private static let logger = Logger(subsystem: "com.number47.fewer", category: "RollingCapture")
    private let configuration = StitchConfiguration(minimumOverlapRatio: 0.1)
    private let scrollClient = RollingScrollClient()
    private var task: Task<Void, Never>?
    private var stepTask: Task<Void, Never>?
    private var captureRect = CGRect.zero
    private var targetApplication: NSRunningApplication?
    private var sessionID = UUID()
    private var frames: [CGImage] = []
    private var placements: [StitchFramePlacement] = []
    private var currentPreparedFrame: StitchEngine.PreparedFrame?
    private var captureSession: ScreenshotCapture.RollingRegionSession?
    private var coverage = StitchCoverage()
    private var pendingTopFrame: (image: CGImage, originY: Int)?
    private var pendingBottomFrame: (image: CGImage, originY: Int)?
    private var duplicateAutomaticSteps = 0
    private var topCandidate = 0
    private var topCandidateCount = 0
    private var confirmedTop = 0
    private var bottomCandidate = 0
    private var bottomCandidateCount = 0
    private var confirmedBottom = 0
    private var guideWindow: NSWindow?
    private var hudWindow: NSPanel?
    private var didEnd = false
    private var completion: ((CGImage) -> Void)?
    private var cancellation: (() -> Void)?

    var canSwitchToManual: Bool { mode.automaticDirection != nil }
    var canPerformStep: Bool { mode == .manual && state == .capturing && !isPerformingStep }

    func start(
        rect: CGRect,
        mode: RollingCaptureMode,
        targetApplication: NSRunningApplication?,
        completion: @escaping (CGImage) -> Void,
        cancellation: @escaping () -> Void
    ) {
        guard state == .idle else { return }
        self.captureRect = rect
        self.mode = mode
        self.targetApplication = targetApplication
        self.completion = completion
        self.cancellation = cancellation
        sessionID = UUID()
        transition(.start)
        statusText = "正在读取首帧…"
        showWindows()
        HotKeyManager.shared.installRollingEscapeHandler { [weak self] in
            self?.cancel()
        }
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func pause() {
        guard state == .capturing else { return }
        stepTask?.cancel()
        stepTask = nil
        isPerformingStep = false
        transition(.pause)
        statusText = "已暂停"
    }

    func resume() {
        guard state == .paused else { return }
        failure = nil
        if frames.isEmpty {
            transition(.retryPreparation)
            statusText = "正在重新读取首帧…"
            task = Task { [weak self] in
                await self?.run()
            }
            return
        }
        transition(.resume)
        statusText = mode == .manual ? "点击按钮逐步滚动并捕获" : "正在\(mode.title)…"
    }

    func switchToManual() {
        guard state == .paused, mode.automaticDirection != nil else { return }
        mode = .manual
        duplicateAutomaticSteps = 0
        resume()
    }

    func performStep(_ direction: RollingScrollDirection) {
        guard canPerformStep else { return }
        isPerformingStep = true
        stepTask = Task { [weak self] in
            guard let self else { return }
            await self.controlledStep(direction: direction, automaticallyContinues: false)
            self.isPerformingStep = false
            self.stepTask = nil
        }
    }

    func requestAccessibility() {
        PermissionService.requestAccessibility()
        statusText = "授权完成后点击“重试”"
    }

    func finish() {
        guard !didEnd, !frames.isEmpty else { return }
        transition(.beginFinishing)
        statusText = "正在生成长图…"
        let snapshot = compositionSnapshot()
        switch StitchEngine.compose(
            frames: snapshot.frames,
            placements: snapshot.placements,
            confirmedTopHeight: confirmedTop,
            confirmedBottomHeight: confirmedBottom,
            configuration: configuration
        ) {
        case .success(let image):
            Self.logger.info("completed mode=\(self.mode.title, privacy: .public) frames=\(self.frameCount) height=\(image.height)")
            didEnd = true
            task?.cancel()
            task = nil
            stepTask?.cancel()
            stepTask = nil
            stopCaptureSession()
            transition(.complete)
            cleanupWindows()
            let completion = completion
            self.completion = nil
            cancellation = nil
            completion?(image)
        case .failure:
            pause(for: .captureFailed("长图合成失败，已保留当前会话。"))
        }
    }

    func cancel() {
        guard !didEnd else { return }
        didEnd = true
        task?.cancel()
        task = nil
        stepTask?.cancel()
        stepTask = nil
        isPerformingStep = false
        stopCaptureSession()
        scrollClient.cancelPending()
        transition(.cancel)
        cleanupWindows()
        let cancellation = cancellation
        completion = nil
        self.cancellation = nil
        cancellation?()
    }

    private func run() async {
        guard let targetApplication, !targetApplication.isTerminated else {
            pause(for: .targetExited)
            return
        }
        targetApplication.activate(options: [])
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }

        do {
            let session = try await ScreenshotCapture.rollingRegionSession(captureRect)
            captureSession = session
            let first = try await session.capture()
            let configuration = configuration
            guard let firstPrepared = await Task.detached(priority: .userInitiated, operation: {
                StitchEngine.prepare(first, configuration: configuration)
            }).value else {
                pause(for: .captureFailed("滚动首帧不可用。"))
                return
            }
            frames = [first]
            placements = [StitchFramePlacement(originY: 0)]
            currentPreparedFrame = firstPrepared
            coverage = StitchCoverage()
            pendingTopFrame = nil
            pendingBottomFrame = nil
            frameCount = 1
            outputHeight = first.height
            transition(.firstFrameCaptured)
            statusText = mode == .manual ? "正在检查逐步滚动权限…" : "正在检查自动滚动权限…"
            Self.logger.info("started mode=\(self.mode.title, privacy: .public) target=\(targetApplication.bundleIdentifier ?? "unknown", privacy: .public) width=\(first.width) height=\(first.height)")
        } catch {
            pause(for: .captureFailed(error.localizedDescription))
            return
        }

        if !(await prepareAutomaticScrolling()) {
            pause(for: .accessibilityUnavailable)
        } else if mode == .manual {
            statusText = "点击向上一步或向下一步，截取完成后可继续"
        }

        while !Task.isCancelled, !didEnd {
            guard state == .capturing else {
                try? await Task.sleep(for: .milliseconds(120))
                continue
            }
            if targetApplication.isTerminated {
                pause(for: .targetExited)
                continue
            }
            switch mode {
            case .manual:
                try? await Task.sleep(for: .milliseconds(100))
            case .automatic(let direction):
                await controlledStep(direction: direction, automaticallyContinues: true)
            }
        }
    }

    private func controlledStep(
        direction: RollingScrollDirection,
        automaticallyContinues: Bool
    ) async {
        statusText = "正在\(direction.title)滚动并捕获第 \(frameCount + 1) 帧…"
        let distance = min(max(Int(captureRect.height * 0.2), 40), RollingScrollCommand.maximumDistance)
        let requestID = UUID()
        guard let command = RollingScrollCommand(
            sessionID: sessionID,
            requestID: requestID,
            screenX: captureRect.midX,
            screenY: captureRect.midY,
            direction: direction,
            distance: distance
        ) else {
            pause(for: .targetDidNotScroll)
            return
        }
        guard let response = await scrollClient.send(command: command, timeout: .seconds(2)) else {
            pause(for: .targetDidNotScroll)
            return
        }
        guard response.reason == .completed else {
            pause(for: response.reason == .accessibilityDenied ? .accessibilityUnavailable : .targetDidNotScroll)
            return
        }
        // SCStream 最多仍有 queueDepth 帧在 WindowServer 管线中；先等页面和管线完成，
        // 再清空队列，避免把滚动前的延迟帧误判为“页面未移动”。
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }
        captureSession?.discardPendingFrames()
        guard let image = await stableFrame(timeout: .seconds(2)) else {
            pause(for: .captureFailed("页面持续变化，无法取得稳定帧。"))
            return
        }

        switch await accept(image, preferredDirection: direction) {
        case .appended:
            duplicateAutomaticSteps = 0
            if !automaticallyContinues {
                statusText = "本步已完成，可继续向上或向下"
            }
        case .repositioned:
            guard automaticallyContinues else {
                statusText = "已回到截取过的区域，可继续向任一端逐步滚动"
                return
            }
            duplicateAutomaticSteps += 1
            if duplicateAutomaticSteps >= 2 {
                pause(for: .targetDidNotScroll)
            }
        case .duplicate:
            guard automaticallyContinues else {
                statusText = "本步未检测到页面移动"
                return
            }
            duplicateAutomaticSteps += 1
            if duplicateAutomaticSteps >= 2 {
                if frameCount == 1 {
                    pause(for: .targetDidNotScroll)
                } else {
                    finish()
                }
            }
        case .failed:
            break
        }
    }

    private func stableFrame(timeout: Duration) async -> CGImage? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var previous: StitchEngine.PreparedFrame?
        while clock.now < deadline, !Task.isCancelled {
            guard let captureSession,
                  let image = try? await captureSession.capture()
            else { return nil }
            let configuration = configuration
            guard let prepared = await Task.detached(priority: .userInitiated, operation: {
                StitchEngine.prepare(image, configuration: configuration)
            }).value else { return nil }
            if let previous {
                let analysis = await Task.detached(priority: .userInitiated) {
                    StitchEngine.analyze(
                        previous: previous,
                        next: prepared,
                        configuration: configuration
                    )
                }.value
                if case .failure(.duplicateFrame) = analysis {
                    return image
                }
            }
            previous = prepared
            try? await Task.sleep(for: .milliseconds(120))
        }
        return nil
    }

    private enum AcceptResult {
        case appended
        case repositioned
        case duplicate
        case failed
    }

    private func accept(
        _ image: CGImage,
        preferredDirection: RollingScrollDirection
    ) async -> AcceptResult {
        guard let previous = currentPreparedFrame else { return .failed }
        let configuration = configuration
        guard let prepared = await Task.detached(priority: .userInitiated, operation: {
            StitchEngine.prepare(image, configuration: configuration)
        }).value else {
            pause(for: .captureFailed("滚动帧不可用。"))
            return .failed
        }
        let analysis = await Task.detached(priority: .userInitiated) {
            StitchEngine.analyze(
                previous: previous,
                next: prepared,
                preferredDirection: preferredDirection,
                maximumShiftRatio: 0.75,
                configuration: configuration
            )
        }.value
        switch analysis {
        case .failure(.duplicateFrame):
            return .duplicate
        case .failure(.dimensionChanged):
            pause(for: .dimensionChanged)
            return .failed
        case .failure(.lowConfidence):
            pause(for: .unreliableMatch)
            return .failed
        case .failure:
            pause(for: .captureFailed("滚动帧不可用。"))
            return .failed
        case .success(let match):
            var nextCoverage = coverage
            let contribution = nextCoverage.advance(by: match)
            let nextHeight = nextCoverage.outputHeight(frameHeight: image.height)
            let nextFrameCount = frames.count + 2
            if let failure = StitchEngine.validateOutput(
                width: image.width,
                height: nextHeight,
                frameCount: nextFrameCount,
                configuration: configuration
            ), failure == .outputLimitExceeded {
                pause(for: .outputLimitExceeded)
                return .failed
            }
            coverage = nextCoverage
            currentPreparedFrame = prepared
            outputHeight = nextHeight
            updateStationaryBands(with: match)
            if contribution == .covered {
                statusText = "已回到截取过的区域，可继续向任一端滚动"
                return .repositioned
            }
            retainKeyframe(image, contribution: contribution)
            frameCount = compositionSnapshot().frames.count
            statusText = mode == .manual
                ? "已向\(match.direction.title)扩展，当前 \(frameCount) 帧"
                : "已\(match.direction.title)拼接 \(frameCount) 帧"
            Self.logger.info("accepted frame=\(self.frameCount) direction=\(match.direction.rawValue, privacy: .public) offset=\(match.offsetY) confidence=\(match.confidence) top=\(match.stationaryTopHeight) bottom=\(match.stationaryBottomHeight)")
            return .appended
        }
    }

    /// 连续帧用于跟踪位移，只保留约半屏间距的关键帧用于最终合成，兼顾快速滚动与长图帧数上限。
    private func retainKeyframe(_ image: CGImage, contribution: StitchCoverageContribution) {
        let originY = coverage.currentOriginY
        let spacing = max(image.height / 2, configuration.minimumShift)
        switch contribution {
        case .prepend:
            pendingTopFrame = (image, originY)
            let minimumStoredOrigin = placements.map(\.originY).min() ?? 0
            if minimumStoredOrigin - originY >= spacing {
                frames.append(image)
                placements.append(StitchFramePlacement(originY: originY))
                pendingTopFrame = nil
            }
        case .append:
            pendingBottomFrame = (image, originY)
            let maximumStoredOrigin = placements.map(\.originY).max() ?? 0
            if originY - maximumStoredOrigin >= spacing {
                frames.append(image)
                placements.append(StitchFramePlacement(originY: originY))
                pendingBottomFrame = nil
            }
        case .covered:
            break
        }
    }

    private func compositionSnapshot() -> (frames: [CGImage], placements: [StitchFramePlacement]) {
        var snapshotFrames = frames
        var snapshotPlacements = placements
        for pending in [pendingTopFrame, pendingBottomFrame].compactMap({ $0 })
        where !snapshotPlacements.contains(where: { $0.originY == pending.originY }) {
            snapshotFrames.append(pending.image)
            snapshotPlacements.append(StitchFramePlacement(originY: pending.originY))
        }
        return (snapshotFrames, snapshotPlacements)
    }

    private func stopCaptureSession() {
        guard let captureSession else { return }
        self.captureSession = nil
        Task {
            await captureSession.stop()
        }
    }

    private func updateStationaryBands(with match: StitchMatch) {
        (topCandidate, topCandidateCount, confirmedTop) = confirmedBand(
            currentCandidate: topCandidate,
            currentCount: topCandidateCount,
            confirmed: confirmedTop,
            incoming: match.stationaryTopHeight
        )
        (bottomCandidate, bottomCandidateCount, confirmedBottom) = confirmedBand(
            currentCandidate: bottomCandidate,
            currentCount: bottomCandidateCount,
            confirmed: confirmedBottom,
            incoming: match.stationaryBottomHeight
        )
    }

    private func confirmedBand(
        currentCandidate: Int,
        currentCount: Int,
        confirmed: Int,
        incoming: Int
    ) -> (Int, Int, Int) {
        guard incoming > 0 else { return (0, 0, confirmed) }
        if abs(incoming - currentCandidate) <= 3 {
            let count = currentCount + 1
            return (incoming, count, count >= 2 ? min(incoming, currentCandidate) : confirmed)
        }
        return (incoming, 1, confirmed)
    }

    private func prepareAutomaticScrolling() async -> Bool {
        _ = PermissionService.launchShortcutHelper()
        for _ in 0..<10 {
            let status = PermissionService.shortcutHelperStatus
            if status.isFresh(), status.isAccessibilityTrusted { return true }
            if status.isFresh(), !status.isAccessibilityTrusted { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private func pause(for failure: RollingCaptureFailure) {
        guard !didEnd else { return }
        stepTask?.cancel()
        stepTask = nil
        isPerformingStep = false
        self.failure = failure
        transition(.pause)
        statusText = failure.message
        Self.logger.error("paused reason=\(failure.message, privacy: .public)")
    }

    private func showWindows() {
        let appKitRect = Self.appKitRect(from: captureRect)
        let guide = NSWindow(
            contentRect: appKitRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        guide.level = .floating
        guide.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        guide.isOpaque = false
        guide.backgroundColor = .clear
        guide.hasShadow = false
        guide.ignoresMouseEvents = true
        guide.isReleasedWhenClosed = false
        guide.identifier = NSUserInterfaceItemIdentifier("rolling-capture-guide")
        guide.contentViewController = NSHostingController(rootView:
            Rectangle().stroke(Color.green, lineWidth: 2)
        )
        guide.orderFrontRegardless()
        guideWindow = guide

        let size = NSSize(width: 440, height: 118)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier("rolling-capture-hud")
        panel.contentViewController = NSHostingController(rootView: RollingCaptureHUDView(controller: self))
        panel.setFrameOrigin(hudOrigin(size: size, selection: appKitRect))
        panel.orderFrontRegardless()
        hudWindow = panel
    }

    private func transition(_ event: RollingCaptureEvent) {
        if let next = RollingCaptureTransitions.next(from: state, event: event) {
            state = next
        }
    }

    private func cleanupWindows() {
        HotKeyManager.shared.removeRollingEscapeHandler()
        scrollClient.cancelPending()
        for window in [guideWindow, hudWindow] {
            window?.contentViewController = nil
            window?.close()
        }
        guideWindow = nil
        hudWindow = nil
    }

    private func hudOrigin(size: NSSize, selection: NSRect) -> NSPoint {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(selection) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? selection
        let x = min(max(selection.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let below = selection.minY - size.height - 10
        let y = below >= visible.minY + 8 ? below : min(selection.maxY + 10, visible.maxY - size.height - 8)
        return NSPoint(x: x, y: y)
    }

    private static func appKitRect(from cgRect: CGRect) -> NSRect {
        let top = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        return NSRect(
            x: cgRect.minX,
            y: top - cgRect.maxY,
            width: cgRect.width,
            height: cgRect.height
        )
    }
}

private struct RollingCaptureHUDView: View {
    @ObservedObject var controller: RollingCaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(controller.mode.title, systemImage: "rectangle.stack")
                    .font(.headline)
                Spacer()
                Text("\(controller.frameCount) 帧 · \(controller.outputHeight) px")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(controller.statusText)
                .font(.caption)
                .foregroundStyle(controller.failure == nil ? Color.secondary : Color.red)
                .lineLimit(2)
            HStack(spacing: 8) {
                if controller.failure == .accessibilityUnavailable {
                    Button("请求权限") { controller.requestAccessibility() }
                }
                if controller.mode == .manual, controller.state == .capturing {
                    Button("向上一步") { controller.performStep(.up) }
                        .disabled(!controller.canPerformStep)
                    Button("向下一步") { controller.performStep(.down) }
                        .disabled(!controller.canPerformStep)
                }
                if controller.canSwitchToManual, controller.state == .paused {
                    Button("改用手动") { controller.switchToManual() }
                }
                if controller.state == .paused {
                    Button("重试") { controller.resume() }
                } else if controller.state == .capturing {
                    Button("暂停") { controller.pause() }
                }
                Spacer()
                Button("取消", role: .cancel) { controller.cancel() }
                Button("完成") { controller.finish() }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.frameCount == 0)
            }
        }
        .padding(12)
        .frame(width: 440, height: 118)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.2)))
    }
}

@MainActor
private final class RollingScrollClient: NSObject {
    private struct PendingRequest {
        let sessionID: UUID
        let continuation: CheckedContinuation<RollingScrollResponse?, Never>
    }

    private var pending: [UUID: PendingRequest] = [:]

    override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(receive(_:)),
            name: AppGroupConstants.rollingScrollResponseNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func send(command: RollingScrollCommand, timeout: Duration) async -> RollingScrollResponse? {
        await withCheckedContinuation { continuation in
            pending[command.requestID] = PendingRequest(
                sessionID: command.sessionID,
                continuation: continuation
            )
            DistributedNotificationCenter.default().postNotificationName(
                AppGroupConstants.rollingScrollCommandNotification,
                object: nil,
                userInfo: command.userInfo,
                deliverImmediately: true
            )
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish(requestID: command.requestID, response: nil)
            }
        }
    }

    func cancelPending() {
        let continuations = pending.values.map(\.continuation)
        pending.removeAll()
        continuations.forEach { $0.resume(returning: nil) }
    }

    @objc private func receive(_ notification: Notification) {
        guard let response = RollingScrollResponse(userInfo: notification.userInfo),
              pending[response.requestID]?.sessionID == response.sessionID
        else { return }
        finish(requestID: response.requestID, response: response)
    }

    private func finish(requestID: UUID, response: RollingScrollResponse?) {
        pending.removeValue(forKey: requestID)?.continuation.resume(returning: response)
    }
}
