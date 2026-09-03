import AppKit
import CoreImage
import CoreGraphics
import CoreMedia
import CoreVideo
import FewerCore
import Foundation
import ScreenCaptureKit
import Security

/// 截屏捕获底层：屏幕录制权限、全屏/区域/窗口捕获、在屏窗口列表。
/// 注意坐标：CGWindowList* 使用全局屏幕坐标（原点左上）；NSEvent/NSScreen 使用 AppKit 坐标（原点左下）。
enum ScreenshotCapture {
    /// 一次滚动截图交付的帧，附带上一次交付以来被队列丢弃的旧帧数。
    /// 丢帧意味着相邻交付帧之间的真实位移被放大，位置连续性先验不可信。
    struct RollingCapturedFrame {
        let image: CGImage
        let droppedBefore: Int
    }

    enum RollingCaptureError: LocalizedError {
        case displayUnavailable
        case captureFailed
        case captureFinished

        var errorDescription: String? {
            switch self {
            case .displayUnavailable: "选区必须完整位于同一台显示器内"
            case .captureFailed: "无法读取滚动截图区域"
            case .captureFinished: "滚动截图录制已结束"
            }
        }
    }

    /// 连续读取 ScreenCaptureKit 帧；拼接计算期间仍保留桥接帧，避免快速滚动跨过可匹配重叠区。
    final class RollingRegionSession: @unchecked Sendable {
        private let stream: SCStream
        private let output: RollingStreamOutput
        private var started = false
        private var finished = false

        fileprivate init(
            filter: SCContentFilter,
            configuration: SCStreamConfiguration,
            cropRect: CGRect
        ) {
            output = RollingStreamOutput(cropRect: cropRect)
            stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        }

        func capture() async throws -> RollingCapturedFrame {
            if !started {
                guard !finished else {
                    return try await output.nextFrame()
                }
                try stream.addStreamOutput(
                    output,
                    type: .screen,
                    sampleHandlerQueue: output.queue
                )
                do {
                    try await stream.startCapture()
                    started = true
                } catch {
                    finished = true
                    output.finish(throwing: error)
                    throw error
                }
            }
            return try await output.nextFrame()
        }

        /// 停止接收新画面，但保留已经进入本地队列的帧，供拼接器按顺序排空。
        func finishProducing() async {
            guard !finished else { return }
            finished = true
            if started {
                started = false
                try? await stream.stopCapture()
            }
            output.finish(discardPendingFrames: false)
        }

        func stop() async {
            guard !finished else {
                output.finish()
                return
            }
            finished = true
            if started {
                started = false
                try? await stream.stopCapture()
            }
            output.finish()
        }
    }

    private final class RollingStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
        let queue = DispatchQueue(label: "com.number47.fewer.rolling-capture-frames", qos: .userInteractive)

        private let cropRect: CGRect
        private let context = CIContext(options: [.cacheIntermediates: false])
        private let lock = NSLock()
        private var frames = RollingFrameBuffer<CGImage>(capacity: 32)
        private var waiter: CheckedContinuation<RollingCapturedFrame, Error>?
        private var terminalError: Error?
        private var finished = false
        /// 自上一次交付以来因队列满而被丢弃的旧帧数。
        private var droppedSinceDelivery = 0

        init(cropRect: CGRect) {
            self.cropRect = cropRect
        }

