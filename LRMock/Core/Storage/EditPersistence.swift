//
//  EditPersistence.swift
//  RawLight
//
//  Persists portable edit state without doing file hashing or writes on the
//  main actor. Referenced originals are revalidated before their adjacent
//  sidecars can be replaced.
//

import Darwin
import Foundation
import CryptoKit
import Observation

nonisolated struct SidecarInstallOperations: Sendable {
    typealias RenameWithFlags = @Sendable (URL, URL, UInt32) -> Int32?
    typealias Rename = @Sendable (URL, URL) -> Int32?
    typealias CreateHardLink = @Sendable (URL, URL) -> Int32?

    let renameWithFlags: RenameWithFlags
    let rename: Rename
    let createHardLink: CreateHardLink
    let afterInstall: @Sendable (URL?) throws -> Void

    init(
        renameWithFlags: @escaping RenameWithFlags,
        createHardLink: @escaping CreateHardLink,
        rename: @escaping Rename = { sourceURL, destinationURL in
            let result = sourceURL.withUnsafeFileSystemRepresentation { sourcePath -> Int32 in
                guard let sourcePath else {
                    errno = EINVAL
                    return -1
                }
                return destinationURL.withUnsafeFileSystemRepresentation { destinationPath -> Int32 in
                    guard let destinationPath else {
                        errno = EINVAL
                        return -1
                    }
                    return Darwin.rename(sourcePath, destinationPath)
                }
            }
            return result == 0 ? nil : errno
        },
        afterInstall: @escaping @Sendable (URL?) throws -> Void = { _ in }
    ) {
        self.renameWithFlags = renameWithFlags
        self.rename = rename
        self.createHardLink = createHardLink
        self.afterInstall = afterInstall
    }

    static let system = SidecarInstallOperations(
        renameWithFlags: { sourceURL, destinationURL, flags in
            let result = sourceURL.withUnsafeFileSystemRepresentation { sourcePath -> Int32 in
                guard let sourcePath else {
                    errno = EINVAL
                    return -1
                }
                return destinationURL.withUnsafeFileSystemRepresentation { destinationPath -> Int32 in
                    guard let destinationPath else {
                        errno = EINVAL
                        return -1
                    }
                    return renamex_np(sourcePath, destinationPath, flags)
                }
            }
            return result == 0 ? nil : errno
        },
        createHardLink: { sourceURL, destinationURL in
            let result = sourceURL.withUnsafeFileSystemRepresentation { sourcePath -> Int32 in
                guard let sourcePath else {
                    errno = EINVAL
                    return -1
                }
                return destinationURL.withUnsafeFileSystemRepresentation { destinationPath -> Int32 in
                    guard let destinationPath else {
                        errno = EINVAL
                        return -1
                    }
                    return Darwin.link(sourcePath, destinationPath)
                }
            }
            return result == 0 ? nil : errno
        }
    )
}

nonisolated private struct SidecarFileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64

    init(_ status: stat) {
        device = UInt64(bitPattern: Int64(status.st_dev))
        inode = UInt64(status.st_ino)
    }
}

