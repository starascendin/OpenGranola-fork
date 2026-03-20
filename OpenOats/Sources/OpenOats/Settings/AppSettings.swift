import AppKit
import Foundation
import Observation
import Security
import CoreAudio

enum LLMProvider: String, CaseIterable, Identifiable {
    case openRouter
    case ollama
    case mlx

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .ollama: "Ollama"
        case .mlx: "MLX"
        }
    }
}

enum TranscriptionModel: String, CaseIterable, Identifiable {
    case groq
    case zai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .groq: "Groq (Whisper Large v3)"
        case .zai: "ZhipuAI / ZAI"
        }
    }

    var downloadPrompt: String {
        ""
    }

    var supportsExplicitLanguageHint: Bool {
        true
    }

    var localeFieldTitle: String {
        "Language"
    }

    var localeHelpText: String {
        switch self {
        case .groq:
            "Optional. Language code for Whisper (e.g. en, zh, fr). Leave empty for auto-detection."
        case .zai:
            "Optional. Language code (e.g. en, zh, ja). Optimized for Chinese. Leave empty for auto-detection."
        }
    }

    func makeBackend(
        customVocabulary: String = "",
        groqApiKey: String = "",
        zaiApiKey: String = ""
    ) -> any TranscriptionBackend {
        switch self {
        case .groq: return RemoteWhisperBackend(provider: .groq(apiKey: groqApiKey))
        case .zai: return RemoteWhisperBackend(provider: .zai(apiKey: zaiApiKey))
        }
    }
}

struct AppSecretStore: Sendable {
    let loadValue: @Sendable (String) -> String?
    let saveValue: @Sendable (String, String) -> Void

    func load(key: String) -> String? {
        loadValue(key)
    }

    func save(key: String, value: String) {
        saveValue(key, value)
    }

    static let keychain = AppSecretStore(
        loadValue: { KeychainHelper.load(key: $0) },
        saveValue: { key, value in
            KeychainHelper.save(key: key, value: value)
        }
    )

    static let ephemeral = AppSecretStore(
        loadValue: { _ in nil },
        saveValue: { _, _ in }
    )
}

struct AppSettingsStorage {
    let defaults: UserDefaults
    let secretStore: AppSecretStore
    let defaultNotesDirectory: URL
    let runMigrations: Bool

    static func live(defaults: UserDefaults = .standard) -> AppSettingsStorage {
        AppSettingsStorage(
            defaults: defaults,
            secretStore: .keychain,
            defaultNotesDirectory: KortexOatsIdentity.defaultNotesDirectory(),
            runMigrations: true
        )
    }
}

@Observable
@MainActor
final class AppSettings {
    private let defaults: UserDefaults
    private let secretStore: AppSecretStore

