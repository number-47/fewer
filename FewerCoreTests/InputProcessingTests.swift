import Foundation
import XCTest
@testable import FewerCore

final class InputProcessingTests: XCTestCase {
    func testTrackpadEventPassesThroughUnchanged() {
        let event = ScrollEventSnapshot(
            isContinuous: true,
            scrollPhase: 1,
            momentumPhase: 0,
            verticalDelta: 4,
            horizontalDelta: -2
        )
        var settings = ScrollEnhancementSettings(isEnabled: true)
        settings.vertical.reversed = true

        let result = ScrollEventProcessor.process(event, settings: settings)

        XCTAssertEqual(result.device, .trackpad)
        XCTAssertEqual(result.verticalDelta, 4)
        XCTAssertEqual(result.horizontalDelta, -2)
        XCTAssertFalse(result.shouldConsumeOriginal)
    }

    func testMouseAxesReverseAndNormalizeIndependently() {
        let event = ScrollEventSnapshot(
            isContinuous: false,
            scrollPhase: 0,
            momentumPhase: 0,
            verticalDelta: 1,
            horizontalDelta: -2
        )
        var settings = ScrollEnhancementSettings(
            isEnabled: true,
            minimumStep: 3,
            speedGain: 2
        )
        settings.vertical.reversed = true
        settings.horizontal.reversed = false

        let result = ScrollEventProcessor.process(event, settings: settings)

        XCTAssertEqual(result.device, .mouse)
        XCTAssertEqual(result.verticalDelta, -6)
        XCTAssertEqual(result.horizontalDelta, -6)
        XCTAssertTrue(result.shouldConsumeOriginal)
    }

    func testReversalConsumesOriginalWithoutSmoothing() {
        let event = ScrollEventSnapshot(
            isContinuous: false,
            scrollPhase: 0,
            momentumPhase: 0,
            verticalDelta: 3,
            horizontalDelta: 0
        )
        var settings = ScrollEnhancementSettings(isEnabled: true)
        settings.vertical.smoothEnabled = false
        settings.horizontal.smoothEnabled = false
        settings.vertical.reversed = true

        let result = ScrollEventProcessor.process(event, settings: settings)

        XCTAssertEqual(result.verticalDelta, -3)
        XCTAssertTrue(result.shouldConsumeOriginal)
    }

    func testMouseAxesUseIndependentStepAndGain() {
        let event = ScrollEventSnapshot(
            isContinuous: false,
            scrollPhase: 0,
            momentumPhase: 0,
            verticalDelta: 1,
            horizontalDelta: 1
        )
        var settings = ScrollEnhancementSettings(isEnabled: true)
        settings.vertical.minimumStep = 2
        settings.vertical.speedGain = 2
        settings.horizontal.minimumStep = 5
        settings.horizontal.speedGain = 3

        let result = ScrollEventProcessor.process(event, settings: settings)

        XCTAssertEqual(result.verticalDelta, 4)
        XCTAssertEqual(result.horizontalDelta, 15)
    }

    func testScrollDeltaReaderPrefersUnambiguousPixelPointDelta() {
        // The point (pixel) delta is preferred even when a fixed-pt value is present,
        // because the fixed-pt field can be line-based (1.0 per notch) on some mice.
        XCTAssertEqual(ScrollDeltaReader.pixelDelta(fixedPtDelta: 1, pointDelta: 40, lineDelta: 1), 40)
        XCTAssertEqual(ScrollDeltaReader.pixelDelta(fixedPtDelta: -1, pointDelta: -40, lineDelta: -1), -40)
        // Falls back to fixed-pt when no point delta is available.
        XCTAssertEqual(ScrollDeltaReader.pixelDelta(fixedPtDelta: 10, pointDelta: 0, lineDelta: 1), 10)
        // Falls back to line delta only as a last resort.
        XCTAssertEqual(ScrollDeltaReader.pixelDelta(fixedPtDelta: 0, pointDelta: 0, lineDelta: 3), 3)
        XCTAssertEqual(ScrollDeltaReader.pixelDelta(fixedPtDelta: 0, pointDelta: 0, lineDelta: 0), 0)
    }

    func testScrollDecayIsRefreshRateIndependent() {
        func simulate(frameRate: Double) -> Double {
            var remaining = 120.0
            for _ in 0..<Int(frameRate) {
                remaining -= ScrollDecayModel.displacement(
                    remaining: remaining,
                    deltaTime: 1 / frameRate,
                    response: 0.18
                )
            }
            return remaining
        }

        XCTAssertEqual(simulate(frameRate: 60), simulate(frameRate: 120), accuracy: 0.000_001)
    }

