//
//  BoundedFileReader.swift
//  RawLight
//
//  Race-free bounded reads for small persistence documents.
//

import Darwin
import Foundation

nonisolated enum BoundedFileReader {

    enum ReadError: Error {
        case fileTooLarge
    }

    private static let chunkSize = 64 * 1024

    /// Opens once, validates the opened object, and never buffers more than
    /// `maximumByteCount + 1` bytes.
    static func readRegularFile(
        at url: URL,
        maximumByteCount: Int
    ) throws -> Data? {
        precondition(maximumByteCount >= 0 && maximumByteCount < Int.max)

        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            let code = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var status = stat()
        guard fstat(handle.fileDescriptor, &status) == 0 else {
            let code = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        guard status.st_mode & S_IFMT == S_IFREG else { return nil }
        guard status.st_size >= 0,
              UInt64(status.st_size) <= UInt64(maximumByteCount) else {
            throw ReadError.fileTooLarge
        }

        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        while data.count <= maximumByteCount {
            let remaining = maximumByteCount + 1 - data.count
            let chunk = try handle.read(upToCount: min(chunkSize, remaining))
            guard let chunk, !chunk.isEmpty else { return data }
            data.append(chunk)
            if data.count > maximumByteCount {
                throw ReadError.fileTooLarge
            }
        }
        return data
    }

    static func isMissingFile(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           [CocoaError.Code.fileNoSuchFile.rawValue,
            CocoaError.Code.fileReadNoSuchFile.rawValue].contains(nsError.code) {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isMissingFile(underlying)
        }
        return false
    }

    static func isAccessDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.Code.fileReadNoPermission.rawValue {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EPERM) || nsError.code == Int(EACCES) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isAccessDenied(underlying)
        }
        return false
    }
}
