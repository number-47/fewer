import AppKit
import FewerCore
import SwiftUI

/// 截屏流程协调器：模式分发、遮罩窗口生命周期、截图后动作。
@MainActor
final class ScreenshotService: CaptureOverlayDelegate {
    static let shared = ScreenshotService()

    private var overlayWindow: NSWindow?
    private var rollingController: RollingCaptureController?
    private var captureTargetApplication: NSRunningApplication?
    private(set) var currentMode: ScreenshotMode?
    private var didShowPermissionRecoveryThisLaunch = false
    private var captureSessions = ScreenshotCaptureSessionGate()
    private let ocrCoordinator = OCRTranslationCoordinator.shared

    private init() {}

    /// 进入指定截屏模式。全屏直接捕获；区域/窗口显示遮罩。
    func begin(_ mode: ScreenshotMode) {
        begin(ScreenshotCaptureIntent(mode: mode))
    }

    func beginOCRTranslation() {
        // OCR 是可替换的请求：新请求必须立即使旧 OCR/译文与选择遮罩失效。
        // 不能等待新 session 成功创建，否则快速连续触发会让旧结果重新出现。
        ocrCoordinator.cancel()
        if captureSessions.hasActiveSession {
            captureSessions.cancel()
            currentMode = nil
            dismissOverlay()
            setKeycastSuppressed(false)
        }
        begin(.ocrTranslation)
    }

