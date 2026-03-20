import Foundation
import os

/// Sends buffered speech segments to an OpenAI-compatible Whisper transcription API.
struct WhisperAPIClient: Sendable {
    let endpoint: URL
    let model: String
    let apiKey: String
    /// ISO 639-1 language code, e.g. "zh" for Mandarin, "" for auto-detect.
    let language: String

    private let log = Logger(subsystem: "com.openoats", category: "WhisperAPI")

    // MARK: - Factory methods

    static func groq(apiKey: String, language: String = "") -> WhisperAPIClient {
        WhisperAPIClient(
            endpoint: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!,
            model: "whisper-large-v3",
            apiKey: apiKey,
            language: language
        )
    }

    /// ZhipuAI (bigmodel.cn) — uses SenseVoice-Small, optimised for Chinese.
    static func zai(apiKey: String, language: String = "") -> WhisperAPIClient {
        WhisperAPIClient(
            endpoint: URL(string: "https://open.bigmodel.cn/api/paas/v4/audio/transcriptions")!,
            model: "glm-asr-2512",
            apiKey: apiKey,
            language: language
        )
    }

    // MARK: - Transcription

    /// Transcribe Float32 samples (16 kHz, mono) using the remote API.
    func transcribe(_ samples: [Float]) async throws -> String {
        let wavData = makeWAV(samples: samples)
        let boundary = "OGBoundary\(UUID().uuidString.filter { $0.isHexDigit })"

        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = buildBody(wavData: wavData, boundary: boundary)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else { throw WhisperError.invalidResponse }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "(no body)"
            log.error("Whisper API \(http.statusCode): \(msg)")
            throw WhisperError.apiError(http.statusCode, msg)
        }

        struct Response: Decodable { let text: String }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Multipart body builder

    private func buildBody(wavData: Data, boundary: String) -> Data {
        var body = Data()
        body.addFilePart(name: "file", filename: "audio.wav", mime: "audio/wav",
                         data: wavData, boundary: boundary)
        body.addTextField(name: "model", value: model, boundary: boundary)
        if !language.isEmpty {
            body.addTextField(name: "language", value: language, boundary: boundary)
        }
        body.addTextField(name: "response_format", value: "json", boundary: boundary)
        body.appendUTF8("--\(boundary)--\r\n")
        return body
    }

    // MARK: - WAV encoding

    /// Encode as 16-bit PCM WAV at 16 kHz, mono.
    private func makeWAV(samples: [Float]) -> Data {
        let sampleRate: UInt32 = 16_000
        let numCh: UInt16    = 1
        let bps: UInt16      = 16
        let byteRate         = sampleRate * UInt32(numCh) * UInt32(bps) / 8
        let blockAlign       = numCh * bps / 8
        let dataLen          = UInt32(samples.count) * UInt32(blockAlign)

        var d = Data(capacity: 44 + Int(dataLen))
        d.appendUTF8("RIFF");  d.appendLE(36 + dataLen); d.appendUTF8("WAVE")
        d.appendUTF8("fmt ");  d.appendLE(UInt32(16)); d.appendLE(UInt16(1))
        d.appendLE(numCh); d.appendLE(sampleRate); d.appendLE(byteRate)
        d.appendLE(blockAlign); d.appendLE(bps)
        d.appendUTF8("data");  d.appendLE(dataLen)
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            d.appendLE(UInt16(bitPattern: Int16(clamped * Float(Int16.max))))
        }
        return d
    }
}

// MARK: - Error

enum WhisperError: Error, LocalizedError {
    case invalidResponse
    case apiError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:         return "Invalid response from transcription API"
        case .apiError(let code, let msg): return "Transcription API \(code): \(msg)"
        }
    }
}

// MARK: - Data helpers (file-private)

private extension Data {
    mutating func appendUTF8(_ s: String) {
        append(contentsOf: s.utf8)
    }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { self.append(contentsOf: $0) }
    }

    mutating func addTextField(name: String, value: String, boundary: String) {
        appendUTF8("--\(boundary)\r\n")
        appendUTF8("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendUTF8(value)
        appendUTF8("\r\n")
    }

    mutating func addFilePart(name: String, filename: String, mime: String,
                              data fileData: Data, boundary: String) {
        appendUTF8("--\(boundary)\r\n")
        appendUTF8("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        appendUTF8("Content-Type: \(mime)\r\n\r\n")
        append(fileData)
        appendUTF8("\r\n")
    }
}
