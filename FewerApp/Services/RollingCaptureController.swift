import AppKit
import FewerCore
import OSLog
import SwiftUI

enum RollingCaptureFailure: Equatable {
    case targetExited
    case captureFailed(String)
    case dimensionChanged
    case outputLimitExceeded

    var message: String {
        switch self {
        case .targetExited: "目标应用已退出，无法继续滚动截图。"
        case .captureFailed(let message): message
        case .dimensionChanged: "选区尺寸或页面缩放发生变化，无法可靠拼接。"
        case .outputLimitExceeded: "长图已达到 64M 像素、32000 像素高度或 120 帧限制。"
        }
    }
}

/// 单个滚动截图会话的唯一状态源。AppKit 只负责窗口边界，SwiftUI HUD 只读取此对象。
@MainActor
final class RollingCaptureController: ObservableObject {
    @Published private(set) var state: RollingCapturePhase = .idle
    @Published private(set) var statusText = "准备滚动截图…"
    @Published private(set) var failure: RollingCaptureFailure?
    @Published private(set) var frameCount = 0
    @Published private(set) var outputHeight = 0
    @Published private(set) var previewImage: CGImage?

    private static let logger = Logger(subsystem: "com.number47.fewer", category: "RollingCapture")
    private let configuration = StitchConfiguration(
        minimumOverlapRatio: 0.1,
        minimumMatchOverlapRatio: 0.25
    )
    private var task: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewNeedsRefresh = false
    private var previewGeneration = 0
    private var previewDirection: RollingScrollDirection?
    /// 最近一次成功匹配的滚动方向。连续同向滚动时用于单方向快速匹配，
    /// 让拼接分析耗时减半，降低快速滚动时丢帧导致的漏图与拼接断开。
    private var lastDirection: RollingScrollDirection?
    /// 最近一次成功匹配的位移，作为低置信度匹配的滚动连续性先验，
    /// 防止快速滚动时平滑内容上的小位移假匹配导致拼接重叠。
    private var lastOffsetY = 0
    private var captureRect = CGRect.zero
    private var targetApplication: NSRunningApplication?
    private var frames: [CGImage] = []
    private var placements: [StitchFramePlacement] = []
    private var currentPreparedFrame: StitchEngine.PreparedFrame?
    private var captureSession: ScreenshotCapture.RollingRegionSession?
    private var coverage = StitchCoverage()
    private var pendingTopFrame: (image: CGImage, originY: Int)?
    private var pendingBottomFrame: (image: CGImage, originY: Int)?
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

    func start(
        rect: CGRect,
        targetApplication: NSRunningApplication?,
        completion: @escaping (CGImage) -> Void,
        cancellation: @escaping () -> Void
    ) {
        guard state == .idle else { return }
        self.captureRect = rect
        self.targetApplication = targetApplication
        self.completion = completion
        self.cancellation = cancellation
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
        statusText = manualRecordingStatus
    }

    func stopManualRecording() {
        guard state == .capturing, !frames.isEmpty else { return }
        finish()
    }

    func finish() {
        guard !didEnd,
              !frames.isEmpty,
              state == .capturing || state == .paused
        else { return }
        failure = nil
        transition(.beginFinishing)
        statusText = "正在处理剩余画面…"
    }

