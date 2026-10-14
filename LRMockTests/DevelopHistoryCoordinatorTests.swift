//
//  DevelopHistoryCoordinatorTests.swift
//  LRMockTests
//

import Foundation
import Testing
@testable import LRMock

@MainActor
struct DevelopHistoryCoordinatorTests {
    @Test func groupsContinuousChangesIntoOneUndoStep() throws {
        let assetID = UUID()
        let history = DevelopHistoryCoordinator()
        let original = DevelopSettings()
        var edited = original

        history.activate(assetID: assetID)
        let transaction = try #require(history.beginChange(for: assetID, current: original))
        edited.exposure = 0.1
        edited.exposure = 0.4
        edited.exposure = 0.75
        #expect(history.updateChange(transaction, current: edited))
        #expect(history.endChange(transaction))

        #expect(history.canUndo)
        #expect(history.undo(for: assetID, current: edited) == original)
        #expect(!history.canUndo)
        #expect(history.canRedo)
        #expect(history.redo(for: assetID, current: original) == edited)
    }

    @Test func discreteChangeIsUndoableAndNewChangeClearsRedo() {
        let assetID = UUID()
        let history = DevelopHistoryCoordinator()
        let original = DevelopSettings()
        var exposureEdit = original
        exposureEdit.exposure = 0.5

        history.activate(assetID: assetID)
        history.registerChange(for: assetID, before: original, after: exposureEdit)
        #expect(history.undo(for: assetID, current: exposureEdit) == original)
        #expect(history.canRedo)

        var contrastEdit = original
        contrastEdit.contrast = -0.25
        history.registerChange(for: assetID, before: original, after: contrastEdit)

        #expect(!history.canRedo)
        #expect(history.undo(for: assetID, current: contrastEdit) == original)
    }

    @Test func switchingAssetsClearsHistoryAndRejectsStaleOperations() {
        let firstID = UUID()
        let secondID = UUID()
        let history = DevelopHistoryCoordinator()
        let original = DevelopSettings()
        var firstEdit = original
        firstEdit.saturation = 0.4

        history.activate(assetID: firstID)
        history.registerChange(for: firstID, before: original, after: firstEdit)
        #expect(history.canUndo)

        history.activate(assetID: secondID)

        #expect(!history.canUndo)
        #expect(history.undo(for: firstID, current: firstEdit) == nil)
        history.registerChange(for: firstID, before: original, after: firstEdit)
        #expect(!history.canUndo)
    }

    @Test func noOpAndDivergedSnapshotsAreNotApplied() throws {
        let assetID = UUID()
        let history = DevelopHistoryCoordinator()
        let original = DevelopSettings()

        history.activate(assetID: assetID)
        let transaction = try #require(history.beginChange(for: assetID, current: original))
        #expect(history.endChange(transaction, current: original))
        #expect(!history.canUndo)

        var recorded = original
        recorded.exposure = 0.2
        history.registerChange(for: assetID, before: original, after: recorded)

        var diverged = recorded
        diverged.temperature = 0.3
        #expect(history.undo(for: assetID, current: diverged) == nil)
        #expect(!history.canUndo)
        #expect(!history.canRedo)
    }

    @Test func overlappingProducerCannotCloseOrMergeOwnedTransaction() throws {
        let assetID = UUID()
        let history = DevelopHistoryCoordinator()
        let original = DevelopSettings()
        history.activate(assetID: assetID)

        let scrub = try #require(history.beginChange(for: assetID, current: original))
        #expect(history.beginChange(for: assetID, current: original) == nil)

        var scrubbed = original
        scrubbed.exposure = 0.65
        #expect(history.updateChange(scrub, current: scrubbed))

        var overlappingCanvas = scrubbed
        overlappingCanvas.contrast = 0.4
        #expect(!history.registerChange(
            for: assetID,
            before: scrubbed,
            after: overlappingCanvas
        ))
        #expect(!history.canUndo)
        #expect(history.endChange(scrub))

        #expect(history.undo(for: assetID, current: scrubbed) == original)
        #expect(history.redo(for: assetID, current: original) == scrubbed)
    }

    @Test func staleOwnerCannotUpdateEndOrCancelNewProducer() throws {
        let assetID = UUID()
        let history = DevelopHistoryCoordinator()
        let original = DevelopSettings()
        history.activate(assetID: assetID)

        let first = try #require(history.beginChange(for: assetID, current: original))
        var firstEdit = original
        firstEdit.exposure = 0.2
        #expect(history.endChange(first, current: firstEdit))

        let second = try #require(history.beginChange(for: assetID, current: firstEdit))
        var secondEdit = firstEdit
        secondEdit.saturation = 0.3
        #expect(!history.updateChange(first, current: secondEdit))
        #expect(!history.endChange(first, current: secondEdit))
        #expect(!history.cancelChange(first))
        #expect(history.updateChange(second, current: secondEdit))
        #expect(history.endChange(second))

        #expect(history.undo(for: assetID, current: secondEdit) == firstEdit)
        #expect(history.undo(for: assetID, current: firstEdit) == original)
    }

    @Test func matchingOwnerCanCancelWithoutCreatingHistory() throws {
        let assetID = UUID()
        let history = DevelopHistoryCoordinator()
        let original = DevelopSettings()
        history.activate(assetID: assetID)

        let transaction = try #require(history.beginChange(for: assetID, current: original))
        var edited = original
        edited.temperature = 0.5
        #expect(history.updateChange(transaction, current: edited))
        #expect(history.cancelChange(transaction))
        #expect(!history.cancelChange(transaction))
        #expect(!history.canUndo)
    }
}