nonisolated private struct SidecarFileVersion: Equatable {
    let identity: SidecarFileIdentity
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64

    init(_ status: stat) {
        identity = SidecarFileIdentity(status)
        size = status.st_size
        modificationSeconds = Int64(status.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        changeSeconds = Int64(status.st_ctimespec.tv_sec)
        changeNanoseconds = Int64(status.st_ctimespec.tv_nsec)
    }
}

nonisolated private struct SidecarContentSnapshot {
    let version: SidecarFileVersion
    let digest: Data
}

nonisolated private final class PinnedSidecarFile {
    private static let digestChunkSize = 64 * 1024

    let identity: SidecarFileIdentity
    let version: SidecarFileVersion
    private let descriptor: Int32

    init(descriptor: Int32, status: stat) {
        self.descriptor = descriptor
        identity = SidecarFileIdentity(status)
        version = SidecarFileVersion(status)
    }

    deinit {
        Darwin.close(descriptor)
    }

    func matchesPath(at url: URL, requireUnchangedVersion: Bool = false) throws -> Bool {
        guard let currentVersion = try currentVersion(at: url) else { return false }
        return !requireUnchangedVersion || currentVersion == version
    }

    func currentVersion(at url: URL) throws -> SidecarFileVersion? {
        // APFS can publish rename-induced ctime updates between adjacent stats.
        // Only accept a stable descriptor/path snapshot.
        for _ in 0..<4 {
            var descriptorStatusBefore = stat()
            guard fstat(descriptor, &descriptorStatusBefore) == 0 else {
                let code = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            guard descriptorStatusBefore.st_mode & S_IFMT == S_IFREG else { return nil }

            var pathStatus = stat()
            let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else {
                    errno = EINVAL
                    return -1
                }
                return lstat(path, &pathStatus)
            }
            if result != 0 {
                let code = errno
                if code == ENOENT || code == ENOTDIR { return nil }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }

            var descriptorStatusAfter = stat()
            guard fstat(descriptor, &descriptorStatusAfter) == 0 else {
                let code = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            guard pathStatus.st_mode & S_IFMT == S_IFREG,
                  descriptorStatusAfter.st_mode & S_IFMT == S_IFREG,
                  SidecarFileIdentity(descriptorStatusBefore) == identity,
                  SidecarFileIdentity(pathStatus) == identity,
                  SidecarFileIdentity(descriptorStatusAfter) == identity else {
                return nil
            }

            let versionBefore = SidecarFileVersion(descriptorStatusBefore)
            let pathVersion = SidecarFileVersion(pathStatus)
            let versionAfter = SidecarFileVersion(descriptorStatusAfter)
            if versionBefore == pathVersion, pathVersion == versionAfter {
                return pathVersion
            }
        }
        return nil
    }

    func stableContentSnapshot(
        at url: URL,
        maximumByteCount: Int
    ) throws -> SidecarContentSnapshot? {
        precondition(maximumByteCount >= 0 && maximumByteCount < Int.max)

        for _ in 0..<4 {
            guard let pathVersionBefore = try currentVersion(at: url) else { return nil }

            var descriptorStatusBefore = stat()
            guard fstat(descriptor, &descriptorStatusBefore) == 0 else {
                let code = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            guard descriptorStatusBefore.st_mode & S_IFMT == S_IFREG,
                  SidecarFileIdentity(descriptorStatusBefore) == identity else {
                return nil
            }

            let versionBefore = SidecarFileVersion(descriptorStatusBefore)
            guard versionBefore == pathVersionBefore else { continue }
            guard versionBefore.size >= 0,
                  UInt64(versionBefore.size) <= UInt64(maximumByteCount) else {
                return nil
            }

            var hasher = SHA256()
            var byteOffset = 0
            var buffer = [UInt8](
                repeating: 0,
                count: max(1, min(Self.digestChunkSize, maximumByteCount + 1))
            )
            while byteOffset <= maximumByteCount {
                try Task.checkCancellation()
                let requestedCount = min(
                    buffer.count,
                    maximumByteCount + 1 - byteOffset
                )
                let byteCount = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.pread(
                        descriptor,
                        bytes.baseAddress,
                        requestedCount,
                        off_t(byteOffset)
                    )
                }
                if byteCount > 0 {
                    byteOffset += byteCount
                    guard byteOffset <= maximumByteCount else { return nil }
                    hasher.update(data: Data(buffer.prefix(byteCount)))
                    continue
                }
                if byteCount == 0 { break }
                if errno == EINTR { continue }
                let code = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }

            var descriptorStatusAfter = stat()
            guard fstat(descriptor, &descriptorStatusAfter) == 0 else {
                let code = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            guard descriptorStatusAfter.st_mode & S_IFMT == S_IFREG,
                  SidecarFileIdentity(descriptorStatusAfter) == identity else {
                return nil
            }

            let versionAfter = SidecarFileVersion(descriptorStatusAfter)
            guard versionBefore == versionAfter,
                  Int64(byteOffset) == versionAfter.size else {
                continue
            }
            guard try currentVersion(at: url) == versionAfter else { continue }
            return SidecarContentSnapshot(
                version: versionAfter,
                digest: Data(hasher.finalize())
            )
        }
        return nil
    }
}

nonisolated private enum EditPersistenceRequest: Sendable {
    case managed(RecipeDocument)
    case referenced(
        reference: AssetFileAccess.Reference,
        sidecar: Sidecar,
        assetID: UUID,
        expectedDigest: String?
    )
}

@MainActor
enum EditPersistence {

    enum PersistenceError: LocalizedError, Equatable {
        case missingSourceDigest
        case sourceContentChanged
        case sourceChangedDuringValidation
        case sourceIsNotRegularFile
        case sidecarDestinationIsNotRegularFile
        case sidecarDestinationChanged
        case unsupportedSidecarFilesystem
        case sidecarRecoveryRequired(String)

        var errorDescription: String? {
            switch self {
            case .missingSourceDigest:
                return "The referenced original has no saved content identity, so its sidecar was not overwritten. Re-import or re-link the original first."
            case .sourceContentChanged:
                return "The referenced original's bytes no longer match this catalog asset. Its existing sidecar was left unchanged."
            case .sourceChangedDuringValidation:
                return "The referenced original changed while it was being validated. Its existing sidecar was left unchanged."
            case .sourceIsNotRegularFile:
                return "The referenced original is not a regular file. Its existing sidecar was left unchanged."
            case .sidecarDestinationIsNotRegularFile:
                return "The existing sidecar is not a regular file and was left unchanged."
            case .sidecarDestinationChanged:
                return "The existing sidecar changed while it was being replaced and was left unchanged."
            case .unsupportedSidecarFilesystem:
                return "This filesystem does not provide the atomic or exclusive operations required to replace sidecars safely."
            case .sidecarRecoveryRequired(let path):
                return "A sidecar changed during replacement. A recoverable file was preserved at \(path)."
            }
        }
    }

    /// Snapshots main-actor model state, then performs encoding, source hashing,
    /// and disk I/O away from the UI actor.
    static func writeSidecar(for asset: ImageAsset) async throws {
        let request: EditPersistenceRequest
        switch asset.storageMode {
        case .managed:
            request = .managed(RecipeDocument(asset: asset))
        case .referenced:
            request = .referenced(
                reference: AssetFileAccess.Reference(asset: asset),
                sidecar: SidecarService.snapshot(of: asset),
                assetID: asset.id,
                expectedDigest: asset.contentDigest
            )
        }

        let task = Task.detached(priority: .utility) {
            try await persist(request)
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private static func persist(_ request: EditPersistenceRequest) async throws {
        switch request {
        case .managed(let document):
            try Task.checkCancellation()
            try RecipeStore.write(document)

        case .referenced(let reference, let sidecar, let assetID, let expectedDigest):
            let handle = try AssetFileAccess.open(reference)
            defer { handle.release() }
            try await writeReferencedSidecar(
                sidecar,
                for: handle.url,
                assetID: assetID,
                expectedDigest: expectedDigest
            )
        }
    }

    /// Internal entry point used by persistence tests after they arrange a
    /// directly-accessible source URL.
    nonisolated static func writeReferencedSidecar(
        _ sidecar: Sidecar,
        for sourceURL: URL,
        assetID _: UUID,
        expectedDigest: String?,
        operations: SidecarInstallOperations = .system
    ) async throws {
        guard let expectedDigest, !expectedDigest.isEmpty else {
            throw PersistenceError.missingSourceDigest
        }

        try Task.checkCancellation()
        let source: ContentDigest.PinnedRegularFile
        do {
            source = try ContentDigest.openPinnedRegularFile(at: sourceURL)
        } catch ContentDigest.DigestError.notRegularFile {
            throw PersistenceError.sourceIsNotRegularFile
        }

        let actualDigest: String
        do {
            actualDigest = try source.sha256()
        } catch ContentDigest.DigestError.fileChangedDuringRead {
            throw PersistenceError.sourceChangedDuringValidation
        }
        guard actualDigest == expectedDigest else {
            throw PersistenceError.sourceContentChanged
        }

        try Task.checkCancellation()
        guard try source.stillMatchesFile(at: sourceURL) else {
            throw PersistenceError.sourceChangedDuringValidation
        }
        var validatedSidecar = sidecar
        validatedSidecar.sourceContentDigest = expectedDigest
        try installReferencedSidecar(
            validatedSidecar,
            for: sourceURL,
            source: source,
            operations: operations
        )
    }

    nonisolated private static func installReferencedSidecar(
        _ sidecar: Sidecar,
        for sourceURL: URL,
        source: ContentDigest.PinnedRegularFile,
        operations: SidecarInstallOperations
    ) throws {
        let sidecarURL = SidecarService.sidecarURL(for: sourceURL)
        let transactionURL = try createTransactionDirectory(
            in: sourceURL.deletingLastPathComponent()
        )
        let stagingSourceURL = transactionURL.appendingPathComponent("new")
        let stagedSidecarURL = SidecarService.sidecarURL(for: stagingSourceURL)
        let probeURL = transactionURL.appendingPathComponent("link-probe.rawlight")
        let rollbackURL = transactionURL.appendingPathComponent("rollback.rawlight")
        let transactionFiles = [stagedSidecarURL, probeURL, rollbackURL]
        var disposableFiles: [String: SidecarFileVersion] = [:]
        defer {
            cleanupTransaction(
                at: transactionURL,
                files: transactionFiles,
                disposableFiles: disposableFiles
            )
        }

        try SidecarService.write(sidecar, for: stagingSourceURL)
        let stagedFile = try requirePinnedRegularFile(at: stagedSidecarURL)
        disposableFiles[stagedSidecarURL.path] = stagedFile.version
        try Task.checkCancellation()
        guard try source.stillMatchesFile(at: sourceURL) else {
            throw PersistenceError.sourceChangedDuringValidation
        }

        let destination = try pinnedSidecarIfPresent(at: sidecarURL)
        let nativeFlags = destination == nil ? UInt32(RENAME_EXCL) : UInt32(RENAME_SWAP)
        let destinationSnapshot: SidecarContentSnapshot?
        if let destination {
            guard let snapshot = try destination.stableContentSnapshot(
                at: sidecarURL,
                maximumByteCount: SidecarService.maximumFileSize
            ), snapshot.version == destination.version else {
                throw PersistenceError.sidecarDestinationChanged
            }
            destinationSnapshot = snapshot
        } else {
            destinationSnapshot = nil
        }

        let nativeError = operations.renameWithFlags(stagedSidecarURL, sidecarURL, nativeFlags)
        if nativeError == nil {
            if let destination {
                disposableFiles.removeValue(forKey: stagedSidecarURL.path)
                do {
                    guard let destinationSnapshot,
                          try stagedFile.matchesPath(at: sidecarURL),
                          let displacedSnapshot = try destination.stableContentSnapshot(
                            at: stagedSidecarURL,
                            maximumByteCount: SidecarService.maximumFileSize
                          ),
                          displacedSnapshot.digest == destinationSnapshot.digest else {
                        throw PersistenceError.sidecarDestinationChanged
                    }
                    try operations.afterInstall(stagedSidecarURL)
                    guard try source.stillMatchesFile(at: sourceURL) else {
                        throw PersistenceError.sourceChangedDuringValidation
                    }
                    guard try stagedFile.matchesPath(at: sidecarURL),
                          let deletionSnapshot = try destination.stableContentSnapshot(
                            at: stagedSidecarURL,
                            maximumByteCount: SidecarService.maximumFileSize
                          ),
                          deletionSnapshot.digest == destinationSnapshot.digest,
                          deletionSnapshot.version == displacedSnapshot.version else {
                        throw PersistenceError.sidecarDestinationChanged
                    }
                    try unlinkFile(at: stagedSidecarURL, matching: deletionSnapshot.version)
                } catch let installationError {
                    let rollbackError = operations.renameWithFlags(
                        stagedSidecarURL,
                        sidecarURL,
                        UInt32(RENAME_SWAP)
                    )
                    guard rollbackError == nil,
                          try destination.matchesPath(at: sidecarURL),
                          let stagedVersion = try stagedFile.currentVersion(
                            at: stagedSidecarURL
                          ) else {
                        throw PersistenceError.sidecarRecoveryRequired(stagedSidecarURL.path)
                    }
                    disposableFiles[stagedSidecarURL.path] = stagedVersion
                    throw installationError
                }
                return
            }

            disposableFiles.removeValue(forKey: stagedSidecarURL.path)
            do {
                guard try stagedFile.matchesPath(at: sidecarURL) else {
                    throw PersistenceError.sidecarDestinationChanged
                }
                try operations.afterInstall(nil)
                guard try source.stillMatchesFile(at: sourceURL),
                      try stagedFile.matchesPath(at: sidecarURL) else {
                    throw PersistenceError.sourceChangedDuringValidation
                }
            } catch let installationError {
                let rollbackError = operations.renameWithFlags(
                    sidecarURL,
                    stagedSidecarURL,
                    UInt32(RENAME_EXCL)
                )
                guard rollbackError == nil else {
                    throw PersistenceError.sidecarRecoveryRequired(sidecarURL.path)
                }
                guard let stagedVersion = try stagedFile.currentVersion(
                    at: stagedSidecarURL
                ) else {
                    throw PersistenceError.sidecarRecoveryRequired(stagedSidecarURL.path)
                }
                disposableFiles[stagedSidecarURL.path] = stagedVersion
                throw installationError
            }
            return
        }

        guard let nativeError else { return }
        if !isUnsupportedRenameError(nativeError) {
            if destination == nil, nativeError == EEXIST {
                throw PersistenceError.sidecarDestinationChanged
            }
            throw posixError(nativeError)
        }
        guard destination == nil else {
            throw PersistenceError.unsupportedSidecarFilesystem
        }

        try installReferencedSidecarFallback(
            at: sidecarURL,
            stagedAt: stagedSidecarURL,
            probeAt: probeURL,
            rollbackAt: rollbackURL,
            stagedFile: stagedFile,
            sourceURL: sourceURL,
            source: source,
            operations: operations,
            disposableFiles: &disposableFiles
        )
    }

    nonisolated private static func installReferencedSidecarFallback(
        at sidecarURL: URL,
        stagedAt stagedSidecarURL: URL,
        probeAt probeURL: URL,
        rollbackAt rollbackURL: URL,
        stagedFile: PinnedSidecarFile,
        sourceURL: URL,
        source: ContentDigest.PinnedRegularFile,
        operations: SidecarInstallOperations,
        disposableFiles: inout [String: SidecarFileVersion]
    ) throws {
        guard let stagedSnapshot = try stagedFile.stableContentSnapshot(
            at: stagedSidecarURL,
            maximumByteCount: SidecarService.maximumFileSize
        ), stagedSnapshot.version == stagedFile.version else {
            throw PersistenceError.sidecarDestinationChanged
        }

        if let linkError = operations.createHardLink(stagedSidecarURL, probeURL) {
            if isUnsupportedLinkError(linkError) {
                throw PersistenceError.unsupportedSidecarFilesystem
            }
            throw posixError(linkError)
        }
        guard let linkedVersion = try stagedFile.currentVersion(at: probeURL),
              try stagedFile.currentVersion(at: stagedSidecarURL) == linkedVersion else {
            throw PersistenceError.unsupportedSidecarFilesystem
        }
        disposableFiles[stagedSidecarURL.path] = linkedVersion
        disposableFiles[probeURL.path] = linkedVersion
        try unlinkFile(at: probeURL, matching: linkedVersion)
        disposableFiles.removeValue(forKey: probeURL.path)
        guard let postProbeVersion = try stagedFile.currentVersion(at: stagedSidecarURL) else {
            throw PersistenceError.sidecarRecoveryRequired(stagedSidecarURL.path)
        }
        disposableFiles[stagedSidecarURL.path] = postProbeVersion

        guard try pinnedSidecarIfPresent(at: sidecarURL) == nil else {
            throw PersistenceError.sidecarDestinationChanged
        }

        guard try source.stillMatchesFile(at: sourceURL) else {
            throw PersistenceError.sourceChangedDuringValidation
        }

        if let linkError = operations.createHardLink(stagedSidecarURL, sidecarURL) {
            if linkError == EEXIST {
                throw PersistenceError.sidecarDestinationChanged
            }
            if isUnsupportedLinkError(linkError) {
                throw PersistenceError.unsupportedSidecarFilesystem
            }
            throw posixError(linkError)
        }
        guard let installedVersion = try stagedFile.currentVersion(at: sidecarURL),
              try stagedFile.currentVersion(at: stagedSidecarURL) == installedVersion else {
            throw PersistenceError.sidecarDestinationChanged
        }
        disposableFiles[stagedSidecarURL.path] = installedVersion

        do {
            try operations.afterInstall(nil)
            guard try source.stillMatchesFile(at: sourceURL) else {
                throw PersistenceError.sourceChangedDuringValidation
            }
            guard try stagedFile.currentVersion(at: sidecarURL) == installedVersion,
                  try stagedFile.currentVersion(at: stagedSidecarURL) == installedVersion else {
                throw PersistenceError.sidecarDestinationChanged
            }
        } catch let installationError {
            // Move the public entry out of reach before checking it; validating
            // and then unlinking the canonical path can delete a racing writer.
            if let rollbackError = operations.rename(sidecarURL, rollbackURL) {
                guard rollbackError == ENOENT else {
                    throw PersistenceError.sidecarRecoveryRequired(sidecarURL.path)
                }
            } else {
                let rollbackSnapshot: SidecarContentSnapshot
                do {
                    guard let snapshot = try stagedFile.stableContentSnapshot(
                        at: rollbackURL,
                        maximumByteCount: SidecarService.maximumFileSize
                    ), snapshot.digest == stagedSnapshot.digest else {
                        throw PersistenceError.sidecarDestinationChanged
                    }
                    rollbackSnapshot = snapshot
                } catch {
                    throw PersistenceError.sidecarRecoveryRequired(rollbackURL.path)
                }
                do {
                    try unlinkFile(at: rollbackURL, matching: rollbackSnapshot.version)
                } catch {
                    throw PersistenceError.sidecarRecoveryRequired(rollbackURL.path)
                }
            }
            guard let stagedVersion = try stagedFile.currentVersion(
                at: stagedSidecarURL
            ) else {
                throw PersistenceError.sidecarRecoveryRequired(stagedSidecarURL.path)
            }
            disposableFiles[stagedSidecarURL.path] = stagedVersion
            throw installationError
        }
    }

    nonisolated private static func pinnedSidecarIfPresent(
        at url: URL
    ) throws -> PinnedSidecarFile? {
        var firstStatus = stat()
        let firstResult = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return lstat(path, &firstStatus)
        }
        if firstResult != 0 {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return nil }
            throw posixError(code)
        }
        guard firstStatus.st_mode & S_IFMT == S_IFREG else {
            throw PersistenceError.sidecarDestinationIsNotRegularFile
        }

        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            var result: Int32
            repeat {
                result = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
            } while result < 0 && errno == EINTR
            return result
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP { throw PersistenceError.sidecarDestinationIsNotRegularFile }
            if code == ENOENT || code == ENOTDIR {
                throw PersistenceError.sidecarDestinationChanged
            }
            throw posixError(code)
        }

        do {
            var descriptorStatus = stat()
            guard fstat(descriptor, &descriptorStatus) == 0 else {
                throw posixError(errno)
            }
            guard descriptorStatus.st_mode & S_IFMT == S_IFREG else {
                throw PersistenceError.sidecarDestinationIsNotRegularFile
            }

            var finalStatus = stat()
            let finalResult = url.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else {
                    errno = EINVAL
                    return -1
                }
                return lstat(path, &finalStatus)
            }
            guard finalResult == 0,
                  finalStatus.st_mode & S_IFMT == S_IFREG,
                  SidecarFileVersion(firstStatus) == SidecarFileVersion(descriptorStatus),
                  SidecarFileVersion(finalStatus) == SidecarFileVersion(descriptorStatus)
            else {
                throw PersistenceError.sidecarDestinationChanged
            }
            return PinnedSidecarFile(descriptor: descriptor, status: descriptorStatus)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    nonisolated private static func requirePinnedRegularFile(
        at url: URL
    ) throws -> PinnedSidecarFile {
        guard let file = try pinnedSidecarIfPresent(at: url) else {
            throw posixError(ENOENT)
        }
        return file
    }

    nonisolated private static func createTransactionDirectory(in parentURL: URL) throws -> URL {
        for _ in 0..<16 {
            let url = parentURL.appendingPathComponent(
                ".rawlight-sidecar-\(UUID().uuidString)-transaction",
                isDirectory: true
            )
            let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else {
                    errno = EINVAL
                    return -1
                }
                return Darwin.mkdir(path, mode_t(S_IRWXU))
            }
            if result == 0 { return url }
            let code = errno
            if code == EEXIST { continue }
            throw posixError(code)
        }
        throw posixError(EEXIST)
    }

    nonisolated private static func cleanupTransaction(
        at transactionURL: URL,
        files: [URL],
        disposableFiles: [String: SidecarFileVersion]
    ) {
        for fileURL in files {
            guard let version = disposableFiles[fileURL.path] else { continue }
            try? unlinkFile(at: fileURL, matching: version)
        }
        _ = transactionURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.rmdir(path)
        }
    }

    nonisolated private static func unlinkFile(
        at url: URL,
        matching version: SidecarFileVersion
    ) throws {
        var status = stat()
        let statusResult = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return lstat(path, &status)
        }
        if statusResult != 0 {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return }
            throw posixError(code)
        }
        guard status.st_mode & S_IFMT == S_IFREG,
              SidecarFileVersion(status) == version else {
            throw PersistenceError.sidecarDestinationChanged
        }
        let unlinkResult = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return Darwin.unlink(path)
        }
        guard unlinkResult == 0 else { throw posixError(errno) }
    }

    nonisolated private static func isUnsupportedRenameError(_ code: Int32) -> Bool {
        code == ENOTSUP || code == EOPNOTSUPP
    }

    nonisolated private static func isUnsupportedLinkError(_ code: Int32) -> Bool {
        code == ENOTSUP || code == EOPNOTSUPP || code == EPERM
    }

    nonisolated private static func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}

