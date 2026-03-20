import XCTest
@testable import OpenOatsKit

@MainActor
final class AppSettingsTests: XCTestCase {

    // MARK: - LLMProvider

    func testLLMProviderAllCases() {
        let cases = LLMProvider.allCases
        XCTAssertEqual(cases.count, 3)
        XCTAssertTrue(cases.contains(.openRouter))
        XCTAssertTrue(cases.contains(.ollama))
        XCTAssertTrue(cases.contains(.mlx))
    }

    func testLLMProviderDisplayNames() {
        XCTAssertEqual(LLMProvider.openRouter.displayName, "OpenRouter")
        XCTAssertEqual(LLMProvider.ollama.displayName, "Ollama")
        XCTAssertEqual(LLMProvider.mlx.displayName, "MLX")
    }

    func testLLMProviderRawValues() {
        XCTAssertEqual(LLMProvider.openRouter.rawValue, "openRouter")
        XCTAssertEqual(LLMProvider.ollama.rawValue, "ollama")
        XCTAssertEqual(LLMProvider.mlx.rawValue, "mlx")
    }

    func testLLMProviderIdentifiable() {
        XCTAssertEqual(LLMProvider.openRouter.id, "openRouter")
        XCTAssertEqual(LLMProvider.ollama.id, "ollama")
    }

    func testLLMProviderRoundTripFromRawValue() {
        for provider in LLMProvider.allCases {
            let restored = LLMProvider(rawValue: provider.rawValue)
            XCTAssertEqual(restored, provider)
        }
    }

    // MARK: - TranscriptionModel

    func testTranscriptionModelAllCases() {
        let cases = TranscriptionModel.allCases
        XCTAssertEqual(cases.count, 2)
        XCTAssertEqual(cases, [.groq, .zai])
    }

    func testTranscriptionModelDisplayNames() {
        XCTAssertEqual(TranscriptionModel.groq.displayName, "Groq (Whisper Large v3)")
        XCTAssertEqual(TranscriptionModel.zai.displayName, "ZhipuAI / ZAI")
    }

    func testTranscriptionModelRoundTripFromRawValue() {
        for model in TranscriptionModel.allCases {
            let restored = TranscriptionModel(rawValue: model.rawValue)
            XCTAssertEqual(restored, model)
        }
    }

    func testTranscriptionModelSupportsExplicitLanguageHint() {
        XCTAssertTrue(TranscriptionModel.groq.supportsExplicitLanguageHint)
        XCTAssertTrue(TranscriptionModel.zai.supportsExplicitLanguageHint)
    }

    func testTranscriptionModelDownloadPromptEmpty() {
        for model in TranscriptionModel.allCases {
            XCTAssertTrue(model.downloadPrompt.isEmpty)
        }
    }

    func testTranscriptionModelLocaleFieldTitle() {
        XCTAssertEqual(TranscriptionModel.groq.localeFieldTitle, "Language")
        XCTAssertEqual(TranscriptionModel.zai.localeFieldTitle, "Language")
    }

    // MARK: - AppSettings Defaults

    func testAppSettingsDefaultTranscriptionLocale() {
        let settings = AppSettings()
        XCTAssertEqual(settings.transcriptionLocale, "zh")
    }

    func testAppSettingsLocaleProperty() {
        let settings = AppSettings()
        let locale = settings.locale
        XCTAssertFalse(locale.identifier.isEmpty)
    }

    func testAppSettingsDefaultsToGroq() {
        let settings = AppSettings()
        XCTAssertEqual(settings.transcriptionModel, .groq)
    }

    func testAppSettingsNotesFolderPathIsConfigured() {
        let settings = AppSettings()
        XCTAssertFalse(settings.notesFolderPath.isEmpty)
    }
}
