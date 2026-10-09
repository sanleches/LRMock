//
//  DevelopClipboard.swift
//  RawLight
//
//  Holds a copied `DevelopSettings` recipe so it can be pasted onto other photos
//  (a lightweight "copy/paste settings", like Lightroom). Geometry (crop/rotate)
//  is intentionally excluded on paste because it's image-specific.
//

import Foundation

@MainActor
enum DevelopClipboard {
    static var settings: DevelopSettings?

    /// Pastes copied settings onto `target`, preserving the target's geometry.
    static func paste(onto target: inout DevelopSettings) {
        guard let s = settings else { return }
        let cropX = target.cropX, cropY = target.cropY, cropW = target.cropW, cropH = target.cropH
        let straighten = target.straighten, flipH = target.flipH, flipV = target.flipV
        let turns = target.rotationQuarterTurns
        target = s
        target.cropX = cropX; target.cropY = cropY; target.cropW = cropW; target.cropH = cropH
        target.straighten = straighten; target.flipH = flipH; target.flipV = flipV
        target.rotationQuarterTurns = turns
    }
}
