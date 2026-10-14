//
//  LoupeViewportTransformTests.swift
//  LRMockTests
//

import CoreGraphics
import Foundation
import Testing
@testable import LRMock

struct LoupeViewportTransformTests {
    @Test func rejectsLetterboxAndMapsFittedImage() {
        let transform = LoupeViewportTransform(
            viewportSize: CGSize(width: 1_000, height: 800),
            fittedImageRect: CGRect(x: 100, y: 200, width: 800, height: 400)
        )

        #expect(transform.croppedNormalized(at: CGPoint(x: 500, y: 100)) == nil)
        let center = transform.croppedNormalized(at: CGPoint(x: 500, y: 400))
        #expect(center != nil)
        #expect(close(center?.x, 0.5))
        #expect(close(center?.y, 0.5))
    }

    @Test func displayedZoomAndOffsetRoundTrip() {
        let transform = LoupeViewportTransform(
            viewportSize: CGSize(width: 1_000, height: 800),
            fittedImageRect: CGRect(x: 100, y: 200, width: 800, height: 400),
            zoomScale: 2,
            zoomOffset: CGSize(width: 50, height: -25)
        )
        let cropped = NormalizedPoint(x: 0.25, y: 0.75)
        let viewportPoint = transform.viewportPoint(forCropped: cropped)

        #expect(close(viewportPoint.x, 150))
        #expect(close(viewportPoint.y, 575))
        let roundTrip = transform.croppedNormalized(at: viewportPoint)
        #expect(close(roundTrip?.x, cropped.x))
        #expect(close(roundTrip?.y, cropped.y))
    }

    @Test func croppedAndCanonicalCoordinatesRoundTripThroughCrop() {
        let transform = LoupeViewportTransform(
            viewportSize: CGSize(width: 800, height: 600),
            fittedImageRect: CGRect(x: 100, y: 100, width: 600, height: 400),
            cropX: 0.2,
            cropY: 0.1,
            cropW: 0.5,
            cropH: 0.6
        )
        let cropped = NormalizedPoint(x: 0.4, y: 0.75)
        let canonical = transform.canonicalNormalized(fromCropped: cropped)

        #expect(close(canonical.x, 0.4))
        #expect(close(canonical.y, 0.55))
        let roundTrip = transform.croppedNormalized(fromCanonical: canonical)
        #expect(close(roundTrip.x, cropped.x))
        #expect(close(roundTrip.y, cropped.y))
    }

    @Test func asymmetricTopLeftCoordinatesRoundTripThroughCropAndZoom() {
        let transform = LoupeViewportTransform(
            viewportSize: CGSize(width: 1_200, height: 900),
            fittedImageRect: CGRect(x: 150, y: 225, width: 900, height: 450),
            zoomScale: 1.75,
            zoomOffset: CGSize(width: 37, height: -29),
            cropX: 0.17,
            cropY: 0.08,
            cropW: 0.52,
            cropH: 0.73
        )
        let canonical = NormalizedPoint(x: 0.31, y: 0.61)
        let viewportPoint = transform.viewportPoint(forCanonical: canonical)
        let roundTrip = transform.canonicalNormalized(at: viewportPoint)

        #expect(close(roundTrip?.x, canonical.x))
        #expect(close(roundTrip?.y, canonical.y))

        let upper = transform.viewportPoint(
            forCanonical: NormalizedPoint(x: canonical.x, y: 0.2)
        )
        let lower = transform.viewportPoint(
            forCanonical: NormalizedPoint(x: canonical.x, y: 0.7)
        )
        #expect(upper.y < lower.y)
    }

