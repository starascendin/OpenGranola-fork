import AppKit
import Foundation
import Observation
import Security
import CoreAudio

// MARK: - Transcription provider

enum TranscriptionProvider: String, CaseIterable {
    case local = "local"
    case groq  = "groq"
    case zai   = "zai"

    var displayName: String {
        switch self {
        case .local: return "Local (Parakeet-TDT v2)"
        case .groq:  return "Groq — Whisper large-v3"
        case .zai:   return "ZhipuAI — GLM-ASR-2512"
        }
    }

    /// Whether this provider uses a remote API (requires an API key).
    var isRemote: Bool { self != .local }
}

@Observable
@MainActor
final class AppSettings {
    var kbFolderPath: String {
        didSet { UserDefaults.standard.set(kbFolderPath, forKey: "kbFolderPath") }
    }

    var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "selectedModel") }
    }

    /// Stored as raw string in UserDefaults.
    var transcriptionProvider: TranscriptionProvider {
        didSet { UserDefaults.standard.set(transcriptionProvider.rawValue, forKey: "transcriptionProvider") }
    }

    /// ISO 639-1 language code for remote transcription, e.g. "zh" or "en". Empty = auto-detect.
    var transcriptionLanguage: String {
        didSet { UserDefaults.standard.set(transcriptionLanguage, forKey: "transcriptionLanguage") }
    }

    /// Stored as the AudioDeviceID integer. 0 means "use system default".
    var inputDeviceID: AudioDeviceID {
        didSet { UserDefaults.standard.set(Int(inputDeviceID), forKey: "inputDeviceID") }
    }

    var openRouterApiKey: String {
        didSet { KeychainHelper.save(key: "openRouterApiKey", value: openRouterApiKey) }
    }

    var voyageApiKey: String {
        didSet { KeychainHelper.save(key: "voyageApiKey", value: voyageApiKey) }
    }

    var groqApiKey: String {
        didSet { KeychainHelper.save(key: "groqApiKey", value: groqApiKey) }
    }

    var zaiApiKey: String {
        didSet { KeychainHelper.save(key: "zaiApiKey", value: zaiApiKey) }
    }

    var saveAudio: Bool {
        didSet { UserDefaults.standard.set(saveAudio, forKey: "saveAudio") }
    }

    /// When true, automatically start/stop recording when a meeting is detected.
    var autoDetectMeetings: Bool {
        didSet { UserDefaults.standard.set(autoDetectMeetings, forKey: "autoDetectMeetings") }
    }

    /// When true, all app windows are invisible to screen sharing / recording.
    var hideFromScreenShare: Bool {
        didSet {
            UserDefaults.standard.set(hideFromScreenShare, forKey: "hideFromScreenShare")
            applyScreenShareVisibility()
        }
    }

    init() {
        let defaults = UserDefaults.standard
        self.kbFolderPath = defaults.string(forKey: "kbFolderPath") ?? ""
        self.selectedModel = defaults.string(forKey: "selectedModel") ?? "anthropic/claude-sonnet-4"
        let providerRaw = defaults.string(forKey: "transcriptionProvider") ?? "groq"
        self.transcriptionProvider = TranscriptionProvider(rawValue: providerRaw) ?? .local
        self.transcriptionLanguage = defaults.string(forKey: "transcriptionLanguage") ?? ""
        self.inputDeviceID = AudioDeviceID(defaults.integer(forKey: "inputDeviceID"))
        self.saveAudio = defaults.bool(forKey: "saveAudio")
        self.autoDetectMeetings = defaults.object(forKey: "autoDetectMeetings") == nil
            ? true
            : defaults.bool(forKey: "autoDetectMeetings")
        self.openRouterApiKey = KeychainHelper.load(key: "openRouterApiKey") ?? ""
        self.voyageApiKey = KeychainHelper.load(key: "voyageApiKey") ?? ""
        self.groqApiKey = KeychainHelper.load(key: "groqApiKey") ?? ""
        self.zaiApiKey = KeychainHelper.load(key: "zaiApiKey") ?? ""
        // Default to true (hidden) if key has never been set
        if defaults.object(forKey: "hideFromScreenShare") == nil {
            self.hideFromScreenShare = true
        } else {
            self.hideFromScreenShare = defaults.bool(forKey: "hideFromScreenShare")
        }
    }

    /// Apply current screen-share visibility to all app windows.
    func applyScreenShareVisibility() {
        let type: NSWindow.SharingType = hideFromScreenShare ? .none : .readOnly
        for window in NSApp.windows {
            window.sharingType = type
        }
    }

    var kbFolderURL: URL? {
        guard !kbFolderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: kbFolderPath)
    }
}

// MARK: - Keychain Helper

enum KeychainHelper {
    private static let service = "com.opengranola.app"

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
