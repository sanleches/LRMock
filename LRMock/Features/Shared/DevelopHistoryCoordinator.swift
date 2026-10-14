//
//  DevelopHistoryCoordinator.swift
//  RawLight
//
//  Asset-scoped snapshot history for non-destructive develop edits.
//

import Foundation
import Observation

nonisolated struct DevelopHistoryTransaction: Equatable, Hashable, Sendable {
    fileprivate let id: UUID
    let assetID: UUID
}

@MainActor
@Observable
final class DevelopHistoryCoordinator {
    private struct Change {
        let before: DevelopSettings
        let after: DevelopSettings
    }

    private struct PendingChange {
        let transaction: DevelopHistoryTransaction
        let before: DevelopSettings
        var current: DevelopSettings
    }

    private static let maximumDepth = 100

    private(set) var activeAssetID: UUID?
    private var undoChanges: [Change] = []
    private var redoChanges: [Change] = []
    private var pendingChange: PendingChange?

    var canUndo: Bool { pendingChange == nil && !undoChanges.isEmpty }
    var canRedo: Bool { pendingChange == nil && !redoChanges.isEmpty }

    /// Selecting another photo starts a fresh timeline. The asset ID checks on
    /// every operation also prevent a stale inspector from applying a snapshot.
    func activate(assetID: UUID?) {
        guard activeAssetID != assetID else { return }
        activeAssetID = assetID
        undoChanges.removeAll()
        redoChanges.removeAll()
        pendingChange = nil
    }

    @discardableResult
    func beginChange(
        for assetID: UUID,
        current: DevelopSettings
    ) -> DevelopHistoryTransaction? {
        guard activeAssetID == assetID, pendingChange == nil else { return nil }
        let transaction = DevelopHistoryTransaction(id: UUID(), assetID: assetID)
        pendingChange = PendingChange(
            transaction: transaction,
            before: current,
            current: current
        )
        return transaction
    }

    @discardableResult
    func updateChange(
        _ transaction: DevelopHistoryTransaction,
        current: DevelopSettings
    ) -> Bool {
        guard activeAssetID == transaction.assetID,
              pendingChange?.transaction == transaction else { return false }
        pendingChange?.current = current
        return true
    }

    @discardableResult
    func endChange(
        _ transaction: DevelopHistoryTransaction,
        current: DevelopSettings? = nil
    ) -> Bool {
        guard activeAssetID == transaction.assetID,
              let pendingChange,
              pendingChange.transaction == transaction else { return false }
        self.pendingChange = nil
        append(before: pendingChange.before, after: current ?? pendingChange.current)
        return true
    }

    @discardableResult
    func cancelChange(_ transaction: DevelopHistoryTransaction) -> Bool {
        guard activeAssetID == transaction.assetID,
              pendingChange?.transaction == transaction else { return false }
        pendingChange = nil
        return true
    }

    @discardableResult
    func registerChange(
        for assetID: UUID,
        before: DevelopSettings,
        after: DevelopSettings
    ) -> Bool {
        guard let transaction = beginChange(for: assetID, current: before) else { return false }
        return endChange(transaction, current: after)
    }

    func undo(for assetID: UUID, current: DevelopSettings) -> DevelopSettings? {
        guard activeAssetID == assetID, pendingChange == nil else { return nil }
        guard let change = undoChanges.last else { return nil }

        guard change.after == current else {
            discardTimeline()
            return nil
        }

        undoChanges.removeLast()
        redoChanges.append(change)
        return change.before
    }

    func redo(for assetID: UUID, current: DevelopSettings) -> DevelopSettings? {
        guard activeAssetID == assetID, pendingChange == nil,
              let change = redoChanges.last else { return nil }

        guard change.before == current else {
            discardTimeline()
            return nil
        }

        redoChanges.removeLast()
        undoChanges.append(change)
        return change.after
    }

    private func append(before: DevelopSettings, after: DevelopSettings) {
        guard before != after else { return }
        undoChanges.append(Change(before: before, after: after))
        if undoChanges.count > Self.maximumDepth {
            undoChanges.removeFirst(undoChanges.count - Self.maximumDepth)
        }
        redoChanges.removeAll()
    }

    private func discardTimeline() {
        undoChanges.removeAll()
        redoChanges.removeAll()
        pendingChange = nil
    }
}
