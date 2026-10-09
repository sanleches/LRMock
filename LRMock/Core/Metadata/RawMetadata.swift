//
//  RawMetadata.swift
//  RawLight
//
//  Reads immutable capture metadata (EXIF/TIFF) and pixel dimensions straight
//  from a file's header using ImageIO. This works for camera RAW formats as well
//  as JPEG/HEIC/TIFF/PNG, and only reads the header — it never decodes full
//  pixels, so it is fast enough to run during import.
//

import Foundation
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

/// Plain snapshot of a file's capture metadata, copied into `ImageAsset` so the
/// UI never has to touch the original file to show EXIF.
nonisolated struct RawMetadata: Sendable {
    var captureDate: Date?
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var iso: Int?
    var focalLength: Double?
    var aperture: Double?
    var shutterSpeed: String?
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    var orientation: Int = 1
}

nonisolated enum MetadataExtractor {

    /// Extracts metadata from the file at `url`. Returns an empty-ish value
    /// (dimensions 0) if the file cannot be read, rather than throwing, so a
    /// single bad file never aborts a bulk import.
    static func read(from url: URL) -> RawMetadata {
        var meta = RawMetadata()

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return meta }

        meta.pixelWidth = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        meta.pixelHeight = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        meta.orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1

        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            meta.cameraMake = tiff[kCGImagePropertyTIFFMake] as? String
            meta.cameraModel = tiff[kCGImagePropertyTIFFModel] as? String
        }

        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            meta.iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
            meta.focalLength = exif[kCGImagePropertyExifFocalLength] as? Double
            meta.aperture = exif[kCGImagePropertyExifFNumber] as? Double
            meta.lensModel = exif[kCGImagePropertyExifLensModel] as? String
            meta.captureDate = parseExifDate(exif[kCGImagePropertyExifDateTimeOriginal] as? String)
            if let exposure = exif[kCGImagePropertyExifExposureTime] as? Double {
                meta.shutterSpeed = formatShutter(exposure)
            }
        }

        return meta
    }

    // MARK: Helpers

    /// EXIF stores dates as "yyyy:MM:dd HH:mm:ss" in local time (no zone).
    private static func parseExifDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.date(from: string)
    }

    /// Converts an exposure time in seconds to a human string (e.g. `1/250s`).
    private static func formatShutter(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        if seconds >= 1 { return String(format: "%.0fs", seconds) }
        return "1/\(Int((1.0 / seconds).rounded()))s"
    }
}