    @Test func pointColorTapMapsThroughCropAndQuarterTurnToSource() throws {
        var settings = DevelopSettings()
        settings.cropX = 0.2
        settings.cropY = 0.1
        settings.cropW = 0.5
        settings.cropH = 0.6
        settings.rotationQuarterTurns = 1
        let transform = LoupeViewportTransform(
            viewportSize: CGSize(width: 1_000, height: 800),
            fittedImageRect: CGRect(x: 100, y: 100, width: 800, height: 600),
            cropX: settings.cropX,
            cropY: settings.cropY,
            cropW: settings.cropW,
            cropH: settings.cropH
        )
        let viewportPoint = transform.viewportPoint(
            forCropped: NormalizedPoint(x: 0.4, y: 0.75)
        )
        let source = try #require(transform.pointColorSourceNormalized(
            at: viewportPoint,
            sourceImageSize: CGSize(width: 400, height: 200),
            settings: settings
        ))

        #expect(close(source.x, 0.55))
        #expect(close(source.y, 0.6))
    }

    @Test func pointColorTapInvertsStraightenCoverTransform() throws {
        var settings = DevelopSettings()
        settings.straighten = 10
        let transform = LoupeViewportTransform(
            viewportSize: CGSize(width: 800, height: 400),
            fittedImageRect: CGRect(x: 0, y: 0, width: 800, height: 400)
        )
        let source = try #require(transform.pointColorSourceNormalized(
            at: transform.viewportPoint(forCropped: NormalizedPoint(x: 0.75, y: 0.5)),
            sourceImageSize: CGSize(width: 400, height: 200),
            settings: settings
        ))
        let angle = 10.0 * Double.pi / 180
        let coverScale = max(
            abs(cos(angle)) + abs(sin(angle)) * 0.5,
            abs(cos(angle)) + abs(sin(angle)) * 2
        )
        let expectedX = (200 + cos(angle) * 100 / coverScale) / 400
        let expectedY = 1 - (100 - sin(angle) * 100 / coverScale) / 200

        #expect(close(source.x, expectedX, tolerance: 0.000_001))
        #expect(close(source.y, expectedY, tolerance: 0.000_001))
    }

    @Test func generatedSpotOffsetsKeepTheWholeSourceInsideVisibleBounds() throws {
        let transform = LoupeViewportTransform(
            viewportSize: CGSize(width: 800, height: 400),
            fittedImageRect: CGRect(x: 0, y: 0, width: 800, height: 400)
        )
        let target = NormalizedPoint(x: 0.02, y: 0.5)
        let offset = try #require(transform.visibleSpotSourceOffset(
            from: target,
            normalizedRadius: 0.2
        ))
        let source = NormalizedPoint(x: target.x + offset.dx, y: target.y + offset.dy)
        #expect(source.x >= 0.2 && source.x <= 0.8)
        #expect(source.y >= 0.4 && source.y <= 0.6)

        let narrowCrop = LoupeViewportTransform(
            viewportSize: CGSize(width: 500, height: 500),
            fittedImageRect: CGRect(x: 0, y: 0, width: 500, height: 500),
            cropX: 0.4,
            cropY: 0.4,
            cropW: 0.1,
            cropH: 0.1
        )
        #expect(narrowCrop.visibleSpotSourceOffset(
            from: NormalizedPoint(x: 0.45, y: 0.45),
            normalizedRadius: 0.06
        ) == nil)
    }

    @Test func longEdgeRadiusAccountsForCropAndZoom() {
        let transform = LoupeViewportTransform(
            viewportSize: CGSize(width: 1_000, height: 700),
            fittedImageRect: CGRect(x: 200, y: 200, width: 600, height: 300),
            zoomScale: 2,
            cropX: 0.2,
            cropY: 0.1,
            cropW: 0.5,
            cropH: 0.5
        )

        #expect(close(
            transform.viewportRadius(forLongEdgeNormalizedRadius: 0.025),
            60
        ))
    }

    @Test func pointColorSamplerUsesTopLeftImageCoordinates() throws {
        let colorSpace = try #require(
            CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        )
        let bytes: [UInt8] = [
            255, 0, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 255, 255, 255, 255,
        ]
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 8,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))

        let topRight = try #require(PointColorImageSampler.extendedLinearDisplayP3(
            in: image,
            at: NormalizedPoint(x: 0.75, y: 0.25)
        ))
        let bottomLeft = try #require(PointColorImageSampler.extendedLinearDisplayP3(
            in: image,
            at: NormalizedPoint(x: 0.25, y: 0.75)
        ))

        #expect(close(topRight.x, 0))
        #expect(close(topRight.y, 1))
        #expect(close(topRight.z, 0))
        #expect(close(bottomLeft.x, 0))
        #expect(close(bottomLeft.y, 0))
        #expect(close(bottomLeft.z, 1))
    }

    @Test func pointColorSamplerConvertsEmbeddedColorSpaceToExtendedLinearDisplayP3() throws {
        let displayP3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let linearDisplayP3 = try #require(
            CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        )
        let bytes: [UInt8] = [191, 89, 38, 255]
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: displayP3,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let sample = try #require(PointColorImageSampler.extendedLinearDisplayP3(
            in: image,
            at: NormalizedPoint(x: 0.5, y: 0.5)
        ))
        let sourceComponents = bytes.map { CGFloat($0) / 255 }
        let sourceColor = try #require(CGColor(
            colorSpace: displayP3,
            components: sourceComponents
        ))
        let expected = try #require(sourceColor.converted(
            to: linearDisplayP3,
            intent: .defaultIntent,
            options: nil
        )?.components)

        #expect(close(sample.x, Double(expected[0]), tolerance: 0.001))
        #expect(close(sample.y, Double(expected[1]), tolerance: 0.001))
        #expect(close(sample.z, Double(expected[2]), tolerance: 0.001))
    }

    @Test func pointColorSamplerUnpremultipliesAndRejectsUnusablePixels() throws {
        let image = try makeLinearDisplayP3Image([
            (SIMD3(0.2, 0.6, 0.4), 1),
            (SIMD3(0.8, 0.3, 0.1), 0.25),
            (SIMD3(0.5, 0.4, 0.3), 0),
            (SIMD3(0.5, 0.4, 0.3), 1 / 1024),
            (SIMD3(1.2, 0.2, 0.3), 1),
            (SIMD3(-0.1, 0.2, 0.3), 1),
        ])
        let width = Double(image.width)
        func sample(_ index: Int) -> SIMD3<Double>? {
            PointColorImageSampler.extendedLinearDisplayP3(
                in: image,
                at: NormalizedPoint(x: (Double(index) + 0.5) / width, y: 0.5)
            )
        }

        let opaque = try #require(sample(0))
        #expect(close(opaque.x, 0.2, tolerance: 0.001))
        #expect(close(opaque.y, 0.6, tolerance: 0.001))
        #expect(close(opaque.z, 0.4, tolerance: 0.001))

        let translucent = try #require(sample(1))
        #expect(close(translucent.x, 0.8, tolerance: 0.001))
        #expect(close(translucent.y, 0.3, tolerance: 0.001))
        #expect(close(translucent.z, 0.1, tolerance: 0.001))

        #expect(sample(2) == nil)
        #expect(sample(3) == nil)
        #expect(sample(4) == nil)
        #expect(sample(5) == nil)
    }

    @Test func renderedGeometryKeyChangesOnlyWithAssetOrGeometry() {
        let assetID = UUID()
        var settings = DevelopSettings()
        let initial = LoupeRenderedGeometryKey(assetID: assetID, settings: settings)

        settings.exposure = 0.7
        #expect(LoupeRenderedGeometryKey(assetID: assetID, settings: settings) == initial)

        settings.cropW = 0.75
        #expect(LoupeRenderedGeometryKey(assetID: assetID, settings: settings) != initial)
        #expect(LoupeRenderedGeometryKey(assetID: UUID(), settings: DevelopSettings()) != initial)
    }

    @Test func establishedGestureOwnerBlocksTheOtherGestureUntilRelease() {
        var arbitration = DevelopGestureArbitration()
        let claimedEdit = arbitration.claim(.edit)
        let blockedMagnify = arbitration.claim(.magnify)
        #expect(claimedEdit)
        #expect(!blockedMagnify)
        arbitration.release(.magnify)
        #expect(arbitration.owner == .edit)
        arbitration.release(.edit)

        let claimedMagnify = arbitration.claim(.magnify)
        let blockedEdit = arbitration.claim(.edit)
        #expect(claimedMagnify)
        #expect(!blockedEdit)
        arbitration.release(.magnify)
        #expect(arbitration.owner == nil)
    }

    @Test func deferredEditGestureCleansCancellationExactlyOnce() {
        var state = DeferredEditGestureState()

        let firstUpdate = state.update(magnifyOwnsGesture: false)
        #expect(firstUpdate == .none)
        #expect(state.phase == .pending)
        let secondUpdate = state.update(magnifyOwnsGesture: false)
        #expect(secondUpdate == .claim)
        let claimed = state.resolveClaim(true)
        #expect(claimed)
        #expect(state.phase == .editing)
        let firstReset = state.reset()
        #expect(firstReset)
        #expect(state.phase == .idle)
        let secondReset = state.reset()
        #expect(!secondReset)
    }

    @Test func deferredEditGestureCommitsShortDragAndHonorsMagnify() {
        var shortDrag = DeferredEditGestureState()
        let shortUpdate = shortDrag.update(magnifyOwnsGesture: false)
        #expect(shortUpdate == .none)
        #expect(shortDrag.shouldClaimAtEnd)
        let shortClaimed = shortDrag.resolveClaim(true)
        #expect(shortClaimed)
        let shortReset = shortDrag.reset()
        #expect(shortReset)
        #expect(!shortDrag.shouldClaimAtEnd)

        var blocked = DeferredEditGestureState()
        let blockedUpdate = blocked.update(magnifyOwnsGesture: true)
        #expect(blockedUpdate == .none)
        #expect(blocked.phase == .blocked)
        #expect(!blocked.shouldClaimAtEnd)
        let blockedReset = blocked.reset()
        #expect(!blockedReset)
    }

    @Test func magnificationCancellationReleasesOwnershipExactlyOnce() {
        var active = MagnificationGestureState()
        #expect(active.needsClaim)
        let claimed = active.resolveClaim(true)
        #expect(claimed)
        #expect(active.isActive)
        let firstReset = active.reset()
        let secondReset = active.reset()
        #expect(firstReset)
        #expect(!secondReset)
        #expect(active.needsClaim)

        var blocked = MagnificationGestureState()
        let blockedClaim = blocked.resolveClaim(false)
        #expect(!blockedClaim)
        #expect(blocked.phase == .blocked)
        let blockedReset = blocked.reset()
        #expect(!blockedReset)
    }

    @Test func brushAvailabilityRespectsStructuralAndTotalPathLimits() {
        let fullStrokes = Array(
            repeating: BrushStroke(),
            count: MaskShape.maximumStrokeCount
        )
        let fullComponents = (0..<LocalMask.maximumComponentCount).map { _ in
            MaskComponent(shape: .brush(strokes: fullStrokes))
        }
        let selected = LocalMask(components: fullComponents)
        var structurallyFull = DevelopSettings()
        structurallyFull.masks = [selected]
        structurallyFull.masks.append(contentsOf: (1..<LocalMask.maximumCount).map { _ in
            LocalMask()
        })
        #expect(!DevelopToolAvailability.canActivate(
            .brush,
            settings: structurallyFull,
            selectedMaskID: selected.id
        ))

        let points = Array(
            repeating: NormalizedPoint(x: 0.5, y: 0.5),
            count: BrushStroke.maximumPointCount
        )
        let strokes = (0..<(
            SelectiveDevelopLimits.maximumTotalPathPoints / BrushStroke.maximumPointCount
        )).map { _ in BrushStroke(points: points) }
        var pathFull = DevelopSettings()
        pathFull.masks = [LocalMask(components: [
            MaskComponent(shape: .brush(strokes: strokes)),
        ])]
        #expect(pathFull.currentPathPointCount == SelectiveDevelopLimits.maximumTotalPathPoints)
        #expect(!DevelopToolAvailability.canActivate(
            .brush,
            settings: pathFull,
            selectedMaskID: pathFull.masks.first?.id
        ))
        #expect(!DevelopToolAvailability.canActivate(
            .spot,
            settings: pathFull,
            selectedMaskID: nil
        ))
    }

    private func close(_ lhs: Double?, _ rhs: Double, tolerance: Double = 0.000_001) -> Bool {
        guard let lhs else { return false }
        return abs(lhs - rhs) <= tolerance
    }

    private func close(_ lhs: CGFloat, _ rhs: Double, tolerance: Double = 0.000_001) -> Bool {
        abs(Double(lhs) - rhs) <= tolerance
    }

    private func makeLinearDisplayP3Image(
        _ pixels: [(rgb: SIMD3<Float>, alpha: Float)]
    ) throws -> CGImage {
        let colorSpace = try #require(
            CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        )
        let components = pixels.flatMap { pixel in
            [
                pixel.rgb.x * pixel.alpha,
                pixel.rgb.y * pixel.alpha,
                pixel.rgb.z * pixel.alpha,
                pixel.alpha,
            ]
        }
        let data = components.withUnsafeBytes { Data($0) }
        let provider = try #require(CGDataProvider(data: data as CFData))
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            .union(.floatComponents)
            .union(.byteOrder32Little)
        return try #require(CGImage(
            width: pixels.count,
            height: 1,
            bitsPerComponent: 32,
            bitsPerPixel: 128,
            bytesPerRow: pixels.count * 4 * MemoryLayout<Float>.size,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }
}
