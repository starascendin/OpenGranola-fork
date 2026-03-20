import XCTest
@testable import OpenOatsKit

final class TranscriptionBackendTests: XCTestCase {

    // MARK: - RemoteWhisperBackend

    func testGroqBackendDisplayName() {
        let backend = TranscriptionModel.groq.makeBackend(groqApiKey: "test-groq")
        XCTAssertEqual(backend.displayName, "Groq (Whisper Large v3)")
    }

    func testZaiBackendDisplayName() {
        let backend = TranscriptionModel.zai.makeBackend(zaiApiKey: "test-zai")
        XCTAssertEqual(backend.displayName, "ZhipuAI / ZAI")
    }

    func testRemoteBackendCheckStatusIsReady() {
        let groq = TranscriptionModel.groq.makeBackend(groqApiKey: "test-groq")
        let zai = TranscriptionModel.zai.makeBackend(zaiApiKey: "test-zai")
        XCTAssertEqual(groq.checkStatus(), .ready)
        XCTAssertEqual(zai.checkStatus(), .ready)
    }

    func testRemoteBackendPrepareWithoutCredentialsThrows() async {
        let backend = TranscriptionModel.groq.makeBackend()
        do {
            try await backend.prepare { _ in }
            XCTFail("Expected missing-credentials error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Missing API key"))
        }
    }

    func testRemoteBackendPrepareEmitsConnectionStatus() async throws {
        let backend = TranscriptionModel.zai.makeBackend(zaiApiKey: "test-zai")
        let collector = StatusCollector()
        try await backend.prepare { status in
            collector.append(status)
        }
        XCTAssertEqual(collector.statuses, ["Connecting to ZhipuAI / ZAI..."])
    }

    // MARK: - Mock Backend (protocol contract)

    func testMockBackendPrepareSetStatus() async throws {
        let mock = MockTranscriptionBackend()
        let collector = StatusCollector()
        try await mock.prepare { status in
            collector.append(status)
        }
        XCTAssertEqual(collector.statuses, ["Preparing Mock..."])
    }

    func testMockBackendTranscribeAfterPrepare() async throws {
        let mock = MockTranscriptionBackend()
        try await mock.prepare { _ in }
        let text = try await mock.transcribe([1.0, 2.0, 3.0], locale: Locale(identifier: "en-US"))
        XCTAssertEqual(text, "mock transcription")
    }

    func testMockBackendTranscribeWithoutPrepareThrows() async {
        let mock = MockTranscriptionBackend()
        do {
            _ = try await mock.transcribe([1.0], locale: Locale(identifier: "en-US"))
            XCTFail("Expected error")
        } catch is TranscriptionBackendError {
            // Expected: notPrepared
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMockBackendCheckStatus() {
        let mock = MockTranscriptionBackend()
        XCTAssertEqual(mock.checkStatus(), .ready)
    }

    // MARK: - BackendStatus

    func testBackendStatusEquality() {
        XCTAssertEqual(BackendStatus.ready, BackendStatus.ready)
        XCTAssertNotEqual(BackendStatus.ready, BackendStatus.needsDownload(prompt: "test"))
        XCTAssertEqual(
            BackendStatus.needsDownload(prompt: "a"),
            BackendStatus.needsDownload(prompt: "a")
        )
    }
}

// MARK: - Test Helpers

private final class StatusCollector: @unchecked Sendable {
    var statuses: [String] = []
    func append(_ status: String) { statuses.append(status) }
}

// MARK: - Mock Backend

private final class MockTranscriptionBackend: TranscriptionBackend, @unchecked Sendable {
    let displayName = "Mock"
    private var prepared = false

    func checkStatus() -> BackendStatus { .ready }

    func prepare(onStatus: @Sendable (String) -> Void) async throws {
        onStatus("Preparing Mock...")
        prepared = true
    }

    func transcribe(_ samples: [Float], locale: Locale) async throws -> String {
        guard prepared else { throw TranscriptionBackendError.notPrepared }
        return "mock transcription"
    }
}
