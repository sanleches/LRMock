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

    /// Writes the sidecar next to the asset's original file (best-effort).
    /// Silently no-ops if the file can't be reached (e.g. external volume
    /// currently offline) — the catalog remains the live source of truth.
    static func writeSidecar(for asset: ImageAsset) {
        try? AssetFileAccess.withAccess(asset) { url in
            try SidecarService.write(SidecarService.snapshot(of: asset), for: url)
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

    private var pending: Task<Void, Never>?

    /// Schedules a sidecar write for `asset` after `delay` of no further changes.
    func schedule(_ asset: ImageAsset, delay: Duration = .seconds(1)) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            EditPersistence.writeSidecar(for: asset)
        }
    }

    /// Cancels any pending write and persists immediately.
    func flush(_ asset: ImageAsset) {
        pending?.cancel()
        pending = nil
        EditPersistence.writeSidecar(for: asset)
    }
}