    func testSyntheticScrollUsesDiscreteLineEventsWithoutTrackpadSimulation() {
        let spec = SyntheticScrollEventSpecFactory.make(
            vertical: -3,
            horizontal: 2,
            simulatesTrackpad: false,
            scrollPhase: 1,
            momentumPhase: 4
        )

        XCTAssertEqual(spec.units, .line)
        XCTAssertFalse(spec.isContinuous)
        XCTAssertNil(spec.scrollPhase)
        XCTAssertNil(spec.momentumPhase)
        XCTAssertEqual(spec.verticalDelta, -3)
        XCTAssertEqual(spec.horizontalDelta, 2)
    }

    func testSyntheticScrollUsesPrecisePixelEventsWithTrackpadSimulation() {
        let spec = SyntheticScrollEventSpecFactory.make(
            vertical: -3,
            horizontal: 2,
            simulatesTrackpad: true,
            scrollPhase: 1,
            momentumPhase: 4
        )

        XCTAssertEqual(spec.units, .pixel)
        XCTAssertTrue(spec.isContinuous)
        XCTAssertEqual(spec.scrollPhase, 1)
        XCTAssertEqual(spec.momentumPhase, 4)
        XCTAssertEqual(spec.verticalDelta, -3)
        XCTAssertEqual(spec.horizontalDelta, 2)
    }

    func testEventTapCircuitBreakerFusesAfterThreeRecentFailures() {
        var breaker = EventTapCircuitBreaker(maximumFailures: 3, window: 10)
        let start = Date(timeIntervalSince1970: 100)

        XCTAssertFalse(breaker.recordFailure(at: start))
        XCTAssertFalse(breaker.recordFailure(at: start.addingTimeInterval(2)))
        XCTAssertTrue(breaker.recordFailure(at: start.addingTimeInterval(4)))
        breaker.reset()
        XCTAssertFalse(breaker.recordFailure(at: start.addingTimeInterval(20)))
    }

    func testSyntheticInputEventFilterOnlyMatchesMarker() {
        XCTAssertTrue(SyntheticInputEventFilter.shouldIgnore(userData: 47, marker: 47))
        XCTAssertFalse(SyntheticInputEventFilter.shouldIgnore(userData: 0, marker: 47))
    }

    func testGlobalToggleShortcutRejectsUnsafeAndReservedCombinations() {
        XCTAssertFalse(InputShortcutSafety.isAllowedGlobalToggle(InputShortcut(
            keyCode: 7,
            modifiers: [.command, .shift]
        )))
        XCTAssertFalse(InputShortcutSafety.isAllowedGlobalToggle(InputShortcut(
            keyCode: 53,
            modifiers: [.control, .option, .command]
        )))
        XCTAssertTrue(InputShortcutSafety.isAllowedGlobalToggle(InputShortcut(
            keyCode: 40,
            modifiers: [.control, .option]
        )))
    }

    func testPerApplicationBypassAndOverride() {
        var overrideSettings = ScrollEnhancementSettings(isEnabled: true)
        overrideSettings.vertical.speedGain = 3
        overrideSettings.horizontal.speedGain = 3
        let settings = InputEnhancementSettings(
            scroll: ScrollEnhancementSettings(isEnabled: true),
            applicationOverrides: [
                ApplicationScrollOverride(
                    bundleIdentifier: "com.example.bypass",
                    displayName: "Bypass",
                    mode: .bypass
                ),
                ApplicationScrollOverride(
                    bundleIdentifier: "com.example.override",
                    displayName: "Override",
                    mode: .override,
                    settings: overrideSettings
                ),
            ]
        )

        XCTAssertNil(settings.resolvedScrollSettings(for: "com.example.bypass"))
        XCTAssertEqual(
            settings.resolvedScrollSettings(for: "com.example.override")?.vertical.speedGain,
            3
        )
        XCTAssertEqual(settings.resolvedScrollSettings(for: "com.example.other")?.vertical.speedGain, 1)
    }

