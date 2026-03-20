import Foundation

/// Remote transcription backend for OpenAI-compatible Whisper-style APIs.
final class RemoteWhisperBackend: TranscriptionBackend, @unchecked Sendable {
    enum Provider {
        case groq(apiKey: String)
        case zai(apiKey: String)

        var displayName: String {
            switch self {
            case .groq:
                return "Groq (Whisper Large v3)"
            case .zai:
                return "ZhipuAI / ZAI"
            }
        }

        func makeClient(language: String) -> WhisperAPIClient {
            switch self {
            case .groq(let apiKey):
                return .groq(apiKey: apiKey, language: language)
            case .zai(let apiKey):
                return .zai(apiKey: apiKey, language: language)
            }
        }

        var hasCredentials: Bool {
            switch self {
            case .groq(let apiKey), .zai(let apiKey):
                return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    let displayName: String
    private let provider: Provider

    init(provider: Provider) {
        self.provider = provider
        self.displayName = provider.displayName
    }

    func checkStatus() -> BackendStatus {
        .ready
    }

    func prepare(onStatus: @Sendable (String) -> Void) async throws {
        guard provider.hasCredentials else {
            throw WhisperError.apiError(401, "Missing API key for \(displayName)")
        }
        onStatus("Connecting to \(displayName)...")
    }

    func transcribe(_ samples: [Float], locale: Locale) async throws -> String {
        let language = Self.normalizedLanguageCode(for: locale)
        return try await provider.makeClient(language: language).transcribe(samples)
    }

    private static func normalizedLanguageCode(for locale: Locale) -> String {
        let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
        return identifier.split(separator: "-").first.map { String($0).lowercased() } ?? ""
    }
}
