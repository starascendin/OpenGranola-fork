import AVFoundation
import os

/// Writes mic audio buffers to a .caf file in ~/Documents/OpenGranola/recordings/.
/// The file is created lazily on the first write, using the buffer's native format.
actor AudioRecorder {
    private var file: AVAudioFile?
    private(set) var fileURL: URL?
    private let log = Logger(subsystem: "com.opengranola", category: "AudioRecorder")

    func write(_ buffer: AVAudioPCMBuffer) {
        // Lazily open the file on first buffer using its native format
        if file == nil {
            let url = makeURL()
            do {
                file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
                fileURL = url
                log.info("AudioRecorder: opened \(url.lastPathComponent)")
                diagLog("[RECORDER] opened \(url.path)")
            } catch {
                log.error("AudioRecorder: failed to open file: \(error.localizedDescription)")
                diagLog("[RECORDER] error opening file: \(error.localizedDescription)")
                return
            }
        }
        do {
            try file?.write(from: buffer)
        } catch {
            log.error("AudioRecorder: write error: \(error.localizedDescription)")
        }
    }

    /// Closes the file and returns its URL.
    func stop() -> URL? {
        file = nil   // AVAudioFile closes on deinit
        let url = fileURL
        fileURL = nil
        if let url { diagLog("[RECORDER] closed \(url.path)") }
        return url
    }

    private func makeURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("OpenGranola/recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return dir.appendingPathComponent("session_\(formatter.string(from: Date())).caf")
    }
}
