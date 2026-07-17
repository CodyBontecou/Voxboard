import Darwin
import Foundation

enum SecureCaptureFileIOError: Error, LocalizedError {
    case invalidPath(String)
    case posix(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let path):
            return "The capture file path is unsafe: \(path)"
        case .posix(let operation, let code):
            return "Secure capture file operation ‘\(operation)’ failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Performs relative file I/O through directory descriptors. Intermediate
/// components are opened with `O_NOFOLLOW`, so a symlink swap between path
/// planning and the coordinated write cannot redirect data outside the root.
enum SecureCaptureFileIO {
    static func read(relativePath: String, rootURL: URL) throws -> Data? {
        let split = try splitPath(relativePath)
        guard let parentFD = try openParent(
            components: split.parentComponents,
            rootURL: rootURL,
            createMissing: false
        ) else { return nil }
        defer { close(parentFD) }

        let fd = split.filename.withCString {
            openat(parentFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT { return nil }
            throw SecureCaptureFileIOError.posix(operation: "open", code: code)
        }
        defer { close(fd) }
        return try readAll(from: fd)
    }

    static func writeAtomically(
        _ data: Data,
        relativePath: String,
        rootURL: URL
    ) throws {
        let split = try splitPath(relativePath)
        guard let parentFD = try openParent(
            components: split.parentComponents,
            rootURL: rootURL,
            createMissing: true
        ) else {
            throw SecureCaptureFileIOError.invalidPath(relativePath)
        }
        defer { close(parentFD) }

        let temporaryName = ".vox-capture-\(UUID().uuidString.lowercased()).tmp"
        let temporaryFD = temporaryName.withCString {
            openat(
                parentFD,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard temporaryFD >= 0 else {
            throw SecureCaptureFileIOError.posix(operation: "create temporary file", code: errno)
        }
        var renamed = false
        defer {
            close(temporaryFD)
            if !renamed {
                temporaryName.withCString { _ = unlinkat(parentFD, $0, 0) }
            }
        }

        try writeAll(data, to: temporaryFD)
        guard fsync(temporaryFD) == 0 else {
            throw SecureCaptureFileIOError.posix(operation: "fsync", code: errno)
        }
        let renameResult = temporaryName.withCString { temporaryPointer in
            split.filename.withCString { filenamePointer in
                renameat(parentFD, temporaryPointer, parentFD, filenamePointer)
            }
        }
        guard renameResult == 0 else {
            throw SecureCaptureFileIOError.posix(operation: "rename", code: errno)
        }
        renamed = true
    }

    static func exists(relativePath: String, rootURL: URL) throws -> Bool {
        let split = try splitPath(relativePath)
        guard let parentFD = try openParent(
            components: split.parentComponents,
            rootURL: rootURL,
            createMissing: false
        ) else { return false }
        defer { close(parentFD) }
        let fd = split.filename.withCString {
            openat(parentFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else {
            if errno == ENOENT { return false }
            throw SecureCaptureFileIOError.posix(operation: "open", code: errno)
        }
        close(fd)
        return true
    }

    static func copy(
        sourceRelativePath: String,
        sourceRootURL: URL,
        destinationRelativePath: String,
        destinationRootURL: URL
    ) throws {
        let source = try splitPath(sourceRelativePath)
        let destination = try splitPath(destinationRelativePath)
        guard let sourceParentFD = try openParent(
            components: source.parentComponents,
            rootURL: sourceRootURL,
            createMissing: false
        ) else {
            throw SecureCaptureFileIOError.invalidPath(sourceRelativePath)
        }
        defer { close(sourceParentFD) }
        let sourceFD = source.filename.withCString {
            openat(sourceParentFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard sourceFD >= 0 else {
            throw SecureCaptureFileIOError.posix(operation: "open source", code: errno)
        }
        defer { close(sourceFD) }

        guard let destinationParentFD = try openParent(
            components: destination.parentComponents,
            rootURL: destinationRootURL,
            createMissing: true
        ) else {
            throw SecureCaptureFileIOError.invalidPath(destinationRelativePath)
        }
        defer { close(destinationParentFD) }
        let destinationFD = destination.filename.withCString {
            openat(
                destinationParentFD,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard destinationFD >= 0 else {
            throw SecureCaptureFileIOError.posix(operation: "create attachment", code: errno)
        }
        var completed = false
        defer {
            close(destinationFD)
            if !completed {
                destination.filename.withCString { _ = unlinkat(destinationParentFD, $0, 0) }
            }
        }

        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(sourceFD, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw SecureCaptureFileIOError.posix(operation: "read attachment", code: errno)
            }
            try buffer.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < count {
                    let written = Darwin.write(destinationFD, base.advanced(by: offset), count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw SecureCaptureFileIOError.posix(operation: "write attachment", code: errno)
                    }
                    offset += written
                }
            }
        }
        guard fsync(destinationFD) == 0 else {
            throw SecureCaptureFileIOError.posix(operation: "fsync attachment", code: errno)
        }
        completed = true
    }

    static func contentsEqual(
        firstRelativePath: String,
        firstRootURL: URL,
        secondRelativePath: String,
        secondRootURL: URL
    ) throws -> Bool {
        guard let firstFD = try openFileForReading(relativePath: firstRelativePath, rootURL: firstRootURL) else {
            return false
        }
        defer { close(firstFD) }
        guard let secondFD = try openFileForReading(relativePath: secondRelativePath, rootURL: secondRootURL) else {
            return false
        }
        defer { close(secondFD) }
        var firstBuffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var secondBuffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let firstCount = retryingRead(fd: firstFD, buffer: &firstBuffer)
            let secondCount = retryingRead(fd: secondFD, buffer: &secondBuffer)
            if firstCount < 0 || secondCount < 0 {
                throw SecureCaptureFileIOError.posix(operation: "compare attachments", code: errno)
            }
            if firstCount != secondCount { return false }
            if firstCount == 0 { return true }
            if firstBuffer.prefix(Int(firstCount)) != secondBuffer.prefix(Int(secondCount)) { return false }
        }
    }

    static func removeIfContentsEqual(
        sourceRelativePath: String,
        sourceRootURL: URL,
        destinationRelativePath: String,
        destinationRootURL: URL
    ) throws {
        guard try contentsEqual(
            firstRelativePath: sourceRelativePath,
            firstRootURL: sourceRootURL,
            secondRelativePath: destinationRelativePath,
            secondRootURL: destinationRootURL
        ) else { return }
        let destination = try splitPath(destinationRelativePath)
        guard let parentFD = try openParent(
            components: destination.parentComponents,
            rootURL: destinationRootURL,
            createMissing: false
        ) else { return }
        defer { close(parentFD) }
        let result = destination.filename.withCString { unlinkat(parentFD, $0, 0) }
        if result != 0, errno != ENOENT {
            throw SecureCaptureFileIOError.posix(operation: "remove attachment", code: errno)
        }
    }

    private static func openFileForReading(relativePath: String, rootURL: URL) throws -> Int32? {
        let split = try splitPath(relativePath)
        guard let parentFD = try openParent(
            components: split.parentComponents,
            rootURL: rootURL,
            createMissing: false
        ) else { return nil }
        defer { close(parentFD) }
        let fd = split.filename.withCString {
            openat(parentFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else {
            throw SecureCaptureFileIOError.posix(operation: "open attachment", code: errno)
        }
        return fd
    }

    private static func retryingRead(fd: Int32, buffer: inout [UInt8]) -> Int {
        while true {
            let result = Darwin.read(fd, &buffer, buffer.count)
            if result < 0, errno == EINTR { continue }
            return result
        }
    }

    private static func splitPath(
        _ relativePath: String
    ) throws -> (parentComponents: [String], filename: String) {
        try CapturePathValidation.validateRelativePath(relativePath)
        let components = relativePath.split(separator: "/").map(String.init)
        guard let filename = components.last else {
            throw SecureCaptureFileIOError.invalidPath(relativePath)
        }
        return (Array(components.dropLast()), filename)
    }

    private static func openParent(
        components: [String],
        rootURL: URL,
        createMissing: Bool
    ) throws -> Int32? {
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        var currentFD = resolvedRoot.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard currentFD >= 0 else {
            throw SecureCaptureFileIOError.posix(operation: "open root", code: errno)
        }

        for component in components {
            var nextFD = component.withCString {
                openat(currentFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            if nextFD < 0, errno == ENOENT, createMissing {
                let createResult = component.withCString {
                    mkdirat(currentFD, $0, mode_t(S_IRWXU))
                }
                if createResult != 0, errno != EEXIST {
                    let code = errno
                    close(currentFD)
                    throw SecureCaptureFileIOError.posix(operation: "create directory", code: code)
                }
                nextFD = component.withCString {
                    openat(currentFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
            }
            guard nextFD >= 0 else {
                let code = errno
                close(currentFD)
                if code == ENOENT, !createMissing { return nil }
                throw SecureCaptureFileIOError.posix(operation: "open directory", code: code)
            }
            close(currentFD)
            currentFD = nextFD
        }
        return currentFD
    }

    private static func readAll(from fd: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw SecureCaptureFileIOError.posix(operation: "read", code: errno)
            }
            result.append(contentsOf: buffer.prefix(Int(count)))
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(fd, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw SecureCaptureFileIOError.posix(operation: "write", code: errno)
                }
                offset += count
            }
        }
    }
}
