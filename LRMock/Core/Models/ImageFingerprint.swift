//
//  ImageFingerprint.swift
//  RawLight
//
//  A stable identity for a RAW file that survives moves and re-imports.
//
//  Why not just use the file path / bookmark?
//  ------------------------------------------
//  Security-scoped bookmarks go stale when a file is moved, a volume is
//  remounted, or the library is rebuilt on another device. When that happens we
//  need a way to recognise "this is the same photo" so the user's edits re-link
//  instead of being lost. Lightroom / Capture One solve this the same way: match
//  on filename + capture time + size.
//
//  The fingerprint is deliberately cheap to compute (no full-file hashing of a
//  40 MB RAW). An optional short content hash of the file header can be added
//  for extra confidence without reading the whole file.
//

import Foundation

nonisolated struct ImageFingerprint: Codable, Hashable, Sendable {

    /// Original file name including extension, e.g. `DSCF1234.RAF`.
    var filename: String

    /// File size in bytes. Cheap and highly discriminating.
    var fileSizeBytes: Int64

    /// EXIF `DateTimeOriginal` when available. The single most reliable key.
    var captureDate: Date?

    /// Optional hex digest of the first few KB of the file (set by the importer
    /// when extra certainty is desired). `nil` keeps matching header-free.
    var headerHash: String?

    init(filename: String,
         fileSizeBytes: Int64,
         captureDate: Date? = nil,
         headerHash: String? = nil) {
        self.filename = filename
        self.fileSizeBytes = fileSizeBytes
        self.captureDate = captureDate
        self.headerHash = headerHash
    }
}

nonisolated extension ImageFingerprint {

    /// Confidence that `self` and `other` identify the same physical file.
    /// Used when re-linking a "missing" asset to a freshly imported file.
    enum MatchStrength: Int { case none, weak, strong, exact }

    func match(_ other: ImageFingerprint) -> MatchStrength {
        if let a = headerHash, let b = other.headerHash, a == b,
           fileSizeBytes == other.fileSizeBytes {
            return .exact
        }
        let sameName = filename.caseInsensitiveCompare(other.filename) == .orderedSame
        let sameSize = fileSizeBytes == other.fileSizeBytes
        let sameDate = captureDate == other.captureDate

        switch (sameName, sameSize, sameDate) {
        case (true, true, true):   return .strong
        case (true, true, false),
             (true, false, true),
             (false, true, true):  return .weak
        default:                   return .none
        }
    }
}
