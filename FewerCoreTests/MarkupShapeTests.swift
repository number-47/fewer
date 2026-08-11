import CoreGraphics
import XCTest
@testable import FewerCore

final class MarkupShapeTests: XCTestCase {
    private let original = CGRect(x: 100, y: 100, width: 200, height: 100)
    private let target = CGRect(x: 120, y: 130, width: 400, height: 200)

    // MARK: - MarkupInteractionPolicy

    func testPointerRoutesHitToActiveToolSoElementsCanOverlapByDefault() {
        let existingID = UUID()

        XCTAssertEqual(
            MarkupInteractionPolicy.primaryPointerRoute(
                moveModifierPressed: false,
                selectedElementID: nil,
                selectedResizeHandle: nil,
                hitElementID: existingID
            ),
            .activeTool
        )
    }

    func testSelectedResizeHandleWinsWhenShapeBodyDoesNotHit() {
        let selectedID = UUID()

        XCTAssertEqual(
            MarkupInteractionPolicy.primaryPointerRoute(
                moveModifierPressed: false,
                selectedElementID: selectedID,
                selectedResizeHandle: .topLeft,
                hitElementID: nil
            ),
            .resizeExistingElement(selectedID, .topLeft)
        )
    }

    func testCommandRoutesHitToMoveExistingElement() {
        let existingID = UUID()

        XCTAssertEqual(
            MarkupInteractionPolicy.primaryPointerRoute(
                moveModifierPressed: true,
                selectedElementID: existingID,
                selectedResizeHandle: nil,
                hitElementID: existingID
            ),
            .moveExistingElement(existingID)
        )
    }

    func testPointerWithoutHitRoutesToActiveTool() {
        XCTAssertEqual(
            MarkupInteractionPolicy.primaryPointerRoute(
                moveModifierPressed: false,
                selectedElementID: nil,
                selectedResizeHandle: nil,
                hitElementID: nil
            ),
            .activeTool
        )
    }

    func testReturnInsertsNewlineAndCommandReturnFinishesTextEditing() {
        XCTAssertEqual(
            MarkupTextEditingPolicy.returnAction(commandModifierPressed: false),
            .insertNewline
        )
        XCTAssertEqual(
            MarkupTextEditingPolicy.returnAction(commandModifierPressed: true),
            .finishEditing
        )
    }

    // MARK: - scaled(to:from:)

    func testScaledRectMapsRelativeBounds() {
        let shape = MarkupShape.rect(CGRect(x: 100, y: 100, width: 200, height: 100))
        XCTAssertEqual(
            shape.scaled(to: target, from: original),
            .rect(CGRect(x: 120, y: 130, width: 400, height: 200))
        )
    }

    func testScaledEllipseMapsRelativeBounds() {
        let shape = MarkupShape.ellipse(CGRect(x: 100, y: 100, width: 200, height: 100))
        XCTAssertEqual(
            shape.scaled(to: target, from: original),
            .ellipse(CGRect(x: 120, y: 130, width: 400, height: 200))
        )
    }

    func testScaledSmallRectKeepsSizeWhenCommitRoundTripsToPixels() {
        let source = CGRect(x: 0, y: 0, width: 1100, height: 700)
        let display = CGRect(x: 0, y: 0, width: 550, height: 350)
        let drawn = MarkupShape.rect(CGRect(x: 100, y: 80, width: 120, height: 90))

        let stored = drawn.scaled(to: source, from: display)
        XCTAssertEqual(
            stored,
            .rect(CGRect(x: 200, y: 160, width: 240, height: 180))
        )
        XCTAssertEqual(stored.scaled(to: display, from: source), drawn)
    }

    func testScaledLineMapsEndpoints() {
        let shape = MarkupShape.line(start: CGPoint(x: 100, y: 100), end: CGPoint(x: 300, y: 200))
        XCTAssertEqual(
            shape.scaled(to: target, from: original),
            .line(start: CGPoint(x: 120, y: 130), end: CGPoint(x: 520, y: 330))
        )
    }

    func testScaledArrowMapsEndpoints() {
        let shape = MarkupShape.arrow(start: CGPoint(x: 100, y: 200), end: CGPoint(x: 300, y: 100))
        XCTAssertEqual(
            shape.scaled(to: target, from: original),
            .arrow(start: CGPoint(x: 120, y: 330), end: CGPoint(x: 520, y: 130))
        )
    }

    func testScaledPolylineMapsEveryPoint() {
        let shape = MarkupShape.polyline([
            CGPoint(x: 100, y: 100),
            CGPoint(x: 200, y: 150),
            CGPoint(x: 300, y: 200),
        ])
        XCTAssertEqual(
            shape.scaled(to: target, from: original),
            .polyline([
                CGPoint(x: 120, y: 130),
                CGPoint(x: 320, y: 230),
                CGPoint(x: 520, y: 330),
            ])
        )
    }

    func testScaledFreehandMapsEveryPoint() {
        let shape = MarkupShape.freehand([CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 200)])
        XCTAssertEqual(
            shape.scaled(to: target, from: original),
            .freehand([CGPoint(x: 120, y: 130), CGPoint(x: 520, y: 330)])
        )
    }

    func testScaledAreaEffectMapsPointsAndKeepsShape() {
        let shape = MarkupShape.mosaic(
            points: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 200)],
            areaShape: .rectangle
        )
        XCTAssertEqual(
            shape.scaled(to: target, from: original),
            .mosaic(points: [CGPoint(x: 120, y: 130), CGPoint(x: 520, y: 330)], areaShape: .rectangle)
        )
    }

    func testScaledTextMapsOrigin() {
        let shape = MarkupShape.text("你好", origin: CGPoint(x: 100, y: 100))
        XCTAssertEqual(
            shape.scaled(to: target, from: original),
            .text("你好", origin: CGPoint(x: 120, y: 130))
        )
    }

    func testScaledTextPreservesNewlines() {
        let shape = MarkupShape.text("第一行\n第二行", origin: CGPoint(x: 100, y: 100))

        XCTAssertEqual(
            shape.scaled(to: target, from: original),
            .text("第一行\n第二行", origin: CGPoint(x: 120, y: 130))
        )
    }

    func testScaledCounterMapsCenter() {
        let shape = MarkupShape.counter(3, center: CGPoint(x: 200, y: 150))
        XCTAssertEqual(
            shape.scaled(to: target, from: original),
            .counter(3, center: CGPoint(x: 320, y: 230))
        )
    }

    func testScaledMagnifierMapsCenterAndScalesRadius() {
        let shape = MarkupShape.magnifier(center: CGPoint(x: 200, y: 150), radius: 40, scale: 2)
        XCTAssertEqual(
            shape.scaled(to: target, from: original),
            .magnifier(center: CGPoint(x: 320, y: 230), radius: 80, scale: 2)
        )
    }

    func testScaledWithEmptyOriginalReturnsSelf() {
        let shape = MarkupShape.rect(CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(shape.scaled(to: target, from: .zero), shape)
    }

    func testMarkupElementRoundTripsBetweenRetinaPixelsAndDisplayPoints() {
        let source = CGRect(x: 0, y: 0, width: 800, height: 400)
        let display = CGRect(x: 0, y: 0, width: 400, height: 200)
        let original = MarkupElement(
            shape: .arrow(start: CGPoint(x: 80, y: 40), end: CGPoint(x: 720, y: 360)),
            color: .red,
            strokeWidth: 8
        )

        let displayed = original.scaled(to: display, from: source)
        XCTAssertEqual(displayed.strokeWidth, 4)
        XCTAssertEqual(displayed.scaled(to: source, from: display), original)
    }
}
