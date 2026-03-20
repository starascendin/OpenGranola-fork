@preconcurrency import AVFoundation
import Foundation
import os

/// Saves raw microphone audio to a `.caf` file for each session.
/// This preserves the fork customization while fitting the upstream recorder lifecycle.
final class AudioRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let log = Logger(subsystem: "com.openoats", category: "AudioRecorder")

    private var file: AVAudioFile?
    private var fileURL: URL?
    private var outputDirectory: URL
    private var sessionTimestamp = ""

    init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
    }

    func updateDirectory(_ url: URL) {
        lock.withLock {
            outputDirectory = url
        }
    }

    func startSession() {
        lock.withLock {
            file = nil
            fileURL = nil

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            sessionTimestamp = formatter.string(from: Date())
        }
    }

    func writeMicBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard buffer.frameLength > 0 else { return }

            if file == nil {
                let url = makeURL()
                do {
                    file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
                    fileURL = url
                    log.info("AudioRecorder opened \(url.lastPathComponent)")
                    diagLog("[RECORDER] opened raw mic recording \(url.path)")
                } catch {
                    log.error("AudioRecorder failed to open file: \(error.localizedDescription)")
                    diagLog("[RECORDER] failed to open raw mic recording: \(error.localizedDescription)")
                    return
                }
            }

            do {
                try file?.write(from: buffer)
            } catch {
                log.error("AudioRecorder write error: \(error.localizedDescription)")
                diagLog("[RECORDER] write error: \(error.localizedDescription)")
            }
        }
    }

    /// Raw-recording mode does not currently persist system audio separately.
    func writeSysBuffer(_ buffer: AVAudioPCMBuffer) {
        _ = buffer
    }

    func finalizeRecording() async {
        lock.withLock {
            file = nil
            if let fileURL {
                diagLog("[RECORDER] finalized raw mic recording \(fileURL.path)")
            }
            fileURL = nil
        }
    }

    private func makeURL() -> URL {
        let recordingsDirectory = outputDirectory.appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        return recordingsDirectory.appendingPathComponent("session_\(sessionTimestamp).caf")
    }
}
