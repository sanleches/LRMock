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

import Darwin
import Foundation
import CryptoKit

nonisolated enum ContentDigest {

    enum DigestError: LocalizedError, Equatable {
        case notRegularFile
        case fileChangedDuringRead

        var errorDescription: String? {
            switch self {
            case .notRegularFile:
                return "The source is not a regular file."
            case .fileChangedDuringRead:
                return "The source changed while its content was being hashed."
            }
        }
    }

    fileprivate struct FileState: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64

        init(_ status: stat) {
            device = UInt64(bitPattern: Int64(status.st_dev))
            inode = UInt64(status.st_ino)
            size = status.st_size
            modificationSeconds = Int64(status.st_mtimespec.tv_sec)
            modificationNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changeSeconds = Int64(status.st_ctimespec.tv_sec)
            changeNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        }
    }

    final class PinnedRegularFile {
        private let descriptor: Int32
        private let openedState: FileState

        fileprivate init(descriptor: Int32, state: FileState) {
            self.descriptor = descriptor
            self.openedState = state
        }

        deinit {
            Darwin.close(descriptor)
        }

        /// Hashes the bytes from the pinned descriptor and rejects mutation
        /// observed while the stream is being consumed.
        func sha256() throws -> String {
            guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
                let code = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }

            var hasher = SHA256()
            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            while true {
                try Task.checkCancellation()
                let byteCount = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                }
                if byteCount > 0 {
                    hasher.update(data: Data(buffer.prefix(Int(byteCount))))
                    continue
                }
                if byteCount == 0 { break }
                if errno == EINTR { continue }
                let code = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }

            guard try Self.state(of: descriptor) == openedState else {
                throw DigestError.fileChangedDuringRead
            }
            return Self.formatted(hasher.finalize())
        }

        /// Confirms the source path still resolves to the exact file version
        /// held by this descriptor. This is a negative race check, never a
        /// substitute for hashing the bytes.
        func stillMatchesFile(at url: URL) throws -> Bool {
            guard try Self.state(of: descriptor) == openedState else { return false }

            do {
                let current = try ContentDigest.openPinnedRegularFile(at: url)
                return current.openedState == openedState
            } catch DigestError.notRegularFile {
                return false
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSPOSIXErrorDomain,
                   [ENOENT, ENOTDIR, ELOOP].contains(Int32(nsError.code)) {
                    return false
                }
                throw error
            }
        }

        fileprivate static func state(of descriptor: Int32) throws -> FileState {
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                let code = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            guard status.st_mode & S_IFMT == S_IFREG else {
                throw DigestError.notRegularFile
            }
            return FileState(status)
        }

        private static func formatted(_ digest: SHA256.Digest) -> String {
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            return "sha256:\(hex)"
        }
    }

    /// Opens a source once without following its final symlink and rejects
    /// FIFOs, devices, sockets, and directories before any read can block.
    static func openPinnedRegularFile(at url: URL) throws -> PinnedRegularFile {
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
            if code == ELOOP { throw DigestError.notRegularFile }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }

        do {
            let state = try PinnedRegularFile.state(of: descriptor)
            return PinnedRegularFile(descriptor: descriptor, state: state)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    /// Returns a `"sha256:<hex>"` digest of the complete file.
    static func sha256(of url: URL) throws -> String {
        try openPinnedRegularFile(at: url).sha256()
    }
}
