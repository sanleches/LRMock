//
//  DevelopSettings.swift
//  RawLight
//
//  The non-destructive "recipe" applied to a RAW file at render/export time.
//
//  Design notes
//  ------------
//  * This is a plain `Codable` value type, NOT a SwiftData model. It is stored
//    inline on `ImageAsset` (SwiftData persists `Codable` structs as an opaque
//    attribute) *and* serialized verbatim into the `.rawlight` sidecar next to
//    the original file. One definition, two persistence targets, zero drift.
//  * The RAW file itself is never modified. Everything here is applied by the
//    `RawPipeline` when producing a preview or an export.
//  * Slider values are normalised to `-1...1` (or `0...1` where a control is
//    one-sided). The imaging pipeline owns the mapping from these neutral units
//    to concrete filter parameters (EV, Kelvin, pixel radius, …). Keeping the
//    stored values unit-less means we can retune the look in Phase 2 (Metal /
//    RawTherapee-derived kernels) without migrating anyone's edits.
//  * `schemaVersion` lets us evolve the field set and migrate old sidecars.
//

import Foundation

struct DevelopSettings: Codable, Equatable, Sendable {

    /// Bump when the field set changes in a non-additive way; drives migration.
    var schemaVersion: Int = DevelopSettings.currentSchemaVersion
    static let currentSchemaVersion = 1

    // MARK: White balance
    /// Warm (+) / cool (-) shift. Pipeline maps to a Kelvin offset.
    var temperature: Double = 0        // -1...1
    /// Green (-) / magenta (+) shift.
    var tint: Double = 0               // -1...1

    // MARK: Tone
    /// Overall exposure. Pipeline maps to EV.
    var exposure: Double = 0           // -1...1
    var contrast: Double = 0           // -1...1
    var highlights: Double = 0         // -1...1
    var shadows: Double = 0            // -1...1
    var whites: Double = 0             // -1...1
    var blacks: Double = 0             // -1...1

    // MARK: Presence
    var vibrance: Double = 0           // -1...1
    var saturation: Double = 0         // -1...1

    // MARK: Detail
    var sharpness: Double = 0          // 0...1
    var noiseReduction: Double = 0     // 0...1

    // MARK: Geometry
    /// Clockwise orientation applied on top of the file's EXIF orientation.
    var rotationQuarterTurns: Int = 0  // 0, 1, 2, 3  (× 90°)

    init() {}
}

extension DevelopSettings {

    /// `true` when no adjustment has been made (ignoring bookkeeping fields).
    /// Used to show the "edited" badge and to decide whether a sidecar is worth
    /// writing.
    var isIdentity: Bool {
        var baseline = DevelopSettings()
        baseline.schemaVersion = schemaVersion
        return self == baseline
    }

    /// Resets every adjustment while preserving the schema version.
    mutating func reset() {
        let version = schemaVersion
        self = DevelopSettings()
        schemaVersion = version
    }
}
