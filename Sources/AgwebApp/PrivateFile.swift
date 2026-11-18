import Foundation

/// Written to a sibling created 0600 (never readable by others, not even for a moment), then renamed over `file`.
func writePrivately(_ data: Data, to file: URL) -> Bool {
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporary = file.path + ".new"
    unlink(temporary)
    let fd = open(temporary, O_CREAT | O_EXCL | O_WRONLY, 0o600)
    guard fd >= 0 else { return false }
    let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    guard close(fd) == 0, written == data.count else { unlink(temporary); return false }
    return rename(temporary, file.path) == 0
}