/// Coalesces edits and keeps failed assets dirty so a later explicit or
/// lifecycle flush can retry them.
@MainActor
@Observable
final class SidecarAutosaver {

    typealias Writer = @MainActor (ImageAsset) async throws -> Void

    private var pending: [UUID: Task<Void, Never>] = [:]
    private var assets: [UUID: ImageAsset] = [:]
    private var tokens: [UUID: UUID] = [:]
    @ObservationIgnored private let writer: Writer
    var lastError: String?

    init(writer: @escaping Writer = { asset in
        try await EditPersistence.writeSidecar(for: asset)
    }) {
        self.writer = writer
    }

    var hasUnsavedChanges: Bool { !assets.isEmpty }

    /// Schedules a sidecar write after `delay` with no further changes.
    func schedule(_ asset: ImageAsset, delay: Duration = .seconds(1)) {
        enqueue(asset, delay: delay)
    }

    /// Cancels a delayed write, persists the newest snapshot, and waits for the
    /// attempt. Failure leaves the asset in `assets` for a later retry.
    func flush(_ asset: ImageAsset) async {
        let task = enqueue(asset, delay: nil)
        await task.value
    }

    func flushAll() async {
        let tasks = Array(assets.values).map { enqueue($0, delay: nil) }
        for task in tasks {
            await task.value
        }
    }

    /// Waits for currently scheduled attempts without changing their debounce
    /// or dirty state. Primarily useful for deterministic persistence tests.
    func waitForPendingWrites() async {
        for task in Array(pending.values) {
            await task.value
        }
    }

    func dismissError() {
        lastError = nil
    }

    @discardableResult
    private func enqueue(_ asset: ImageAsset, delay: Duration?) -> Task<Void, Never> {
        let id = asset.id
        let token = UUID()
        let previous = pending[id]
        previous?.cancel()
        assets[id] = asset
        tokens[id] = token

        let task = Task { @MainActor in
            if let previous { await previous.value }
            if let delay {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, tokens[id] == token else { return }
            await persist(asset, id: id, token: token)
        }
        pending[id] = task
        return task
    }

    private func persist(_ asset: ImageAsset, id: UUID, token: UUID) async {
        do {
            try await writer(asset)
            guard tokens[id] == token else { return }
            pending[id] = nil
            assets[id] = nil
            tokens[id] = nil
        } catch is CancellationError {
            if tokens[id] == token { pending[id] = nil }
        } catch {
            guard tokens[id] == token else { return }
            pending[id] = nil
            lastError = "\(asset.originalFilename): \(error.localizedDescription)"
        }
    }
}
