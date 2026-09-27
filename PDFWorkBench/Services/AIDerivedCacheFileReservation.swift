import Darwin
import Foundation

nonisolated enum AIDerivedCacheFileReservationError: Error {
    case unsafeExistingPath
}

/// Reserves a previously absent cache file without following the final path
/// component. Callers may initialize an unclaimed SQLite header only when this
/// returns `true`; every pre-existing file must already carry the caller's
/// complete database identity before any persistent mutation is allowed.
nonisolated enum AIDerivedCacheFileReservation {
    struct Reservation: Sendable {
        let url: URL
        let createdHere: Bool
        private let device: dev_t?
        private let inode: ino_t?

        fileprivate init(url: URL, createdHere: Bool, information: stat?) {
            self.url = url
            self.createdHere = createdHere
            self.device = information?.st_dev
            self.inode = information?.st_ino
        }

        func removeIfStillOwned() {
            guard createdHere, let device, let inode else { return }
            var current = stat()
            guard url.path.withCString({ lstat($0, &current) }) == 0,
                  (current.st_mode & S_IFMT) == S_IFREG,
                  current.st_dev == device,
                  current.st_ino == inode
            else { return }
            _ = url.path.withCString { Darwin.unlink($0) }
        }
    }

    static func reserveIfAbsent(_ url: URL) throws -> Reservation {
        var information = stat()
        let existing = url.path.withCString { lstat($0, &information) }
        if existing == 0 {
            guard (information.st_mode & S_IFMT) == S_IFREG else {
                throw AIDerivedCacheFileReservationError.unsafeExistingPath
            }
            return Reservation(url: url, createdHere: false, information: nil)
        }
        guard errno == ENOENT else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        let descriptor = url.path.withCString { path in
            Darwin.open(
                path,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        if descriptor >= 0 {
            var reservedInformation = stat()
            guard fstat(descriptor, &reservedInformation) == 0,
                  (reservedInformation.st_mode & S_IFMT) == S_IFREG else {
                let savedError = errno
                _ = Darwin.close(descriptor)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(savedError))
            }
            let reservation = Reservation(
                url: url,
                createdHere: true,
                information: reservedInformation
            )
            if Darwin.close(descriptor) != 0 {
                let savedError = errno
                reservation.removeIfStillOwned()
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(savedError))
            }
            return reservation
        }
        guard errno == EEXIST else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        // Another process won the exclusive create. Treat it as unknown
        // existing state; validate only its file type here and let the SQLite
        // caller require a complete Dogear identity before writing anything.
        guard url.path.withCString({ lstat($0, &information) }) == 0,
              (information.st_mode & S_IFMT) == S_IFREG else {
            throw AIDerivedCacheFileReservationError.unsafeExistingPath
        }
        return Reservation(url: url, createdHere: false, information: nil)
    }

    static func requireAbsent(paths: [String]) throws {
        for path in paths {
            var information = stat()
            if path.withCString({ lstat($0, &information) }) == 0 || errno != ENOENT {
                throw AIDerivedCacheFileReservationError.unsafeExistingPath
            }
        }
    }
}
