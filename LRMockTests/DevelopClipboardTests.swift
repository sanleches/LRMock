//
//  DevelopClipboardTests.swift
//  LRMockTests
//

import Foundation
import Testing
@testable import LRMock

@MainActor
@Suite(.serialized)
struct DevelopClipboardTests {

    @Test func samePhotoPastePreservesTargetGeometryAndSpatialEdits() {
        defer { DevelopClipboard.clear() }

        let assetID = UUID()
        let source = sourceIdentity(assetID: assetID)
        let matchingPointColorID = UUID()
        let copiedOnlyPointColorID = UUID()
        var copied = DevelopSettings()
        copied.schemaVersion = 1
        copied.exposure = 0.6
        copied.cropX = 0.4; copied.cropY = 0.3; copied.cropW = 0.5; copied.cropH = 0.6
        copied.straighten = -12; copied.flipH = false; copied.flipV = true
        copied.rotationQuarterTurns = 3
        copied.geometryVertical = -0.8; copied.geometryHorizontal = 0.7
        copied.geometryAspect = -0.6; copied.geometryScale = 0.75
        copied.geometryOffsetX = 0.5; copied.geometryOffsetY = -0.4
        copied.pointColors = [
            PointColorAdjustment(
                id: matchingPointColorID,
                hueShift: 0.35,
                location: NormalizedPoint(x: 0.2, y: 0.8)
            ),
            PointColorAdjustment(
                id: copiedOnlyPointColorID,
                hueShift: -0.2,
                location: NormalizedPoint(x: 0.9, y: 0.1)
            ),
        ]
        copied.masks = [LocalMask(name: "Copied")]
        copied.spots = [SpotCorrection(points: [NormalizedPoint(x: 0.1, y: 0.1)])]
        copied.redEyes = [RedEyeCorrection(center: NormalizedPoint(x: 0.2, y: 0.2))]
        let copiedBeforePaste = copied
        DevelopClipboard.copy(copied, from: source)

        var target = DevelopSettings()
        target.cropX = 0.1; target.cropY = 0.2; target.cropW = 0.8; target.cropH = 0.7
        target.straighten = 8; target.flipH = true; target.flipV = false
        target.rotationQuarterTurns = 1
        target.geometryVertical = 0.1; target.geometryHorizontal = -0.2
        target.geometryAspect = 0.3; target.geometryScale = 1.25
        target.geometryOffsetX = -0.15; target.geometryOffsetY = 0.25
        let targetPointColorLocation = NormalizedPoint(x: 0.65, y: 0.45)
        target.pointColors = [PointColorAdjustment(
            id: matchingPointColorID,
            location: targetPointColorLocation
        )]
        let targetMasks = [LocalMask(name: "Target")]
        let targetSpots = [SpotCorrection(points: [NormalizedPoint(x: 0.7, y: 0.6)])]
        let targetRedEyes = [RedEyeCorrection(center: NormalizedPoint(x: 0.8, y: 0.7))]
        target.masks = targetMasks
        target.spots = targetSpots
        target.redEyes = targetRedEyes

        DevelopClipboard.paste(onto: &target, targetSource: source)

        #expect(target.schemaVersion == DevelopSettings.currentSchemaVersion)
        #expect(target.exposure == copied.exposure)
        #expect(target.pointColors.count == 2)
        #expect(target.pointColors[0].hueShift == copied.pointColors[0].hueShift)
        #expect(target.pointColors[0].location == targetPointColorLocation)
        #expect(target.pointColors[1].id == copiedOnlyPointColorID)
        #expect(target.pointColors[1].location == nil)
        #expect(copied == copiedBeforePaste)
        #expect(target.masks == targetMasks)
        #expect(target.spots == targetSpots)
        #expect(target.redEyes == targetRedEyes)
        #expect(target.cropX == 0.1 && target.cropY == 0.2)
        #expect(target.cropW == 0.8 && target.cropH == 0.7)
        #expect(target.straighten == 8)
        #expect(target.flipH && !target.flipV)
        #expect(target.rotationQuarterTurns == 1)
        #expect(target.geometryVertical == 0.1)
        #expect(target.geometryHorizontal == -0.2)
        #expect(target.geometryAspect == 0.3)
        #expect(target.geometryScale == 1.25)
        #expect(target.geometryOffsetX == -0.15)
        #expect(target.geometryOffsetY == 0.25)
    }

    @Test func crossPhotoPasteClearsPointColorLocationsEvenWhenIDsMatch() {
        defer { DevelopClipboard.clear() }

        let matchingID = UUID()
        let source = sourceIdentity(assetID: UUID())
        var copied = DevelopSettings()
        copied.exposure = 0.4
        copied.pointColors = [PointColorAdjustment(
            id: matchingID,
            hueShift: 0.3,
            location: NormalizedPoint(x: 0.1, y: 0.2)
        )]
        DevelopClipboard.copy(copied, from: source)

        var target = DevelopSettings()
        target.pointColors = [PointColorAdjustment(
            id: matchingID,
            location: NormalizedPoint(x: 0.8, y: 0.9)
        )]
        let targetMasks = [LocalMask(name: "Target")]
        target.masks = targetMasks

        DevelopClipboard.paste(
            onto: &target,
            targetSource: sourceIdentity(assetID: UUID())
        )

        #expect(target.exposure == 0.4)
        #expect(target.pointColors.map(\.id) == [matchingID])
        #expect(target.pointColors[0].location == nil)
        #expect(target.masks == targetMasks)
    }

