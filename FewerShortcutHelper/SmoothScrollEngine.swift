import AppKit
import FewerCore
import QuartzCore

@MainActor
final class SmoothScrollEngine: NSObject {
    var activityChanged: ((Bool) -> Void)?
    private let isGenerationCurrent: (UInt64) -> Bool
    private var displayLink: CADisplayLink?
    private var verticalRemaining = 0.0
    private var horizontalRemaining = 0.0
    private var lastTimestamp: CFTimeInterval?
    private var verticalResponse = 0.18
    private var horizontalResponse = 0.18
    private var simulatesTrackpad = false
    private var phaseStarted = false
    private var momentumStarted = false
    private var activeGeneration: UInt64?
    private(set) var isActive = false

    init(isGenerationCurrent: @escaping (UInt64) -> Bool) {
        self.isGenerationCurrent = isGenerationCurrent
        super.init()
    }

    func enqueue(
        vertical: Double,
        horizontal: Double,
        settings: ScrollEnhancementSettings,
        displayID: CGDirectDisplayID?,
        generation: UInt64
    ) {
        guard isGenerationCurrent(generation) else { return }
        if activeGeneration != generation || (settings.simulatesTrackpad && isActive) {
            cancel()
        }
        verticalResponse = settings.vertical.response
        horizontalResponse = settings.horizontal.response
        simulatesTrackpad = settings.simulatesTrackpad
        if vertical != 0, verticalRemaining != 0, vertical.sign != verticalRemaining.sign {
            verticalRemaining = 0
        }
        if horizontal != 0, horizontalRemaining != 0, horizontal.sign != horizontalRemaining.sign {
            horizontalRemaining = 0
        }

        if settings.vertical.smoothEnabled {
            verticalRemaining += vertical
        } else if vertical != 0 {
            post(vertical: vertical, horizontal: 0, phase: nil)
        }
        if settings.horizontal.smoothEnabled {
            horizontalRemaining += horizontal
        } else if horizontal != 0 {
            post(vertical: 0, horizontal: horizontal, phase: nil)
        }
        guard abs(verticalRemaining) >= 0.5 || abs(horizontalRemaining) >= 0.5 else { return }
        activeGeneration = generation
        let screen: NSScreen?
        if let displayID {
            screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                    == displayID
            }
        } else {
            screen = NSScreen.main
        }
        startDisplayLink(on: screen ?? NSScreen.main)
    }

    func cancel() {
        let wasActive = isActive
        if phaseStarted {
            if momentumStarted {
                post(vertical: 0, horizontal: 0, phase: nil, momentumPhase: .ended)
            } else {
                post(vertical: 0, horizontal: 0, phase: .ended)
            }
        }
        displayLink?.invalidate()
        displayLink = nil
        verticalRemaining = 0
        horizontalRemaining = 0
        lastTimestamp = nil
        phaseStarted = false
        momentumStarted = false
        activeGeneration = nil
        isActive = false
        if wasActive { activityChanged?(false) }
    }

    private func startDisplayLink(on screen: NSScreen?) {
        guard displayLink == nil, let screen else { return }
        let link = screen.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        isActive = true
        activityChanged?(true)
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let activeGeneration, isGenerationCurrent(activeGeneration) else {
            cancel()
            return
        }
        let timestamp = link.timestamp
        let deltaTime = min(max(timestamp - (lastTimestamp ?? timestamp - link.duration), 1.0 / 240.0), 0.05)
        lastTimestamp = timestamp
        let vertical = ScrollDecayModel.consumableAmount(
            from: &verticalRemaining,
            deltaTime: deltaTime,
            response: verticalResponse
        )
        let horizontal = ScrollDecayModel.consumableAmount(
            from: &horizontalRemaining,
            deltaTime: deltaTime,
            response: horizontalResponse
        )

        if vertical != 0 || horizontal != 0 {
            if simulatesTrackpad, !phaseStarted {
                phaseStarted = true
                post(vertical: vertical, horizontal: horizontal, phase: .began)
            } else if simulatesTrackpad, !momentumStarted {
                post(vertical: 0, horizontal: 0, phase: .ended)
                momentumStarted = true
                post(vertical: vertical, horizontal: horizontal, phase: nil, momentumPhase: .began)
            } else {
                post(
                    vertical: vertical,
                    horizontal: horizontal,
                    phase: nil,
                    momentumPhase: simulatesTrackpad ? .changed : nil
                )
            }
        }
        if abs(verticalRemaining) < 0.5, abs(horizontalRemaining) < 0.5 {
            cancel()
        }
    }

    private func post(
        vertical: Double,
        horizontal: Double,
        phase: CGScrollPhase?,
        momentumPhase: CGScrollPhase? = nil
    ) {
        let spec = SyntheticScrollEventSpecFactory.make(
            vertical: vertical,
            horizontal: horizontal,
            simulatesTrackpad: simulatesTrackpad,
            scrollPhase: phase.map { Int($0.rawValue) },
            momentumPhase: momentumPhase.map { Int($0.rawValue) }
        )
        let source = CGEventSource(stateID: .hidSystemState)
        let units: CGScrollEventUnit = spec.units == .pixel ? .pixel : .line
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: units,
            wheelCount: 2,
            wheel1: spec.verticalDelta,
            wheel2: spec.horizontalDelta,
            wheel3: 0
        ) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: syntheticInputEventMarker)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: spec.isContinuous ? 1 : 0)
        if let scrollPhase = spec.scrollPhase {
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(scrollPhase))
        }
        if let momentumPhase = spec.momentumPhase {
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentumPhase))
        }
        event.post(tap: .cghidEventTap)
    }
}