        func nextFrame() async throws -> RollingCapturedFrame {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                defer { lock.unlock() }
                if let next = frames.removeNext() {
                    let dropped = droppedSinceDelivery
                    droppedSinceDelivery = 0
                    continuation.resume(returning: RollingCapturedFrame(image: next, droppedBefore: dropped))
                } else if let terminalError {
                    continuation.resume(throwing: terminalError)
                } else if finished {
                    continuation.resume(throwing: RollingCaptureError.captureFinished)
                } else {
                    waiter = continuation
                }
            }
        }

        func finish(
            throwing error: Error? = nil,
            discardPendingFrames: Bool = true
        ) {
            lock.lock()
            finished = true
            terminalError = error
            let waiter = waiter
            self.waiter = nil
            if discardPendingFrames {
                frames.removeAll()
            }
            lock.unlock()
            waiter?.resume(throwing: error ?? RollingCaptureError.captureFinished)
        }

        func stream(
            _ stream: SCStream,
            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
            of type: SCStreamOutputType
        ) {
            guard type == .screen,
                  sampleBuffer.isValid,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(
                    sampleBuffer,
                    createIfNecessary: false
                  ) as? [[SCStreamFrameInfo: Any]],
                  let statusRawValue = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: statusRawValue) == .complete,
                  let pixelBuffer = sampleBuffer.imageBuffer
            else { return }

            let fullImage = CIImage(cvPixelBuffer: pixelBuffer)
            let ciCropRect = CGRect(
                x: cropRect.minX,
                y: fullImage.extent.height - cropRect.maxY,
                width: cropRect.width,
                height: cropRect.height
            ).integral
            guard fullImage.extent.contains(ciCropRect),
                  let image = context.createCGImage(fullImage, from: ciCropRect)
            else { return }
            offer(image)
        }

        func stream(_ stream: SCStream, didStopWithError error: Error) {
            finish(throwing: error)
        }

        private func offer(_ image: CGImage) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            if let waiter {
                self.waiter = nil
                let dropped = droppedSinceDelivery
                droppedSinceDelivery = 0
                lock.unlock()
                waiter.resume(returning: RollingCapturedFrame(image: image, droppedBefore: dropped))
                return
            }
            if frames.count == frames.capacity {
                droppedSinceDelivery += 1
            }
            frames.append(image)
            lock.unlock()
        }
    }
    /// TCC 授权与代码签名身份绑定。请求记录也必须按身份隔离，不能让旧 ad-hoc
    /// 构建留下的标记阻止新签名构建发起自己的首次授权。
    private static var permissionRequestedKey: String {
        "fewer.screenCapturePermissionRequested.v2.\(codeSigningScope)"
    }

    private static let codeSigningScope: String = {
        var dynamicCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &dynamicCode) == errSecSuccess,
              let dynamicCode
        else { return "unknown" }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamicCode, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else { return "unknown" }

        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
              let information = signingInformation as? [CFString: Any]
        else { return "unknown" }

        let team = information[kSecCodeInfoTeamIdentifier] as? String ?? "adhoc"
        let identifier = information[kSecCodeInfoIdentifier] as? String
            ?? Bundle.main.bundleIdentifier
            ?? "unknown"
        return "\(team).\(identifier)"
    }()

    static var permissionIdentity: String { codeSigningScope }

    // MARK: - 权限

    /// 是否已获得屏幕录制权限（TCC）。无权限时所有捕获 API 返回 nil。
    static var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 是否已经向系统发起过权限请求。用于避免每次点击截图都重复弹出同一请求。
    static var permissionWasRequested: Bool {
        UserDefaults.standard.bool(forKey: permissionRequestedKey)
    }

    /// 请求屏幕录制权限。只允许触发一次系统请求；之后改为引导用户去系统设置，
    /// 避免权限状态短暂不同步时每次截图都重新触发系统提示。
    @discardableResult
    static func requestPermission() -> Bool {
        guard !permissionWasRequested else { return hasPermission }
        UserDefaults.standard.set(true, forKey: permissionRequestedKey)
        UserDefaults.standard.synchronize()
        return CGRequestScreenCaptureAccess()
    }

    /// 保留“已请求”标记。权限被撤销或开发构建身份变化时，也不应自动再次弹系统请求。
    static func reconcilePermissionState() {
        _ = hasPermission
    }

    @MainActor
    static func openPermissionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    /// macOS 的屏幕录制授权通常需要重启当前进程才会对捕获 API 生效。
    @MainActor
    static func restartApplication() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, error in
            guard error == nil else { return }
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - 捕获

    /// 鼠标所在屏幕的全屏图像。
    static func fullscreenImage() async throws -> CGImage {
        guard let displayID = displayIDUnderMouse() else {
            throw RollingCaptureError.displayUnavailable
        }
        return try await fullscreenImage(displayID: displayID)
    }

    /// 使用 ScreenCaptureKit 按指定显示器的物理像素尺寸捕获全屏图像。
    static func fullscreenImage(displayID: CGDirectDisplayID) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw RollingCaptureError.displayUnavailable
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let outputSize = ScreenshotPixelGeometry.outputSize(
            pointSize: display.frame.size,
            pointPixelScale: CGFloat(filter.pointPixelScale)
        )
        let configuration = SCStreamConfiguration()
        configuration.width = Int(outputSize.width)
        configuration.height = Int(outputSize.height)
        configuration.captureResolution = .best
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.capturesAudio = false
        guard let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        ) as CGImage? else {
            throw RollingCaptureError.captureFailed
        }
        return image
    }

    /// 使用 ScreenCaptureKit 按窗口所在屏幕的物理像素尺寸捕获，避免旧 API 返回低分辨率图像。
    static func windowImage(windowID: CGWindowID) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw RollingCaptureError.captureFailed
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        // 过滤器自带窗口所在屏幕的点到像素比例，比手动匹配显示器更可靠。
        let scale = CGFloat(filter.pointPixelScale)
        let outputSize = ScreenshotPixelGeometry.outputSize(
            pointSize: window.frame.size,
            pointPixelScale: scale
        )
        let configuration = SCStreamConfiguration()
        configuration.width = Int(outputSize.width)
        configuration.height = Int(outputSize.height)
        configuration.captureResolution = .best
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        guard let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        ) as CGImage? else {
            throw RollingCaptureError.captureFailed
        }
        return image
    }

    /// 使用 ScreenCaptureKit 捕获滚动截图选区，并排除 Fewer 自身的 HUD/边框窗口。
    static func rollingRegionImage(_ cgRect: CGRect) async throws -> CGImage {
        try await rollingRegionSession(cgRect).capture().image
    }

    static func rollingRegionSession(_ cgRect: CGRect) async throws -> RollingRegionSession {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.frame.contains(cgRect) }) else {
            throw RollingCaptureError.displayUnavailable
        }
        let ownApplications = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplications,
            exceptingWindows: []
        )
        // 使用 ScreenCaptureKit 自己的点像素比例，避免 NSScreen 映射失败时退化成 1x。
        let scale = CGFloat(filter.pointPixelScale)
        // SCK 的 sourceRect（点）与输出宽高（像素）不严格 1:1 时会在流内重采样，
        // 画面发虚。先把选区对齐到整点，再按整点尺寸乘点像素比取整输出，
        // 保证缩放恒为 1，滚动长图的每一帧都保持原始清晰度。
        let alignedRect = cgRect.integral.intersection(display.frame)
        guard alignedRect.width > 0, alignedRect.height > 0 else {
            throw RollingCaptureError.displayUnavailable
        }
        let outputSize = ScreenshotPixelGeometry.outputSize(
            pointSize: alignedRect.size,
            pointPixelScale: scale
        )
        let configuration = SCStreamConfiguration()
        // 连续流直接在 WindowServer 端裁剪，避免 60 fps 整屏 Retina 帧在传输后才裁剪而丢帧。
        // 输出尺寸与选区物理像素严格一致，不发生缩放，保留原始清晰度。
        configuration.sourceRect = CGRect(
            x: alignedRect.minX - display.frame.minX,
            y: alignedRect.minY - display.frame.minY,
            width: alignedRect.width,
            height: alignedRect.height
        )
        configuration.width = Int(outputSize.width)
        configuration.height = Int(outputSize.height)
        configuration.captureResolution = .best
        configuration.scalesToFit = false
        configuration.preservesAspectRatio = true
        configuration.showsCursor = false
        configuration.capturesAudio = false
        // 30 fps 足以保留快速滚动的桥接画面，同时避免拼接计算长期落后于 60 fps 输入。
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        // 拼接分析期间回调仍以 30 fps 入帧，内部缓冲过小会在回调稍慢时丢帧，
        // 放大相邻被分析帧之间的滚动位移；加大缓冲保留更多桥接帧。
        configuration.queueDepth = 16
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        let cropRect = CGRect(origin: .zero, size: outputSize)
        return RollingRegionSession(filter: filter, configuration: configuration, cropRect: cropRect)
    }

    // MARK: - 窗口信息

    struct WindowInfo {
        let id: CGWindowID
        let ownerPID: pid_t
        /// 全局屏幕坐标（原点左上）。
        let bounds: CGRect
        let title: String
        let ownerName: String
    }

    /// 鼠标下的屏幕 display ID。
    static func displayIDUnderMouse() -> CGDirectDisplayID? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) else {
            return NSScreen.main.flatMap { displayID(for: $0) }
        }
        return displayID(for: screen)
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// 所有在屏窗口（排除桌面/菜单栏/自己），按 z-order 从顶到底。
    static func onScreenWindows(excludingOwnProcess: Bool = true) -> [WindowInfo] {
        let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        var windows: [WindowInfo] = []
        for dict in list {
            let layer = dict[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }
            if excludingOwnProcess,
               let pid = dict[kCGWindowOwnerPID as String] as? Int32,
               pid == ProcessInfo.processInfo.processIdentifier {
                continue
            }
            guard let id = dict[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat],
                  (boundsDict["Width"] ?? 0) > 4,
                  (boundsDict["Height"] ?? 0) > 4
            else { continue }

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            windows.append(WindowInfo(
                id: id,
                ownerPID: dict[kCGWindowOwnerPID as String] as? pid_t ?? 0,
                bounds: bounds,
                title: dict[kCGWindowName as String] as? String ?? "",
                ownerName: dict[kCGWindowOwnerName as String] as? String ?? ""
            ))
        }
        return windows
    }

    static func runningApplication(at point: CGPoint) -> NSRunningApplication? {
        guard let window = onScreenWindows().first(where: { $0.bounds.contains(point) }),
              window.ownerPID > 0
        else { return nil }
        return NSRunningApplication(processIdentifier: window.ownerPID)
    }
}
