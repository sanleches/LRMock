//
//  PersistenceSafetyTests.swift
//  LRMockTests
//

import Darwin
import Foundation
import SwiftData
import Testing
@testable import LRMock

@MainActor
@Suite(.serialized)
struct PersistenceSafetyTests {

    @Test func boundedSidecarReadsHandleMissingNonRegularAndOversizedFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-sidecar-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missing = root.appendingPathComponent("missing.rawlight")
        #expect(try SidecarService.read(at: missing) == nil)

        let directory = root.appendingPathComponent("directory.rawlight", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        #expect(try SidecarService.read(at: directory) == nil)

        let regular = root.appendingPathComponent("regular.rawlight")
        try Data("{}".utf8).write(to: regular)
        let symbolicLink = root.appendingPathComponent("link.rawlight")
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: regular)
        #expect(throws: (any Error).self) {
            try BoundedFileReader.readRegularFile(at: symbolicLink, maximumByteCount: 1024)
        }

        let oversized = root.appendingPathComponent("oversized.rawlight")
        try Data(repeating: 0, count: 2 * 1024 * 1024 + 1).write(to: oversized)
        do {
            _ = try SidecarService.read(at: oversized)
            Issue.record("An oversized sidecar read was accepted")
        } catch let error as SidecarService.SidecarError {
            guard case .fileTooLarge = error else {
                Issue.record("Unexpected sidecar error: \(error)")
                return
            }
        }
    }

    @Test func boundedReaderRejectsFIFOWithoutBlocking() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-fifo-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fifo = root.appendingPathComponent("sidecar.rawlight")
        let creationResult = fifo.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return mkfifo(path, 0o600)
        }
        try #require(creationResult == 0)

        // If a regression restores a blocking read-only open, this delayed
        // read/write descriptor releases it so the test fails instead of hanging.
        let safetyWriter = Task.detached {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let descriptor = fifo.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            }
            if descriptor >= 0 {
                try? await Task.sleep(for: .milliseconds(100))
                Darwin.close(descriptor)
            }
        }
        defer { safetyWriter.cancel() }

        let clock = ContinuousClock()
        let start = clock.now
        let contents = try await Task.detached {
            try BoundedFileReader.readRegularFile(at: fifo, maximumByteCount: 1024)
        }.value
        let elapsed = start.duration(to: clock.now)

        #expect(contents == nil)
        #expect(elapsed < .seconds(1))
    }

    @Test func persistenceWritersCanonicalizeCompleteEnvelopes() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("canonical-sidecar-\(UUID().uuidString).raw")
        let sidecarURL = SidecarService.sidecarURL(for: sourceURL)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: sidecarURL)
        }
        try Data([1]).write(to: sourceURL)

        var sidecarDevelop = DevelopSettings()
        sidecarDevelop.exposure = 9
        var sidecar = Sidecar(
            schemaVersion: 999,
            fingerprint: ImageFingerprint(
                filename: sourceURL.lastPathComponent,
                fileSizeBytes: -10
            ),
            develop: sidecarDevelop,
            rating: 99,
            flag: 99,
            colorLabel: -4
        )
        sidecar.sourceContentDigest = "sha256:test"
        try SidecarService.write(sidecar, for: sourceURL)

        let decodedSidecar = try SidecarService.read(for: sourceURL)
        let restoredSidecar = try #require(decodedSidecar)
        #expect(restoredSidecar.schemaVersion == 1)
        #expect(restoredSidecar.fingerprint.fileSizeBytes == 0)
        #expect(restoredSidecar.develop.exposure == 1)
        #expect(restoredSidecar.rating == 5)
        #expect(restoredSidecar.flag == PickFlag.unflagged.rawValue)
        #expect(restoredSidecar.colorLabel == 0)

        try withTemporaryLibrary { _, _ in
            let asset = makeAsset(storageMode: .managed)
            var document = RecipeDocument(asset: asset)
            document.format = "invalid"
            document.schemaVersion = 999
            document.recipeID = UUID()
            document.editablePrimaryResourceID = UUID()
            document.pipeline.id = "invalid.pipeline"
            document.pipeline.semanticVersion = "999.0.0"
            document.pipeline.decoderFamily = "invalid-decoder"
            document.pipeline.decoderVersion = "invalid-version"
            document.workingColor.space = "invalid-space"
            document.workingColor.intent = "invalid-intent"
            document.rating = -1
            document.flag = 99
            document.colorLabel = 99
            document.geometry.orientation = 99
            document.geometry.crop = .init(x: 1, y: 1, width: 0, height: 0)
            document.geometry.rotationDegrees = -999
            document.parameters = ["stale": 123]
            document.develop.exposure = 9
            document.develop.cropX = 0.9
            document.develop.cropY = -1
            document.develop.cropW = 0.5
            document.develop.cropH = 2
            document.develop.straighten = 99
            document.develop.rotationQuarterTurns = -1
            document.develop.flipH = true

            try RecipeStore.write(document)
            let decodedRecipe = try RecipeStore.read(assetID: asset.id)
            let restored = try #require(decodedRecipe)
            #expect(restored.format == RecipeDocument.formatIdentifier)
            #expect(restored.schemaVersion == RecipeDocument.currentSchemaVersion)
            #expect(restored.recipeID == asset.id)
            #expect(restored.editablePrimaryResourceID == asset.id)
            #expect(restored.pipeline == RecipeDocument.Pipeline())
            #expect(restored.workingColor == RecipeDocument.WorkingColor())
            #expect(restored.rating == 0)
            #expect(restored.flag == PickFlag.unflagged.rawValue)
            #expect(restored.colorLabel == 5)
            #expect(restored.geometry.orientation == 8)
            #expect(restored.geometry.crop.x == restored.develop.cropX)
            #expect(restored.geometry.crop.y == restored.develop.cropY)
            #expect(restored.geometry.crop.width == restored.develop.cropW)
            #expect(restored.geometry.crop.height == restored.develop.cropH)
            #expect(restored.geometry.rotationDegrees == 315)
            #expect(restored.geometry.flipHorizontal)
            #expect(restored.geometry.flipVertical == restored.develop.flipV)
            #expect(restored.parameters["foundation.exposureEV"] == 2.5)
            #expect(restored.parameters["stale"] == nil)
        }
    }

    @Test func recipeValidationRejectsUnsupportedPipelineAndWorkingColor() throws {
        let asset = makeAsset(storageMode: .managed)
        let valid = RecipeDocument(asset: asset)

        var unsupportedPipeline = valid
        unsupportedPipeline.pipeline.id = "example.unsupported"
        #expect(throws: RecipeStore.RecipeError.unsupportedPipeline) {
            try RecipeStore.validate(unsupportedPipeline, assetID: asset.id)
        }

        var unsupportedWorkingColor = valid
        unsupportedWorkingColor.workingColor.space = "unsupported-space"
        #expect(throws: RecipeStore.RecipeError.unsupportedWorkingColor) {
            try RecipeStore.validate(unsupportedWorkingColor, assetID: asset.id)
        }

        try withTemporaryLibrary { _, _ in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let url = LibraryLocations.recipeURL(assetID: asset.id)

            try encoder.encode(unsupportedPipeline).write(to: url)
            #expect(throws: RecipeStore.RecipeError.unsupportedPipeline) {
                try RecipeStore.read(assetID: asset.id)
            }

            try encoder.encode(unsupportedWorkingColor).write(to: url)
            #expect(throws: RecipeStore.RecipeError.unsupportedWorkingColor) {
                try RecipeStore.read(assetID: asset.id)
            }
        }
    }

    @Test func recipeReadCanonicalizesContradictoryRedundantFields() throws {
        try withTemporaryLibrary { _, _ in
            let asset = makeAsset(storageMode: .managed)
            var external = RecipeDocument(asset: asset)
            external.develop.exposure = 0.4
            external.develop.cropX = 0.1
            external.develop.cropY = 0.2
            external.develop.cropW = 0.8
            external.develop.cropH = 0.7
            external.develop.straighten = 7
            external.develop.rotationQuarterTurns = 1
            external.develop.flipH = true
            external.geometry.orientation = 3
            external.geometry.crop = .init(x: 0.9, y: 0.9, width: 0.01, height: 0.01)
            external.geometry.rotationDegrees = -999
            external.geometry.flipHorizontal = false
            external.geometry.flipVertical = true
            external.parameters = ["contradiction": 999]
            external.rating = -4
            external.flag = 99
            external.colorLabel = 99

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(external).write(
                to: LibraryLocations.recipeURL(assetID: asset.id),
                options: .atomic
            )

            let decoded = try #require(try RecipeStore.read(assetID: asset.id))
            #expect(decoded.geometry.orientation == 3)
            #expect(decoded.geometry.crop.x == decoded.develop.cropX)
            #expect(decoded.geometry.crop.y == decoded.develop.cropY)
            #expect(decoded.geometry.crop.width == decoded.develop.cropW)
            #expect(decoded.geometry.crop.height == decoded.develop.cropH)
            #expect(decoded.geometry.rotationDegrees == 97)
            #expect(decoded.geometry.flipHorizontal)
            #expect(!decoded.geometry.flipVertical)
            #expect(decoded.parameters["foundation.exposureEV"] == 1)
            #expect(decoded.parameters["contradiction"] == nil)
            #expect(decoded.rating == 0)
            #expect(decoded.flag == PickFlag.unflagged.rawValue)
            #expect(decoded.colorLabel == 5)
        }
    }

    @Test func applyingRecipeAssignsNormalizedDevelopSettings() {
        let source = makeAsset(storageMode: .managed)
        var document = RecipeDocument(asset: source)
        document.develop.exposure = 99
        document.develop.cropX = 0.9
        document.develop.cropW = 0.5
        document.develop.rotationQuarterTurns = -1

        let target = makeAsset(storageMode: .managed)
        document.apply(to: target)

        #expect(target.develop == document.develop.normalizedForPersistence())
        #expect(target.develop.exposure == 1)
        #expect(target.develop.cropX == 0.5)
        #expect(target.develop.rotationQuarterTurns == 3)
    }

    @Test func maximumNormalizedSelectiveContentFitsSidecarAndRecipeLimits() throws {
        let settings = makeMaximumSelectiveSettings().normalizedForPersistence()
        #expect(settings.pointColors.count == PointColorAdjustment.maximumCount)
        #expect(settings.masks.count == LocalMask.maximumCount)
        #expect(settings.masks.allSatisfy { $0.components.count == LocalMask.maximumComponentCount })
        #expect(settings.spots.count == SpotCorrection.maximumCount)
        #expect(settings.redEyes.count == RedEyeCorrection.maximumCount)
        #expect(settings.currentPathPointCount == SelectiveDevelopLimits.maximumTotalPathPoints)

        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("maximum-selective-\(UUID().uuidString).raw")
        let sidecarURL = SidecarService.sidecarURL(for: sourceURL)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: sidecarURL)
        }
        try Data([1]).write(to: sourceURL)
        let sidecar = Sidecar(
            fingerprint: ImageFingerprint(filename: sourceURL.lastPathComponent, fileSizeBytes: 1),
            develop: settings,
            rating: 5,
            flag: PickFlag.picked.rawValue,
            colorLabel: 5
        )
        try SidecarService.write(sidecar, for: sourceURL)
        let sidecarBytes = try Data(contentsOf: sidecarURL).count
        #expect(sidecarBytes <= 2 * 1024 * 1024)
        let decodedSidecar = try SidecarService.read(for: sourceURL)
        let restoredSidecar = try #require(decodedSidecar)
        #expect(restoredSidecar.develop == settings)

        try withTemporaryLibrary { _, _ in
            let asset = makeAsset(storageMode: .managed)
            asset.develop = settings
            try RecipeStore.write(for: asset)
            let recipeURL = LibraryLocations.recipeURL(assetID: asset.id)
            let recipeBytes = try Data(contentsOf: recipeURL).count
            #expect(recipeBytes <= 4 * 1024 * 1024)
            let decodedRecipe = try RecipeStore.read(assetID: asset.id)
            let restoredRecipe = try #require(decodedRecipe)
            #expect(restoredRecipe.develop == settings)
        }
    }

    @Test func swiftDataSaveAndRefetchPreservesSelectiveArrays() throws {
        let container = CatalogStore.makeInMemoryContainer()
        let writeContext = ModelContext(container)
        let asset = makeAsset(storageMode: .managed)
        let pointColorID = UUID()
        let maskID = UUID()
        let spotID = UUID()
        let redEyeID = UUID()
        asset.develop.pointColors = [PointColorAdjustment(
            id: pointColorID,
            hueShift: 0.2,
            location: NormalizedPoint(x: 0.3, y: 0.7)
        )]
        asset.develop.masks = [LocalMask(
            id: maskID,
            name: "Persisted",
            components: [MaskComponent(shape: .linear(
                start: NormalizedPoint(x: 0.1, y: 0.2),
                end: NormalizedPoint(x: 0.8, y: 0.9)
            ))],
            adjustments: LocalAdjustments(exposure: 0.4)
        )]
        asset.develop.spots = [SpotCorrection(
            id: spotID,
            mode: .heal,
            points: [NormalizedPoint(x: 0.4, y: 0.6)]
        )]
        asset.develop.redEyes = [RedEyeCorrection(
            id: redEyeID,
            center: NormalizedPoint(x: 0.45, y: 0.55)
        )]
        writeContext.insert(asset)
        try writeContext.save()

        let readContext = ModelContext(container)
        let restored = try #require(try readContext.fetch(FetchDescriptor<ImageAsset>()).first)
        #expect(restored !== asset)
        #expect(restored.develop.pointColors.map(\.id) == [pointColorID])
        #expect(restored.develop.masks.map(\.id) == [maskID])
        #expect(restored.develop.spots.map(\.id) == [spotID])
        #expect(restored.develop.redEyes.map(\.id) == [redEyeID])
        #expect(restored.develop.masks[0].adjustments.exposure == 0.4)
    }

    @Test func legacyManagedRecipeWithoutDigestIsAcceptedAndNextSnapshotBackfillsIt() throws {
        let asset = makeAsset(storageMode: .managed)
        asset.contentDigest = "sha256:current-source"

        var legacy = RecipeDocument(asset: asset)
        legacy.sourceContentDigest = nil
        let restored = try RecipeStore.validate(
            legacy,
            assetID: asset.id,
            sourceContentDigest: asset.contentDigest
        )
        #expect(restored.sourceContentDigest == nil)

        var wrongSource = legacy
        wrongSource.sourceContentDigest = "sha256:different-source"
        #expect(throws: RecipeStore.RecipeError.sourceMismatch) {
            try RecipeStore.validate(
                wrongSource,
                assetID: asset.id,
                sourceContentDigest: asset.contentDigest
            )
        }

        let nextSave = RecipeDocument(asset: asset)
        #expect(nextSave.sourceContentDigest == "sha256:current-source")
    }

    @Test func replacedReferencedOriginalDoesNotOverwriteExistingSidecar() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("referenced-\(UUID().uuidString).raw")
        let sidecarURL = SidecarService.sidecarURL(for: sourceURL)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: sidecarURL)
        }

        try Data("original".utf8).write(to: sourceURL)
        let originalDigest = try ContentDigest.sha256(of: sourceURL)
        let fingerprint = ImageFingerprint(
            filename: sourceURL.lastPathComponent,
            fileSizeBytes: 8
        )
        let existing = Sidecar(
            fingerprint: fingerprint,
            sourceContentDigest: originalDigest,
            develop: DevelopSettings(),
            rating: 1,
            flag: PickFlag.unflagged.rawValue,
            colorLabel: 0
        )
        try SidecarService.write(existing, for: sourceURL)

        // Keep the byte count identical so validation cannot rely on size alone.
        try Data("replaced".utf8).write(to: sourceURL, options: .atomic)
        var stale = existing
        stale.rating = 5

        do {
            try await EditPersistence.writeReferencedSidecar(
                stale,
                for: sourceURL,
                assetID: UUID(),
                expectedDigest: originalDigest
            )
            Issue.record("A replaced referenced original was accepted")
        } catch let error as EditPersistence.PersistenceError {
            #expect(error == .sourceContentChanged)
        }

        let restoredSidecar = try SidecarService.read(for: sourceURL)
        let untouched = try #require(restoredSidecar)
        #expect(untouched.rating == 1)
        #expect(untouched.sourceContentDigest == originalDigest)
    }

    @Test func sameSizeSameMtimeRewriteIsRehashedBeforeEverySidecarWrite() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("referenced-cache-bypass-\(UUID().uuidString).raw")
        let sidecarURL = SidecarService.sidecarURL(for: sourceURL)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: sidecarURL)
        }

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try Data("original".utf8).write(to: sourceURL)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: sourceURL.path)
        let expectedDigest = try ContentDigest.sha256(of: sourceURL)
        let assetID = UUID()
        var sidecar = Sidecar(
            fingerprint: ImageFingerprint(filename: sourceURL.lastPathComponent, fileSizeBytes: 8),
            sourceContentDigest: expectedDigest,
            develop: DevelopSettings(),
            rating: 2,
            flag: PickFlag.unflagged.rawValue,
            colorLabel: 0
        )
        try await EditPersistence.writeReferencedSidecar(
            sidecar,
            for: sourceURL,
            assetID: assetID,
            expectedDigest: expectedDigest
        )

        sidecar.rating = 3
        try await EditPersistence.writeReferencedSidecar(
            sidecar,
            for: sourceURL,
            assetID: assetID,
            expectedDigest: expectedDigest
        )
        let replaced = try #require(try SidecarService.read(for: sourceURL))
        #expect(replaced.rating == 3)

        let handle = try FileHandle(forWritingTo: sourceURL)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data("replaced".utf8))
        try handle.synchronize()
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: sourceURL.path)

        sidecar.rating = 5
        do {
            try await EditPersistence.writeReferencedSidecar(
                sidecar,
                for: sourceURL,
                assetID: assetID,
                expectedDigest: expectedDigest
            )
            Issue.record("A same-size, same-mtime rewrite bypassed content validation")
        } catch let error as EditPersistence.PersistenceError {
            #expect(error == .sourceContentChanged)
        }

        let restored = try #require(try SidecarService.read(for: sourceURL))
        #expect(restored.rating == 3)
    }

    @Test func nonregularSidecarDestinationsAreRejectedAndPreserved() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "sd-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.raw")
        let sidecarURL = SidecarService.sidecarURL(for: sourceURL)
        try Data("original".utf8).write(to: sourceURL)
        let digest = try ContentDigest.sha256(of: sourceURL)
        let sidecar = referencedSidecar(for: sourceURL, digest: digest, rating: 4)

        try FileManager.default.createDirectory(at: sidecarURL, withIntermediateDirectories: false)
        let sentinelURL = sidecarURL.appendingPathComponent("preserve.txt")
        try Data("sentinel".utf8).write(to: sentinelURL)
        await expectNonregularSidecarRejection(sidecar, sourceURL: sourceURL, digest: digest)
        #expect(try fileType(at: sidecarURL) == S_IFDIR)
        #expect(try Data(contentsOf: sentinelURL) == Data("sentinel".utf8))
        try FileManager.default.removeItem(at: sidecarURL)

        let symlinkTarget = root.appendingPathComponent("symlink-target")
        try Data("target".utf8).write(to: symlinkTarget)
        try FileManager.default.createSymbolicLink(at: sidecarURL, withDestinationURL: symlinkTarget)
        await expectNonregularSidecarRejection(sidecar, sourceURL: sourceURL, digest: digest)
        #expect(try fileType(at: sidecarURL) == S_IFLNK)
        #expect(try Data(contentsOf: symlinkTarget) == Data("target".utf8))
        try FileManager.default.removeItem(at: sidecarURL)

        let fifoResult = sidecarURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return mkfifo(path, 0o600)
        }
        try #require(fifoResult == 0)
        await expectNonregularSidecarRejection(sidecar, sourceURL: sourceURL, digest: digest)
        #expect(try fileType(at: sidecarURL) == S_IFIFO)
        try FileManager.default.removeItem(at: sidecarURL)

        let socketDescriptor = try createUnixSocket(at: sidecarURL)
        defer { Darwin.close(socketDescriptor) }
        await expectNonregularSidecarRejection(sidecar, sourceURL: sourceURL, digest: digest)
        #expect(try fileType(at: sidecarURL) == S_IFSOCK)
    }

    @Test func renameUnsupportedFallsBackOnlyForFirstCreation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.raw")
        try Data("original".utf8).write(to: sourceURL)
        let digest = try ContentDigest.sha256(of: sourceURL)
        let systemOperations = SidecarInstallOperations.system
        let fallbackOperations = SidecarInstallOperations(
            renameWithFlags: { _, _, _ in ENOTSUP },
            createHardLink: systemOperations.createHardLink
        )

        var sidecar = referencedSidecar(for: sourceURL, digest: digest, rating: 2)
        try await EditPersistence.writeReferencedSidecar(
            sidecar,
            for: sourceURL,
            assetID: UUID(),
            expectedDigest: digest,
            operations: fallbackOperations
        )
        let created = try #require(try SidecarService.read(for: sourceURL))
        #expect(created.rating == 2)
        let sidecarURL = SidecarService.sidecarURL(for: sourceURL)
        let originalSidecarData = try Data(contentsOf: sidecarURL)

        sidecar.rating = 5
        let replacementOperations = SidecarInstallOperations(
            renameWithFlags: { _, _, _ in ENOTSUP },
            createHardLink: { _, _ in EIO }
        )
        do {
            try await EditPersistence.writeReferencedSidecar(
                sidecar,
                for: sourceURL,
                assetID: UUID(),
                expectedDigest: digest,
                operations: replacementOperations
            )
            Issue.record("ENOTSUP replacement moved the canonical sidecar")
        } catch let error as EditPersistence.PersistenceError {
            #expect(error == .unsupportedSidecarFilesystem)
        } catch {
            Issue.record("Unexpected ENOTSUP replacement error: \(error)")
        }

        #expect(try Data(contentsOf: sidecarURL) == originalSidecarData)
        #expect(try transactionDirectories(in: root).isEmpty)
    }

    @Test func fallbackCreationPreservesRacedDestination() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("race-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.raw")
        try Data("original".utf8).write(to: sourceURL)
        let sidecarURL = SidecarService.sidecarURL(for: sourceURL)
        let digest = try ContentDigest.sha256(of: sourceURL)
        let sidecar = referencedSidecar(for: sourceURL, digest: digest, rating: 0)
        let systemOperations = SidecarInstallOperations.system
        let fallbackOperations = SidecarInstallOperations(
            renameWithFlags: { _, _, _ in ENOTSUP },
            createHardLink: { source, destination in
                guard destination != sidecarURL else {
                    return destination.withUnsafeFileSystemRepresentation { path in
                        guard let path else { return EINVAL }
                        return Darwin.mkdir(path, S_IRWXU) == 0 ? EEXIST : errno
                    }
                }
                return systemOperations.createHardLink(source, destination)
            }
        )

        do {
            try await EditPersistence.writeReferencedSidecar(
                sidecar,
                for: sourceURL,
                assetID: UUID(),
                expectedDigest: digest,
                operations: fallbackOperations
            )
            Issue.record("Fallback creation replaced a raced destination")
        } catch let error as EditPersistence.PersistenceError {
            #expect(error == .sidecarDestinationChanged)
        } catch {
            Issue.record("Unexpected fallback race error: \(error)")
        }

        #expect(try fileType(at: sidecarURL) == S_IFDIR)
        #expect(try Data(contentsOf: sourceURL) == Data("original".utf8))
    }

    @Test func fallbackFirstCreationRollsBackWhenSourceIdentityChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-fallback-rollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.raw")
        try Data("original".utf8).write(to: sourceURL)
        let digest = try ContentDigest.sha256(of: sourceURL)
        let sidecar = referencedSidecar(for: sourceURL, digest: digest, rating: 5)

        let systemOperations = SidecarInstallOperations.system
        let fallbackOperations = SidecarInstallOperations(
            renameWithFlags: { _, _, _ in ENOTSUP },
            createHardLink: systemOperations.createHardLink,
            afterInstall: { _ in
                try Data("replaced".utf8).write(to: sourceURL, options: .atomic)
            }
        )
        do {
            try await EditPersistence.writeReferencedSidecar(
                sidecar,
                for: sourceURL,
                assetID: UUID(),
                expectedDigest: digest,
                operations: fallbackOperations
            )
            Issue.record("A fallback install was not rolled back after source replacement")
        } catch let error as EditPersistence.PersistenceError {
            #expect(error == .sourceChangedDuringValidation)
        }

        #expect(!FileManager.default.fileExists(
            atPath: SidecarService.sidecarURL(for: sourceURL).path
        ))
        #expect(try transactionDirectories(in: root).isEmpty)
    }

    @Test func fallbackRollbackPreservesConcurrentCanonicalReplacement() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fallback-rollback-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.raw")
        let sidecarURL = SidecarService.sidecarURL(for: sourceURL)
        try Data("original".utf8).write(to: sourceURL)
        let digest = try ContentDigest.sha256(of: sourceURL)
        let sidecar = referencedSidecar(for: sourceURL, digest: digest, rating: 5)
        let replacementData = Data("concurrent writer sidecar".utf8)
        let systemOperations = SidecarInstallOperations.system
        let operations = SidecarInstallOperations(
            renameWithFlags: { _, _, _ in ENOTSUP },
            createHardLink: systemOperations.createHardLink,
            rename: { source, destination in
                guard source == sidecarURL else {
                    return systemOperations.rename(source, destination)
                }
                do {
                    try replacementData.write(to: source, options: .atomic)
                } catch {
                    return EIO
                }
                return systemOperations.rename(source, destination)
            },
            afterInstall: { _ in
                throw TestFailure.expected
            }
        )

        do {
            try await EditPersistence.writeReferencedSidecar(
                sidecar,
                for: sourceURL,
                assetID: UUID(),
                expectedDigest: digest,
                operations: operations
            )
            Issue.record("A concurrent fallback rollback replacement was discarded")
        } catch let error as EditPersistence.PersistenceError {
            guard case .sidecarRecoveryRequired(let recoveryPath) = error else {
                Issue.record("Unexpected persistence error: \(error)")
                return
            }
            #expect(recoveryPath.hasSuffix("/rollback.rawlight"))
            #expect(try Data(contentsOf: URL(fileURLWithPath: recoveryPath)) == replacementData)
        } catch {
            Issue.record("Unexpected fallback rollback error: \(error)")
        }

        #expect(!FileManager.default.fileExists(atPath: sidecarURL.path))
        #expect(try Data(contentsOf: sourceURL) == Data("original".utf8))
    }

    @Test func unsupportedFallbackFilesystemPreservesSourceWithoutCreatingSidecar() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-unsupported-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.raw")
        let sidecarURL = SidecarService.sidecarURL(for: sourceURL)
        try Data("original".utf8).write(to: sourceURL)
        let digest = try ContentDigest.sha256(of: sourceURL)
        let sidecar = referencedSidecar(for: sourceURL, digest: digest, rating: 5)

        let unsupportedOperations = SidecarInstallOperations(
            renameWithFlags: { _, _, _ in ENOTSUP },
            createHardLink: { _, _ in ENOTSUP }
        )
        do {
            try await EditPersistence.writeReferencedSidecar(
                sidecar,
                for: sourceURL,
                assetID: UUID(),
                expectedDigest: digest,
                operations: unsupportedOperations
            )
            Issue.record("A filesystem without safe install primitives was accepted")
        } catch let error as EditPersistence.PersistenceError {
            #expect(error == .unsupportedSidecarFilesystem)
        }

        #expect(!FileManager.default.fileExists(atPath: sidecarURL.path))
        #expect(try Data(contentsOf: sourceURL) == Data("original".utf8))
        #expect(try transactionDirectories(in: root).isEmpty)
    }

    @Test func nativeSwapRestoresMutatedDisplacedSidecar() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swap-mutation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.raw")
        let sidecarURL = SidecarService.sidecarURL(for: sourceURL)
        try Data("original".utf8).write(to: sourceURL)
        let digest = try ContentDigest.sha256(of: sourceURL)
        let existing = referencedSidecar(for: sourceURL, digest: digest, rating: 1)
        try SidecarService.write(existing, for: sourceURL)
        let replacement = referencedSidecar(for: sourceURL, digest: digest, rating: 5)
        let mutatedData = Data("mutated displaced sidecar".utf8)
        let systemOperations = SidecarInstallOperations.system
        let mutationOperations = SidecarInstallOperations(
            renameWithFlags: systemOperations.renameWithFlags,
            createHardLink: systemOperations.createHardLink,
            afterInstall: { displacedURL in
                let displacedURL = try #require(displacedURL)
                let handle = try FileHandle(forWritingTo: displacedURL)
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: mutatedData)
                try handle.synchronize()
                try handle.close()
            }
        )

        do {
            try await EditPersistence.writeReferencedSidecar(
                replacement,
                for: sourceURL,
                assetID: UUID(),
                expectedDigest: digest,
                operations: mutationOperations
            )
            Issue.record("A mutated displaced sidecar was silently discarded")
        } catch let error as EditPersistence.PersistenceError {
            #expect(error == .sidecarDestinationChanged)
        } catch {
            Issue.record("Unexpected displaced-sidecar mutation error: \(error)")
        }

        let restoredData = try Data(contentsOf: sidecarURL)
        #expect(restoredData == mutatedData)
        #expect(try transactionDirectories(in: root).isEmpty)
    }

    @Test func nativeSwapRestoresSidecarMutatedImmediatelyBeforeSwap() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pre-swap-mutation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.raw")
        let sidecarURL = SidecarService.sidecarURL(for: sourceURL)
        try Data("original".utf8).write(to: sourceURL)
        let digest = try ContentDigest.sha256(of: sourceURL)
        let existing = referencedSidecar(for: sourceURL, digest: digest, rating: 1)
        try SidecarService.write(existing, for: sourceURL)
        let replacement = referencedSidecar(for: sourceURL, digest: digest, rating: 5)
        let mutatedData = Data("mutated immediately before swap".utf8)
        let mutation = OneShotGate()
        let systemOperations = SidecarInstallOperations.system
        let mutationOperations = SidecarInstallOperations(
            renameWithFlags: { source, destination, flags in
                if flags == UInt32(RENAME_SWAP), mutation.claim() {
                    do {
                        let handle = try FileHandle(forWritingTo: destination)
                        try handle.truncate(atOffset: 0)
                        try handle.write(contentsOf: mutatedData)
                        try handle.synchronize()
                        try handle.close()
                    } catch {
                        return EIO
                    }
                }
                return systemOperations.renameWithFlags(source, destination, flags)
            },
            createHardLink: systemOperations.createHardLink
        )

        do {
            try await EditPersistence.writeReferencedSidecar(
                replacement,
                for: sourceURL,
                assetID: UUID(),
                expectedDigest: digest,
                operations: mutationOperations
            )
            Issue.record("A sidecar mutated immediately before swap was silently discarded")
        } catch let error as EditPersistence.PersistenceError {
            #expect(error == .sidecarDestinationChanged)
        } catch {
            Issue.record("Unexpected pre-swap mutation error: \(error)")
        }

        #expect(try Data(contentsOf: sidecarURL) == mutatedData)
        #expect(try transactionDirectories(in: root).isEmpty)
    }

    @Test func failedFirstCreateRollbackReportsCanonicalRecoveryPath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollback-failed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.raw")
        let sidecarURL = SidecarService.sidecarURL(for: sourceURL)
        try Data("original".utf8).write(to: sourceURL)
        let digest = try ContentDigest.sha256(of: sourceURL)
        let sidecar = referencedSidecar(for: sourceURL, digest: digest, rating: 3)
        let systemOperations = SidecarInstallOperations.system
        let operations = SidecarInstallOperations(
            renameWithFlags: { source, destination, flags in
                guard source != sidecarURL else { return EIO }
                return systemOperations.renameWithFlags(source, destination, flags)
            },
            createHardLink: systemOperations.createHardLink,
            afterInstall: { _ in
                throw NSError(domain: "InjectedFirstCreateFailure", code: 1)
            }
        )

        do {
            try await EditPersistence.writeReferencedSidecar(
                sidecar,
                for: sourceURL,
                assetID: UUID(),
                expectedDigest: digest,
                operations: operations
            )
            Issue.record("A failed first-create rollback was accepted")
        } catch let error as EditPersistence.PersistenceError {
            #expect(error == .sidecarRecoveryRequired(sidecarURL.path))
        } catch {
            Issue.record("Unexpected failed rollback error: \(error)")
        }

        #expect(FileManager.default.fileExists(atPath: sidecarURL.path))
    }

    @Test func mismatchedFirstCreateRollbackReportsStagedRecoveryPath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollback-mismatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.raw")
        let sidecarURL = SidecarService.sidecarURL(for: sourceURL)
        try Data("original".utf8).write(to: sourceURL)
        let digest = try ContentDigest.sha256(of: sourceURL)
        let sidecar = referencedSidecar(for: sourceURL, digest: digest, rating: 3)
        let replacementData = Data("foreign staged recovery".utf8)
        let systemOperations = SidecarInstallOperations.system
        let operations = SidecarInstallOperations(
            renameWithFlags: { source, destination, flags in
                let error = systemOperations.renameWithFlags(source, destination, flags)
                guard error == nil, source == sidecarURL else { return error }
                do {
                    try replacementData.write(to: destination, options: .atomic)
                    return nil
                } catch {
                    return EIO
                }
            },
            createHardLink: systemOperations.createHardLink,
            afterInstall: { _ in
                throw NSError(domain: "InjectedFirstCreateFailure", code: 2)
            }
        )

        do {
            try await EditPersistence.writeReferencedSidecar(
                sidecar,
                for: sourceURL,
                assetID: UUID(),
                expectedDigest: digest,
                operations: operations
            )
            Issue.record("A mismatched first-create rollback was accepted")
        } catch let error as EditPersistence.PersistenceError {
            guard case .sidecarRecoveryRequired(let recoveryPath) = error else {
                Issue.record("Unexpected persistence error: \(error)")
                return
            }
            #expect(recoveryPath != sidecarURL.path)
            #expect(recoveryPath.hasSuffix("/new.rawlight"))
            #expect(try Data(contentsOf: URL(fileURLWithPath: recoveryPath)) == replacementData)
        } catch {
            Issue.record("Unexpected mismatched rollback error: \(error)")
        }

        #expect(!FileManager.default.fileExists(atPath: sidecarURL.path))
    }

    @Test func pinnedDigestDetectsAtomicSourceReplacement() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinned-source-\(UUID().uuidString).raw")
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        try Data("original".utf8).write(to: sourceURL)
        let expectedDigest = try ContentDigest.sha256(of: sourceURL)
        let source = try ContentDigest.openPinnedRegularFile(at: sourceURL)
        let digest = try source.sha256()
        try Data("replaced".utf8).write(to: sourceURL, options: .atomic)

        #expect(digest == expectedDigest)
        let stillMatches = try source.stillMatchesFile(at: sourceURL)
        #expect(!stillMatches)
    }

    @Test func referencedSidecarRejectsSymlinkSourcePromptly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("referenced-symlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let regular = root.appendingPathComponent("regular.raw")
        let link = root.appendingPathComponent("linked.raw")
        try Data("original".utf8).write(to: regular)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        let digest = try ContentDigest.sha256(of: regular)
        let sidecar = Sidecar(
            fingerprint: ImageFingerprint(filename: link.lastPathComponent, fileSizeBytes: 8),
            sourceContentDigest: digest,
            develop: DevelopSettings(),
            rating: 1,
            flag: 0,
            colorLabel: 0
        )

        let start = ContinuousClock.now
        do {
            try await EditPersistence.writeReferencedSidecar(
                sidecar,
                for: link,
                assetID: UUID(),
                expectedDigest: digest
            )
            Issue.record("A symlink source was accepted")
        } catch let error as EditPersistence.PersistenceError {
            #expect(error == .sourceIsNotRegularFile)
        }
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(!FileManager.default.fileExists(atPath: SidecarService.sidecarURL(for: link).path))
    }

    @Test func referencedSidecarRejectsFIFOWithoutBlocking() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("referenced-fifo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fifo = root.appendingPathComponent("source.raw")
        let creationResult = fifo.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return mkfifo(path, 0o600)
        }
        try #require(creationResult == 0)

        let safetyWriter = Task.detached {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let descriptor = fifo.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            }
            if descriptor >= 0 { Darwin.close(descriptor) }
        }
        defer { safetyWriter.cancel() }

        let sidecar = Sidecar(
            fingerprint: ImageFingerprint(filename: fifo.lastPathComponent, fileSizeBytes: 0),
            sourceContentDigest: "sha256:unused",
            develop: DevelopSettings(),
            rating: 1,
            flag: 0,
            colorLabel: 0
        )
        let start = ContinuousClock.now
        do {
            try await EditPersistence.writeReferencedSidecar(
                sidecar,
                for: fifo,
                assetID: UUID(),
                expectedDigest: "sha256:unused"
            )
            Issue.record("A FIFO source was accepted")
        } catch let error as EditPersistence.PersistenceError {
            #expect(error == .sourceIsNotRegularFile)
        }
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(!FileManager.default.fileExists(atPath: SidecarService.sidecarURL(for: fifo).path))
    }

    @Test func failedScheduledAutosaveRemainsDirtyAndExplicitFlushRetriesIt() async {
        let asset = makeAsset(storageMode: .managed)
        var attempts = 0
        let autosaver = SidecarAutosaver { _ in
            attempts += 1
            if attempts == 1 { throw TestFailure.expected }
        }

        autosaver.schedule(asset, delay: .zero)
        await autosaver.waitForPendingWrites()
        #expect(attempts == 1)
        #expect(autosaver.hasUnsavedChanges)
        #expect(autosaver.lastError != nil)

        await autosaver.flush(asset)
        #expect(attempts == 2)
        #expect(!autosaver.hasUnsavedChanges)
        // The first failure stays visible until the user dismisses it.
        #expect(autosaver.lastError != nil)
    }

    private func makeAsset(storageMode: StorageMode) -> ImageAsset {
        ImageAsset(
            originalFilename: "photo.raw",
            storageMode: storageMode,
            fingerprint: ImageFingerprint(filename: "photo.raw", fileSizeBytes: 8),
            fileSizeBytes: 8
        )
    }

    private func referencedSidecar(
        for sourceURL: URL,
        digest: String,
        rating: Int
    ) -> Sidecar {
        Sidecar(
            fingerprint: ImageFingerprint(
                filename: sourceURL.lastPathComponent,
                fileSizeBytes: 8
            ),
            sourceContentDigest: digest,
            develop: DevelopSettings(),
            rating: rating,
            flag: PickFlag.unflagged.rawValue,
            colorLabel: 0
        )
    }

    private func expectNonregularSidecarRejection(
        _ sidecar: Sidecar,
        sourceURL: URL,
        digest: String
    ) async {
        do {
            try await EditPersistence.writeReferencedSidecar(
                sidecar,
                for: sourceURL,
                assetID: UUID(),
                expectedDigest: digest
            )
            Issue.record("A nonregular sidecar destination was replaced")
        } catch let error as EditPersistence.PersistenceError {
            #expect(error == .sidecarDestinationIsNotRegularFile)
        } catch {
            Issue.record("Unexpected sidecar destination error: \(error)")
        }
    }

    private func fileType(at url: URL) throws -> mode_t {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return lstat(path, &status)
        }
        if result != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return status.st_mode & S_IFMT
    }

    private func transactionDirectories(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".rawlight-sidecar-") }
    }

    private func createUnixSocket(at url: URL) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        let copied = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                let destination = UnsafeMutableRawPointer(tuplePointer)
                    .assumingMemoryBound(to: CChar.self)
                return strlcpy(
                    destination,
                    path,
                    pathCapacity
                ) < pathCapacity
            }
        }
        guard copied else {
            Darwin.close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }

        let result = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return descriptor
    }

    private func withTemporaryLibrary<T>(
        _ operation: (_ appRoot: URL, _ cacheRoot: URL) throws -> T
    ) throws -> T {
        let appRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawLight-Persistence-\(UUID().uuidString)", isDirectory: true)
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawLight-Persistence-Cache-\(UUID().uuidString)", isDirectory: true)
        LibraryLocations.configureRoots(appRoot: appRoot, cacheRoot: cacheRoot)
        defer {
            LibraryLocations.resetConfiguredRoots()
            try? FileManager.default.removeItem(at: appRoot)
            try? FileManager.default.removeItem(at: cacheRoot)
        }
        _ = try LibraryLocations.bootstrap()
        return try operation(appRoot, cacheRoot)
    }

    private func makeMaximumSelectiveSettings() -> DevelopSettings {
        var idValue = 1
        func nextID() -> UUID {
            defer { idValue += 1 }
            return UUID(uuidString: String(
                format: "00000000-0000-4000-8000-%012llx",
                UInt64(idValue)
            ))!
        }

        let point = NormalizedPoint(
            x: 0.12345678901234566,
            y: 0.9876543210987654
        )
        let adjustments = LocalAdjustments(
            temperature: 0.12345678901234566,
            tint: -0.12345678901234566,
            exposure: 0.9876543210987654,
            contrast: -0.9876543210987654,
            highlights: 0.8765432109876543,
            shadows: -0.8765432109876543,
            whites: 0.7654321098765432,
            blacks: -0.7654321098765432,
            texture: 0.6543210987654321,
            clarity: -0.6543210987654321,
            dehaze: 0.543210987654321,
            hue: -0.543210987654321,
            saturation: 0.4321098765432109,
            sharpness: -0.4321098765432109,
            noiseReduction: 0.3210987654321098,
            amount: 1.9876543210987654
        )

        var remainingBrushPoints = SelectiveDevelopLimits.maximumTotalPathPoints
            - SpotCorrection.maximumCount
        var masks: [LocalMask] = []
        for _ in 0..<LocalMask.maximumCount {
            var components: [MaskComponent] = []
            for _ in 0..<LocalMask.maximumComponentCount {
                let shape: MaskShape
                if remainingBrushPoints > 0 {
                    let strokeCount = min(MaskShape.maximumStrokeCount, remainingBrushPoints)
                    let strokes = (0..<strokeCount).map { _ in
                        BrushStroke(
                            points: [point],
                            size: 0.24999999999999997,
                            feather: 0.9876543210987654,
                            flow: 0.8765432109876543,
                            density: 0.7654321098765432,
                            erase: true
                        )
                    }
                    shape = .brush(strokes: strokes)
                    remainingBrushPoints -= strokeCount
                } else {
                    shape = .radial(
                        center: point,
                        radiusX: 0.9876543210987654,
                        radiusY: 0.8765432109876543,
                        angle: 179.98765432109876,
                        feather: 0.7654321098765432,
                        inverted: true
                    )
                }
                components.append(MaskComponent(
                    id: nextID(),
                    operation: .intersect,
                    inverted: true,
                    shape: shape
                ))
            }
            masks.append(LocalMask(
                id: nextID(),
                name: String(
                    repeating: "\u{0001}",
                    count: SelectiveDevelopNormalization.maximumNameScalarCount
                ),
                enabled: true,
                inverted: true,
                components: components,
                adjustments: adjustments
            ))
        }

        var settings = DevelopSettings()
        settings.pointColors = (0..<PointColorAdjustment.maximumCount).map { _ in
            PointColorAdjustment(
                id: nextID(),
                luminance: 0.9876543210987654,
                chroma: 0.49999999999999994,
                hue: 0.8765432109876543,
                hueShift: -0.9876543210987654,
                saturationShift: 0.9876543210987654,
                luminanceShift: -0.8765432109876543,
                variance: 0.7654321098765432,
                range: 0.9876543210987654,
                hueRange: 0.8765432109876543,
                chromaRange: 0.7654321098765432,
                luminanceRange: 0.6543210987654321,
                location: point
            )
        }
        settings.masks = masks
        settings.spots = (0..<SpotCorrection.maximumCount).map { _ in
            SpotCorrection(
                id: nextID(),
                mode: .clone,
                points: [point],
                size: 0.24999999999999997,
                feather: 0.9876543210987654,
                opacity: 0.8765432109876543,
                sourceOffset: NormalizedVector(
                    dx: -0.9876543210987654,
                    dy: 0.9876543210987654
                )
            )
        }
        settings.redEyes = (0..<RedEyeCorrection.maximumCount).map { _ in
            RedEyeCorrection(
                id: nextID(),
                center: point,
                radiusX: 0.49999999999999994,
                radiusY: 0.49999999999999994,
                pupilSize: 0.9876543210987654,
                darken: 0.8765432109876543,
                petEye: true,
                catchlight: NormalizedVector(
                    dx: -0.9876543210987654,
                    dy: 0.9876543210987654
                )
            )
        }
        let curve = (0..<DevelopSettings.maximumToneCurvePointCount).map { index in
            let x = Double(index) / Double(DevelopSettings.maximumToneCurvePointCount - 1)
            return CurvePoint(x, 1 - x)
        }
        settings.toneCurve = curve
        settings.toneCurveRed = curve
        settings.toneCurveGreen = curve
        settings.toneCurveBlue = curve
        return settings
    }

    private enum TestFailure: Error {
        case expected
    }
}

private final class OneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isAvailable = true

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isAvailable else { return false }
        isAvailable = false
        return true
    }
}
