//
//  LibraryLocations.swift
//  RawLight
//
//  On-disk layout of the managed Library, aligned with the RawLight design
//  (docs/architecture/catalog-and-persistence.md). All canonical stores for one
//  active library live under a single generation root, so a future restore can
//  build a new generation and atomically switch `CurrentLibrary.json`:
//
//      Application Support/RawLight/
//        CurrentLibrary.json                     ← checksummed pointer to a generation
//        LegacyCatalogMigration.json              ← explicit legacy-migration completion
//        Libraries/<generation UUID>/
//          Catalog/catalog.store                 ← SwiftData (catalog index)
//          Catalog/Catalog.complete.json          ← successful-open marker
//          Originals/<asset UUID>/primary.<ext>  ← immutable managed originals
//          Recipes/<asset UUID>.rawlight.json    ← canonical edit recipe + metadata
//          Trash/                                ← recoverable deletes
//      Library/Caches/RawLight/Thumbnails/       ← disposable render cache
//
//  This is the Lightroom-style "catalog folder": importing copies the RAW into
//  `Originals/` and the edit recipe/metadata is saved next to it in `Recipes/`.
//  It is user-revealable in Finder on macOS and visible in Files on iPadOS.
//

import Foundation
import CryptoKit
import Darwin

nonisolated enum LibraryLocations {

    /// `{ "schemaVersion": 1, "generationID": "<uuid>", "checksum": "..." }`
    private struct CurrentLibrary: Codable {
        var schemaVersion: Int
        var generationID: UUID
        var checksum: String?
    }

    private struct CatalogCompletion: Codable {
        var schemaVersion: Int
        var generationID: UUID
    }

    private struct CatalogCreation: Codable {
        var schemaVersion: Int
        var generationID: UUID
    }

    private struct LegacyMigrationCompletion: Codable {
        var schemaVersion: Int
        var sourceIdentity: CatalogV4Migration.SourceIdentity
        var targetGenerationID: UUID
    }

    private struct GenerationMigrationIntent: Codable {
        var schemaVersion: Int
        var sourceGenerationID: UUID
        var targetGenerationID: UUID
        var abandonSourceOnCommit: Bool?
    }

    private struct AbandonedMigrationTarget: Codable {
        var schemaVersion: Int
        var generationID: UUID
        var ownerPID: Int32
    }

    private struct UITestRootOwner: Codable {
        var schemaVersion: Int
        var rootID: UUID
        var ownerPID: Int32
    }

    private struct CatalogResolution {
        let generationID: UUID
        let generationURL: URL
        let catalogURL: URL
        let appRootURL: URL
        let pointerSnapshot: Data?
        let allowsCatalogCreation: Bool
        let shouldPublishPointer: Bool
        let needsCompletionMarker: Bool
        let needsCreationMarker: Bool
        let migrationSourceURL: URL?
        let requiresLegacySourceRevalidation: Bool
    }

    struct CatalogPreparation {
        let generationID: UUID
        let generationURL: URL
        let catalogURL: URL
        let allowsCatalogCreation: Bool
        let migrationSourceURL: URL?

        fileprivate let appRootURL: URL
        fileprivate let pointerSnapshot: Data?
        fileprivate let shouldPublishPointer: Bool
        fileprivate let needsCompletionMarker: Bool
        fileprivate let needsCreationMarker: Bool
        fileprivate let generationLock: GenerationLockLease
        let requiresLegacySourceRevalidation: Bool
    }

    final class CatalogSessionLease {
        private let generationLock: GenerationLockLease
        private let migrationSourceLease: AnyObject?

        fileprivate init(
            generationLock: GenerationLockLease,
            migrationSourceLease: AnyObject?
        ) {
            self.generationLock = generationLock
            self.migrationSourceLease = migrationSourceLease
        }

        deinit {
            generationLock.release()
        }
    }

    private enum CompletionMarkerState: Equatable {
        case missing
        case valid
        case invalid
    }

    private enum RecoveryKind {
        case completed
        case preMarkerV4
        case interruptedMigration
        case interruptedFresh
    }

    private struct RecoveryCandidate {
        let generationID: UUID
        let kind: RecoveryKind
        let allowsCatalogCreation: Bool
        let migrationSourceURL: URL?
    }

    enum LocationError: LocalizedError {
        case corruptLibraryPointer
        case unsupportedPointerVersion(Int)
        case missingLibraryGeneration(UUID)
        case catalogNotInitialized(UUID)
        case ambiguousLibraryGenerations
        case pointerWriteFailed(Error)
        case unsafeLibraryPath(URL)
        case libraryChangedDuringOpen
        case libraryInUse
        case invalidCatalogMetadata(URL)
        case oversizedCatalogMetadata(URL)
        case pathOutsideLibrary(URL)
        case invalidRelativePath(String)

        var errorDescription: String? {
            switch self {
            case .corruptLibraryPointer:
                return "The active library pointer is damaged and no existing library could be recovered."
            case .unsupportedPointerVersion(let version):
                return "This library pointer uses unsupported version \(version)."
            case .missingLibraryGeneration(let id):
                return "The active library generation \(id.uuidString) is missing."
            case .catalogNotInitialized(let id):
                return "The active library generation \(id.uuidString) does not contain an initialized catalog."
            case .ambiguousLibraryGenerations:
                return "Multiple library generations exist and the active one cannot be determined safely."
            case .pointerWriteFailed(let error):
                return "The active library pointer could not be saved: \(error.localizedDescription)"
            case .unsafeLibraryPath(let url):
                return "A library path escapes the configured library root: \(url.path)"
            case .libraryChangedDuringOpen:
                return "The library changed while its catalog was being opened."
            case .libraryInUse:
                return "Another RawLight process is opening or migrating this library. Close it and retry."
            case .invalidCatalogMetadata(let url):
                return "Catalog metadata is not a bounded regular file: \(url.path)"
            case .oversizedCatalogMetadata(let url):
                return "Catalog metadata exceeds the supported size limit: \(url.path)"
            case .pathOutsideLibrary(let url):
                return "The managed file is outside the active library: \(url.path)"
            case .invalidRelativePath(let path):
                return "The managed path is invalid: \(path)"
            }
        }
    }

    private static let schemaVersion = 1
    private static let completionSchemaVersion = 1
    private static let creationSchemaVersion = 1
    private static let legacyMigrationSchemaVersion = 1
    private static let generationMigrationSchemaVersion = 1
    private static let metadataMaximumByteCount = 16 * 1024
    private static let generationLockFileName = ".RawLight.generation.lock"
    private static let generationMigrationIntentName = "CatalogMigration.pending.json"
    private static let migrationTargetMarkerName = "CatalogMigration.target.json"
    private static let abandonedMigrationMarkerName = "CatalogMigration.abandoned.json"
    private static let uiTestRootEnvironmentKey = "RAWLIGHT_UI_TEST_ROOT_ID"
    private static let uiTestPointerVersionEnvironmentKey = "RAWLIGHT_UI_TEST_POINTER_SCHEMA_VERSION"
    private static let uiTestAppRootPrefix = "RawLight-UITests-"
    private static let uiTestCacheRootPrefix = "RawLight-UICache-"
    private static let uiTestOwnerMarkerName = ".RawLight.ui-test-owner.json"
    private static let sqliteHeader = Data("SQLite format 3\0".utf8)
    private static let lock = NSLock()
    private static var cachedResolution: CatalogResolution?
    private static var configuredAppRoot: URL?
    private static var configuredCacheRoot: URL?

    fileprivate final class GenerationLockLease {
        private static let processLock = NSLock()
        private static var activePaths: Set<String> = []

        private let stateLock = NSLock()
        private let path: String
        private var descriptor: Int32

        private init(descriptor: Int32, path: String) {
            self.descriptor = descriptor
            self.path = path
        }

        deinit {
            release()
        }

        var isHeld: Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return descriptor >= 0
        }

        static func acquire(at root: URL) throws -> GenerationLockLease {
            let url = root.appendingPathComponent(generationLockFileName)
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            processLock.lock()
            let reserved = activePaths.insert(path).inserted
            processLock.unlock()
            guard reserved else { throw LocationError.libraryInUse }
            var acquired = false
            defer {
                if !acquired {
                    processLock.lock()
                    activePaths.remove(path)
                    processLock.unlock()
                }
            }
            let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else {
                    errno = EINVAL
                    return -1
                }
                return Darwin.open(
                    path,
                    O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                    S_IRUSR | S_IWUSR
                )
            }
            guard descriptor >= 0 else {
                throw LocationError.unsafeLibraryPath(url)
            }

            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_nlink == 1
            else {
                Darwin.close(descriptor)
                throw LocationError.unsafeLibraryPath(url)
            }
            var requestedLock = flock(
                l_start: 0,
                l_len: 0,
                l_pid: 0,
                l_type: Int16(F_WRLCK),
                l_whence: Int16(SEEK_SET)
            )
            guard fcntl(descriptor, F_SETLK, &requestedLock) == 0 else {
                let code = errno
                Darwin.close(descriptor)
                if code == EACCES || code == EAGAIN {
                    throw LocationError.libraryInUse
                }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            acquired = true
            return GenerationLockLease(descriptor: descriptor, path: path)
        }

        func release() {
            stateLock.lock()
            let descriptor = self.descriptor
            self.descriptor = -1
            stateLock.unlock()
            guard descriptor >= 0 else { return }
            var requestedLock = flock(
                l_start: 0,
                l_len: 0,
                l_pid: 0,
                l_type: Int16(F_UNLCK),
                l_whence: Int16(SEEK_SET)
            )
            _ = fcntl(descriptor, F_SETLK, &requestedLock)
            Darwin.close(descriptor)
            Self.processLock.lock()
            Self.activePaths.remove(path)
            Self.processLock.unlock()
        }
    }

    // MARK: Roots

    /// `Application Support/RawLight` — the library container.
    static var appRoot: URL {
        lock.lock()
        let configured = configuredAppRoot
        lock.unlock()
        if let configured { return configured }
        if let uiTestRoot {
            return uiTestRoot
        }
        if let path = ProcessInfo.processInfo.environment["RAWLIGHT_LIBRARY_ROOT"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        else { preconditionFailure("Application Support is unavailable") }
        return base.appendingPathComponent("RawLight", isDirectory: true)
    }

    static var usesCustomLibraryRoot: Bool {
        lock.lock()
        let configured = configuredAppRoot != nil
        lock.unlock()
        let environment = ProcessInfo.processInfo.environment["RAWLIGHT_LIBRARY_ROOT"]
        return configured || uiTestRoot != nil || (environment?.isEmpty == false)
    }

    /// Identity-bound record written only after the default schema-v4 store was
    /// copied into, validated in, and successfully opened from a generation.
    static var legacyCatalogMigrationCompletionMarkerURL: URL {
        appRoot.appendingPathComponent("LegacyCatalogMigration.json")
    }

    /// The active generation directory, `Libraries/<generation UUID>`.
    static var currentGeneration: URL {
        appRoot
            .appendingPathComponent("Libraries", isDirectory: true)
            .appendingPathComponent(generationID().uuidString, isDirectory: true)
    }

    static var originals: URL { currentGeneration.appendingPathComponent("Originals", isDirectory: true) }
    static var incoming: URL { currentGeneration.appendingPathComponent("Incoming", isDirectory: true) }
    static var recipes: URL { currentGeneration.appendingPathComponent("Recipes", isDirectory: true) }
    static var trash: URL { currentGeneration.appendingPathComponent("Trash", isDirectory: true) }
    static var catalogStoreURL: URL {
        currentGeneration
            .appendingPathComponent("Catalog", isDirectory: true)
            .appendingPathComponent("catalog.store")
    }
    static var catalogCompletionMarkerURL: URL {
        currentGeneration
            .appendingPathComponent("Catalog", isDirectory: true)
            .appendingPathComponent("Catalog.complete.json")
    }

    /// Disposable thumbnail cache (safe to purge; never canonical).
    static var thumbnailsCache: URL {
        lock.lock()
        let configured = configuredCacheRoot
        lock.unlock()
        if let configured { return configured.appendingPathComponent("Thumbnails", isDirectory: true) }
        if let uiTestCacheRoot {
            return uiTestCacheRoot.appendingPathComponent("Thumbnails", isDirectory: true)
        }
        if let path = ProcessInfo.processInfo.environment["RAWLIGHT_CACHE_ROOT"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
                .standardizedFileURL
                .appendingPathComponent("Thumbnails", isDirectory: true)
        }
        guard let caches = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { preconditionFailure("Caches directory is unavailable") }
        return caches.appendingPathComponent("RawLight/Thumbnails", isDirectory: true)
    }

    // MARK: Lifecycle

    /// Creates the library tree and resolves/creates the current generation.
    /// Idempotent; call once at launch (and safe to call again).
    @discardableResult
    static func bootstrap() throws -> UUID {
        try prepareCatalog().generationID
    }

    /// Resolves a catalog without publishing a recovered or new generation.
    /// Only a genuinely empty first-run layout is allowed to create a store.
    static func prepareCatalog() throws -> CatalogPreparation {
        let root = appRoot.standardizedFileURL
        try prepareUITestRootsIfNeeded()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try installUITestPointerIfRequested(appRoot: root)
        let generationLock = try GenerationLockLease.acquire(at: root)
        do {
            CatalogV4Migration.cleanupStaleTemporaryWorkspaces()
            let resolution = try resolveCatalogResolution(appRoot: root)
            let preparation = CatalogPreparation(
                generationID: resolution.generationID,
                generationURL: resolution.generationURL,
                catalogURL: resolution.catalogURL,
                allowsCatalogCreation: resolution.allowsCatalogCreation,
                migrationSourceURL: resolution.migrationSourceURL,
                appRootURL: resolution.appRootURL,
                pointerSnapshot: resolution.pointerSnapshot,
                shouldPublishPointer: resolution.shouldPublishPointer,
                needsCompletionMarker: resolution.needsCompletionMarker,
                needsCreationMarker: resolution.needsCreationMarker,
                generationLock: generationLock,
                requiresLegacySourceRevalidation: resolution.requiresLegacySourceRevalidation
            )
            let shouldCreateLibraryTree: Bool
            if resolution.allowsCatalogCreation {
                shouldCreateLibraryTree = true
            } else if resolution.migrationSourceURL != nil {
                shouldCreateLibraryTree = false
            } else if FileManager.default.fileExists(atPath: resolution.catalogURL.path) {
                shouldCreateLibraryTree = (try? CatalogV4Migration.storeFormat(
                    at: resolution.catalogURL
                )) == .current
            } else {
                shouldCreateLibraryTree = false
            }
            if shouldCreateLibraryTree {
                try createLibraryTree(for: preparation)
            }
            return preparation
        } catch {
            generationLock.release()
            lock.lock()
            if cachedResolution?.appRootURL.path == root.path {
                cachedResolution = nil
            }
            lock.unlock()
            throw error
        }
    }

    /// Records a successful SwiftData open, then atomically publishes the
    /// generation when recovery or first-run creation requires it.
    static func completeCatalogOpen(
        _ preparation: CatalogPreparation,
        legacySourceIdentity: CatalogV4Migration.SourceIdentity? = nil,
        migrationSourceLease: AnyObject? = nil
    ) throws -> CatalogSessionLease {
        try requireGenerationLock(preparation)
        let root = appRoot
        lock.lock(); defer { lock.unlock() }

        guard root.standardizedFileURL.path == preparation.appRootURL.path,
              cachedResolution?.generationID == preparation.generationID,
              cachedResolution?.catalogURL.standardizedFileURL.path
                == preparation.catalogURL.standardizedFileURL.path
        else {
            throw LocationError.libraryChangedDuringOpen
        }

        let paths = try validatedGenerationPaths(
            generationID: preparation.generationID,
            appRoot: preparation.appRootURL
        )
        guard try catalogHasSQLiteHeader(
            at: preparation.catalogURL,
            canonicalGeneration: paths.canonicalGeneration
        ) else {
            throw LocationError.catalogNotInitialized(preparation.generationID)
        }

        let pointer = preparation.appRootURL.appendingPathComponent("CurrentLibrary.json")
        try validatePointerURL(pointer, appRoot: preparation.appRootURL)
        guard try pointerSnapshot(at: pointer) == preparation.pointerSnapshot else {
            throw LocationError.libraryChangedDuringOpen
        }
        let completedMigrationIntent = try matchingGenerationMigrationIntent(
            targetGenerationID: preparation.generationID,
            appRoot: preparation.appRootURL
        )

        if preparation.needsCompletionMarker {
            try writeCompletionMarker(
                generationID: preparation.generationID,
                generationURL: preparation.generationURL,
                canonicalGeneration: paths.canonicalGeneration
            )
        } else if try completionMarkerState(
            generationID: preparation.generationID,
            generationURL: preparation.generationURL,
            canonicalGeneration: paths.canonicalGeneration
        ) != .valid {
            throw LocationError.catalogNotInitialized(preparation.generationID)
        }

        if preparation.shouldPublishPointer {
            try writePointer(generationID: preparation.generationID, to: pointer)
        }

        if let legacySourceIdentity {
            try writeLegacyMigrationCompletion(
                sourceIdentity: legacySourceIdentity,
                targetGenerationID: preparation.generationID,
                appRoot: preparation.appRootURL
            )
        }

        if let completedMigrationIntent,
           completedMigrationIntent.abandonSourceOnCommit == true
            || legacySourceIdentity != nil {
            try markMigrationTargetAbandoned(
                generationID: completedMigrationIntent.sourceGenerationID,
                appRoot: preparation.appRootURL
            )
        }

        if completedMigrationIntent != nil {
            try FileManager.default.removeItem(
                at: preparation.appRootURL.appendingPathComponent(
                    generationMigrationIntentName
                )
            )
        }

        try removeCreationMarkerIfPresent(
            generationID: preparation.generationID,
            generationURL: preparation.generationURL,
            canonicalGeneration: paths.canonicalGeneration
        )

        cachedResolution = CatalogResolution(
            generationID: preparation.generationID,
            generationURL: preparation.generationURL,
            catalogURL: preparation.catalogURL,
            appRootURL: preparation.appRootURL,
            pointerSnapshot: try pointerSnapshot(at: pointer),
            allowsCatalogCreation: false,
            shouldPublishPointer: false,
            needsCompletionMarker: false,
            needsCreationMarker: false,
            migrationSourceURL: nil,
            requiresLegacySourceRevalidation: false
        )
        return CatalogSessionLease(
            generationLock: preparation.generationLock,
            migrationSourceLease: migrationSourceLease
        )
    }

    static func requireGenerationLock(_ preparation: CatalogPreparation) throws {
        guard preparation.generationLock.isHeld else {
            throw LocationError.libraryInUse
        }
    }

    /// Allocates or resumes the unpublished generation used for a v4
    /// migration. The source pointer snapshot and lock lease are intentionally
    /// carried forward so only `completeCatalogOpen` can publish the target.
    static func prepareMigrationTarget(
        from source: CatalogPreparation,
        sourceLease: CatalogV4Migration.SourceLease? = nil,
        copiesSourceGenerationContent: Bool = true,
        abandonSourceOnCommit: Bool = false,
        expectedLegacyManagedFilesIdentity: CatalogV4Migration.ManagedFilesIdentity? = nil
    ) throws -> CatalogPreparation {
        try requireGenerationLock(source)
        lock.lock()
        let sourceIsCurrent = cachedResolution?.generationID == source.generationID
            && cachedResolution?.appRootURL.path == source.appRootURL.path
        lock.unlock()
        guard sourceIsCurrent else { throw LocationError.libraryChangedDuringOpen }

        try removeAbandonedMigrationTargets(
            appRoot: source.appRootURL,
            preserving: source.generationID
        )

        let intentURL = source.appRootURL.appendingPathComponent(generationMigrationIntentName)
        try validateRootMetadataURL(
            intentURL,
            named: generationMigrationIntentName,
            appRoot: source.appRootURL
        )
        let targetID: UUID
        if let data = try readCatalogMetadataIfPresent(at: intentURL) {
            guard let intent = try? JSONDecoder().decode(
                GenerationMigrationIntent.self,
                from: data
            ),
            intent.schemaVersion == generationMigrationSchemaVersion,
            intent.sourceGenerationID == source.generationID,
            intent.targetGenerationID != source.generationID,
            (intent.abandonSourceOnCommit == true) == abandonSourceOnCommit
            else {
                throw LocationError.invalidCatalogMetadata(intentURL)
            }
            targetID = intent.targetGenerationID
        } else {
            targetID = UUID()
            let intent = GenerationMigrationIntent(
                schemaVersion: generationMigrationSchemaVersion,
                sourceGenerationID: source.generationID,
                targetGenerationID: targetID,
                abandonSourceOnCommit: abandonSourceOnCommit ? true : nil
            )
            try JSONEncoder().encode(intent).write(to: intentURL, options: [.atomic])
        }

        let paths = try validatedGenerationPaths(
            generationID: targetID,
            appRoot: source.appRootURL
        )
        let target = CatalogPreparation(
            generationID: targetID,
            generationURL: paths.generation,
            catalogURL: catalogURL(in: paths.generation),
            allowsCatalogCreation: true,
            migrationSourceURL: nil,
            appRootURL: source.appRootURL,
            pointerSnapshot: source.pointerSnapshot,
            shouldPublishPointer: true,
            needsCompletionMarker: true,
            needsCreationMarker: false,
            generationLock: source.generationLock,
            requiresLegacySourceRevalidation: source.requiresLegacySourceRevalidation
        )

        func prepareReplacement(markCurrentAbandoned: Bool) throws -> CatalogPreparation {
            if markCurrentAbandoned {
                try markMigrationTargetAbandoned(target)
            }
            let replacementIntent = GenerationMigrationIntent(
                schemaVersion: generationMigrationSchemaVersion,
                sourceGenerationID: source.generationID,
                targetGenerationID: UUID(),
                abandonSourceOnCommit: abandonSourceOnCommit ? true : nil
            )
            try JSONEncoder().encode(replacementIntent).write(
                to: intentURL,
                options: [.atomic]
            )
            return try prepareMigrationTarget(
                from: source,
                sourceLease: sourceLease,
                copiesSourceGenerationContent: copiesSourceGenerationContent,
                abandonSourceOnCommit: abandonSourceOnCommit,
                expectedLegacyManagedFilesIdentity: expectedLegacyManagedFilesIdentity
            )
        }

        if try isAbandonedMigrationTarget(
            generationID: target.generationID,
            generationURL: target.generationURL,
            canonicalGeneration: paths.canonicalGeneration
        ) {
            return try prepareReplacement(markCurrentAbandoned: false)
        }
        try createLibraryTree(for: target)
        try writeOrValidateMigrationTargetMarker(
            sourceGenerationID: source.generationID,
            targetGenerationID: targetID,
            abandonSourceOnCommit: abandonSourceOnCommit,
            generationURL: target.generationURL
        )
        let targetStoreExists = FileManager.default.fileExists(atPath: target.catalogURL.path)
        var shouldReplaceTarget = false
        if targetStoreExists {
            let reusable: Bool
            do {
                reusable = try CatalogV4Migration.storeFormat(at: target.catalogURL) == .current
                    && CatalogV4Migration.isValidatedInterruptedCurrentCatalog(
                        at: target.catalogURL,
                        generationID: target.generationID,
                        sourceLease: sourceLease,
                        expectedLegacyManagedFilesIdentity: expectedLegacyManagedFilesIdentity
                    )
            } catch {
                reusable = false
            }
            shouldReplaceTarget = !reusable
        } else {
            let catalogEntries = try FileManager.default.contentsOfDirectory(
                at: target.catalogURL.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            )
            let generationEntries = try FileManager.default.contentsOfDirectory(
                at: target.generationURL,
                includingPropertiesForKeys: nil
            )
            shouldReplaceTarget = !catalogEntries.isEmpty || generationEntries.contains {
                $0.lastPathComponent.hasPrefix(CatalogV4Migration.backupDirectoryPrefix)
                    || $0.lastPathComponent.hasPrefix(CatalogV4Migration.stagingDirectoryPrefix)
            }
        }
        if shouldReplaceTarget {
            return try prepareReplacement(markCurrentAbandoned: true)
        }
        if copiesSourceGenerationContent {
            if try !nonCatalogGenerationContentCanResumeCopy(
                source.generationURL,
                target.generationURL
            ) {
                return try prepareReplacement(markCurrentAbandoned: true)
            }
            try copyNonCatalogGenerationContent(
                from: source.generationURL,
                to: target.generationURL
            )
            if try !nonCatalogGenerationContentMatches(
                source.generationURL,
                target.generationURL
            ) {
                return try prepareReplacement(markCurrentAbandoned: true)
            }
        }

        let resolution = CatalogResolution(
            generationID: target.generationID,
            generationURL: target.generationURL,
            catalogURL: target.catalogURL,
            appRootURL: target.appRootURL,
            pointerSnapshot: target.pointerSnapshot,
            allowsCatalogCreation: true,
            shouldPublishPointer: true,
            needsCompletionMarker: true,
            needsCreationMarker: false,
            migrationSourceURL: nil,
            requiresLegacySourceRevalidation: target.requiresLegacySourceRevalidation
        )
        lock.lock()
        cachedResolution = resolution
        lock.unlock()
        return target
    }

    static func abandonCatalogOpen(_ preparation: CatalogPreparation) {
        preparation.generationLock.release()
        lock.lock()
        if cachedResolution?.appRootURL.path == preparation.appRootURL.path {
            cachedResolution = nil
        }
        lock.unlock()
    }

    /// Overrides all persistent roots for hermetic tests and previews.
    /// Call before accessing any other location, then call `resetConfiguredRoots()`.
    static func configureRoots(appRoot: URL, cacheRoot: URL) {
        lock.lock()
        configuredAppRoot = appRoot.standardizedFileURL
        configuredCacheRoot = cacheRoot.standardizedFileURL
        cachedResolution = nil
        lock.unlock()
    }

    static func resetConfiguredRoots() {
        lock.lock()
        configuredAppRoot = nil
        configuredCacheRoot = nil
        cachedResolution = nil
        lock.unlock()
    }

    private static var uiTestRootID: UUID? {
        #if DEBUG
        guard let value = ProcessInfo.processInfo.environment[uiTestRootEnvironmentKey],
              !value.isEmpty
        else { return nil }
        return UUID(uuidString: value)
        #else
        return nil
        #endif
    }

    private static var uiTestRoot: URL? {
        guard let uiTestRootID else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(
                uiTestAppRootPrefix + uiTestRootID.uuidString,
                isDirectory: true
            )
            .standardizedFileURL
    }

    private static var uiTestCacheRoot: URL? {
        guard let uiTestRootID else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(
                uiTestCacheRootPrefix + uiTestRootID.uuidString,
                isDirectory: true
            )
            .standardizedFileURL
    }

    private static func prepareUITestRootsIfNeeded() throws {
        #if DEBUG
        guard let rootID = uiTestRootID,
              let appRoot = uiTestRoot,
              let cacheRoot = uiTestCacheRoot
        else { return }

        let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
        cleanupStaleUITestRoots(in: temporaryDirectory, preserving: rootID)
        for root in [appRoot, cacheRoot] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let values = try root.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw LocationError.invalidCatalogMetadata(root)
            }
            let marker = root.appendingPathComponent(uiTestOwnerMarkerName)
            if let data = try readCatalogMetadataIfPresent(at: marker) {
                guard let owner = try? JSONDecoder().decode(UITestRootOwner.self, from: data),
                      owner.schemaVersion == 1,
                      owner.rootID == rootID,
                      owner.ownerPID > 0
                else {
                    throw LocationError.invalidCatalogMetadata(marker)
                }
                if owner.ownerPID != getpid(), processIsRunning(owner.ownerPID) {
                    throw LocationError.libraryInUse
                }
            }
            let owner = UITestRootOwner(
                schemaVersion: 1,
                rootID: rootID,
                ownerPID: getpid()
            )
            try JSONEncoder().encode(owner).write(to: marker, options: [.atomic])
        }
        #endif
    }

    #if DEBUG
    static func cleanupStaleUITestRoots(
        in temporaryDirectory: URL,
        preserving currentRootID: UUID
    ) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries {
            let name = entry.lastPathComponent
            let prefix: String
            if name.hasPrefix(uiTestAppRootPrefix) {
                prefix = uiTestAppRootPrefix
            } else if name.hasPrefix(uiTestCacheRootPrefix) {
                prefix = uiTestCacheRootPrefix
            } else {
                continue
            }
            guard let rootID = UUID(uuidString: String(name.dropFirst(prefix.count))),
                  rootID.uuidString == String(name.dropFirst(prefix.count)),
                  rootID != currentRootID,
                  let values = try? entry.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                  ),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let data = try? BoundedFileReader.readRegularFile(
                    at: entry.appendingPathComponent(uiTestOwnerMarkerName),
                    maximumByteCount: metadataMaximumByteCount
                  ),
                  let owner = try? JSONDecoder().decode(UITestRootOwner.self, from: data),
                  owner.schemaVersion == 1,
                  owner.rootID == rootID,
                  owner.ownerPID > 0,
                  owner.ownerPID != getpid(),
                  !processIsRunning(owner.ownerPID)
            else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }
    #endif

    private static func installUITestPointerIfRequested(appRoot: URL) throws {
        #if DEBUG
        guard uiTestRootID != nil,
              let value = ProcessInfo.processInfo.environment[uiTestPointerVersionEnvironmentKey],
              let version = Int(value)
        else { return }

        let pointer = appRoot.appendingPathComponent("CurrentLibrary.json")
        guard !FileManager.default.fileExists(atPath: pointer.path) else { return }
        let fixture = CurrentLibrary(
            schemaVersion: version,
            generationID: UUID(),
            checksum: nil
        )
        try JSONEncoder().encode(fixture).write(to: pointer, options: [.atomic])
        #endif
    }

    // MARK: Managed paths

    /// Directory that holds one asset's managed original(s).
    static func managedOriginalDirectory(assetID: UUID) -> URL {
        originals.appendingPathComponent(assetID.uuidString, isDirectory: true)
    }

    /// `Originals/<assetID>/primary.<ext>`
    static func managedOriginalURL(assetID: UUID, fileExtension ext: String) -> URL {
        let name = ext.isEmpty ? "primary" : "primary.\(ext.lowercased())"
        return managedOriginalDirectory(assetID: assetID).appendingPathComponent(name)
    }

    /// `Recipes/<assetID>.rawlight.json`
    static func recipeURL(assetID: UUID) -> URL {
        recipes.appendingPathComponent("\(assetID.uuidString).rawlight.json")
    }

    /// Path relative to the current generation (what we persist on the asset).
    static func relativePath(of url: URL) throws -> String {
        let root = currentGeneration.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        guard candidate.hasPrefix(root + "/") else {
            throw LocationError.pathOutsideLibrary(url)
        }
        let relative = String(candidate.dropFirst(root.count + 1))
        let validated = try self.url(forManagedRelativePath: relative)
        guard validated.standardizedFileURL.path == candidate else {
            throw LocationError.pathOutsideLibrary(url)
        }
        return relative
    }

    /// Resolves a stored relative path back to an absolute URL.
    static func url(forManagedRelativePath relative: String, expectedAssetID: UUID? = nil) throws -> URL {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 3,
              components[0] == "Originals",
              let assetID = UUID(uuidString: components[1]),
              expectedAssetID == nil || expectedAssetID == assetID
        else {
            throw LocationError.invalidRelativePath(relative)
        }

        let filename = components[2]
        let extensionPart = filename.hasPrefix("primary.")
            ? filename.dropFirst("primary.".count)
            : Substring()
        guard filename == "primary"
                || (!extensionPart.isEmpty && !extensionPart.contains("."))
        else {
            throw LocationError.invalidRelativePath(relative)
        }

        let root = currentGeneration.standardizedFileURL
        let candidate = root.appendingPathComponent(relative).standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        let expectedResolved = resolvedRoot.appendingPathComponent(relative).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/"),
              resolvedCandidate.path == expectedResolved.path
        else {
            throw LocationError.invalidRelativePath(relative)
        }
        return candidate
    }

    // MARK: Generation resolution

    private static func generationID() -> UUID {
        lock.lock()
        let resolved = cachedResolution.flatMap { resolution in
            resolution.shouldPublishPointer ? nil : resolution.generationID
        }
        lock.unlock()
        if let resolved { return resolved }

        do {
            return try prepareCatalog().generationID
        } catch {
            preconditionFailure("Unable to resolve RawLight library: \(error.localizedDescription)")
        }
    }

    private static func resolveCatalogResolution(appRoot root: URL) throws -> CatalogResolution {
        lock.lock(); defer { lock.unlock() }
        if let cached = cachedResolution { return cached }

        let pointer = root.appendingPathComponent("CurrentLibrary.json")
        try validatePointerURL(pointer, appRoot: root)
        _ = try validatedLibrariesPaths(appRoot: root)

        if let pointerData = try readCatalogMetadataIfPresent(at: pointer) {
            do {
                let current = try JSONDecoder().decode(CurrentLibrary.self, from: pointerData)
                guard current.schemaVersion == schemaVersion else {
                    throw LocationError.unsupportedPointerVersion(current.schemaVersion)
                }
                if let checksum = current.checksum,
                   checksum != pointerChecksum(generationID: current.generationID) {
                    throw LocationError.corruptLibraryPointer
                }
                let resolution = try resolutionForPointedGeneration(
                    current.generationID,
                    appRoot: root,
                    pointerSnapshot: pointerData,
                    shouldPublishPointer: current.checksum == nil
                )
                cachedResolution = resolution
                return resolution
            } catch let error as LocationError {
                if case .unsupportedPointerVersion = error { throw error }
                if case .unsafeLibraryPath = error { throw error }
                if case .invalidCatalogMetadata = error { throw error }
                if case .oversizedCatalogMetadata = error { throw error }
                if let recovered = try recoverGeneration(appRoot: root) {
                    let resolution = try recoveryResolution(
                        recovered,
                        appRoot: root,
                        pointerSnapshot: pointerData
                    )
                    cachedResolution = resolution
                    return resolution
                }
                throw error
            } catch {
                if let recovered = try recoverGeneration(appRoot: root) {
                    let resolution = try recoveryResolution(
                        recovered,
                        appRoot: root,
                        pointerSnapshot: pointerData
                    )
                    cachedResolution = resolution
                    return resolution
                }
                throw LocationError.corruptLibraryPointer
            }
        }

        if let recovered = try recoverGeneration(appRoot: root) {
            let resolution = try recoveryResolution(
                recovered,
                appRoot: root,
                pointerSnapshot: nil
            )
            cachedResolution = resolution
            return resolution
        }

        let fresh = UUID()
        let generation = root
            .appendingPathComponent("Libraries", isDirectory: true)
            .appendingPathComponent(fresh.uuidString, isDirectory: true)
        let resolution = CatalogResolution(
            generationID: fresh,
            generationURL: generation,
            catalogURL: catalogURL(in: generation),
            appRootURL: root,
            pointerSnapshot: nil,
            allowsCatalogCreation: true,
            shouldPublishPointer: true,
            needsCompletionMarker: true,
            needsCreationMarker: true,
            migrationSourceURL: nil,
            requiresLegacySourceRevalidation: false
        )
        cachedResolution = resolution
        return resolution
    }

    private static func recoverGeneration(appRoot: URL) throws -> RecoveryCandidate? {
        let libraryPaths = try validatedLibrariesPaths(appRoot: appRoot)
        let libraries = libraryPaths.libraries
        guard FileManager.default.fileExists(atPath: libraries.path) else { return nil }
        let migrationIntent = try generationMigrationIntent(appRoot: appRoot)
        let entries = try FileManager.default.contentsOfDirectory(
            at: libraries,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )

        var sawGeneration = false
        var completed: [RecoveryCandidate] = []
        var preMarkerV4: [RecoveryCandidate] = []
        var interruptedMigration: [RecoveryCandidate] = []
        var interruptedFresh: [RecoveryCandidate] = []
        var sawUnclassifiedCatalog = false
        var abandonedGenerationCount = 0
        var nonAbandonedGenerationCount = 0
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent) else { continue }
            sawGeneration = true
            guard entry.lastPathComponent == id.uuidString else {
                throw LocationError.corruptLibraryPointer
            }

            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                nonAbandonedGenerationCount += 1
                continue
            }
            let paths = try validatedGenerationPaths(generationID: id, appRoot: appRoot)
            if try isAbandonedMigrationTarget(
                generationID: id,
                generationURL: paths.generation,
                canonicalGeneration: paths.canonicalGeneration
            ) {
                abandonedGenerationCount += 1
                continue
            }
            nonAbandonedGenerationCount += 1
            let isPendingMigrationTarget = try migrationIntent.map {
                try migrationTargetMarkerMatches(
                    $0,
                    generationID: id,
                    generationURL: paths.generation,
                    canonicalGeneration: paths.canonicalGeneration
                )
            } ?? false
            let completionBeforeRecovery = try completionMarkerState(
                generationID: id,
                generationURL: paths.generation,
                canonicalGeneration: paths.canonicalGeneration
            )
            try CatalogV4Migration.recoverInterruptedMigration(
                in: paths.generation,
                generationID: id,
                canonicalCurrentIsAuthoritative: completionBeforeRecovery == .valid
            )

            let completionState = try completionMarkerState(
                generationID: id,
                generationURL: paths.generation,
                canonicalGeneration: paths.canonicalGeneration
            )
            let creationState = try creationMarkerState(
                generationID: id,
                generationURL: paths.generation,
                canonicalGeneration: paths.canonicalGeneration
            )
            if completionState == .invalid {
                sawUnclassifiedCatalog = true
                continue
            }
            let storeURL = catalogURL(in: paths.generation)
            guard FileManager.default.fileExists(atPath: storeURL.path) else {
                if isPendingMigrationTarget { continue }
                if let recoveryStore = try CatalogV4Migration.recoverableV4Store(
                    in: paths.generation,
                    generationID: id
                ) {
                    preMarkerV4.append(RecoveryCandidate(
                        generationID: id,
                        kind: .preMarkerV4,
                        allowsCatalogCreation: false,
                        migrationSourceURL: recoveryStore
                    ))
                    continue
                }
                if completionState == .missing, creationState == .valid {
                    interruptedFresh.append(RecoveryCandidate(
                        generationID: id,
                        kind: .interruptedFresh,
                        allowsCatalogCreation: true,
                        migrationSourceURL: nil
                    ))
                }
                continue
            }
            guard try catalogHasSQLiteHeader(
                at: storeURL,
                canonicalGeneration: paths.canonicalGeneration
            ) else {
                if isPendingMigrationTarget { continue }
                sawUnclassifiedCatalog = true
                continue
            }
            guard let format = try? CatalogV4Migration.storeFormat(at: storeURL) else {
                if isPendingMigrationTarget { continue }
                sawUnclassifiedCatalog = true
                continue
            }

            switch (completionState, format) {
            case (.valid, .current):
                let candidate = RecoveryCandidate(
                    generationID: id,
                    kind: isPendingMigrationTarget ? .interruptedMigration : .completed,
                    allowsCatalogCreation: false,
                    migrationSourceURL: nil
                )
                if isPendingMigrationTarget {
                    interruptedMigration.append(candidate)
                } else {
                    completed.append(candidate)
                }
            case (.missing, .v1), (.missing, .v4):
                preMarkerV4.append(RecoveryCandidate(
                    generationID: id,
                    kind: .preMarkerV4,
                    allowsCatalogCreation: false,
                    migrationSourceURL: nil
                ))
            case (.missing, .current):
                let probe = try CatalogV4Migration.probeStore(at: storeURL)
                if creationState == .valid && probe.isEmpty {
                    interruptedFresh.append(RecoveryCandidate(
                        generationID: id,
                        kind: .interruptedFresh,
                        allowsCatalogCreation: false,
                        migrationSourceURL: nil
                    ))
                } else if try CatalogV4Migration.isValidatedInterruptedCurrentCatalog(
                    at: storeURL,
                    generationID: id
                ) {
                    interruptedMigration.append(RecoveryCandidate(
                        generationID: id,
                        kind: .interruptedMigration,
                        allowsCatalogCreation: false,
                        migrationSourceURL: nil
                    ))
                } else if !probe.isEmpty {
                    if isPendingMigrationTarget { continue }
                    sawUnclassifiedCatalog = true
                }
            default:
                if format.isLegacy, !isPendingMigrationTarget {
                    sawUnclassifiedCatalog = true
                }
                continue
            }
        }

        if sawUnclassifiedCatalog {
            if !completed.isEmpty || !preMarkerV4.isEmpty || !interruptedMigration.isEmpty {
                throw LocationError.ambiguousLibraryGenerations
            }
            throw LocationError.corruptLibraryPointer
        }
        if let migrationIntent,
           interruptedMigration.contains(where: {
               $0.generationID == migrationIntent.targetGenerationID
           }),
           let source = preMarkerV4.first(where: {
               $0.generationID == migrationIntent.sourceGenerationID
           }) {
            guard completed.isEmpty,
                  preMarkerV4.count == 1,
                  interruptedMigration.count == 1,
                  interruptedFresh.isEmpty
            else {
                throw LocationError.ambiguousLibraryGenerations
            }
            return source
        }
        guard completed.count <= 1 else {
            throw LocationError.ambiguousLibraryGenerations
        }
        if let completed = completed.first { return completed }
        guard interruptedMigration.count <= 1 else {
            throw LocationError.ambiguousLibraryGenerations
        }
        if let interruptedMigration = interruptedMigration.first { return interruptedMigration }
        guard preMarkerV4.count <= 1 else {
            throw LocationError.ambiguousLibraryGenerations
        }
        if let preMarkerV4 = preMarkerV4.first { return preMarkerV4 }
        guard interruptedFresh.count <= 1 else {
            throw LocationError.ambiguousLibraryGenerations
        }
        if let interruptedFresh = interruptedFresh.first {
            return interruptedFresh
        }
        if abandonedGenerationCount > 0,
           nonAbandonedGenerationCount == 0,
           migrationIntent == nil {
            return RecoveryCandidate(
                generationID: UUID(),
                kind: .interruptedFresh,
                allowsCatalogCreation: true,
                migrationSourceURL: nil
            )
        }
        guard sawGeneration else {
            return nil
        }
        throw LocationError.corruptLibraryPointer
    }

    private static func resolutionForPointedGeneration(
        _ id: UUID,
        appRoot: URL,
        pointerSnapshot: Data,
        shouldPublishPointer: Bool
    ) throws -> CatalogResolution {
        let paths = try validatedGenerationPaths(generationID: id, appRoot: appRoot)
        guard try !isAbandonedMigrationTarget(
            generationID: id,
            generationURL: paths.generation,
            canonicalGeneration: paths.canonicalGeneration
        ) else {
            throw LocationError.catalogNotInitialized(id)
        }
        try CatalogV4Migration.recoverInterruptedMigration(
            in: paths.generation,
            generationID: id,
            canonicalCurrentIsAuthoritative: true
        )
        guard try exactGenerationDirectoryExists(id, in: paths.libraries),
              try catalogHasSQLiteHeader(
                at: catalogURL(in: paths.generation),
                canonicalGeneration: paths.canonicalGeneration
              )
        else {
            throw LocationError.catalogNotInitialized(id)
        }

        let markerState = try completionMarkerState(
            generationID: id,
            generationURL: paths.generation,
            canonicalGeneration: paths.canonicalGeneration
        )
        guard markerState != .invalid else {
            throw LocationError.catalogNotInitialized(id)
        }
        _ = try CatalogV4Migration.probeStore(at: catalogURL(in: paths.generation))

        return CatalogResolution(
            generationID: id,
            generationURL: paths.generation,
            catalogURL: catalogURL(in: paths.generation),
            appRootURL: appRoot,
            pointerSnapshot: pointerSnapshot,
            allowsCatalogCreation: false,
            shouldPublishPointer: shouldPublishPointer,
            needsCompletionMarker: markerState == .missing,
            needsCreationMarker: false,
            migrationSourceURL: nil,
            requiresLegacySourceRevalidation: false
        )
    }

    private static func recoveryResolution(
        _ candidate: RecoveryCandidate,
        appRoot: URL,
        pointerSnapshot: Data?
    ) throws -> CatalogResolution {
        let paths = try validatedGenerationPaths(
            generationID: candidate.generationID,
            appRoot: appRoot
        )
        return CatalogResolution(
            generationID: candidate.generationID,
            generationURL: paths.generation,
            catalogURL: catalogURL(in: paths.generation),
            appRootURL: appRoot,
            pointerSnapshot: pointerSnapshot,
            allowsCatalogCreation: candidate.allowsCatalogCreation,
            shouldPublishPointer: true,
            needsCompletionMarker: candidate.kind != .completed,
            needsCreationMarker: candidate.kind == .interruptedFresh
                && candidate.allowsCatalogCreation,
            migrationSourceURL: candidate.migrationSourceURL,
            requiresLegacySourceRevalidation: true
        )
    }

    private static func matchingGenerationMigrationIntent(
        targetGenerationID: UUID,
        appRoot: URL
    ) throws -> GenerationMigrationIntent? {
        guard let intent = try generationMigrationIntent(appRoot: appRoot) else { return nil }
        return intent.targetGenerationID == targetGenerationID ? intent : nil
    }

    private static func generationMigrationIntent(
        appRoot: URL
    ) throws -> GenerationMigrationIntent? {
        let url = appRoot.appendingPathComponent(generationMigrationIntentName)
        try validateRootMetadataURL(
            url,
            named: generationMigrationIntentName,
            appRoot: appRoot
        )
        guard let data = try readCatalogMetadataIfPresent(at: url) else { return nil }
        guard let intent = try? JSONDecoder().decode(
            GenerationMigrationIntent.self,
            from: data
        ),
        intent.schemaVersion == generationMigrationSchemaVersion,
        intent.sourceGenerationID != intent.targetGenerationID
        else {
            throw LocationError.invalidCatalogMetadata(url)
        }
        return intent
    }

    private static func migrationTargetMarkerMatches(
        _ intent: GenerationMigrationIntent,
        generationID: UUID,
        generationURL: URL,
        canonicalGeneration: URL
    ) throws -> Bool {
        guard intent.targetGenerationID == generationID else { return false }
        let marker = generationURL.appendingPathComponent(migrationTargetMarkerName)
        try validateGenerationChild(
            marker,
            named: migrationTargetMarkerName,
            canonicalGeneration: canonicalGeneration
        )
        guard let data = try readCatalogMetadataIfPresent(at: marker) else { return false }
        guard let target = try? JSONDecoder().decode(
            GenerationMigrationIntent.self,
            from: data
        ), target.schemaVersion == intent.schemaVersion,
           target.sourceGenerationID == intent.sourceGenerationID,
           target.targetGenerationID == intent.targetGenerationID,
           (target.abandonSourceOnCommit == true)
            == (intent.abandonSourceOnCommit == true)
        else {
            throw LocationError.invalidCatalogMetadata(marker)
        }
        return true
    }

    private static func writeOrValidateMigrationTargetMarker(
        sourceGenerationID: UUID,
        targetGenerationID: UUID,
        abandonSourceOnCommit: Bool,
        generationURL: URL
    ) throws {
        let marker = generationURL.appendingPathComponent(migrationTargetMarkerName)
        let canonicalGeneration = generationURL.resolvingSymlinksInPath().standardizedFileURL
        try validateGenerationChild(
            marker,
            named: migrationTargetMarkerName,
            canonicalGeneration: canonicalGeneration
        )
        let expected = GenerationMigrationIntent(
            schemaVersion: generationMigrationSchemaVersion,
            sourceGenerationID: sourceGenerationID,
            targetGenerationID: targetGenerationID,
            abandonSourceOnCommit: abandonSourceOnCommit ? true : nil
        )
        if let data = try readCatalogMetadataIfPresent(at: marker) {
            guard let existing = try? JSONDecoder().decode(
                GenerationMigrationIntent.self,
                from: data
            ),
            existing.schemaVersion == expected.schemaVersion,
            existing.sourceGenerationID == expected.sourceGenerationID,
            existing.targetGenerationID == expected.targetGenerationID,
            (existing.abandonSourceOnCommit == true)
                == (expected.abandonSourceOnCommit == true)
            else {
                throw LocationError.invalidCatalogMetadata(marker)
            }
            return
        }
        try JSONEncoder().encode(expected).write(to: marker, options: [.atomic])
    }

    private static func isAbandonedMigrationTarget(
        generationID: UUID,
        generationURL: URL,
        canonicalGeneration: URL
    ) throws -> Bool {
        try abandonedMigrationTarget(
            generationID: generationID,
            generationURL: generationURL,
            canonicalGeneration: canonicalGeneration
        ) != nil
    }

    private static func abandonedMigrationTarget(
        generationID: UUID,
        generationURL: URL,
        canonicalGeneration: URL
    ) throws -> AbandonedMigrationTarget? {
        let marker = generationURL.appendingPathComponent(abandonedMigrationMarkerName)
        try validateGenerationChild(
            marker,
            named: abandonedMigrationMarkerName,
            canonicalGeneration: canonicalGeneration
        )
        guard let data = try readCatalogMetadataIfPresent(at: marker) else { return nil }
        guard let payload = try? JSONDecoder().decode(
            AbandonedMigrationTarget.self,
            from: data
        ),
        payload.schemaVersion == generationMigrationSchemaVersion,
        payload.generationID == generationID,
        payload.ownerPID > 0
        else {
            throw LocationError.invalidCatalogMetadata(marker)
        }
        return payload
    }

    private static func markMigrationTargetAbandoned(
        _ preparation: CatalogPreparation
    ) throws {
        try markMigrationTargetAbandoned(
            generationID: preparation.generationID,
            appRoot: preparation.appRootURL
        )
    }

    private static func markMigrationTargetAbandoned(
        generationID: UUID,
        appRoot: URL
    ) throws {
        let paths = try validatedGenerationPaths(
            generationID: generationID,
            appRoot: appRoot
        )
        let marker = paths.generation.appendingPathComponent(abandonedMigrationMarkerName)
        try validateGenerationChild(
            marker,
            named: abandonedMigrationMarkerName,
            canonicalGeneration: paths.canonicalGeneration
        )
        let payload = AbandonedMigrationTarget(
            schemaVersion: generationMigrationSchemaVersion,
            generationID: generationID,
            ownerPID: getpid()
        )
        try JSONEncoder().encode(payload).write(to: marker, options: [.atomic])
    }

    private static func removeAbandonedMigrationTargets(
        appRoot: URL,
        preserving sourceGenerationID: UUID
    ) throws {
        let libraryPaths = try validatedLibrariesPaths(appRoot: appRoot)
        guard FileManager.default.fileExists(atPath: libraryPaths.libraries.path) else { return }
        let entries = try FileManager.default.contentsOfDirectory(
            at: libraryPaths.libraries,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )

        for entry in entries {
            guard let generationID = UUID(uuidString: entry.lastPathComponent),
                  entry.lastPathComponent == generationID.uuidString,
                  generationID != sourceGenerationID
            else { continue }
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let paths = try validatedGenerationPaths(
                generationID: generationID,
                appRoot: appRoot
            )
            guard let abandoned = try abandonedMigrationTarget(
                generationID: generationID,
                generationURL: paths.generation,
                canonicalGeneration: paths.canonicalGeneration
            ) else { continue }
            guard abandoned.ownerPID != getpid(),
                  !processIsRunning(abandoned.ownerPID)
            else { continue }

            if try completionMarkerState(
                generationID: generationID,
                generationURL: paths.generation,
                canonicalGeneration: paths.canonicalGeneration
            ) == .valid {
                continue
            }

            let targetMarker = paths.generation.appendingPathComponent(migrationTargetMarkerName)
            try validateGenerationChild(
                targetMarker,
                named: migrationTargetMarkerName,
                canonicalGeneration: paths.canonicalGeneration
            )
            guard let markerData = try readCatalogMetadataIfPresent(at: targetMarker),
                  let marker = try? JSONDecoder().decode(
                    GenerationMigrationIntent.self,
                    from: markerData
                  ),
                  marker.schemaVersion == generationMigrationSchemaVersion,
                  marker.targetGenerationID == generationID,
                  marker.sourceGenerationID != generationID
            else {
                throw LocationError.invalidCatalogMetadata(targetMarker)
            }
            try FileManager.default.removeItem(at: paths.generation)
        }
    }

    private static func processIsRunning(_ pid: pid_t) -> Bool {
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    private static func copyNonCatalogGenerationContent(
        from sourceGeneration: URL,
        to targetGeneration: URL
    ) throws {
        guard sourceGeneration.standardizedFileURL.path
                != targetGeneration.standardizedFileURL.path
        else { throw LocationError.unsafeLibraryPath(targetGeneration) }
        let entries = try FileManager.default.contentsOfDirectory(
            at: sourceGeneration,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: []
        )
        for source in entries where !isCatalogGenerationArtifact(source.lastPathComponent) {
            try copyGenerationItem(
                from: source,
                to: targetGeneration.appendingPathComponent(source.lastPathComponent)
            )
        }
    }

    private static func nonCatalogGenerationContentMatches(
        _ sourceGeneration: URL,
        _ targetGeneration: URL
    ) throws -> Bool {
        let sourceEntries = try FileManager.default.contentsOfDirectory(
            at: sourceGeneration,
            includingPropertiesForKeys: nil,
            options: []
        ).filter { !isCatalogGenerationArtifact($0.lastPathComponent) }
        let targetEntries = try FileManager.default.contentsOfDirectory(
            at: targetGeneration,
            includingPropertiesForKeys: nil,
            options: []
        ).filter { !isCatalogGenerationArtifact($0.lastPathComponent) }
        let sourceByName = Dictionary(uniqueKeysWithValues: sourceEntries.map {
            ($0.lastPathComponent, $0)
        })
        let targetByName = Dictionary(uniqueKeysWithValues: targetEntries.map {
            ($0.lastPathComponent, $0)
        })
        guard sourceByName.keys.allSatisfy({ targetByName[$0] != nil }) else {
            return false
        }
        let implicitEmptyDirectories = Set(["Originals", "Incoming", "Recipes", "Trash"])
        for (name, target) in targetByName where sourceByName[name] == nil {
            guard implicitEmptyDirectories.contains(name),
                  try generationDirectoryIsEmpty(target)
            else { return false }
        }
        return try sourceByName.allSatisfy { name, source in
            guard let target = targetByName[name] else { return false }
            return try generationItemsMatch(source, target)
        }
    }

    private static func nonCatalogGenerationContentCanResumeCopy(
        _ sourceGeneration: URL,
        _ targetGeneration: URL
    ) throws -> Bool {
        let sourceEntries = try FileManager.default.contentsOfDirectory(
            at: sourceGeneration,
            includingPropertiesForKeys: nil,
            options: []
        ).filter { !isCatalogGenerationArtifact($0.lastPathComponent) }
        let targetEntries = try FileManager.default.contentsOfDirectory(
            at: targetGeneration,
            includingPropertiesForKeys: nil,
            options: []
        ).filter { !isCatalogGenerationArtifact($0.lastPathComponent) }
        let sourceByName = Dictionary(uniqueKeysWithValues: sourceEntries.map {
            ($0.lastPathComponent, $0)
        })
        let implicitEmptyDirectories = Set(["Originals", "Incoming", "Recipes", "Trash"])
        for target in targetEntries {
            let name = target.lastPathComponent
            if let source = sourceByName[name] {
                guard try generationItemsMatch(
                    source,
                    target,
                    allowingMissingTargetItems: true
                ) else { return false }
            } else {
                guard implicitEmptyDirectories.contains(name),
                      try generationDirectoryIsEmpty(target)
                else { return false }
            }
        }
        return true
    }

    private static func generationDirectoryIsEmpty(_ directory: URL) throws -> Bool {
        let values = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            return false
        }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ).isEmpty
    }

    private static func generationItemsMatch(
        _ source: URL,
        _ target: URL,
        allowingMissingTargetItems: Bool = false
    ) throws -> Bool {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        let sourceValues = try source.resourceValues(forKeys: keys)
        let targetValues = try target.resourceValues(forKeys: keys)
        guard sourceValues.isSymbolicLink != true,
              targetValues.isSymbolicLink != true
        else {
            throw LocationError.unsafeLibraryPath(
                sourceValues.isSymbolicLink == true ? source : target
            )
        }
        if sourceValues.isDirectory == true || targetValues.isDirectory == true {
            guard sourceValues.isDirectory == true, targetValues.isDirectory == true else {
                return false
            }
            let sourceChildren = try FileManager.default.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: nil,
                options: []
            )
            let targetChildren = try FileManager.default.contentsOfDirectory(
                at: target,
                includingPropertiesForKeys: nil,
                options: []
            )
            let sourceByName = Dictionary(uniqueKeysWithValues: sourceChildren.map {
                ($0.lastPathComponent, $0)
            })
            let targetByName = Dictionary(uniqueKeysWithValues: targetChildren.map {
                ($0.lastPathComponent, $0)
            })
            if allowingMissingTargetItems {
                guard targetByName.keys.allSatisfy({ sourceByName[$0] != nil }) else {
                    return false
                }
                return try targetByName.allSatisfy { name, targetChild in
                    guard let sourceChild = sourceByName[name] else { return false }
                    return try generationItemsMatch(
                        sourceChild,
                        targetChild,
                        allowingMissingTargetItems: true
                    )
                }
            }
            guard sourceByName.keys == targetByName.keys else { return false }
            return try sourceByName.allSatisfy { name, sourceChild in
                guard let targetChild = targetByName[name] else { return false }
                return try generationItemsMatch(sourceChild, targetChild)
            }
        }
        guard sourceValues.isRegularFile == true,
              targetValues.isRegularFile == true
        else { return false }

        let sourceFile = try ContentDigest.openPinnedRegularFile(at: source)
        let targetFile = try ContentDigest.openPinnedRegularFile(at: target)
        let matches = try sourceFile.sha256() == targetFile.sha256()
        guard try sourceFile.stillMatchesFile(at: source),
              try targetFile.stillMatchesFile(at: target)
        else { throw LocationError.libraryChangedDuringOpen }
        return matches
    }

    private static func isCatalogGenerationArtifact(_ name: String) -> Bool {
        name == "Catalog"
            || name == "CatalogCreation.pending.json"
            || name == "CatalogArtifactQuarantine.json"
            || name == migrationTargetMarkerName
            || name == abandonedMigrationMarkerName
            || name.hasPrefix("Catalog.v4-backup-")
            || name.hasPrefix("Catalog.migrating-")
            || name.hasPrefix("Catalog.obsolete-v4-backup-")
            || name.hasPrefix("Catalog.unreadable-")
            || name.hasPrefix("Catalog.incomplete-")
            || name.hasPrefix(".Catalog.")
    }

    private static func copyGenerationItem(from source: URL, to destination: URL) throws {
        let values = try source.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isSymbolicLink != true else {
            throw LocationError.unsafeLibraryPath(source)
        }

        if values.isDirectory == true {
            if FileManager.default.fileExists(atPath: destination.path) {
                let destinationValues = try destination.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ])
                guard destinationValues.isDirectory == true,
                      destinationValues.isSymbolicLink != true
                else { throw LocationError.unsafeLibraryPath(destination) }
            } else {
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: false
                )
            }
            let children = try FileManager.default.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: nil,
                options: []
            )
            for child in children {
                try copyGenerationItem(
                    from: child,
                    to: destination.appendingPathComponent(child.lastPathComponent)
                )
            }
            return
        }

        guard values.isRegularFile == true else {
            throw LocationError.unsafeLibraryPath(source)
        }
        let pinnedSource = try ContentDigest.openPinnedRegularFile(at: source)
        let sourceDigest = try pinnedSource.sha256()
        if FileManager.default.fileExists(atPath: destination.path) {
            let destinationValues = try destination.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard destinationValues.isRegularFile == true,
                  destinationValues.isSymbolicLink != true,
                  try ContentDigest.sha256(of: destination) == sourceDigest
            else { throw LocationError.unsafeLibraryPath(destination) }
        } else {
            try FileManager.default.copyItem(at: source, to: destination)
        }
        guard try pinnedSource.stillMatchesFile(at: source),
              try ContentDigest.sha256(of: destination) == sourceDigest
        else { throw LocationError.libraryChangedDuringOpen }
    }

    private static func createLibraryTree(for preparation: CatalogPreparation) throws {
        let fm = FileManager.default
        var paths = try validatedGenerationPaths(
            generationID: preparation.generationID,
            appRoot: preparation.appRootURL
        )

        if preparation.allowsCatalogCreation {
            try fm.createDirectory(at: paths.libraries, withIntermediateDirectories: true)
            try fm.createDirectory(at: paths.generation, withIntermediateDirectories: true)
            paths = try validatedGenerationPaths(
                generationID: preparation.generationID,
                appRoot: preparation.appRootURL
            )
            if preparation.needsCreationMarker {
                try writeCreationMarker(
                    generationID: preparation.generationID,
                    generationURL: paths.generation,
                    canonicalGeneration: paths.canonicalGeneration
                )
            }
        } else if try !exactGenerationDirectoryExists(
            preparation.generationID,
            in: paths.libraries
        ) {
            throw LocationError.missingLibraryGeneration(preparation.generationID)
        }

        for name in ["Originals", "Incoming", "Recipes", "Trash", "Catalog"] {
            let directory = paths.generation.appendingPathComponent(name, isDirectory: true)
            try validateDirectChild(
                directory,
                named: name,
                canonicalParent: paths.canonicalGeneration
            )
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try validateDirectChild(
                directory,
                named: name,
                canonicalParent: paths.canonicalGeneration
            )
        }
        try fm.createDirectory(at: thumbnailsCache, withIntermediateDirectories: true)
    }

    private static func exactGenerationDirectoryExists(_ id: UUID, in libraries: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: libraries.path) else { return false }
        let entries = try FileManager.default.contentsOfDirectory(
            at: libraries,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        guard let entry = entries.first(where: { $0.lastPathComponent == id.uuidString }) else {
            return false
        }
        let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func catalogURL(in generation: URL) -> URL {
        generation
            .appendingPathComponent("Catalog", isDirectory: true)
            .appendingPathComponent("catalog.store")
    }

    private static func completionMarkerURL(in generation: URL) -> URL {
        generation
            .appendingPathComponent("Catalog", isDirectory: true)
            .appendingPathComponent("Catalog.complete.json")
    }

    private static func creationMarkerURL(in generation: URL) -> URL {
        generation.appendingPathComponent("CatalogCreation.pending.json")
    }

    private static func completionMarkerState(
        generationID: UUID,
        generationURL: URL,
        canonicalGeneration: URL
    ) throws -> CompletionMarkerState {
        let marker = completionMarkerURL(in: generationURL)
        try validateCatalogChild(
            marker,
            named: "Catalog.complete.json",
            canonicalGeneration: canonicalGeneration
        )
        guard let data = try readCatalogMetadataIfPresent(at: marker) else { return .missing }
        guard let payload = try? JSONDecoder().decode(
                CatalogCompletion.self,
                from: data
              ),
              payload.schemaVersion == completionSchemaVersion,
              payload.generationID == generationID
        else { return .invalid }
        return .valid
    }

    private static func writeCompletionMarker(
        generationID: UUID,
        generationURL: URL,
        canonicalGeneration: URL
    ) throws {
        let marker = completionMarkerURL(in: generationURL)
        try validateCatalogChild(
            marker,
            named: "Catalog.complete.json",
            canonicalGeneration: canonicalGeneration
        )
        let payload = CatalogCompletion(
            schemaVersion: completionSchemaVersion,
            generationID: generationID
        )
        try JSONEncoder().encode(payload).write(to: marker, options: [.atomic])
    }

    private static func creationMarkerState(
        generationID: UUID,
        generationURL: URL,
        canonicalGeneration: URL
    ) throws -> CompletionMarkerState {
        let marker = creationMarkerURL(in: generationURL)
        try validateGenerationChild(
            marker,
            named: "CatalogCreation.pending.json",
            canonicalGeneration: canonicalGeneration
        )
        guard let data = try readCatalogMetadataIfPresent(at: marker) else { return .missing }
        guard let payload = try? JSONDecoder().decode(CatalogCreation.self, from: data),
              payload.schemaVersion == creationSchemaVersion,
              payload.generationID == generationID
        else { return .invalid }
        return .valid
    }

    private static func writeCreationMarker(
        generationID: UUID,
        generationURL: URL,
        canonicalGeneration: URL
    ) throws {
        let marker = creationMarkerURL(in: generationURL)
        try validateGenerationChild(
            marker,
            named: "CatalogCreation.pending.json",
            canonicalGeneration: canonicalGeneration
        )
        let payload = CatalogCreation(
            schemaVersion: creationSchemaVersion,
            generationID: generationID
        )
        try JSONEncoder().encode(payload).write(to: marker, options: [.atomic])
    }

    private static func removeCreationMarkerIfPresent(
        generationID: UUID,
        generationURL: URL,
        canonicalGeneration: URL
    ) throws {
        let marker = creationMarkerURL(in: generationURL)
        let state = try creationMarkerState(
            generationID: generationID,
            generationURL: generationURL,
            canonicalGeneration: canonicalGeneration
        )
        guard state != .missing else { return }
        guard state == .valid else {
            throw LocationError.invalidCatalogMetadata(marker)
        }
        try FileManager.default.removeItem(at: marker)
    }

    private static func writeLegacyMigrationCompletion(
        sourceIdentity: CatalogV4Migration.SourceIdentity,
        targetGenerationID: UUID,
        appRoot: URL
    ) throws {
        let marker = appRoot.appendingPathComponent("LegacyCatalogMigration.json")
        try validateRootMetadataURL(
            marker,
            named: "LegacyCatalogMigration.json",
            appRoot: appRoot
        )
        let payload = LegacyMigrationCompletion(
            schemaVersion: legacyMigrationSchemaVersion,
            sourceIdentity: sourceIdentity,
            targetGenerationID: targetGenerationID
        )
        try JSONEncoder().encode(payload).write(to: marker, options: [.atomic])
    }

    static func legacyMigrationCompletionMatches(
        at marker: URL,
        sourceIdentity: CatalogV4Migration.SourceIdentity,
        targetGenerationID: UUID
    ) throws -> Bool {
        guard let payload = try legacyMigrationCompletion(at: marker) else { return false }
        return payload.sourceIdentity == sourceIdentity
            && payload.targetGenerationID == targetGenerationID
    }

    static func legacyMigrationWasCompleted(at marker: URL) throws -> Bool {
        try legacyMigrationCompletion(at: marker) != nil
    }

    static func legacyMigrationTargetIsMissing(
        at marker: URL,
        appRoot: URL
    ) throws -> Bool {
        guard let payload = try legacyMigrationCompletion(at: marker) else { return false }
        let paths = try validatedLibrariesPaths(appRoot: appRoot)
        return try !exactGenerationDirectoryExists(
            payload.targetGenerationID,
            in: paths.libraries
        )
    }

    private static func legacyMigrationCompletion(
        at marker: URL
    ) throws -> LegacyMigrationCompletion? {
        guard let data = try readCatalogMetadataIfPresent(at: marker) else { return nil }
        guard let payload = try? JSONDecoder().decode(
            LegacyMigrationCompletion.self,
            from: data
        ), payload.schemaVersion == legacyMigrationSchemaVersion,
           CatalogV4Migration.validSourceIdentity(payload.sourceIdentity)
        else {
            throw LocationError.invalidCatalogMetadata(marker)
        }
        return payload
    }

    private static func catalogHasSQLiteHeader(
        at catalog: URL,
        canonicalGeneration: URL
    ) throws -> Bool {
        guard FileManager.default.fileExists(atPath: catalog.path) else { return false }
        try validateCatalogChild(
            catalog,
            named: "catalog.store",
            canonicalGeneration: canonicalGeneration
        )
        let values = try catalog.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) >= sqliteHeader.count
        else { return false }

        let handle = try FileHandle(forReadingFrom: catalog)
        defer { try? handle.close() }
        return try handle.read(upToCount: sqliteHeader.count) == sqliteHeader
    }

    private static func validatedLibrariesPaths(
        appRoot: URL
    ) throws -> (libraries: URL, canonicalRoot: URL, canonicalLibraries: URL) {
        let canonicalRoot = appRoot.resolvingSymlinksInPath().standardizedFileURL
        let libraries = appRoot.appendingPathComponent("Libraries", isDirectory: true)
        let canonicalLibraries = FileManager.default.fileExists(atPath: libraries.path)
            ? libraries.resolvingSymlinksInPath().standardizedFileURL
            : canonicalRoot.appendingPathComponent("Libraries", isDirectory: true)
        guard isDescendant(canonicalLibraries, of: canonicalRoot) else {
            throw LocationError.unsafeLibraryPath(libraries)
        }
        return (libraries, canonicalRoot, canonicalLibraries)
    }

    private static func validatedGenerationPaths(
        generationID: UUID,
        appRoot: URL
    ) throws -> (
        libraries: URL,
        generation: URL,
        canonicalRoot: URL,
        canonicalGeneration: URL
    ) {
        let libraryPaths = try validatedLibrariesPaths(appRoot: appRoot)
        let generation = libraryPaths.libraries
            .appendingPathComponent(generationID.uuidString, isDirectory: true)
        let generationExists = FileManager.default.fileExists(atPath: generation.path)
        let canonicalGeneration = generationExists
            ? generation.resolvingSymlinksInPath().standardizedFileURL
            : libraryPaths.canonicalLibraries
                .appendingPathComponent(generationID.uuidString, isDirectory: true)
        guard isDescendant(canonicalGeneration, of: libraryPaths.canonicalRoot),
              canonicalGeneration.deletingLastPathComponent().path
                == libraryPaths.canonicalLibraries.path,
              canonicalGeneration.lastPathComponent == generationID.uuidString
        else {
            throw LocationError.unsafeLibraryPath(generation)
        }
        if generationExists {
            let values = try generation.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw LocationError.unsafeLibraryPath(generation)
            }
        }
        return (
            libraryPaths.libraries,
            generation,
            libraryPaths.canonicalRoot,
            canonicalGeneration
        )
    }

    private static func validateDirectChild(
        _ url: URL,
        named name: String,
        canonicalParent: URL
    ) throws {
        let expected = canonicalParent
            .appendingPathComponent(name, isDirectory: true)
            .standardizedFileURL
        let resolved = FileManager.default.fileExists(atPath: url.path)
            ? url.resolvingSymlinksInPath().standardizedFileURL
            : expected
        guard resolved.path == expected.path else {
            throw LocationError.unsafeLibraryPath(url)
        }
    }

    private static func validateCatalogChild(
        _ url: URL,
        named name: String,
        canonicalGeneration: URL
    ) throws {
        let canonicalCatalog = canonicalGeneration
            .appendingPathComponent("Catalog", isDirectory: true)
            .standardizedFileURL
        let catalogDirectoryURL = url.deletingLastPathComponent()
        let catalogDirectory = FileManager.default.fileExists(atPath: catalogDirectoryURL.path)
            ? catalogDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
            : canonicalCatalog
        let expected = canonicalCatalog.appendingPathComponent(name)
        let resolved = FileManager.default.fileExists(atPath: url.path)
            ? url.resolvingSymlinksInPath().standardizedFileURL
            : expected
        guard catalogDirectory.path == canonicalCatalog.path,
              resolved.path == expected.path
        else {
            throw LocationError.unsafeLibraryPath(url)
        }
    }

    private static func validateGenerationChild(
        _ url: URL,
        named name: String,
        canonicalGeneration: URL
    ) throws {
        let expected = canonicalGeneration.appendingPathComponent(name).standardizedFileURL
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let resolved = FileManager.default.fileExists(atPath: url.path)
            ? url.resolvingSymlinksInPath().standardizedFileURL
            : expected
        guard parent.path == canonicalGeneration.path, resolved.path == expected.path else {
            throw LocationError.unsafeLibraryPath(url)
        }
    }

    private static func validateRootMetadataURL(
        _ url: URL,
        named name: String,
        appRoot: URL
    ) throws {
        let canonicalRoot = appRoot.resolvingSymlinksInPath().standardizedFileURL
        let expected = canonicalRoot.appendingPathComponent(name).standardizedFileURL
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let resolved = FileManager.default.fileExists(atPath: url.path)
            ? url.resolvingSymlinksInPath().standardizedFileURL
            : expected
        guard parent.path == canonicalRoot.path, resolved.path == expected.path else {
            throw LocationError.unsafeLibraryPath(url)
        }
    }

    private static func validatePointerURL(_ pointer: URL, appRoot: URL) throws {
        let canonicalRoot = appRoot.resolvingSymlinksInPath().standardizedFileURL
        let expected = canonicalRoot.appendingPathComponent("CurrentLibrary.json")
        let resolved = FileManager.default.fileExists(atPath: pointer.path)
            ? pointer.resolvingSymlinksInPath().standardizedFileURL
            : expected
        guard resolved.path == expected.path else {
            throw LocationError.unsafeLibraryPath(pointer)
        }
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        candidate.path.hasPrefix(root.path + "/")
    }

    private static func pointerSnapshot(at pointer: URL) throws -> Data? {
        try readCatalogMetadataIfPresent(at: pointer)
    }

    private static func readCatalogMetadataIfPresent(at url: URL) throws -> Data? {
        do {
            guard let data = try BoundedFileReader.readRegularFile(
                at: url,
                maximumByteCount: metadataMaximumByteCount
            ) else {
                throw LocationError.invalidCatalogMetadata(url)
            }
            return data
        } catch BoundedFileReader.ReadError.fileTooLarge {
            throw LocationError.oversizedCatalogMetadata(url)
        } catch {
            if BoundedFileReader.isMissingFile(error) { return nil }
            if let error = error as? LocationError { throw error }
            throw LocationError.invalidCatalogMetadata(url)
        }
    }

    private static func writePointer(generationID: UUID, to url: URL) throws {
        let payload = CurrentLibrary(
            schemaVersion: schemaVersion,
            generationID: generationID,
            checksum: pointerChecksum(generationID: generationID)
        )
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw LocationError.pointerWriteFailed(error)
        }
    }

    private static func pointerChecksum(generationID: UUID) -> String {
        let value = "\(schemaVersion):\(generationID.uuidString.lowercased())"
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
