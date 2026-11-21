#if AGWEB_COMMAND_LOG
import AgwebCore
import Foundation

/// <root>/logs/commands.jsonl, renamed to commands.1.jsonl at 10 MB.
@MainActor
enum CommandLogFile {
    private static let folder = Agweb.logsFolder
    private static let file = folder.appendingPathComponent("commands.jsonl")

    static func append(_ request: Request, _ response: Response, started: Date) {
        let line = CommandLog.line(request, ok: response.ok, output: response.output, at: started, seconds: Date().timeIntervalSince(started)) + "\n"
        // The end offset is the size: no stat per command, which showed in the main thread's profile under load.
        guard var handle = open(), let size = try? handle.seekToEnd() else { return }
        if size > 10_000_000 {
            try? handle.close()
            let fm = FileManager.default
            let old = folder.appendingPathComponent("commands.1.jsonl")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: file, to: old)
            // At the end: if the rename failed this is the same full file, whose start must not be written over.
            guard let fresh = open() else { return }
            _ = try? fresh.seekToEnd()
            handle = fresh
        }
        defer { try? handle.close() }
        try? handle.write(contentsOf: Data(line.utf8))
    }

    /// The log for appending, created 0600 when missing; one that exists but won't open is left alone, not replaced.
    private static func open() -> FileHandle? {
        if let handle = try? FileHandle(forWritingTo: file) { return handle }
        guard !FileManager.default.fileExists(atPath: file.path) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        return try? FileHandle(forWritingTo: file)
    }
}
#endif
