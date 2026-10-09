//
//  ContentDigest.swift
//  RawLight
//
//  Complete cryptographic content digest of a source file, used as the canonical
//  identity for managed originals, recipes, and exports
//  (docs/architecture/catalog-and-persistence.md: "Source Identity"). Unlike a
//  quick fingerprint, this covers every byte, so a same-size file that changed
//  outside sampled blocks cannot be mistaken for the same source.
//
//  Streams the file in bounded chunks so large RAWs don't load fully into memory.
//

import Foundation
import CryptoKit

nonisolated enum ContentDigest {

    /// Returns a `"sha256:<hex>"` digest of the complete file.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1 << 20 // 1 MB
        while true {
            let data = try handle.read(upToCount: chunkSize)
            guard let data, !data.isEmpty else { break }
            hasher.update(data: data)
        }
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
    }
}
