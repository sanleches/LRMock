//
//  DevelopClipboard.swift
//  RawLight
//
//  Holds a copied `DevelopSettings` recipe so it can be pasted onto other photos
//  (a lightweight "copy/paste settings", like Lightroom). Image-specific
//  geometry and spatial edits are intentionally excluded on paste.
//

import Foundation

@MainActor
enum DevelopClipboard {
    struct SourceIdentity: Equatable, Sendable {
        let libraryIdentifier: String
        let assetID: UUID
        let contentDigest: String?
        let fingerprint: ImageFingerprint

        init(
            libraryIdentifier: String,
            assetID: UUID,
            contentDigest: String?,
            fingerprint: ImageFingerprint
        ) {
            self.libraryIdentifier = libraryIdentifier
            self.assetID = assetID
            self.contentDigest = contentDigest?.isEmpty == false ? contentDigest : nil
            self.fingerprint = fingerprint
        }

        fileprivate func identifiesSameSource(as other: SourceIdentity) -> Bool {
            guard libraryIdentifier == other.libraryIdentifier,
                  assetID == other.assetID else {
                return false
            }

            switch (contentDigest, other.contentDigest) {
            case let (sourceDigest?, targetDigest?):
                return sourceDigest == targetDigest
            case (nil, nil):
                return fingerprint == other.fingerprint
            default:
                return false
            }
        }
    }

    private struct Payload {
        let source: SourceIdentity
        let settings: DevelopSettings
    }

    private static var payload: Payload?

    static var hasSettings: Bool { payload != nil }

    static func copy(_ settings: DevelopSettings, from source: SourceIdentity) {
        payload = Payload(source: source, settings: settings.normalizedForPersistence())
    }

    static func clear() {
        payload = nil
    }

    /// Pastes copied settings onto `target`, preserving the target's geometry.
    static func paste(onto target: inout DevelopSettings, targetSource: SourceIdentity) {
        guard let payload else { return }
        let normalizedTarget = target.normalizedForPersistence()
        let cropX = normalizedTarget.cropX, cropY = normalizedTarget.cropY
        let cropW = normalizedTarget.cropW, cropH = normalizedTarget.cropH
        let straighten = normalizedTarget.straighten
        let flipH = normalizedTarget.flipH, flipV = normalizedTarget.flipV
        let vertical = normalizedTarget.geometryVertical
        let horizontal = normalizedTarget.geometryHorizontal
        let aspect = normalizedTarget.geometryAspect, scale = normalizedTarget.geometryScale
        let offsetX = normalizedTarget.geometryOffsetX, offsetY = normalizedTarget.geometryOffsetY
        let turns = normalizedTarget.rotationQuarterTurns
        let masks = normalizedTarget.masks
        let spots = normalizedTarget.spots
        let redEyes = normalizedTarget.redEyes
        let preservesPointColorLocations = payload.source.identifiesSameSource(as: targetSource)
        var pointColorLocations: [UUID: NormalizedPoint] = [:]
        if preservesPointColorLocations {
            for adjustment in normalizedTarget.pointColors {
                if let location = adjustment.location, pointColorLocations[adjustment.id] == nil {
                    pointColorLocations[adjustment.id] = location
                }
            }
        }

        var merged = payload.settings
        merged.cropX = cropX; merged.cropY = cropY; merged.cropW = cropW; merged.cropH = cropH
        merged.straighten = straighten; merged.flipH = flipH; merged.flipV = flipV
        merged.geometryVertical = vertical; merged.geometryHorizontal = horizontal
        merged.geometryAspect = aspect; merged.geometryScale = scale
        merged.geometryOffsetX = offsetX; merged.geometryOffsetY = offsetY
        merged.rotationQuarterTurns = turns
        merged.masks = masks; merged.spots = spots; merged.redEyes = redEyes
        merged.pointColors = merged.pointColors.map { adjustment in
            var copied = adjustment
            copied.location = pointColorLocations[copied.id]
            return copied
        }
        target = merged.normalizedForPersistence()
    }
}
