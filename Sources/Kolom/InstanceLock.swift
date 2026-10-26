import Foundation

/// One process at a time may own Kolom's recovery records and move windows:
/// the running app, or its watchdog after the app has exited. The lock is an
/// flock on a file in Kolom's storage folder and is released when the owning
/// process exits, including after a crash.
final class InstanceLock {
    private var descriptor: Int32 = -1
    let url: URL
    init(storage: URL) { url = storage.appendingPathComponent("instance.lock") }
    var held: Bool { descriptor >= 0 }
    enum Result { case acquired, busy, unavailable }
    /// Try to take the lock, polling until `timeout` elapses. `busy` means
    /// another process holds it; `unavailable` means the lock file itself could
    /// not be used (permissions, symlink, full disk), which callers must not
    /// mistake for another owner.
    @discardableResult func acquire(timeout: TimeInterval = 0) -> Result {
        if held { return .acquired }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .unavailable }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                descriptor = fd
                return .acquired
            }
            guard errno == EWOULDBLOCK else {
                close(fd)
                return .unavailable
            }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.1)
        } while true
        close(fd)
        return .busy
    }
    func release() {
        guard held else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
    deinit { release() }
}