    private func completeComposition() {
        guard !didEnd, state == .finishing else { return }
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
            Self.logger.info("completed frames=\(self.frameCount) height=\(image.height)")
            didEnd = true
            task = nil
            previewTask?.cancel()
            previewTask = nil
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
        previewTask?.cancel()
        previewTask = nil
        stopCaptureSession()
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

        do {
            let session = try await ScreenshotCapture.rollingRegionSession(captureRect)
            captureSession = session
            let first = try await firstCleanFrame(from: session)
            let configuration = configuration
            guard let firstPrepared = await Task.detached(priority: .userInitiated, operation: {
                StitchEngine.prepare(first.image, configuration: configuration)
            }).value else {
                pause(for: .captureFailed("滚动首帧不可用。"))
                return
            }
            installFirstFrame(first.image, prepared: firstPrepared)
            transition(.firstFrameCaptured)
            statusText = manualRecordingStatus
            Self.logger.info("started target=\(targetApplication.bundleIdentifier ?? "unknown", privacy: .public) width=\(first.image.width) height=\(first.image.height)")
        } catch {
            pause(for: .captureFailed(error.localizedDescription))
            return
        }

        targetApplication.activate(options: [])
        guard !Task.isCancelled else { return }

        while !Task.isCancelled, !didEnd {
            switch state {
            case .capturing:
                if targetApplication.isTerminated {
                    pause(for: .targetExited)
                    continue
                }
                await captureManualFrame()
            case .finishing:
                await finishManualCapture()
                return
            default:
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func captureManualFrame() async {
        guard let captureSession else {
            pause(for: .captureFailed("滚动截图会话不可用。"))
            return
        }
        do {
            let frame = try await captureSession.capture()
            guard !Task.isCancelled, !didEnd else { return }
            switch await accept(frame) {
            case .appended, .repositioned:
                break
            case .duplicate:
                if state == .capturing {
                    statusText = manualRecordingStatus
                }
            case .unreliable:
                break
            case .failed:
                break
            }
        } catch {
            pause(for: .captureFailed(error.localizedDescription))
        }
    }

    private func finishManualCapture() async {
        guard let captureSession else {
            completeComposition()
            return
        }
        await captureSession.finishProducing()
        while state == .finishing, !Task.isCancelled {
            do {
                let frame = try await captureSession.capture()
                _ = await accept(frame)
            } catch ScreenshotCapture.RollingCaptureError.captureFinished {
                break
            } catch {
                pause(for: .captureFailed(error.localizedDescription))
                return
            }
        }
        guard state == .finishing, !Task.isCancelled else { return }
        self.captureSession = nil
        completeComposition()
    }

    private enum AcceptResult {
        case appended
        case repositioned
        case duplicate
        case unreliable
        case failed
    }

    private func accept(_ frame: ScreenshotCapture.RollingCapturedFrame) async -> AcceptResult {
        let image = frame.image
        guard let previous = currentPreparedFrame else { return .failed }
        let configuration = configuration
        guard let prepared = await Task.detached(priority: .userInitiated, operation: {
            StitchEngine.prepare(image, configuration: configuration)
        }).value else {
            pause(for: .captureFailed("滚动帧不可用。"))
            return .failed
        }
        guard !Task.isCancelled, !didEnd else { return .failed }
        // 滚动过头或页面未渲染时，捕获帧边缘会出现纯黑区域；拼接后即长图上的黑带。
        // 用上一帧亮度作参考：主体大面积变黑且参考帧偏亮时是未渲染黑带，
        // 跳过这类帧（不存储、不更新基准），等画面恢复后再继续；深色页面不受影响。
        let bands = await Task.detached(priority: .userInitiated) {
            StitchEngine.blackBands(of: prepared, referenceMeanLuminance: previous.meanLuminance)
        }.value
        guard !Task.isCancelled, !didEnd else { return .failed }
        if !bands.isEmpty {
            Self.logger.info("skipped black-edge frame top=\(bands.top) bottom=\(bands.bottom)")
            return .duplicate
        }
        let direction = lastDirection
        // 滚动连续性先验：快速滚动时周期性内容容易锁到错误峰值，
        // 传给 analyze 让引擎在方向一致且分数接近时优先采用上一帧位移。
        let priorShift = lastOffsetY
        let analysis = await Task.detached(priority: .userInitiated) {
            // 连续同向滚动时先单方向匹配（耗时减半）；失败再回退双向，
            // 让拼接分析跟上快速滚动，减少丢帧造成的漏图与断开。
            if let direction {
                let result = StitchEngine.analyze(
                    previous: previous,
                    next: prepared,
                    preferredDirection: direction,
                    priorShift: priorShift,
                    configuration: configuration
                )
                if case .failure(.lowConfidence) = result {
                    return StitchEngine.analyze(
                        previous: previous,
                        next: prepared,
                        preferredDirection: nil,
                        configuration: configuration
                    )
                }
                return result
            }
            return StitchEngine.analyze(
                previous: previous,
                next: prepared,
                preferredDirection: nil,
                configuration: configuration
            )
        }.value
        guard !Task.isCancelled, !didEnd else { return .failed }
        switch analysis {
        case .failure(.duplicateFrame):
            // 滚动停顿：当前画面是同一位置的完整渲染版本，用其刷新桥接帧，
            // 让长图尾部使用已渲染清晰的画面（网页图片渐进加载时尤为明显）。
            currentPreparedFrame = prepared
            refreshPendingFrame(with: image)
            return .duplicate
        case .failure(.dimensionChanged):
            pause(for: .dimensionChanged)
            return .failed
        case .failure(.lowConfidence):
            // PageDown、拖滚动条等一次位移可达 75%–95% 帧高的跳转超出可靠
            // 匹配上限；用放宽上限 + 更高置信度/峰值锐度的组合尝试恢复，
            // 通过才写入长图，否则进入安全保持。
            if let match = await extendedJumpMatch(
                previous: previous,
                prepared: prepared,
                direction: direction
            ) {
                return applyMatch(match, prepared: prepared, image: image)
            }
            return await handleUnreliableMatch(
                previous: previous,
                prepared: prepared,
                image: image,
                droppedBefore: frame.droppedBefore,
                direction: direction
            )
        case .failure:
            pause(for: .captureFailed("滚动帧不可用。"))
            return .failed
        case .success(let match):
            return applyMatch(match, prepared: prepared, image: image)
        }
    }

    /// 将可靠匹配写入位置链与长图（普通匹配与跳页恢复共用）。
    private func applyMatch(
        _ match: StitchMatch,
        prepared: StitchEngine.PreparedFrame,
        image: CGImage
    ) -> AcceptResult {
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
        if contribution != .covered,
           !retainKeyframe(
               image,
               contribution: contribution,
               originY: nextCoverage.currentOriginY,
               match: match
           ) {
            if state == .capturing {
                statusText = "滚动过快，当前画面与已截内容断开；放慢或回滚后自动恢复"
            }
            Self.logger.info("held frame that breaks keyframe chain origin=\(nextCoverage.currentOriginY)")
            return .unreliable
        }
        coverage = nextCoverage
        currentPreparedFrame = prepared
        lastDirection = match.direction
        lastOffsetY = match.offsetY
        outputHeight = nextHeight
        updateStationaryBands(with: match)
        if contribution == .covered {
            refreshPendingFrame(with: image)
            requestPreviewUpdate(direction: match.direction)
            if state == .capturing {
                statusText = "已回到截取过的区域，可继续向任一端滚动"
            }
            return .repositioned
        }
        frameCount = compositionSnapshot().frames.count
        requestPreviewUpdate(direction: match.direction)
        if state == .capturing {
            statusText = "已向\(match.direction.title)扩展，当前 \(frameCount) 帧"
        }
        Self.logger.info("accepted frame=\(self.frameCount) direction=\(match.direction.rawValue, privacy: .public) offset=\(match.offsetY) confidence=\(match.confidence) top=\(match.stationaryTopHeight) bottom=\(match.stationaryBottomHeight)")
        return .appended
    }

    /// 跳页/滚动条大位移恢复：放宽重叠上限，同时要求更高的置信度与峰值锐度，
    /// 只有明显唯一的对齐才被接受，避免周期性内容在大位移处锁到错误峰值。
    private func extendedJumpMatch(
        previous: StitchEngine.PreparedFrame,
        prepared: StitchEngine.PreparedFrame,
        direction: RollingScrollDirection?
    ) async -> StitchMatch? {
        let configuration = jumpRecoveryConfiguration
        if let direction {
            let preferred = await Task.detached(priority: .userInitiated) {
                StitchEngine.analyze(
                    previous: previous,
                    next: prepared,
                    preferredDirection: direction,
                    maximumShiftRatio: 0.95,
                    configuration: configuration
                )
            }.value
            guard !Task.isCancelled, !didEnd else { return nil }
            if case .success(let match) = preferred { return match }
        }
        let result = await Task.detached(priority: .userInitiated) {
            StitchEngine.analyze(
                previous: previous,
                next: prepared,
                preferredDirection: nil,
                maximumShiftRatio: 0.95,
                configuration: configuration
            )
        }.value
        guard !Task.isCancelled, !didEnd, case .success(let match) = result else { return nil }
        return match
    }

    private var jumpRecoveryConfiguration: StitchConfiguration {
        StitchConfiguration(
            minimumOverlapRatio: 0.04,
            minimumMatchOverlapRatio: 0.05,
            minimumConfidence: 0.98,
            minimumScoreMargin: 0.06
        )
    }

    /// 滚动停顿或回访已截区域时，用完全渲染的当前画面刷新同一位置的桥接帧，
    /// 让长图尾部使用清晰版本（滚动中的帧可能还未完全渲染）。
    private func refreshPendingFrame(with image: CGImage) {
        let origin = coverage.currentOriginY
        if pendingBottomFrame?.originY == origin {
            pendingBottomFrame = (image, origin)
        }
        if pendingTopFrame?.originY == origin {
            pendingTopFrame = (image, origin)
        }
    }

    /// 低置信度帧的安全处理。
    /// 只有“猜测恰好采纳先验方向+位移”才允许推进 coverage：这种情形是
    /// 周期性内容带来的位移歧义，连续性得到确认，可以安全恢复。丢帧后的帧
    /// 同样走这条路径：交付帧之间仍保留重叠时内容没有丢失，先验一致且
    /// 置信度达标即可继续延伸，不再因丢帧让长图停止增长（尾部缺失）。
    /// 其余情况（滚动过快、画面未稳定）保持基准与 coverage 不动，等待画面
    /// 回到与基准仍有足够重叠的范围后自动恢复。这样不存储任何位置不可靠的
    /// 帧，避免错误 placement 造成长图内容重复（重叠）或漏画（黑边）。
    private func handleUnreliableMatch(
        previous: StitchEngine.PreparedFrame,
        prepared: StitchEngine.PreparedFrame,
        image: CGImage,
        droppedBefore: Int,
        direction: RollingScrollDirection?
    ) async -> AcceptResult {
        guard let priorDirection = direction, lastOffsetY >= configuration.minimumShift else {
            if state == .capturing {
                statusText = "内容暂无法可靠拼接，放慢或回滚后自动恢复"
            }
            return .unreliable
        }
        let priorShift = lastOffsetY
        let configuration = configuration
        let guess = await Task.detached(priority: .userInitiated) {
            StitchEngine.bestGuess(
                previous: previous,
                next: prepared,
                priorDirection: priorDirection,
                priorShift: priorShift,
                configuration: configuration
            )
        }.value
        guard !Task.isCancelled, !didEnd else { return .failed }
        // 只有猜测与先验完全一致（周期性内容上采纳了连续性先验）才推进；
        // 其余猜测可能来自错误峰值（实际位移已超出可靠匹配范围），
        // 推进会让 coverage 漂移，产生内容重复（重叠）或漏画（黑边）。
        guard let guess,
              guess.direction == priorDirection,
              guess.offsetY == priorShift,
              guess.confidence >= configuration.minimumConfidence
        else {
            if state == .capturing {
                statusText = "内容暂无法可靠拼接，放慢或回滚后自动恢复"
            }
            Self.logger.info("held low-confidence frame confidence=\(guess?.confidence ?? 0, privacy: .public) droppedBefore=\(droppedBefore)")
            return .unreliable
        }
        // 周期性内容歧义：先验引导的猜测置信度达标，可以安全推进位置追踪。
        var nextCoverage = coverage
        let contribution = nextCoverage.advance(by: guess)
        if contribution != .covered,
           !retainKeyframe(
               image,
               contribution: contribution,
               originY: nextCoverage.currentOriginY,
               match: guess
           ) {
            if state == .capturing {
                statusText = "滚动过快，当前画面与已截内容断开；放慢或回滚后自动恢复"
            }
            return .unreliable
        }
        coverage = nextCoverage
        currentPreparedFrame = prepared
        lastDirection = guess.direction
        lastOffsetY = guess.offsetY
        outputHeight = coverage.outputHeight(frameHeight: image.height)
        if contribution != .covered {
            frameCount = compositionSnapshot().frames.count
        }
        requestPreviewUpdate(direction: guess.direction)
        if state == .capturing {
            statusText = manualRecordingStatus
        }
        return .unreliable
    }

    /// 首帧也会进入最终合成；若选区一开始就是滚动未渲染的黑边帧，
    /// 等待干净帧（最多约 2 秒）再开始，避免长图顶部出现黑带。
    private func firstCleanFrame(
        from session: ScreenshotCapture.RollingRegionSession
    ) async throws -> ScreenshotCapture.RollingCapturedFrame {
        var fallback: ScreenshotCapture.RollingCapturedFrame?
        for _ in 0..<60 {
            if Task.isCancelled || didEnd { break }
            let candidate = try await session.capture()
            fallback = candidate
            let configuration = configuration
            guard let prepared = await Task.detached(priority: .userInitiated, operation: {
                StitchEngine.prepare(candidate.image, configuration: configuration)
            }).value else { continue }
            let bands = await Task.detached(priority: .userInitiated) {
                StitchEngine.blackBands(of: prepared)
            }.value
            if bands.isEmpty { return candidate }
        }
        if let fallback { return fallback }
        return try await session.capture()
    }

    private func installFirstFrame(
        _ image: CGImage,
        prepared: StitchEngine.PreparedFrame
    ) {
        frames = [image]
        placements = [StitchFramePlacement(originY: 0)]
        currentPreparedFrame = prepared
        coverage = StitchCoverage()
        lastDirection = nil
        lastOffsetY = 0
        pendingTopFrame = nil
        pendingBottomFrame = nil
        topCandidate = 0
        topCandidateCount = 0
        confirmedTop = 0
        bottomCandidate = 0
        bottomCandidateCount = 0
        confirmedBottom = 0
        frameCount = 1
        outputHeight = image.height
        requestPreviewUpdate(direction: nil)
    }

    private var manualRecordingStatus: String {
        "正在录制，可上下滚动；点击“停止并生成”结束"
    }

    private func requestPreviewUpdate(direction: RollingScrollDirection?) {
        if let direction {
            previewDirection = direction
        }
        previewGeneration += 1
        previewNeedsRefresh = true
        guard previewTask == nil else { return }
        previewTask = Task { [weak self] in
            await self?.renderPreviewLoop()
        }
    }

    private func renderPreviewLoop() async {
        while previewNeedsRefresh, !Task.isCancelled, !didEnd {
            previewNeedsRefresh = false
            let generation = previewGeneration
            let snapshot = previewSnapshot()
            let top = confirmedTop
            let bottom = confirmedBottom
            let configuration = configuration
            let direction = previewDirection
            let image = await Task.detached(priority: .utility) {
                Self.makePreview(
                    frames: snapshot.frames,
                    placements: snapshot.placements,
                    confirmedTopHeight: top,
                    confirmedBottomHeight: bottom,
                    configuration: configuration,
                    direction: direction
                )
            }.value
            guard !Task.isCancelled, !didEnd else { break }
            if generation == previewGeneration, let image {
                previewImage = image
            }
            if previewNeedsRefresh {
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        previewTask = nil
    }

    private func previewSnapshot() -> (frames: [CGImage], placements: [StitchFramePlacement]) {
        let snapshot = compositionSnapshot()
        let currentOriginY = coverage.currentOriginY
        let nearby = zip(snapshot.frames, snapshot.placements)
            .sorted {
                abs($0.1.originY - currentOriginY) < abs($1.1.originY - currentOriginY)
            }
            .prefix(4)
            .sorted { $0.1.originY < $1.1.originY }
        return (nearby.map(\.0), nearby.map(\.1))
    }

    nonisolated private static func makePreview(
        frames: [CGImage],
        placements: [StitchFramePlacement],
        confirmedTopHeight: Int,
        confirmedBottomHeight: Int,
        configuration: StitchConfiguration,
        direction: RollingScrollDirection?
    ) -> CGImage? {
        guard let first = frames.first else { return nil }
        let scale = min(1, 160 / CGFloat(first.width))
        let previewFrames = frames.compactMap { downscaled($0, scale: scale) }
        guard previewFrames.count == frames.count else { return nil }
        let previewPlacements = placements.map {
            StitchFramePlacement(originY: Int((CGFloat($0.originY) * scale).rounded()))
        }
        guard let image = try? StitchEngine.compose(
            frames: previewFrames,
            placements: previewPlacements,
            confirmedTopHeight: Int((CGFloat(confirmedTopHeight) * scale).rounded()),
            confirmedBottomHeight: Int((CGFloat(confirmedBottomHeight) * scale).rounded()),
            configuration: configuration
        ).get(),
        let cropRect = RollingPreviewViewport.cropRect(
            imageSize: CGSize(width: image.width, height: image.height),
            maximumHeight: 176,
            direction: direction
        ) else { return nil }
        return image.cropping(to: cropRect)
    }

    nonisolated private static func downscaled(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// 连续帧用于跟踪位移，只保留约半屏间距的关键帧用于最终合成，兼顾快速滚动与长图帧数上限。
    /// 与快照链失去重叠的帧不参与合成，避免长图上出现空白带；空白带判断
    /// 以“最后一个将进入快照的帧”（含桥接帧）为参照，而不是最近已存储帧，
    /// 否则快速滚动时一次大位移会让后续所有帧被永久丢弃。
    private func retainKeyframe(
        _ image: CGImage,
        contribution: StitchCoverageContribution,
        originY: Int,
        match: StitchMatch
    ) -> Bool {
        let spacing = max(image.height / 2, configuration.minimumShift)
        // 固定顶/底栏确认后会从合成时的每帧可用高度中扣除；链检查必须用同样的
        // 有效高度，否则极端间距下收尾合成会因帧间无重叠而失败。
        let effectiveHeight = max(
            image.height
                - max(confirmedTop, match.stationaryTopHeight)
                - max(confirmedBottom, match.stationaryBottomHeight),
            configuration.minimumShift
        )
        switch contribution {
        case .prepend:
            let minimumStoredOrigin = placements.map(\.originY).min() ?? 0
            let lastSnapshotOrigin = pendingTopFrame?.originY ?? minimumStoredOrigin
            guard !StitchKeyframePolicy.breaksSnapshotChain(
                gap: lastSnapshotOrigin - originY,
                frameHeight: effectiveHeight,
                minimumShift: configuration.minimumShift
            ) else { return false }
            switch StitchKeyframePolicy.decide(
                gap: minimumStoredOrigin - originY,
                spacing: spacing
            ) {
            case .bridge:
                pendingTopFrame = (image, originY)
            case .retain:
                if StitchKeyframePolicy.breaksSnapshotChain(
                    gap: minimumStoredOrigin - originY,
                    frameHeight: effectiveHeight,
                    minimumShift: configuration.minimumShift
                ), let pendingTopFrame {
                    frames.append(pendingTopFrame.image)
                    placements.append(StitchFramePlacement(originY: pendingTopFrame.originY))
                }
                frames.append(image)
                placements.append(StitchFramePlacement(originY: originY))
                pendingTopFrame = nil
            }
        case .append:
            let maximumStoredOrigin = placements.map(\.originY).max() ?? 0
            let lastSnapshotOrigin = pendingBottomFrame?.originY ?? maximumStoredOrigin
            guard !StitchKeyframePolicy.breaksSnapshotChain(
                gap: originY - lastSnapshotOrigin,
                frameHeight: effectiveHeight,
                minimumShift: configuration.minimumShift
            ) else { return false }
            switch StitchKeyframePolicy.decide(
                gap: originY - maximumStoredOrigin,
                spacing: spacing
            ) {
            case .bridge:
                pendingBottomFrame = (image, originY)
            case .retain:
                if StitchKeyframePolicy.breaksSnapshotChain(
                    gap: originY - maximumStoredOrigin,
                    frameHeight: effectiveHeight,
                    minimumShift: configuration.minimumShift
                ), let pendingBottomFrame {
                    frames.append(pendingBottomFrame.image)
                    placements.append(StitchFramePlacement(originY: pendingBottomFrame.originY))
                }
                frames.append(image)
                placements.append(StitchFramePlacement(originY: originY))
                pendingBottomFrame = nil
            }
        case .covered:
            break
        }
        return true
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

    private func pause(for failure: RollingCaptureFailure) {
        guard !didEnd else { return }
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

        let size = NSSize(width: 680, height: 220)
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
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label("手动滚动", systemImage: "rectangle.stack")
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
                Spacer()
                HStack(spacing: 8) {
                    if controller.state == .paused {
                        Button("重试") { controller.resume() }
                    }
                    Spacer()
                    Button("取消", role: .cancel) { controller.cancel() }
                    if controller.state == .capturing {
                        Button("停止并生成") { controller.stopManualRecording() }
                            .buttonStyle(.borderedProminent)
                    } else if controller.state == .paused {
                        Button("完成") { controller.finish() }
                            .buttonStyle(.borderedProminent)
                            .disabled(controller.frameCount == 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            RollingCapturePreviewView(controller: controller)
                .frame(width: 170, height: 196)
        }
        .padding(12)
        .frame(width: 680, height: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.2)))
    }
}

private struct RollingCapturePreviewView: View {
    @ObservedObject var controller: RollingCaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("最近拼接预览")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ZStack {
                if let image = controller.previewImage {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.12)))
        }
    }
}
