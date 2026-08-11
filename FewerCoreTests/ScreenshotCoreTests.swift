import CoreGraphics
import XCTest
@testable import FewerCore

final class ScreenshotCoreTests: XCTestCase {
    // MARK: - ScreenshotPixelGeometry

    func testOutputSizeUsesPhysicalPixelScale() {
        XCTAssertEqual(
            ScreenshotPixelGeometry.outputSize(
                pointSize: CGSize(width: 1512, height: 982),
                pointPixelScale: 2
            ),
            CGSize(width: 3024, height: 1964)
        )
    }

    func testCropRectRoundsOutwardToWholePixels() {
        XCTAssertEqual(
            ScreenshotPixelGeometry.cropRect(
                pointRect: CGRect(x: 110.25, y: 60.25, width: 100.5, height: 80.5),
                displayFrame: CGRect(x: 100, y: 50, width: 1512, height: 982),
                pointPixelScale: 2
            ),
            CGRect(x: 20, y: 20, width: 202, height: 162)
        )
    }

    // MARK: - ScreenshotToolbarLayout

    func testToolbarUsesMeasuredHeightBelowSelectionWithoutOverlap() {
        let selection = CGRect(x: 100, y: 100, width: 500, height: 300)
        let toolbarSize = CGSize(width: 620, height: 190)

        let position = ScreenshotToolbarLayout.position(
            selection: selection,
            containerSize: CGSize(width: 1000, height: 800),
            toolbarSize: toolbarSize
        )
        let toolbarFrame = CGRect(
            x: position.x - toolbarSize.width / 2,
            y: position.y - toolbarSize.height / 2,
            width: toolbarSize.width,
            height: toolbarSize.height
        )

        XCTAssertEqual(toolbarFrame.minY, selection.maxY + 10)
        XCTAssertFalse(toolbarFrame.intersects(selection))
    }

    func testToolbarMovesAboveSelectionWhenMeasuredHeightDoesNotFitBelow() {
        let selection = CGRect(x: 100, y: 400, width: 500, height: 220)
        let toolbarSize = CGSize(width: 620, height: 190)

        let position = ScreenshotToolbarLayout.position(
            selection: selection,
            containerSize: CGSize(width: 1000, height: 800),
            toolbarSize: toolbarSize
        )
        let toolbarFrame = CGRect(
            x: position.x - toolbarSize.width / 2,
            y: position.y - toolbarSize.height / 2,
            width: toolbarSize.width,
            height: toolbarSize.height
        )

        XCTAssertEqual(toolbarFrame.maxY, selection.minY - 10)
        XCTAssertFalse(toolbarFrame.intersects(selection))
    }

    func testCompactToolbarWidthDoesNotExpandWithFullscreenSelection() {
        XCTAssertEqual(ScreenshotToolbarLayout.compactHeight, 40)
        XCTAssertEqual(ScreenshotToolbarLayout.compactWidth(containerWidth: 1440), 860)
        XCTAssertEqual(ScreenshotToolbarLayout.compactWidth(containerWidth: 800), 784)
    }

    // MARK: - ScreenshotCaptureSessionGate

    func testCaptureSessionGateRejectsConcurrentCapture() {
        var gate = ScreenshotCaptureSessionGate()
        XCTAssertNotNil(gate.begin())
        XCTAssertNil(gate.begin())
    }

    func testCaptureSessionGateIgnoresStaleCompletionAfterRestart() throws {
        var gate = ScreenshotCaptureSessionGate()
        let staleID = try XCTUnwrap(gate.begin())
        gate.cancel()
        let currentID = try XCTUnwrap(gate.begin())

        XCTAssertFalse(gate.complete(staleID))
        XCTAssertTrue(gate.isActive(currentID))
        XCTAssertTrue(gate.complete(currentID))
    }

    func testCaptureSessionGateCompletesCurrentCapture() throws {
        var gate = ScreenshotCaptureSessionGate()
        let captureID = try XCTUnwrap(gate.begin())

        XCTAssertTrue(gate.complete(captureID))
        XCTAssertFalse(gate.hasActiveSession)
    }

    // MARK: - CaptureRegion

