//
//  LoupeZoomStateTests.swift
//  LRMockTests
//

import Testing
import CoreGraphics
@testable import LRMock

struct LoupeZoomStateTests {
    private let viewport = CGSize(width: 1_000, height: 800)
    private let landscapeContent = CGSize(width: 1_000, height: 500)

    @Test func startsAndResetsAtFit() {
        var state = LoupeZoomState()
        #expect(state.isFit)
        #expect(state.scale == 1)
        #expect(state.offset == .zero)

        state.magnify(
            by: 3,
            at: CGPoint(x: 500, y: 400),
            in: viewport,
            contentSize: landscapeContent
        )
        state.reset()

        #expect(state.isFit)
        #expect(state.scale == 1)
        #expect(state.offset == .zero)
    }

    @Test func doubleTapZoomKeepsTappedImagePointStationary() {
        var state = LoupeZoomState()
        state.toggle(
            at: CGPoint(x: 750, y: 400),
            in: viewport,
            contentSize: landscapeContent
        )

        #expect(state.scale == 2)
        #expect(state.offset.width == -250)
        #expect(state.offset.height == 0)

        state.toggle(
            at: CGPoint(x: 750, y: 400),
            in: viewport,
            contentSize: landscapeContent
        )
        #expect(state.isFit)
        #expect(state.offset == .zero)
    }

    @Test func magnificationStaysWithinLimits() {
        var state = LoupeZoomState()
        let center = CGPoint(x: 500, y: 400)

        state.magnify(by: 100, at: center, in: viewport, contentSize: landscapeContent)
        #expect(state.scale == LoupeZoomState.maximumScale)

        state.magnify(by: 0.001, at: center, in: viewport, contentSize: landscapeContent)
        #expect(state.isFit)
        #expect(state.offset == .zero)
    }

    @Test func panClampsEachAxisToVisibleImageEdges() {
        var state = LoupeZoomState()
        state.magnify(
            by: 2,
            at: CGPoint(x: 500, y: 400),
            in: viewport,
            contentSize: landscapeContent
        )
        state.pan(
            by: CGSize(width: 2_000, height: -2_000),
            in: viewport,
            contentSize: landscapeContent
        )

        #expect(state.offset.width == 500)
        #expect(state.offset.height == -100)
    }

    @Test func viewportChangeReclampsExistingOffset() {
        var state = LoupeZoomState()
        state.magnify(
            by: 2,
            at: CGPoint(x: 500, y: 400),
            in: viewport,
            contentSize: landscapeContent
        )
        state.pan(
            by: CGSize(width: 500, height: 100),
            in: viewport,
            contentSize: landscapeContent
        )

        let squareViewport = CGSize(width: 1_000, height: 1_000)
        let squareFittedContent = LoupeZoomState.fittedContentSize(
            aspectRatio: 2,
            in: squareViewport
        )
        state.clamp(to: squareViewport, contentSize: squareFittedContent)

        #expect(state.offset.width == 500)
        #expect(state.offset.height == 0)
    }
}