    @Test func pasteNormalizesCrossTypeIDCollisionsAndPathBudget() {
        defer { DevelopClipboard.clear() }

        let collision = UUID()
        let source = sourceIdentity(assetID: UUID())
        let point = NormalizedPoint(x: 0.25, y: 0.75)
        var copied = DevelopSettings()
        copied.exposure = 9
        copied.pointColors = [PointColorAdjustment(
            id: collision,
            hueShift: 0.2,
            location: point
        )]
        let copiedBeforePaste = copied
        DevelopClipboard.copy(copied, from: source)

        let fullStroke = BrushStroke(
            points: Array(repeating: point, count: BrushStroke.maximumPointCount)
        )
        let overBudgetShape = MaskShape.brush(strokes: Array(repeating: fullStroke, count: 5))
        var target = DevelopSettings()
        target.masks = [LocalMask(
            id: collision,
            components: [MaskComponent(shape: overBudgetShape)]
        )]

        DevelopClipboard.paste(
            onto: &target,
            targetSource: sourceIdentity(assetID: UUID())
        )

        let entityIDs = target.pointColors.map(\.id) + target.masks.map(\.id)
        #expect(Set(entityIDs).count == entityIDs.count)
        #expect(target.currentPathPointCount == SelectiveDevelopLimits.maximumTotalPathPoints)
        #expect(target.exposure == 1)
        #expect(target == target.normalizedForPersistence())
        #expect(copied == copiedBeforePaste)
    }

    @Test func matchingSourceNormalizesDuplicatePointColorIDsBeforeLocationMatching() {
        defer { DevelopClipboard.clear() }

        let source = sourceIdentity(assetID: UUID())
        let duplicateID = UUID()
        var copied = DevelopSettings()
        copied.pointColors = [
            PointColorAdjustment(id: duplicateID, hueShift: 0.1),
            PointColorAdjustment(id: duplicateID, hueShift: 0.2),
        ]
        DevelopClipboard.copy(copied, from: source)

        let firstLocation = NormalizedPoint(x: 0.2, y: 0.3)
        let secondLocation = NormalizedPoint(x: 0.7, y: 0.8)
        var target = DevelopSettings()
        target.pointColors = [
            PointColorAdjustment(id: duplicateID, location: firstLocation),
            PointColorAdjustment(id: duplicateID, location: secondLocation),
        ]

        DevelopClipboard.paste(onto: &target, targetSource: source)

        #expect(Set(target.pointColors.map(\.id)).count == 2)
        #expect(target.pointColors.map(\.location) == [firstLocation, secondLocation])
    }

    @Test func matchingAssetUUIDRequiresSameContentAndLibrary() {
        defer { DevelopClipboard.clear() }

        let assetID = UUID()
        let pointColorID = UUID()
        let copiedSource = sourceIdentity(
            libraryIdentifier: "library-a",
            assetID: assetID,
            contentDigest: "sha256:source-a"
        )
        var copied = DevelopSettings()
        copied.pointColors = [PointColorAdjustment(id: pointColorID, hueShift: 0.3)]
        DevelopClipboard.copy(copied, from: copiedSource)

        let mismatchedSources = [
            sourceIdentity(
                libraryIdentifier: "library-a",
                assetID: assetID,
                contentDigest: "sha256:changed-source"
            ),
            sourceIdentity(
                libraryIdentifier: "library-b",
                assetID: assetID,
                contentDigest: "sha256:source-a"
            ),
        ]

        for targetSource in mismatchedSources {
            var target = DevelopSettings()
            target.pointColors = [PointColorAdjustment(
                id: pointColorID,
                location: NormalizedPoint(x: 0.6, y: 0.4)
            )]

            DevelopClipboard.paste(onto: &target, targetSource: targetSource)
            #expect(target.pointColors[0].location == nil)
        }
    }

    @Test func exactFingerprintIdentifiesSameSourceWhenBothDigestsAreMissing() {
        defer { DevelopClipboard.clear() }

        let source = sourceIdentity(assetID: UUID(), contentDigest: nil)
        let pointColorID = UUID()
        var copied = DevelopSettings()
        copied.pointColors = [PointColorAdjustment(id: pointColorID, hueShift: 0.2)]
        DevelopClipboard.copy(copied, from: source)

        let location = NormalizedPoint(x: 0.3, y: 0.7)
        var target = DevelopSettings()
        target.pointColors = [PointColorAdjustment(id: pointColorID, location: location)]
        DevelopClipboard.paste(onto: &target, targetSource: source)

        #expect(target.pointColors[0].location == location)
    }

    private func sourceIdentity(
        libraryIdentifier: String = "library-a",
        assetID: UUID,
        contentDigest: String? = "sha256:source-a"
    ) -> DevelopClipboard.SourceIdentity {
        DevelopClipboard.SourceIdentity(
            libraryIdentifier: libraryIdentifier,
            assetID: assetID,
            contentDigest: contentDigest,
            fingerprint: ImageFingerprint(
                filename: "photo.raw",
                fileSizeBytes: 8,
                captureDate: Date(timeIntervalSince1970: 1_000),
                headerHash: "header"
            )
        )
    }
}
