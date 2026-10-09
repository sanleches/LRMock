//
//  EditPersistence.swift
//  RawLight
//
//  Writes a catalog asset's current metadata + develop recipe back out to its
//  portable `.rawlight` sidecar, and provides a debounced autosaver so live
//  editing doesn't hammer the disk on every slider tick.
//
//  The SwiftData catalog autosaves on its own; this is specifically about
//  keeping the *sidecar* (the portable, next-to-RAW copy) in sync so edits
//  survive a catalog rebuild or move to another device.
//

import Foundation

@MainActor
enum EditPersistence {

    /// Persists the asset's edit recipe + culling metadata to the canonical
    /// location for its storage mode:
    ///   * managed → the library's `Recipes/<assetID>.rawlight.json`
    ///   * referenced → a `.rawlight` sidecar next to the external original
    static func writeSidecar(for asset: ImageAsset) throws {
        switch asset.storageMode {
        case .managed:
            try RecipeStore.write(for: asset)
        case .referenced:
            try AssetFileAccess.withAccess(asset) { url in
                try SidecarService.write(SidecarService.snapshot(of: asset), for: url)
            }
        }
    }
}

/// Coalesces rapid edits into a single sidecar write after a quiet period.
///
/// Usage: keep one instance alive in the editing view, call `schedule(_:)` on
/// every change, and `flush(_:)` when leaving the editor to persist immediately.
@MainActor
@Observable
final class SidecarAutosaver {

    private var pending: [UUID: Task<Void, Never>] = [:]
    private var assets: [UUID: ImageAsset] = [:]
    private var tokens: [UUID: UUID] = [:]
    var lastError: String?

    /// Schedules a sidecar write for `asset` after `delay` of no further changes.
    func schedule(_ asset: ImageAsset, delay: Duration = .seconds(1)) {
        let id = asset.id
        let token = UUID()
        pending[id]?.cancel()
        assets[id] = asset
        tokens[id] = token
        pending[id] = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, tokens[id] == token else { return }
            persist(asset)
            if tokens[id] == token {
                pending[id] = nil
                assets[id] = nil
                tokens[id] = nil
            }
        }
    }

    /// Cancels any pending write and persists immediately.
    func flush(_ asset: ImageAsset) {
        let id = asset.id
        pending[id]?.cancel()
        pending[id] = nil
        assets[id] = nil
        tokens[id] = nil
        persist(asset)
    }

    func flushAll() {
        let pendingAssets = Array(assets.values)
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        assets.removeAll()
        tokens.removeAll()
        pendingAssets.forEach(persist)
    }

    func dismissError() {
        lastError = nil
    }

    private func persist(_ asset: ImageAsset) {
        do {
            try EditPersistence.writeSidecar(for: asset)
        } catch {
            lastError = error.localizedDescription
        }
    }
}
