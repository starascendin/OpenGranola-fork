import Foundation

/// Auto-saves transcripts as plain text files to a configurable folder.
actor TranscriptLogger {
    private var directory: URL
    private var currentFile: URL?
    private var fileHandle: FileHandle?
    private var sessionHeader: String = ""

    init(directory: URL? = nil) {
        self.directory = directory ?? KortexOatsIdentity.defaultNotesDirectory()
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        Self.dropMetadataNeverIndex(in: self.directory)
    }

    func updateDirectory(_ url: URL) {
        self.directory = url
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        Self.dropMetadataNeverIndex(in: url)
    }

    /// Place a .metadata_never_index sentinel so Spotlight skips this directory.
    private static func dropMetadataNeverIndex(in directory: URL) {
        let sentinel = directory.appendingPathComponent(".metadata_never_index")
        if !FileManager.default.fileExists(atPath: sentinel.path) {
            FileManager.default.createFile(atPath: sentinel.path, contents: nil)
        }
    }

    func startSession() {
        let now = Date()
        let fileFmt = DateFormatter()
        fileFmt.dateFormat = "yyyy-MM-dd_HH-mm"
        let filename = "\(fileFmt.string(from: now)).txt"
        currentFile = directory.appendingPathComponent(filename)

        let headerFmt = DateFormatter()
        headerFmt.dateStyle = .medium
        headerFmt.timeStyle = .short
        sessionHeader = "\(KortexOatsIdentity.appDisplayName) - \(headerFmt.string(from: now))\n\n"

        FileManager.default.createFile(atPath: currentFile!.path, contents: sessionHeader.data(using: .utf8),
                                       attributes: [.posixPermissions: 0o600])
        fileHandle = try? FileHandle(forWritingTo: currentFile!)
        fileHandle?.seekToEndOfFile()
    }

    func append(speaker: String, text: String, timestamp: Date, refinedText: String? = nil) {
        guard let fileHandle else { return }
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"
        let displayText = refinedText ?? text
        let line = "[\(timeFmt.string(from: timestamp))] \(speaker): \(displayText)\n"
        if let data = line.data(using: .utf8) {
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
        }
    }

    func endSession() {
        try? fileHandle?.close()
        fileHandle = nil
        currentFile = nil
    }
}