    func testGestureRecognizerCompressesDirectionsAndPrefersAppRule() {
        var recognizer = MouseGestureRecognizer(minimumSegmentLength: 10)
        recognizer.begin(at: GesturePoint(x: 0, y: 0))
        XCTAssertEqual(recognizer.append(GesturePoint(x: 20, y: 1)), .right)
        XCTAssertNil(recognizer.append(GesturePoint(x: 40, y: 2)))
        XCTAssertEqual(recognizer.append(GesturePoint(x: 40, y: 20)), .up)

        let global = MouseGestureRule(
            triggerButton: 2,
            directions: [.right, .up],
            action: .mouseForward
        )
        let app = MouseGestureRule(
            triggerButton: 2,
            directions: [.right, .up],
            action: .showDesktop,
            bundleIdentifier: "com.example.app"
        )

        XCTAssertEqual(
            recognizer.matchingRule(
                in: [global, app],
                triggerButton: 2,
                bundleIdentifier: "com.example.app"
            )?.id,
            app.id
        )
    }

    func testGestureShortClickAndJitterDoNotProduceDirections() {
        var recognizer = MouseGestureRecognizer(minimumSegmentLength: 10)
        recognizer.begin(at: GesturePoint(x: 100, y: 100))

        XCTAssertNil(recognizer.append(GesturePoint(x: 104, y: 103)))
        XCTAssertNil(recognizer.append(GesturePoint(x: 98, y: 96)))
        XCTAssertTrue(recognizer.directions.isEmpty)
        XCTAssertNil(recognizer.matchingRule(in: [], triggerButton: 1, bundleIdentifier: nil))
    }

    func testGestureStopsAtEightDirections() {
        var recognizer = MouseGestureRecognizer(minimumSegmentLength: 10)
        recognizer.begin(at: GesturePoint(x: 0, y: 0))
        _ = recognizer.append(GesturePoint(x: 20, y: 0))
        _ = recognizer.append(GesturePoint(x: 20, y: 20))
        _ = recognizer.append(GesturePoint(x: 0, y: 20))
        _ = recognizer.append(GesturePoint(x: 0, y: 0))
        _ = recognizer.append(GesturePoint(x: 20, y: 0))
        _ = recognizer.append(GesturePoint(x: 20, y: 20))
        _ = recognizer.append(GesturePoint(x: 0, y: 20))
        _ = recognizer.append(GesturePoint(x: 0, y: 0))

        XCTAssertNil(recognizer.append(GesturePoint(x: 20, y: 0)))
        XCTAssertEqual(recognizer.directions, [
            .right, .up, .left, .down, .right, .up, .left, .down,
        ])
    }

    func testGestureRecognizesEightSectors() {
        func point(angleDegrees: Double, radius: Double = 20) -> GesturePoint {
            let radians = angleDegrees * .pi / 180
            return GesturePoint(x: cos(radians) * radius, y: sin(radians) * radius)
        }
        func recognized(_ angle: Double) -> MouseGestureDirection? {
            var recognizer = MouseGestureRecognizer(minimumSegmentLength: 10)
            recognizer.begin(at: GesturePoint(x: 0, y: 0))
            return recognizer.append(point(angleDegrees: angle))
        }

        XCTAssertEqual(recognized(0), .right)
        XCTAssertEqual(recognized(30), .upRight)
        XCTAssertEqual(recognized(60), .upRight)
        XCTAssertEqual(recognized(90), .up)
        XCTAssertEqual(recognized(120), .upLeft)
        XCTAssertEqual(recognized(150), .upLeft)
        XCTAssertEqual(recognized(180), .left)
        XCTAssertEqual(recognized(-150), .downLeft)
        XCTAssertEqual(recognized(-120), .downLeft)
        XCTAssertEqual(recognized(-90), .down)
        XCTAssertEqual(recognized(-60), .downRight)
        XCTAssertEqual(recognized(-30), .downRight)
    }

    func testGestureRuleMatchesDiagonalDirection() {
        var recognizer = MouseGestureRecognizer(minimumSegmentLength: 10)
        recognizer.begin(at: GesturePoint(x: 0, y: 0))
        XCTAssertEqual(recognizer.append(GesturePoint(x: 20, y: -20)), .downRight)

        let rule = MouseGestureRule(
            triggerButton: 1,
            directions: [.downRight],
            action: .closeTab
        )
        XCTAssertEqual(
            recognizer.matchingRule(in: [rule], triggerButton: 1, bundleIdentifier: nil)?.action,
            .closeTab
        )
    }

    func testGestureSessionCancelsOnApplicationSwitchOrTimeout() {
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(MouseGestureSessionPolicy.cancellationReason(
            startedAt: start,
            now: start,
            startedBundleIdentifier: "com.example.one",
            currentBundleIdentifier: "com.example.two"
        ), .applicationChanged)
        XCTAssertEqual(MouseGestureSessionPolicy.cancellationReason(
            startedAt: start,
            now: start.addingTimeInterval(3.1),
            startedBundleIdentifier: "com.example.one",
            currentBundleIdentifier: "com.example.one"
        ), .timedOut)
        XCTAssertNil(MouseGestureSessionPolicy.cancellationReason(
            startedAt: start,
            now: start.addingTimeInterval(2.9),
            startedBundleIdentifier: "com.example.one",
            currentBundleIdentifier: "com.example.one"
        ))
    }

