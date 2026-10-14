//
//  LibraryTrash.swift
//  RawLight
//
//  Moves managed originals and recipes into a recoverable package before their
//  catalog row is removed. A receipt can restore filesystem state if the catalog
//  save fails.
//

import Foundation

nonisolated enum LibraryTrash {
    struct Manifest: Codable, Sendable {
        let assetID: UUID
        let originalFilename: String
        let managedRelativePath: String
        let deletedAt: Date
    }

    struct Receipt: Sendable {
        fileprivate let packageURL: URL
        fileprivate let moves: [(source: URL, destination: URL)]

        func restore() throws {
            let fm = FileManager.default
            for move in moves.reversed() where fm.fileExists(atPath: move.destination.path) {
                try fm.createDirectory(
                    at: move.source.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fm.moveItem(at: move.destination, to: move.source)
            }
            if fm.fileExists(atPath: packageURL.path) {
                try fm.removeItem(at: packageURL)
            }
        }
    }

    static func moveManagedAsset(
        id: UUID,
        originalFilename: String,
        managedRelativePath: String
    ) throws -> Receipt {
        let fm = FileManager.default
        let originalURL = try LibraryLocations.url(
            forManagedRelativePath: managedRelativePath,
            expectedAssetID: id
        )
        let originalDirectory = originalURL.deletingLastPathComponent()
        let recipeURL = LibraryLocations.recipeURL(assetID: id)
        let packageURL = LibraryLocations.trash
            .appendingPathComponent("\(id.uuidString)-\(UUID().uuidString)", isDirectory: true)
        let trashedOriginal = packageURL.appendingPathComponent("Original", isDirectory: true)
        let trashedRecipe = packageURL.appendingPathComponent("Recipe.rawlight.json")
        var completedMoves: [(source: URL, destination: URL)] = []

        do {
            try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)
            let manifest = Manifest(
                assetID: id,
                originalFilename: originalFilename,
                managedRelativePath: managedRelativePath,
                deletedAt: .now
            )
            let data = try JSONEncoder().encode(manifest)
            try data.write(
                to: packageURL.appendingPathComponent("Manifest.json"),
                options: [.atomic]
            )

            if fm.fileExists(atPath: originalDirectory.path) {
                try fm.moveItem(at: originalDirectory, to: trashedOriginal)
                completedMoves.append((originalDirectory, trashedOriginal))
            }
            if fm.fileExists(atPath: recipeURL.path) {
                try fm.moveItem(at: recipeURL, to: trashedRecipe)
                completedMoves.append((recipeURL, trashedRecipe))
            }

            return Receipt(packageURL: packageURL, moves: completedMoves)
        } catch {
            let receipt = Receipt(packageURL: packageURL, moves: completedMoves)
            try? receipt.restore()
            throw error
        }
    }
}