    // SwiftUI can evaluate view bodies outside a MainActor executor context in
    // Swift 6.2. Use nonisolated backing storage plus manual observation
    // tracking so bound settings remain safe to read during those updates.
    @ObservationIgnored nonisolated(unsafe) private var _notesFolderPath: String
    var notesFolderPath: String {
        get { access(keyPath: \.notesFolderPath); return _notesFolderPath }
        set {
            withMutation(keyPath: \.notesFolderPath) {
                _notesFolderPath = newValue
                defaults.set(newValue, forKey: "notesFolderPath")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _selectedModel: String
    var selectedModel: String {
        get { access(keyPath: \.selectedModel); return _selectedModel }
        set {
            withMutation(keyPath: \.selectedModel) {
                _selectedModel = newValue
                defaults.set(newValue, forKey: "selectedModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _transcriptionLocale: String
    var transcriptionLocale: String {
        get { access(keyPath: \.transcriptionLocale); return _transcriptionLocale }
        set {
            withMutation(keyPath: \.transcriptionLocale) {
                _transcriptionLocale = newValue
                defaults.set(newValue, forKey: "transcriptionLocale")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _transcriptionCustomVocabulary: String
    var transcriptionCustomVocabulary: String {
        get { access(keyPath: \.transcriptionCustomVocabulary); return _transcriptionCustomVocabulary }
        set {
            withMutation(keyPath: \.transcriptionCustomVocabulary) {
                _transcriptionCustomVocabulary = newValue
                defaults.set(newValue, forKey: "transcriptionCustomVocabulary")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _transcriptionModel: TranscriptionModel
    var transcriptionModel: TranscriptionModel {
        get { access(keyPath: \.transcriptionModel); return _transcriptionModel }
        set {
            withMutation(keyPath: \.transcriptionModel) {
                _transcriptionModel = newValue
                defaults.set(newValue.rawValue, forKey: "transcriptionModel")
            }
        }
    }

    /// Stored as the AudioDeviceID integer. 0 means "use system default".
    @ObservationIgnored nonisolated(unsafe) private var _inputDeviceID: AudioDeviceID
    var inputDeviceID: AudioDeviceID {
        get { access(keyPath: \.inputDeviceID); return _inputDeviceID }
        set {
            withMutation(keyPath: \.inputDeviceID) {
                _inputDeviceID = newValue
                defaults.set(Int(newValue), forKey: "inputDeviceID")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _openRouterApiKey: String
    var openRouterApiKey: String {
        get { access(keyPath: \.openRouterApiKey); return _openRouterApiKey }
        set {
            withMutation(keyPath: \.openRouterApiKey) {
                _openRouterApiKey = newValue
                secretStore.save(key: "openRouterApiKey", value: newValue)
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _groqApiKey: String
    var groqApiKey: String {
        get { access(keyPath: \.groqApiKey); return _groqApiKey }
        set {
            withMutation(keyPath: \.groqApiKey) {
                _groqApiKey = newValue
                secretStore.save(key: "groqApiKey", value: newValue)
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _zaiApiKey: String
    var zaiApiKey: String {
        get { access(keyPath: \.zaiApiKey); return _zaiApiKey }
        set {
            withMutation(keyPath: \.zaiApiKey) {
                _zaiApiKey = newValue
                secretStore.save(key: "zaiApiKey", value: newValue)
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _llmProvider: LLMProvider
    var llmProvider: LLMProvider {
        get { access(keyPath: \.llmProvider); return _llmProvider }
        set {
            withMutation(keyPath: \.llmProvider) {
                _llmProvider = newValue
                defaults.set(newValue.rawValue, forKey: "llmProvider")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _ollamaBaseURL: String
    var ollamaBaseURL: String {
        get { access(keyPath: \.ollamaBaseURL); return _ollamaBaseURL }
        set {
            withMutation(keyPath: \.ollamaBaseURL) {
                _ollamaBaseURL = newValue
                defaults.set(newValue, forKey: "ollamaBaseURL")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _ollamaLLMModel: String
    var ollamaLLMModel: String {
        get { access(keyPath: \.ollamaLLMModel); return _ollamaLLMModel }
        set {
            withMutation(keyPath: \.ollamaLLMModel) {
                _ollamaLLMModel = newValue
                defaults.set(newValue, forKey: "ollamaLLMModel")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _mlxBaseURL: String
    var mlxBaseURL: String {
        get { access(keyPath: \.mlxBaseURL); return _mlxBaseURL }
        set {
            withMutation(keyPath: \.mlxBaseURL) {
                _mlxBaseURL = newValue
                defaults.set(newValue, forKey: "mlxBaseURL")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _mlxModel: String
    var mlxModel: String {
        get { access(keyPath: \.mlxModel); return _mlxModel }
        set {
            withMutation(keyPath: \.mlxModel) {
                _mlxModel = newValue
                defaults.set(newValue, forKey: "mlxModel")
            }
        }
    }

    /// Whether the user has acknowledged their obligation to comply with recording consent laws.
    @ObservationIgnored nonisolated(unsafe) private var _hasAcknowledgedRecordingConsent: Bool
    var hasAcknowledgedRecordingConsent: Bool {
        get { access(keyPath: \.hasAcknowledgedRecordingConsent); return _hasAcknowledgedRecordingConsent }
        set {
            withMutation(keyPath: \.hasAcknowledgedRecordingConsent) {
                _hasAcknowledgedRecordingConsent = newValue
                defaults.set(newValue, forKey: "hasAcknowledgedRecordingConsent")
            }
        }
    }

    /// When false, the live transcript panel is hidden during recording to save resources.
    @ObservationIgnored nonisolated(unsafe) private var _showLiveTranscript: Bool
    var showLiveTranscript: Bool {
        get { access(keyPath: \.showLiveTranscript); return _showLiveTranscript }
        set {
            withMutation(keyPath: \.showLiveTranscript) {
                _showLiveTranscript = newValue
                defaults.set(newValue, forKey: "showLiveTranscript")
            }
        }
    }

    /// When true, a local .m4a audio file is saved alongside each transcript.
    @ObservationIgnored nonisolated(unsafe) private var _saveAudioRecording: Bool
    var saveAudioRecording: Bool {
        get { access(keyPath: \.saveAudioRecording); return _saveAudioRecording }
        set {
            withMutation(keyPath: \.saveAudioRecording) {
                _saveAudioRecording = newValue
                defaults.set(newValue, forKey: "saveAudioRecording")
            }
        }
    }

    /// When true, all app windows are invisible to screen sharing / recording.
    @ObservationIgnored nonisolated(unsafe) private var _hideFromScreenShare: Bool
    var hideFromScreenShare: Bool {
        get { access(keyPath: \.hideFromScreenShare); return _hideFromScreenShare }
        set {
            withMutation(keyPath: \.hideFromScreenShare) {
                _hideFromScreenShare = newValue
                defaults.set(newValue, forKey: "hideFromScreenShare")
                applyScreenShareVisibility()
            }
        }
    }

    // MARK: - Meeting Detection

    /// Whether automatic meeting detection is enabled.
    @ObservationIgnored nonisolated(unsafe) private var _meetingAutoDetectEnabled: Bool
    var meetingAutoDetectEnabled: Bool {
        get { access(keyPath: \.meetingAutoDetectEnabled); return _meetingAutoDetectEnabled }
        set {
            withMutation(keyPath: \.meetingAutoDetectEnabled) {
                _meetingAutoDetectEnabled = newValue
                defaults.set(newValue, forKey: "meetingAutoDetectEnabled")
            }
        }
    }

    /// Whether the explanation sheet for auto-detect has been shown.
    @ObservationIgnored nonisolated(unsafe) private var _hasShownAutoDetectExplanation: Bool
    var hasShownAutoDetectExplanation: Bool {
        get { access(keyPath: \.hasShownAutoDetectExplanation); return _hasShownAutoDetectExplanation }
        set {
            withMutation(keyPath: \.hasShownAutoDetectExplanation) {
                _hasShownAutoDetectExplanation = newValue
                defaults.set(newValue, forKey: "hasShownAutoDetectExplanation")
            }
        }
    }

    /// Whether the user has seen the suggestion to enable Launch at Login.
    @ObservationIgnored nonisolated(unsafe) private var _hasSeenLaunchAtLoginSuggestion: Bool
    var hasSeenLaunchAtLoginSuggestion: Bool {
        get { access(keyPath: \.hasSeenLaunchAtLoginSuggestion); return _hasSeenLaunchAtLoginSuggestion }
        set {
            withMutation(keyPath: \.hasSeenLaunchAtLoginSuggestion) {
                _hasSeenLaunchAtLoginSuggestion = newValue
                defaults.set(newValue, forKey: "hasSeenLaunchAtLoginSuggestion")
            }
        }
    }

    /// Minutes of mic silence before auto-stopping a detected session.
    @ObservationIgnored nonisolated(unsafe) private var _silenceTimeoutMinutes: Int
    var silenceTimeoutMinutes: Int {
        get { access(keyPath: \.silenceTimeoutMinutes); return _silenceTimeoutMinutes }
        set {
            withMutation(keyPath: \.silenceTimeoutMinutes) {
                _silenceTimeoutMinutes = newValue
                defaults.set(newValue, forKey: "silenceTimeoutMinutes")
            }
        }
    }

    /// User-added meeting app bundle IDs beyond the built-in list.
    @ObservationIgnored nonisolated(unsafe) private var _customMeetingAppBundleIDs: [String]
    var customMeetingAppBundleIDs: [String] {
        get { access(keyPath: \.customMeetingAppBundleIDs); return _customMeetingAppBundleIDs }
        set {
            withMutation(keyPath: \.customMeetingAppBundleIDs) {
                _customMeetingAppBundleIDs = newValue
                defaults.set(newValue, forKey: "customMeetingAppBundleIDs")
            }
        }
    }

    /// When true, detection events are logged to the console.
    @ObservationIgnored nonisolated(unsafe) private var _detectionLogEnabled: Bool
    var detectionLogEnabled: Bool {
        get { access(keyPath: \.detectionLogEnabled); return _detectionLogEnabled }
        set {
            withMutation(keyPath: \.detectionLogEnabled) {
                _detectionLogEnabled = newValue
                defaults.set(newValue, forKey: "detectionLogEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _kortexSyncEnabled: Bool
    var kortexSyncEnabled: Bool {
        get { access(keyPath: \.kortexSyncEnabled); return _kortexSyncEnabled }
        set {
            withMutation(keyPath: \.kortexSyncEnabled) {
                _kortexSyncEnabled = newValue
                defaults.set(newValue, forKey: "kortexSyncEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _kortexWorkspaceId: String
    var kortexWorkspaceId: String {
        get { access(keyPath: \.kortexWorkspaceId); return _kortexWorkspaceId }
        set {
            withMutation(keyPath: \.kortexWorkspaceId) {
                _kortexWorkspaceId = newValue
                defaults.set(newValue, forKey: "kortexWorkspaceId")
            }
        }
    }

    init(storage: AppSettingsStorage = .live()) {
        self.defaults = storage.defaults
        self.secretStore = storage.secretStore

        let defaults = storage.defaults

        // One-time migrations from previous bundle IDs
        if storage.runMigrations {
            Self.migrateFromOldBundleIfNeeded(defaults: defaults)
            Self.migrateFromOpenGranolaIfNeeded(defaults: defaults)
        }

        let defaultNotesPath = storage.defaultNotesDirectory.path
        self._notesFolderPath = defaults.string(forKey: "notesFolderPath") ?? defaultNotesPath
        self._selectedModel = defaults.string(forKey: "selectedModel") ?? "google/gemini-3-flash-preview"
        self._transcriptionLocale = defaults.string(forKey: "transcriptionLocale") ?? "zh"
        self._transcriptionCustomVocabulary = defaults.string(forKey: "transcriptionCustomVocabulary") ?? ""
        self._transcriptionModel = TranscriptionModel(
            rawValue: defaults.string(forKey: "transcriptionModel") ?? ""
        ) ?? .groq
        self._inputDeviceID = AudioDeviceID(defaults.integer(forKey: "inputDeviceID"))
        self._openRouterApiKey = secretStore.load(key: "openRouterApiKey") ?? ""
        self._groqApiKey = secretStore.load(key: "groqApiKey") ?? ""
        self._zaiApiKey = secretStore.load(key: "zaiApiKey") ?? ""
        self._llmProvider = LLMProvider(rawValue: defaults.string(forKey: "llmProvider") ?? "") ?? .openRouter
        self._ollamaBaseURL = defaults.string(forKey: "ollamaBaseURL") ?? "http://localhost:11434"
        self._ollamaLLMModel = defaults.string(forKey: "ollamaLLMModel") ?? "qwen3:8b"
        self._mlxBaseURL = defaults.string(forKey: "mlxBaseURL") ?? "http://localhost:8080"
        self._mlxModel = defaults.string(forKey: "mlxModel") ?? "mlx-community/Llama-3.2-3B-Instruct-4bit"
        self._hasAcknowledgedRecordingConsent = defaults.bool(forKey: "hasAcknowledgedRecordingConsent")
        self._saveAudioRecording = defaults.bool(forKey: "saveAudioRecording")

        // Default to true (shown) if key has never been set
        if defaults.object(forKey: "showLiveTranscript") == nil {
            self._showLiveTranscript = true
        } else {
            self._showLiveTranscript = defaults.bool(forKey: "showLiveTranscript")
        }

        // Meeting detection — default to enabled
        if defaults.object(forKey: "meetingAutoDetectEnabled") == nil {
            if defaults.object(forKey: "autoDetectMeetings") != nil {
                self._meetingAutoDetectEnabled = defaults.bool(forKey: "autoDetectMeetings")
            } else {
                self._meetingAutoDetectEnabled = true
            }
        } else {
            self._meetingAutoDetectEnabled = defaults.bool(forKey: "meetingAutoDetectEnabled")
        }
        self._hasShownAutoDetectExplanation = defaults.bool(forKey: "hasShownAutoDetectExplanation")
        self._hasSeenLaunchAtLoginSuggestion = defaults.bool(forKey: "hasSeenLaunchAtLoginSuggestion")
        self._silenceTimeoutMinutes = defaults.object(forKey: "silenceTimeoutMinutes") != nil
            ? defaults.integer(forKey: "silenceTimeoutMinutes") : 15
        self._customMeetingAppBundleIDs = defaults.stringArray(forKey: "customMeetingAppBundleIDs") ?? []
        self._detectionLogEnabled = defaults.bool(forKey: "detectionLogEnabled")
        self._kortexSyncEnabled = defaults.bool(forKey: "kortexSyncEnabled")
        self._kortexWorkspaceId = defaults.string(forKey: "kortexWorkspaceId") ?? ""

        // Default to true (hidden) if key has never been set
        if defaults.object(forKey: "hideFromScreenShare") == nil {
            self._hideFromScreenShare = true
        } else {
            self._hideFromScreenShare = defaults.bool(forKey: "hideFromScreenShare")
        }

        // Ensure notes folder exists
        try? FileManager.default.createDirectory(
            atPath: notesFolderPath,
            withIntermediateDirectories: true
        )

        // Prevent Spotlight from indexing transcript contents
        Self.dropMetadataNeverIndex(atPath: notesFolderPath)
    }

    /// Place a .metadata_never_index sentinel so Spotlight skips the directory.
    private static func dropMetadataNeverIndex(atPath directoryPath: String) {
        let sentinel = URL(fileURLWithPath: directoryPath).appendingPathComponent(".metadata_never_index")
        if !FileManager.default.fileExists(atPath: sentinel.path) {
            FileManager.default.createFile(atPath: sentinel.path, contents: nil)
        }
    }

    /// Migrate settings from the old "On The Spot" (com.onthespot.app) bundle.
    /// Copies UserDefaults and Keychain entries to the current bundle, then marks migration as done.
    private static func migrateFromOldBundleIfNeeded(defaults: UserDefaults) {
        let migrationKey = "didMigrateFromOnTheSpot"
        guard !defaults.bool(forKey: migrationKey) else { return }
        defer { defaults.set(true, forKey: migrationKey) }

        // Migrate UserDefaults from old bundle
        guard let oldDefaults = UserDefaults(suiteName: "com.onthespot.app") else { return }

        let keysToMigrate = [
            "selectedModel", "transcriptionLocale", "transcriptionModel", "inputDeviceID",
            "llmProvider", "ollamaBaseURL", "ollamaLLMModel", "hideFromScreenShare",
            "isTranscriptExpanded", "hasCompletedOnboarding",
            "autoDetectMeetings", "saveAudioRecording"
        ]
        for key in keysToMigrate {
            if let value = oldDefaults.object(forKey: key), defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        // Migrate Keychain entries from old service
        let oldService = "com.onthespot.app"
        let keychainKeys = ["openRouterApiKey", "groqApiKey", "zaiApiKey"]
        for key in keychainKeys {
            if KeychainHelper.load(key: key) == nil,
               let oldValue = Self.loadKeychain(service: oldService, key: key) {
                KeychainHelper.save(key: key, value: oldValue)
            }
        }
    }

    /// Migrate settings from the previous "OpenGranola" (com.opengranola.app) bundle.
    private static func migrateFromOpenGranolaIfNeeded(defaults: UserDefaults) {
        let migrationKey = "didMigrateFromOpenGranola"
        guard !defaults.bool(forKey: migrationKey) else { return }
        defer { defaults.set(true, forKey: migrationKey) }

        // --- Migrate UserDefaults ---
        guard let oldDefaults = UserDefaults(suiteName: "com.opengranola.app") else {
            // Even without old defaults, migrate file-backed state
            migrateFilesFromOpenGranola(defaults: defaults)
            return
        }

        let keysToMigrate = [
            "selectedModel", "transcriptionLocale", "transcriptionModel", "inputDeviceID",
            "llmProvider", "ollamaBaseURL", "ollamaLLMModel", "hideFromScreenShare",
            "isTranscriptExpanded", "hasCompletedOnboarding",
            "hasAcknowledgedRecordingConsent", "autoDetectMeetings", "saveAudioRecording"
        ]
        for key in keysToMigrate {
            if let value = oldDefaults.object(forKey: key), defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        // --- Migrate file-backed state ---
        migrateFilesFromOpenGranola(defaults: defaults)
    }

    /// Migrate file-backed state (sessions, templates, transcripts)
    /// from ~/Library/Application Support/OpenGranola/ to OpenOats/ and
    /// preserve the notes directory when it already contains transcript archives.
    private static func migrateFilesFromOpenGranola(defaults: UserDefaults) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

        let oldAppSupportDir = appSupport.appendingPathComponent("OpenGranola")
        let newAppSupportDir =
            appSupport.appendingPathComponent(KortexOatsIdentity.appSupportFolderName)

        // Migrate Application Support: sessions/ and templates.json
        if fm.fileExists(atPath: oldAppSupportDir.path) {
            try? fm.createDirectory(at: newAppSupportDir, withIntermediateDirectories: true)

            // Sessions directory (JSONL files + sidecars)
            let oldSessions = oldAppSupportDir.appendingPathComponent("sessions")
            let newSessions = newAppSupportDir.appendingPathComponent("sessions")
            if fm.fileExists(atPath: oldSessions.path) && !fm.fileExists(atPath: newSessions.path) {
                try? fm.moveItem(at: oldSessions, to: newSessions)
            }

            // Templates
            let oldTemplates = oldAppSupportDir.appendingPathComponent("templates.json")
            let newTemplates = newAppSupportDir.appendingPathComponent("templates.json")
            if fm.fileExists(atPath: oldTemplates.path) && !fm.fileExists(atPath: newTemplates.path) {
                try? fm.moveItem(at: oldTemplates, to: newTemplates)
            }

        }

        let oldDocDir = home.appendingPathComponent("Documents/OpenGranola")
        let newDocDir =
            home.appendingPathComponent("Documents/\(KortexOatsIdentity.documentsFolderName)")

        // Migrate notes folder: if the old default directory has content,
        // use it as the notes folder so transcript archives stay accessible.
        if defaults.string(forKey: "notesFolderPath") == nil {
            if fm.fileExists(atPath: oldDocDir.path) {
                let contents = (try? fm.contentsOfDirectory(atPath: oldDocDir.path)) ?? []
                if !contents.isEmpty {
                    defaults.set(oldDocDir.path, forKey: "notesFolderPath")
                }
            }
        }

        // Migrate transcript archives: move files from ~/Documents/OpenGranola/
        // into ~/Documents/OpenOats/ so new sessions and old archives coexist.
        // Skip if the old dir is the active notes folder (files stay in place).
        let activeNotes = defaults.string(forKey: "notesFolderPath") ?? ""
        if fm.fileExists(atPath: oldDocDir.path) && oldDocDir.path != activeNotes {
            try? fm.createDirectory(at: newDocDir, withIntermediateDirectories: true)
            if let files = try? fm.contentsOfDirectory(at: oldDocDir, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "txt" {
                    let dest = newDocDir.appendingPathComponent(file.lastPathComponent)
                    if !fm.fileExists(atPath: dest.path) {
                        try? fm.moveItem(at: file, to: dest)
                    }
                }
            }
        }
    }

    /// Read a keychain entry from a specific service (used for migration only).
    private static func loadKeychain(service: String, key: String) -> String? {
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

    /// Apply current screen-share visibility to all app windows.
    func applyScreenShareVisibility() {
        let type: NSWindow.SharingType = hideFromScreenShare ? .none : .readOnly
        for window in NSApp.windows {
            window.sharingType = type
        }
    }

    var locale: Locale {
        Locale(identifier: transcriptionLocale)
    }

    var transcriptionModelDisplay: String {
        transcriptionModel.displayName
    }

    /// The model name to display in the UI, respecting the active LLM provider.
    var activeModelDisplay: String {
        let raw: String
        switch llmProvider {
        case .openRouter: raw = selectedModel
        case .ollama: raw = ollamaLLMModel
        case .mlx: raw = mlxModel
        }
        return raw.split(separator: "/").last.map(String.init) ?? raw
    }

}

// MARK: - Keychain Helper

enum KeychainHelper {
    private static let service = KortexOatsIdentity.bundleIdentifier

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