    func testNormalizedFromTopLeftToBottomRight() {
        let rect = CaptureRegion.normalized(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 100, y: 80))
        XCTAssertEqual(rect, CGRect(x: 10, y: 20, width: 90, height: 60))
    }

    func testNormalizedFromBottomRightToTopLeft() {
        let rect = CaptureRegion.normalized(from: CGPoint(x: 100, y: 80), to: CGPoint(x: 10, y: 20))
        XCTAssertEqual(rect, CGRect(x: 10, y: 20, width: 90, height: 60))
    }

    func testNormalizedHandlesZeroSize() {
        let rect = CaptureRegion.normalized(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 5, y: 5))
        XCTAssertEqual(rect, CGRect(x: 5, y: 5, width: 0, height: 0))
    }

    func testClampedIntersectsWithScreenBounds() {
        let rect = CGRect(x: -50, y: -50, width: 400, height: 400)
        let clamped = CaptureRegion.clamped(rect, within: CGRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(clamped, CGRect(x: 0, y: 0, width: 350, height: 350))
    }

    func testClampedFullyOutsideReturnsEmpty() {
        let rect = CGRect(x: 2000, y: 2000, width: 100, height: 100)
        let clamped = CaptureRegion.clamped(rect, within: CGRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertTrue(clamped.isEmpty)
    }

    // MARK: - WindowHitTester

    func testHitTestReturnsTopmostWindow() {
        // 两个重叠窗口，points 落在两者内 → 应命中列表靠前的（z-order 顶部）
        let windows = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 50, y: 50, width: 100, height: 100),
        ]
        XCTAssertEqual(WindowHitTester.hitTest(point: CGPoint(x: 75, y: 75), windowBounds: windows), 0)
    }

    func testHitTestMissesAll() {
        let windows = [CGRect(x: 0, y: 0, width: 100, height: 100)]
        XCTAssertNil(WindowHitTester.hitTest(point: CGPoint(x: 500, y: 500), windowBounds: windows))
    }

    func testHitTestEmptyList() {
        XCTAssertNil(WindowHitTester.hitTest(point: .zero, windowBounds: []))
    }

    func testSmartCaptureClickChoosesHoveredWindow() {
        XCTAssertEqual(
            SmartCaptureGesture.resolve(start: CGPoint(x: 20, y: 20), end: CGPoint(x: 21, y: 21), windowIndex: 2),
            .window(index: 2)
        )
    }

    func testSmartCaptureDragChoosesRegionInsteadOfWindow() {
        XCTAssertEqual(
            SmartCaptureGesture.resolve(start: CGPoint(x: 20, y: 20), end: CGPoint(x: 120, y: 80), windowIndex: 2),
            .region(CGRect(x: 20, y: 20, width: 100, height: 60))
        )
    }

    func testSmartCaptureEmptyClickDoesNothing() {
        XCTAssertEqual(
            SmartCaptureGesture.resolve(start: CGPoint(x: 20, y: 20), end: CGPoint(x: 20, y: 20), windowIndex: nil),
            .none
        )
    }

    // MARK: - ScreenshotContentPicker

    func testScreenshotContentPickerReturnsSmallestElementUnderPoint() {
        let rect = ScreenshotContentPicker.elementRect(
            at: CGPoint(x: 75, y: 75),
            imageSize: CGSize(width: 200, height: 200),
            elementBounds: [
                CGRect(x: 0, y: 0, width: 150, height: 150),
                CGRect(x: 50, y: 50, width: 50, height: 50),
            ]
        )

        XCTAssertEqual(rect, CGRect(x: 50, y: 50, width: 50, height: 50))
    }

    func testRawElementPickerReturnsSmallestCandidate() {
        let rect = ScreenshotContentPicker.elementRect(
            at: CGPoint(x: 42, y: 24),
            imageSize: CGSize(width: 200, height: 100),
            elementBounds: [
                CGRect(x: 10, y: 15, width: 120, height: 24),
                CGRect(x: 39, y: 19, width: 7, height: 10),
            ]
        )

        XCTAssertEqual(rect, CGRect(x: 39, y: 19, width: 7, height: 10))
    }

    func testScreenshotContentPickerClipsCandidateToImage() {
        let rect = ScreenshotContentPicker.elementRect(
            at: CGPoint(x: 10, y: 20),
            imageSize: CGSize(width: 200, height: 100),
            elementBounds: [CGRect(x: -50, y: -20, width: 120, height: 80)]
        )

        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 70, height: 60))
    }

    func testScreenshotContentPickerReturnsNilWhenNothingContainsPoint() {
        XCTAssertNil(ScreenshotContentPicker.elementRect(
            at: CGPoint(x: 150, y: 80),
            imageSize: CGSize(width: 200, height: 100),
            elementBounds: [CGRect(x: 10, y: 10, width: 40, height: 30)]
        ))
    }

    func testScreenshotContentPickerReturnsNilOutsideImage() {
        XCTAssertNil(ScreenshotContentPicker.elementRect(
            at: CGPoint(x: 201, y: 50),
            imageSize: CGSize(width: 200, height: 100),
            elementBounds: [CGRect(x: 0, y: 0, width: 200, height: 100)]
        ))
    }

    func testScreenshotContentPickerUsesVisionLowerLeftCoordinates() {
        let rect = ScreenshotContentPicker.elementRect(
            at: CGPoint(x: 50, y: 170),
            imageSize: CGSize(width: 200, height: 200),
            elementBounds: [
                CGRect(x: 20, y: 150, width: 80, height: 30),
                CGRect(x: 20, y: 20, width: 80, height: 30),
            ]
        )

        XCTAssertEqual(rect, CGRect(x: 20, y: 150, width: 80, height: 30))
    }

    func testPageElementPickerPrefersNestedTextOverOuterBlock() {
        let block = CGRect(x: 20, y: 20, width: 120, height: 50)
        let text = CGRect(x: 40, y: 35, width: 50, height: 15)

        let rect = ScreenshotContentPicker.pageElementRect(
            at: CGPoint(x: 60, y: 45),
            imageSize: CGSize(width: 200, height: 100),
            blockBounds: [block],
            fallbackBounds: [text]
        )

        XCTAssertEqual(rect, text)
    }

    func testPageElementStackKeepsNestedCandidatesFromSmallToLarge() {
        let text = CGRect(x: 50, y: 40, width: 40, height: 12)
        let row = CGRect(x: 35, y: 30, width: 100, height: 30)
        let panel = CGRect(x: 20, y: 10, width: 150, height: 80)

        let stack = ScreenshotContentPicker.pageElementStack(
            at: CGPoint(x: 60, y: 45),
            imageSize: CGSize(width: 200, height: 100),
            blockBounds: [panel, row],
            fallbackBounds: [text]
        )

        XCTAssertEqual(stack, [text, row, panel])
    }

    func testPageElementPickerFallsBackToWholeTextLine() {
        let text = CGRect(x: 40, y: 35, width: 80, height: 20)

        let rect = ScreenshotContentPicker.pageElementRect(
            at: CGPoint(x: 60, y: 45),
            imageSize: CGSize(width: 200, height: 100),
            blockBounds: [],
            fallbackBounds: [text]
        )

        XCTAssertEqual(rect, text)
    }

    func testFilteredBlockBoundsRejectsGlyphRectangleButKeepsContainer() {
        let text = CGRect(x: 40, y: 35, width: 50, height: 15)
        let glyph = CGRect(x: 45, y: 38, width: 8, height: 10)
        let button = CGRect(x: 20, y: 20, width: 120, height: 50)

        let bounds = ScreenshotContentPicker.filteredBlockBounds(
            [glyph, button],
            textBounds: [text],
            imageSize: CGSize(width: 200, height: 100)
        )

        XCTAssertEqual(bounds, [button])
    }

    func testFilteredElementBoundsKeepsNestedTextAndSymbolCandidates() {
        let line = CGRect(x: 10, y: 40, width: 120, height: 24)
        let symbol = CGRect(x: 35, y: 45, width: 9, height: 12)

        let bounds = ScreenshotContentPicker.filteredElementBounds(
            [line, symbol],
            imageSize: CGSize(width: 200, height: 100)
        )

        XCTAssertEqual(Set(bounds.map(NSStringFromRect)), Set([line, symbol].map(NSStringFromRect)))
    }

    func testFilteredElementBoundsDeduplicatesNearlyIdenticalCandidates() {
        let bounds = ScreenshotContentPicker.filteredElementBounds(
            [
                CGRect(x: 20, y: 20, width: 40, height: 30),
                CGRect(x: 21, y: 21, width: 40, height: 30),
            ],
            imageSize: CGSize(width: 200, height: 100)
        )

        XCTAssertEqual(bounds.count, 1)
    }

    // MARK: - CaptureResizeHandle.hitTest

    private let selection = CGRect(x: 100, y: 100, width: 200, height: 100)

    func testHitTestEdgeHandles() {
        XCTAssertEqual(CaptureResizeHandle.hitTest(point: CGPoint(x: 102, y: 150), in: selection), .left)
        XCTAssertEqual(CaptureResizeHandle.hitTest(point: CGPoint(x: 298, y: 150), in: selection), .right)
        XCTAssertEqual(CaptureResizeHandle.hitTest(point: CGPoint(x: 200, y: 102), in: selection), .top)
        XCTAssertEqual(CaptureResizeHandle.hitTest(point: CGPoint(x: 200, y: 198), in: selection), .bottom)
    }

    func testHitTestCornerHandles() {
        XCTAssertEqual(CaptureResizeHandle.hitTest(point: CGPoint(x: 102, y: 102), in: selection), .topLeft)
        XCTAssertEqual(CaptureResizeHandle.hitTest(point: CGPoint(x: 298, y: 102), in: selection), .topRight)
        XCTAssertEqual(CaptureResizeHandle.hitTest(point: CGPoint(x: 102, y: 198), in: selection), .bottomLeft)
        XCTAssertEqual(CaptureResizeHandle.hitTest(point: CGPoint(x: 298, y: 198), in: selection), .bottomRight)
    }

    func testHitTestInsidePicksOppositeQuadrantCorner() {
        // 选区内按下：鼠标所在象限固定对角 → 左上象限对应 topLeft 手柄
        XCTAssertEqual(CaptureResizeHandle.hitTest(point: CGPoint(x: 120, y: 110), in: selection), .topLeft)
        XCTAssertEqual(CaptureResizeHandle.hitTest(point: CGPoint(x: 280, y: 110), in: selection), .topRight)
        XCTAssertEqual(CaptureResizeHandle.hitTest(point: CGPoint(x: 120, y: 190), in: selection), .bottomLeft)
        XCTAssertEqual(CaptureResizeHandle.hitTest(point: CGPoint(x: 280, y: 190), in: selection), .bottomRight)
    }

    func testHitTestOutsideReturnsNil() {
        XCTAssertNil(CaptureResizeHandle.hitTest(point: CGPoint(x: 50, y: 150), in: selection))
        XCTAssertNil(CaptureResizeHandle.hitTest(point: CGPoint(x: 350, y: 300), in: selection))
    }

    func testEdgeHitTestLeavesInteriorForMovingSelection() {
        XCTAssertNil(CaptureResizeHandle.edgeHitTest(point: CGPoint(x: 200, y: 150), in: selection))
        XCTAssertEqual(CaptureResizeHandle.edgeHitTest(point: CGPoint(x: 102, y: 150), in: selection), .left)
        XCTAssertEqual(CaptureResizeHandle.edgeHitTest(point: CGPoint(x: 298, y: 198), in: selection), .bottomRight)
    }

    // MARK: - CaptureResizeHandle.resizedRect

    func testResizeBottomRightKeepsTopLeftFixed() {
        let rect = CaptureResizeHandle.resizedRect(
            original: selection,
            handle: .bottomRight,
            current: CGPoint(x: 350, y: 250)
        )
        XCTAssertEqual(rect, CGRect(x: 100, y: 100, width: 250, height: 150))
    }

    func testResizeTopLeftKeepsBottomRightFixed() {
        let rect = CaptureResizeHandle.resizedRect(
            original: selection,
            handle: .topLeft,
            current: CGPoint(x: 80, y: 60)
        )
        XCTAssertEqual(rect, CGRect(x: 80, y: 60, width: 220, height: 140))
    }

    func testResizeLeftMovesLeftEdgeOnly() {
        let rect = CaptureResizeHandle.resizedRect(
            original: selection,
            handle: .left,
            current: CGPoint(x: 150, y: 999)
        )
        XCTAssertEqual(rect, CGRect(x: 150, y: 100, width: 150, height: 100))
    }

    func testResizeTopMovesTopEdgeOnly() {
        let rect = CaptureResizeHandle.resizedRect(
            original: selection,
            handle: .top,
            current: CGPoint(x: 999, y: 80)
        )
        XCTAssertEqual(rect, CGRect(x: 100, y: 80, width: 200, height: 120))
    }

    func testResizeCannotShrinkBelowMinSize() {
        let rect = CaptureResizeHandle.resizedRect(
            original: selection,
            handle: .bottomRight,
            current: CGPoint(x: 101, y: 101)
        )
        XCTAssertEqual(rect, CGRect(x: 100, y: 100, width: 4, height: 4))
        XCTAssertEqual(rect.width, 4)
        XCTAssertEqual(rect.height, 4)
    }

    // MARK: - CaptureResizeHandle.clamped

    func testClampedMovesSelectionBackInsideBounds() {
        let rect = CGRect(x: -30, y: 900, width: 200, height: 100)
        let clamped = CaptureResizeHandle.clamped(rect, within: CGRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(clamped, CGRect(x: 0, y: 800, width: 200, height: 100))
    }

    func testClampedKeepsInBoundsSelectionUnchanged() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        let clamped = CaptureResizeHandle.clamped(rect, within: CGRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(clamped, rect)
    }

    func testClampedIgnoresOversizedSelection() {
        let rect = CGRect(x: 100, y: 100, width: 2000, height: 100)
        let clamped = CaptureResizeHandle.clamped(rect, within: CGRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(clamped, rect)
    }

    func testAnchorPointPlacesCornersAndEdgeMidpoints() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 50)
        let anchors = Dictionary(
            uniqueKeysWithValues: CaptureResizeHandle.allCases.map { ($0, $0.anchorPoint(in: rect)) }
        )
        XCTAssertEqual(anchors[.topLeft], CGPoint(x: 10, y: 20))
        XCTAssertEqual(anchors[.topRight], CGPoint(x: 110, y: 20))
        XCTAssertEqual(anchors[.bottomLeft], CGPoint(x: 10, y: 70))
        XCTAssertEqual(anchors[.bottomRight], CGPoint(x: 110, y: 70))
        XCTAssertEqual(anchors[.top], CGPoint(x: 60, y: 20))
        XCTAssertEqual(anchors[.bottom], CGPoint(x: 60, y: 70))
        XCTAssertEqual(anchors[.left], CGPoint(x: 10, y: 45))
        XCTAssertEqual(anchors[.right], CGPoint(x: 110, y: 45))
    }

    // MARK: - StitchEngine.frame(of:)

    func testFrameOfGradientImageProducesRowHashes() {
        let image = makeGradientImage(width: 64, height: 32)
        let frame = StitchEngine.frame(of: image)
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.width, 64)
        XCTAssertEqual(frame?.height, 32)
        XCTAssertEqual(frame?.rowHashes.count, 32)
        // 渐变图每行内容不同 → 行哈希各不相同
        XCTAssertEqual(Set(frame!.rowHashes).count, 32)
    }

    func testFrameOfSolidImageProducesIdenticalRowHashes() {
        let image = makeSolidImage(width: 64, height: 32, color: (r: 200, g: 100, b: 50))
        let frame = StitchEngine.frame(of: image)
        XCTAssertEqual(Set(frame!.rowHashes).count, 1)
    }

    // MARK: - StitchEngine.verticalOverlap

    func testVerticalOverlapFindsExactMatch() {
        let top = StitchEngine.Frame(width: 100, height: 50, rowHashes: (0..<50).map { UInt64($0) })
        // bottom 前 10 行 == top 后 10 行，随后是全新内容
        let bottomRows = Array((40..<50).map { UInt64($0) }) + Array((100..<160).map { UInt64($0) })
        let bottom = StitchEngine.Frame(width: 100, height: 70, rowHashes: bottomRows)
        XCTAssertEqual(StitchEngine.verticalOverlap(top: top, bottom: bottom), 10)
    }

    func testVerticalOverlapNoMatch() {
        let top = StitchEngine.Frame(width: 100, height: 50, rowHashes: (0..<50).map { UInt64($0) })
        let bottom = StitchEngine.Frame(width: 100, height: 50, rowHashes: (500..<550).map { UInt64($0) })
        XCTAssertEqual(StitchEngine.verticalOverlap(top: top, bottom: bottom), 0)
    }

    func testVerticalOverlapPartialMatchStopsAtBreak() {
        let top = StitchEngine.Frame(width: 100, height: 40, rowHashes: (0..<40).map { UInt64($0) })
        // 匹配 3 行后断裂（第 4 行不同）
        let bottomRows = [UInt64(37), 38, 39, 999, 1000, 1001]
        let bottom = StitchEngine.Frame(width: 100, height: 6, rowHashes: bottomRows)
        XCTAssertEqual(StitchEngine.verticalOverlap(top: top, bottom: bottom), 3)
    }

    func testVerticalOverlapRequiresEqualWidth() {
        let top = StitchEngine.Frame(width: 100, height: 50, rowHashes: [UInt64](repeating: 7, count: 50))
        let bottom = StitchEngine.Frame(width: 80, height: 50, rowHashes: [UInt64](repeating: 7, count: 50))
        XCTAssertEqual(StitchEngine.verticalOverlap(top: top, bottom: bottom), 0)
    }

    func testVerticalOverlapCapsAtMaxCandidates() {
        // 超过 maxOverlapCandidates 的全等行不应全量匹配
        let n = 300
        let top = StitchEngine.Frame(width: 10, height: n, rowHashes: [UInt64](repeating: 1, count: n))
        let bottom = StitchEngine.Frame(width: 10, height: n, rowHashes: [UInt64](repeating: 1, count: n))
        let overlap = StitchEngine.verticalOverlap(top: top, bottom: bottom)
        XCTAssertLessThanOrEqual(overlap, StitchEngine.maxOverlapCandidates)
        XCTAssertEqual(overlap, StitchEngine.maxOverlapCandidates)
    }

    // MARK: - StitchEngine.stitchedHeight

    func testStitchedHeight() {
        XCTAssertEqual(StitchEngine.stitchedHeight(topHeight: 100, bottomHeight: 80, overlap: 10), 170)
        XCTAssertEqual(StitchEngine.stitchedHeight(topHeight: 100, bottomHeight: 80, overlap: 0), 180)
    }

    // MARK: - StitchEngine robust scrolling

    func testAnalyzeFindsDownwardOffsetWithLargeOverlap() throws {
        let previous = makeScrollingFrame(documentStart: 0, width: 96, height: 500)
        let next = makeScrollingFrame(documentStart: 80, width: 96, height: 500)

        let match = try StitchEngine.analyze(previous: previous, next: next).get()

        XCTAssertEqual(match.offsetY, 80)
        XCTAssertEqual(match.overlapHeight, 420)
        XCTAssertGreaterThanOrEqual(match.confidence, 0.99)
    }

    func testAnalyzeBuildsReliableChainForFastScrollingFrames() throws {
        let starts = [0, 180, 360, 540]
        let frames = starts.map { makeScrollingFrame(documentStart: $0, width: 96, height: 240) }
        let matches = try zip(frames, frames.dropFirst()).map { pair in
            try StitchEngine.analyze(previous: pair.0, next: pair.1).get()
        }

        XCTAssertEqual(matches.map(\.offsetY), [180, 180, 180])
        XCTAssertTrue(matches.allSatisfy { $0.overlapHeight == 60 && $0.confidence >= 0.99 })

        let result = try StitchEngine.compose(frames: frames, matches: matches).get()
        XCTAssertEqual(result.height, 780)
    }

    func testAnalyzeTracksFastSameDirectionWithTenPercentOverlap() throws {
        let configuration = StitchConfiguration(minimumOverlapRatio: 0.1)
        let previous = makeScrollingFrame(documentStart: 0, width: 96, height: 240)
        let next = makeScrollingFrame(documentStart: 216, width: 96, height: 240)
        let previousPrepared = try XCTUnwrap(StitchEngine.prepare(previous, configuration: configuration))
        let nextPrepared = try XCTUnwrap(StitchEngine.prepare(next, configuration: configuration))

        let match = try StitchEngine.analyze(
            previous: previousPrepared,
            next: nextPrepared,
            preferredDirection: .down,
            maximumShiftRatio: 0.9,
            configuration: configuration
        ).get()

        XCTAssertEqual(match.offsetY, 216)
        XCTAssertEqual(match.overlapHeight, 24)
        XCTAssertGreaterThanOrEqual(match.confidence, 0.99)
    }

    func testAnalyzeToleratesSmallPixelNoise() throws {
        let previous = makeScrollingFrame(documentStart: 0, width: 96, height: 240)
        let next = makeScrollingFrame(documentStart: 64, width: 96, height: 240, noise: 2)

        let match = try StitchEngine.analyze(previous: previous, next: next).get()

        XCTAssertEqual(match.offsetY, 64)
        XCTAssertGreaterThanOrEqual(match.confidence, 0.98)
    }

    func testAnalyzeReportsStationaryTopAndBottomBands() throws {
        let previous = makeScrollingFrame(
            documentStart: 0,
            width: 96,
            height: 260,
            stationaryTop: 18,
            stationaryBottom: 14
        )
        let next = makeScrollingFrame(
            documentStart: 70,
            width: 96,
            height: 260,
            stationaryTop: 18,
            stationaryBottom: 14
        )

        let match = try StitchEngine.analyze(previous: previous, next: next).get()

        XCTAssertEqual(match.offsetY, 70)
        XCTAssertEqual(match.stationaryTopHeight, 18)
        XCTAssertEqual(match.stationaryBottomHeight, 14)
    }

    func testAnalyzeFindsUpwardOffset() throws {
        let previous = makeScrollingFrame(documentStart: 80, width: 96, height: 240)
        let next = makeScrollingFrame(documentStart: 0, width: 96, height: 240)

        let match = try StitchEngine.analyze(previous: previous, next: next).get()

        XCTAssertEqual(match.direction, .up)
        XCTAssertEqual(match.offsetY, 80)
        XCTAssertEqual(match.signedOffsetY, -80)
    }

    func testCoverageAllowsReversingThroughCapturedContentAndExtendingBothEnds() throws {
        let starts = [0, -60, 0, 60]
        let frames = starts.map { makeScrollingFrame(documentStart: $0, width: 96, height: 240) }
        var coverage = StitchCoverage()
        var contributions: [StitchCoverageContribution] = []
        for pair in zip(frames, frames.dropFirst()) {
            contributions.append(coverage.advance(by: try StitchEngine.analyze(previous: pair.0, next: pair.1).get()))
        }

        XCTAssertEqual(contributions, [.prepend, .covered, .append])
        XCTAssertEqual(coverage.minimumOriginY, -60)
        XCTAssertEqual(coverage.maximumOriginY, 60)
        XCTAssertEqual(coverage.outputHeight(frameHeight: 240), 360)
    }

    func testComposeOrdersBidirectionalPlacementsWithoutDuplicatingRevisitedFrames() throws {
        let frames = [
            makeScrollingFrame(documentStart: 0, width: 96, height: 240),
            makeScrollingFrame(documentStart: -60, width: 96, height: 240),
            makeScrollingFrame(documentStart: 60, width: 96, height: 240),
        ]
        let result = try StitchEngine.compose(
            frames: frames,
            placements: [
                StitchFramePlacement(originY: 0),
                StitchFramePlacement(originY: -60),
                StitchFramePlacement(originY: 60),
            ]
        ).get()

        XCTAssertEqual(result.height, 360)
    }

    func testAnalyzeRejectsDimensionChange() {
        let previous = makeScrollingFrame(documentStart: 0, width: 96, height: 240)
        let next = makeScrollingFrame(documentStart: 40, width: 88, height: 240)

        XCTAssertEqual(
            StitchEngine.analyze(previous: previous, next: next),
            .failure(.dimensionChanged(
                expectedWidth: 96,
                expectedHeight: 240,
                actualWidth: 88,
                actualHeight: 240
            ))
        )
    }

    func testIsDuplicateDetectsIdenticalFrames() throws {
        let first = try XCTUnwrap(StitchEngine.prepare(makeScrollingFrame(documentStart: 0, width: 96, height: 240)))
        let second = try XCTUnwrap(StitchEngine.prepare(makeScrollingFrame(documentStart: 0, width: 96, height: 240)))

        XCTAssertTrue(StitchEngine.isDuplicate(first: first, second: second))
    }

    func testIsDuplicateRejectsScrolledFrames() throws {
        let first = try XCTUnwrap(StitchEngine.prepare(makeScrollingFrame(documentStart: 0, width: 96, height: 240)))
        let second = try XCTUnwrap(StitchEngine.prepare(makeScrollingFrame(documentStart: 64, width: 96, height: 240)))

        XCTAssertFalse(StitchEngine.isDuplicate(first: first, second: second))
    }

    func testAnalyzeRejectsUnrelatedFrame() {
        let previous = makeScrollingFrame(documentStart: 0, width: 96, height: 240)
        let next = makeSolidImage(width: 96, height: 240, color: (r: 255, g: 255, b: 255))

        guard case .failure(.lowConfidence(let confidence)) = StitchEngine.analyze(
            previous: previous,
            next: next
        ) else {
            return XCTFail("无关帧应返回低置信度")
        }
        XCTAssertLessThan(confidence, StitchConfiguration.default.minimumConfidence)
    }

    func testAnalyzeRejectsAmbiguousShiftWhenContentIsPeriodic() {
        // 周期 60 的内容（如重复的表格行/列表项）：位移 30、90、150 分数相同，
        // 若没有锐度检查会任意选一个假位移导致拼接内容重复。
        let previous = makePeriodicFrame(period: 60, documentStart: 0, width: 96, height: 240)
        let next = makePeriodicFrame(period: 60, documentStart: 30, width: 96, height: 240)

        guard case .failure(.lowConfidence) = StitchEngine.analyze(
            previous: previous,
            next: next
        ) else {
            return XCTFail("周期性内容上的模糊位移应返回低置信度")
        }
    }

    func testAnalyzeStillFindsOffsetWhenBlankAreaIsMinority() {
        // 少量空白不影响真实位移识别，锐度检查不应误伤正常滚动。
        let previous = makeScrollingFrameWithBlankTop(blankTop: 40, documentStart: 0, width: 96, height: 240)
        let next = makeScrollingFrameWithBlankTop(blankTop: 40, documentStart: 64, width: 96, height: 240)

        let match = try! StitchEngine.analyze(previous: previous, next: next).get()

        XCTAssertEqual(match.offsetY, 64)
    }

    func testComposeBuildsExpectedLongImageAndDeduplicatesFixedBands() throws {
        let frames = [
            makeScrollingFrame(documentStart: 0, width: 96, height: 240, stationaryTop: 16, stationaryBottom: 12),
            makeScrollingFrame(documentStart: 60, width: 96, height: 240, stationaryTop: 16, stationaryBottom: 12),
            makeScrollingFrame(documentStart: 120, width: 96, height: 240, stationaryTop: 16, stationaryBottom: 12),
        ]
        let matches = try zip(frames, frames.dropFirst()).map { pair in
            try StitchEngine.analyze(previous: pair.0, next: pair.1).get()
        }

        let result = try StitchEngine.compose(
            frames: frames,
            matches: matches,
            confirmedTopHeight: 16,
            confirmedBottomHeight: 12
        ).get()

        XCTAssertEqual(result.width, 96)
        XCTAssertEqual(result.height, 360)
        let sourceHashes = StitchEngine.frame(of: frames[0])!.rowHashes
        let resultHashes = StitchEngine.frame(of: result)!.rowHashes
        XCTAssertEqual(resultHashes.filter { $0 == sourceHashes[0] }.count, 16)
        XCTAssertEqual(resultHashes.filter { $0 == sourceHashes.last! }.count, 12)
    }

    func testBidirectionalComposeKeepsFixedBandsOnce() throws {
        let frames = [
            makeScrollingFrame(documentStart: 60, width: 96, height: 240, stationaryTop: 16, stationaryBottom: 12),
            makeScrollingFrame(documentStart: 0, width: 96, height: 240, stationaryTop: 16, stationaryBottom: 12),
            makeScrollingFrame(documentStart: 120, width: 96, height: 240, stationaryTop: 16, stationaryBottom: 12),
        ]
        let result = try StitchEngine.compose(
            frames: frames,
            placements: [
                StitchFramePlacement(originY: 60),
                StitchFramePlacement(originY: 0),
                StitchFramePlacement(originY: 120),
            ],
            confirmedTopHeight: 16,
            confirmedBottomHeight: 12
        ).get()

        XCTAssertEqual(result.height, 360)
        let sourceHashes = StitchEngine.frame(of: frames[0])!.rowHashes
        let resultHashes = StitchEngine.frame(of: result)!.rowHashes
        XCTAssertEqual(resultHashes.filter { $0 == sourceHashes[0] }.count, 16)
        XCTAssertEqual(resultHashes.filter { $0 == sourceHashes.last! }.count, 12)
    }

    func testValidateOutputEnforcesPixelHeightAndFrameLimits() {
        let configuration = StitchConfiguration(
            maximumPixelCount: 10_000,
            maximumHeight: 500,
            maximumFrameCount: 3
        )
        XCTAssertNil(StitchEngine.validateOutput(width: 20, height: 400, frameCount: 3, configuration: configuration))
        XCTAssertEqual(
            StitchEngine.validateOutput(width: 30, height: 400, frameCount: 3, configuration: configuration),
            .outputLimitExceeded
        )
        XCTAssertEqual(
            StitchEngine.validateOutput(width: 20, height: 501, frameCount: 3, configuration: configuration),
            .outputLimitExceeded
        )
        XCTAssertEqual(
            StitchEngine.validateOutput(width: 20, height: 400, frameCount: 4, configuration: configuration),
            .outputLimitExceeded
        )
    }

    // MARK: - Helpers

    private func makeGradientImage(width: Int, height: Int) -> CGImage {
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    bytes[i] = UInt8(y % 256) // R 随行变化 → 行哈希不同
                    bytes[i + 1] = UInt8(x % 256)
                    bytes[i + 2] = 128
                    bytes[i + 3] = 255
                }
            }
        }
        return makeImage(width: width, height: height, data: &data)
    }

    private func makeSolidImage(width: Int, height: Int, color: (r: Int, g: Int, b: Int)) -> CGImage {
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<(width * height) {
                bytes[i * 4] = UInt8(color.r)
                bytes[i * 4 + 1] = UInt8(color.g)
                bytes[i * 4 + 2] = UInt8(color.b)
                bytes[i * 4 + 3] = 255
            }
        }
        return makeImage(width: width, height: height, data: &data)
    }

    private func makeScrollingFrame(
        documentStart: Int,
        width: Int,
        height: Int,
        stationaryTop: Int = 0,
        stationaryBottom: Int = 0,
        noise: Int = 0
    ) -> CGImage {
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let values: (Int, Int, Int)
                    if y < stationaryTop {
                        values = (28 + x % 7, 42, 58)
                    } else if y >= height - stationaryBottom {
                        values = (72, 48 + x % 9, 36)
                    } else {
                        let documentY = documentStart + y
                        values = (
                            (documentY * 7 + x * 3) % 251,
                            (documentY * 11 + x * 5) % 247,
                            (documentY * 13 + x * 7) % 239
                        )
                    }
                    let signedNoise = noise == 0 ? 0 : ((x + y) % (noise * 2 + 1)) - noise
                    bytes[i] = UInt8(clamping: values.0 + signedNoise)
                    bytes[i + 1] = UInt8(clamping: values.1 + signedNoise)
                    bytes[i + 2] = UInt8(clamping: values.2 + signedNoise)
                    bytes[i + 3] = 255
                }
            }
        }
        return makeImage(width: width, height: height, data: &data)
    }

    private func makeScrollingFrameWithBlankTop(
        blankTop: Int,
        documentStart: Int,
        width: Int,
        height: Int
    ) -> CGImage {
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let values: (Int, Int, Int)
                    if y < blankTop {
                        values = (255, 255, 255)
                    } else {
                        let documentY = documentStart + y
                        values = (
                            (documentY * 7 + x * 3) % 251,
                            (documentY * 11 + x * 5) % 247,
                            (documentY * 13 + x * 7) % 239
                        )
                    }
                    bytes[i] = UInt8(values.0)
                    bytes[i + 1] = UInt8(values.1)
                    bytes[i + 2] = UInt8(values.2)
                    bytes[i + 3] = 255
                }
            }
        }
        return makeImage(width: width, height: height, data: &data)
    }

    private func makePeriodicFrame(
        period: Int,
        documentStart: Int,
        width: Int,
        height: Int
    ) -> CGImage {
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let index = (y * width + x) * 4
                    let row = (documentStart + y) % period
                    bytes[index] = UInt8((row * 7 + x * 3) % 251)
                    bytes[index + 1] = UInt8((row * 11 + x * 5) % 247)
                    bytes[index + 2] = UInt8((row * 13 + x * 7) % 239)
                    bytes[index + 3] = 255
                }
            }
        }
        return makeImage(width: width, height: height, data: &data)
    }

    private func makeImage(width: Int, height: Int, data: inout Data) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return data.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            return context.makeImage()!
        }
    }
}