    func testGestureClickToleranceUsesActualDistanceAndKeepsFourPointsAsClick() {
        let origin = GesturePoint(x: 10, y: 10)

        XCTAssertFalse(MouseGestureClickTolerance.isExceeded(from: origin, to: origin))
        XCTAssertFalse(MouseGestureClickTolerance.isExceeded(
            from: origin,
            to: GesturePoint(x: 10, y: 14)
        ))
        XCTAssertTrue(MouseGestureClickTolerance.isExceeded(
            from: origin,
            to: GesturePoint(x: 10, y: 14.01)
        ))
        XCTAssertTrue(MouseGestureClickTolerance.isExceeded(
            from: origin,
            to: GesturePoint(x: 13, y: 13)
        ))
    }

    func testGestureCompletionOnlyReplaysClickBeforeClickToleranceIsExceeded() {
        let rule = MouseGestureRule(
            triggerButton: 1,
            directions: [.right],
            action: .mouseBack
        )

        XCTAssertEqual(
            MouseGestureCompletionPolicy.completion(rule: rule, hasExceededClickTolerance: true),
            .executeAction(.mouseBack)
        )
        XCTAssertEqual(
            MouseGestureCompletionPolicy.completion(rule: rule, hasExceededClickTolerance: false),
            .executeAction(.mouseBack)
        )
        XCTAssertEqual(
            MouseGestureCompletionPolicy.completion(rule: nil, hasExceededClickTolerance: false),
            .replayClick
        )
        XCTAssertEqual(
            MouseGestureCompletionPolicy.completion(rule: nil, hasExceededClickTolerance: true),
            .none
        )
    }

    func testGestureCancellationDoesNotReplayAfterClickToleranceIsExceeded() {
        XCTAssertEqual(
            MouseGestureCompletionPolicy.completion(rule: nil, hasExceededClickTolerance: false),
            .replayClick
        )
        XCTAssertEqual(
            MouseGestureCompletionPolicy.completion(rule: nil, hasExceededClickTolerance: true),
            .none
        )
    }

    func testKeycastDefaultsToShortcutsAndSpecialKeys() {
        XCTAssertFalse(KeycastEventFilter.shouldDisplay(
            keyCode: 0,
            modifiers: [],
            mode: .shortcutsOnly,
            temporaryAllKeys: false,
            secureInputEnabled: false,
            isExcludedApplication: false
        ))
        XCTAssertTrue(KeycastEventFilter.shouldDisplay(
            keyCode: 0,
            modifiers: [.command, .shift],
            mode: .shortcutsOnly,
            temporaryAllKeys: false,
            secureInputEnabled: false,
            isExcludedApplication: false
        ))
        XCTAssertTrue(KeycastEventFilter.shouldDisplay(
            keyCode: 53,
            modifiers: [],
            mode: .shortcutsOnly,
            temporaryAllKeys: false,
            secureInputEnabled: false,
            isExcludedApplication: false
        ))
        XCTAssertTrue(KeycastEventFilter.shouldDisplay(
            keyCode: 122,
            modifiers: [],
            mode: .shortcutsOnly,
            temporaryAllKeys: false,
            secureInputEnabled: false,
            isExcludedApplication: false
        ))
        XCTAssertEqual(KeycastEventFilter.displayString(keyCode: 122, modifiers: []), "F1")
        XCTAssertEqual(
            KeycastEventFilter.displayString(keyCode: 0, modifiers: [.command, .shift]),
            "⇧⌘A"
        )
        XCTAssertEqual(
            KeycastEventFilter.displayString(keyCode: 18, modifiers: [.command], keyLabel: "1"),
            "⌘1"
        )
    }

    func testKeycastSuppressesSecureAndExcludedInput() {
        for (secure, excluded) in [(true, false), (false, true), (true, true)] {
            XCTAssertFalse(KeycastEventFilter.shouldDisplay(
                keyCode: 0,
                modifiers: [.command],
                mode: .shortcutsOnly,
                temporaryAllKeys: true,
                secureInputEnabled: secure,
                isExcludedApplication: excluded
            ))
        }
    }


}