    /// OCR 通过独立 purpose 复用截图交互，不改变既有 ScreenshotMode。
    func begin(_ intent: ScreenshotCaptureIntent) {
        Self.debugLog(
            "begin mode=\(intent.mode) hasPermission=\(ScreenshotCapture.hasPermission) "
                + "requested=\(ScreenshotCapture.permissionWasRequested) "
                + "identity=\(ScreenshotCapture.permissionIdentity)"
        )
        guard !captureSessions.hasActiveSession else { return }
        guard ScreenshotCapture.hasPermission || debugIgnorePermission else {
            if ScreenshotCapture.permissionWasRequested {
                showPermissionRecoveryOnce()
            } else {
                let granted = ScreenshotCapture.requestPermission()
                if granted, ScreenshotCapture.hasPermission {
                    begin(intent)
                }
            }
            return
        }
        guard let captureID = captureSessions.begin() else { return }
        setKeycastSuppressed(true)
        // 上一张结果窗口不能继续留在屏幕上，否则新的区域/全屏截图会再次截到旧图。
        ScreenshotResultWindowController.shared.close()
        ocrCoordinator.cancel()
        currentMode = intent.mode
        captureTargetApplication = NSWorkspace.shared.frontmostApplication
        switch intent.mode {
        case .fullscreen:
            // 等旧结果窗口从 WindowServer 合成画面中消失后再读取当前屏幕。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self, self.captureSessions.isActive(captureID) else { return }
                self.captureFullscreen(captureID: captureID)
            }
        case .region, .smart, .window:
            showOverlay(intent: intent)
        }
    }

    // MARK: - 全屏

    private func captureFullscreen(captureID: UInt64) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let screen,
              let displayID = ScreenshotCapture.displayID(for: screen)
        else {
            captureFailed(message: "无法读取当前屏幕，请检查屏幕录制权限后重试。")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let image = try await ScreenshotCapture.fullscreenImage(displayID: displayID)
                guard self.captureSessions.isActive(captureID) else { return }
                self.finish(with: image, pointSize: screen.frame.size, captureID: captureID)
            } catch {
                guard self.captureSessions.isActive(captureID) else { return }
                self.captureFailed(message: "无法读取当前屏幕，请检查屏幕录制权限后重试。")
            }
        }
    }

    // MARK: - 遮罩

    private func showOverlay(intent: ScreenshotCaptureIntent) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let screen else {
            cancel()
            return
        }

        let window = CaptureOverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        // 手动管理窗口生命周期，避免 close() 立即释放带来的悬垂时序
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("screenshot-overlay")

        let view = CaptureOverlayView(
            intent: intent,
            rollingCaptureEnabled: intent.purpose == .screenshot
                && ScreenshotSettingsStore().load().rollingCaptureEnabled,
            screenFrame: screen.frame,
            delegate: self
        )
        window.contentViewController = NSHostingController(rootView: view)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        overlayWindow = window
    }

    // MARK: - CaptureOverlayDelegate

    func overlayDidStartRollingCapture(_ cgRect: CGRect) {
        guard let captureID = captureSessions.activeID else { return }
        Self.debugLog("rolling selected rect=\(cgRect)")
        dismissOverlay()
        let controller = RollingCaptureController()
        rollingController = controller
        let target = ScreenshotCapture.runningApplication(at: CGPoint(x: cgRect.midX, y: cgRect.midY))
            ?? captureTargetApplication
        controller.start(
            rect: cgRect,
            targetApplication: target,
            completion: { [weak self, weak controller] image in
                guard let self, self.rollingController === controller else { return }
                self.rollingController = nil
                let scale = max(CGFloat(image.width) / max(cgRect.width, 1), 1)
                let pointSize = CGSize(
                    width: CGFloat(image.width) / scale,
                    height: CGFloat(image.height) / scale
                )
                self.finish(with: image, pointSize: pointSize, captureID: captureID)
            },
            cancellation: { [weak self, weak controller] in
                guard let self, self.rollingController === controller else { return }
                self.rollingController = nil
                self.captureSessions.cancel()
                self.currentMode = nil
                self.setKeycastSuppressed(false)
            }
        )
    }

    func overlayDidFinishEditing() {
        guard let captureID = captureSessions.activeID,
              captureSessions.complete(captureID)
        else { return }
        currentMode = nil
        dismissOverlay()
        setKeycastSuppressed(false)
    }

    func overlayDidPin(_ pngData: Data) {
        guard let captureID = captureSessions.activeID,
              captureSessions.complete(captureID)
        else { return }
        currentMode = nil
        dismissOverlay()
        setKeycastSuppressed(false)
        PinWindowController.shared.pin(pngData: pngData)
    }

    func overlayDidCancel() {
        cancel()
    }

    func overlayDidSelectOCRRegion(_ cgRect: CGRect) {
        guard let captureID = captureSessions.activeID else { return }
        ocrCoordinator.start()
        let selection = Self.appKitRect(fromCaptureRect: cgRect)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(selection) }) ?? NSScreen.main
        dismissOverlay()
        // 先让遮罩窗口从 WindowServer 合成画面移除，再读取原始区域图像。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, self.captureSessions.isActive(captureID) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let capturedImage = try await ScreenshotCapture.rollingRegionImage(cgRect)
                    guard self.captureSessions.complete(captureID) else { return }
                    self.currentMode = nil
                    self.setKeycastSuppressed(false)
                    guard let image = OCRCaptureImageBudget.downsampled(capturedImage) else {
                        self.ocrCoordinator.cancel()
                        OCRTranslationWindowController.shared.showFeedback("截图失败", near: selection, on: screen)
                        return
                    }
                    self.ocrCoordinator.recognize(image: image, selection: selection, on: screen)
                } catch {
                    guard self.captureSessions.complete(captureID) else { return }
                    self.currentMode = nil
                    self.setKeycastSuppressed(false)
                    self.ocrCoordinator.cancel()
                    OCRTranslationWindowController.shared.showFeedback("截图失败", near: selection, on: screen)
                }
            }
        }
    }

    // MARK: - 完成/取消

    private func finish(with image: CGImage, pointSize: CGSize? = nil, captureID: UInt64) {
        guard captureSessions.complete(captureID) else { return }
        Self.debugLog("finish")
        currentMode = nil
        setKeycastSuppressed(false)
        guard let pngData = Self.pngData(from: image, pointSize: pointSize) else {
            captureFailed(message: "截图编码失败，请重试。")
            return
        }
        if ScreenshotSettingsStore().load().afterAction == .pin {
            PinWindowController.shared.pin(pngData: pngData)
            return
        }
        Self.debugLog("showing result actions")
        ScreenshotResultWindowController.shared.show(pngData: pngData)
    }

    func cancel() {
        if let rollingController {
            rollingController.cancel()
            return
        }
        captureSessions.cancel()
        ocrCoordinator.cancel()
        currentMode = nil
        dismissOverlay()
        setKeycastSuppressed(false)
    }

    private func dismissOverlay() {
        overlayWindow?.contentViewController = nil
        overlayWindow?.close()
        overlayWindow = nil
    }

    private func captureFailed(message: String) {
        captureSessions.cancel()
        currentMode = nil
        dismissOverlay()
        setKeycastSuppressed(false)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "截图失败"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func showPermissionRecovery() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "屏幕录制权限尚未生效"
        alert.informativeText = "如果系统设置中已经允许 Fewer，但这里仍显示未授权，请先关闭 Fewer 的开关，再重新打开，然后重新启动应用。这样可以清除旧签名版本遗留的授权记录。"
        alert.addButton(withTitle: "重新启动 Fewer")
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            ScreenshotCapture.restartApplication()
        case .alertSecondButtonReturn:
            ScreenshotCapture.openPermissionSettings()
        default:
            break
        }
    }

    private func setKeycastSuppressed(_ suppressed: Bool) {
        DistributedNotificationCenter.default().postNotificationName(
            AppGroupConstants.inputEnhancementControlNotification,
            object: nil,
            userInfo: ["command": "screenshot-active", "enabled": suppressed],
            deliverImmediately: true
        )
    }

    private func showPermissionRecoveryOnce() {
        guard !didShowPermissionRecoveryThisLaunch else { return }
        didShowPermissionRecoveryThisLaunch = true
        showPermissionRecovery()
    }

    // MARK: - 工具

    static func pngData(from image: CGImage, pointSize: CGSize? = nil) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        if let pointSize, pointSize.width > 0, pointSize.height > 0 {
            rep.size = pointSize
        }
        return rep.representation(using: .png, properties: [:])
    }

    /// CaptureOverlay 的选区使用全局左上原点；窗口定位使用 AppKit 左下原点。
    private static func appKitRect(fromCaptureRect rect: CGRect) -> CGRect {
        let top = NSScreen.screens.map(\.frame.maxY).max() ?? rect.maxY
        return CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
    }

    /// 沙盒调试：无屏幕录制权限时用合成图像走完流程（仅验证用）。
    private var debugIgnorePermission: Bool {
        UserDefaults.standard.bool(forKey: "fewer.debug.ignoreScreenPermission")
    }

    static func debugPlaceholderImage(size: CGSize) -> CGImage? {
        let width = max(Int(size.width), 1)
        let height = max(Int(size.height), 1)
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            let bytes = base.bindMemory(to: UInt8.self, capacity: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    bytes[i] = UInt8(60 + x * 137 / max(width, 1))     // R
                    bytes[i + 1] = UInt8(120 + y * 89 / max(height, 1)) // G
                    bytes[i + 2] = 200                                  // B
                    bytes[i + 3] = 255
                }
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            return context?.makeImage()
        }
    }

    private static func debugLog(_ message: String) {
        let line = "\(Date()) [ScreenshotService] \(message)\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fewer-hotkey.log")
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                try? handle.close()
            }
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// 截屏遮罩窗口：borderless 但可成为 key window（接收键盘事件，如 Esc 取消）。
@MainActor
final class CaptureOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
