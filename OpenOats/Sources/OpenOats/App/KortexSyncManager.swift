import AVFoundation
import ClerkKit
@preconcurrency import Combine
@preconcurrency import ConvexMobile
import Foundation
import Observation
import UniformTypeIdentifiers

struct KortexWorkspace: Identifiable, Equatable, Decodable {
    let id: String
    let name: String
    let slug: String?
    let role: String

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case name
        case slug
        case role
    }
}

private struct KortexUserRecord: Decodable {
    let id: String

    enum CodingKeys: String, CodingKey {
        case id = "_id"
    }
}

private struct KortexMeetingRecord: Decodable {
    let externalSessionId: String
}

private struct ConvexUploadResponse: Decodable {
    let storageId: String
}

private struct UploadedArtifact {
    let storageId: String
    let fileName: String
    let contentType: String
    let size: Int
}

struct KortexMeetingUpload: Sendable {
    let externalSessionId: String
    let title: String?
    let startedAt: Date
    let endedAt: Date?
    let utteranceCount: Int
    let transcriptPreview: String?
    let transcriptURL: URL
    let sidecarURL: URL
    let audioURL: URL?
}

@MainActor
@Observable
final class KortexSyncManager {
    @ObservationIgnored private let client: ConvexClientWithAuth<String>
    @ObservationIgnored private var authTask: Task<Void, Never>?
    @ObservationIgnored private var workspaceSubscription: AnyCancellable?
    @ObservationIgnored private var syncedSessionsSubscription: AnyCancellable?
    @ObservationIgnored private var lastSilentReauthAt: Date?

    private(set) var authState: AuthState<String> = .loading
    private(set) var availableWorkspaces: [KortexWorkspace] = []
    private(set) var syncedSessionIds: Set<String> = []
    private(set) var isRefreshingWorkspaces = false
    private(set) var isUploading = false
    private(set) var lastStatusMessage: String?
    private(set) var lastErrorMessage: String?
    var isAuthViewPresented = false

    private static var hasConfiguredClerk = false

    init() {
        Self.configureClerkIfNeeded()
        let authProvider = KortexClerkConvexAuthProvider()
        client = ConvexClientWithAuth(
            deploymentUrl: KortexOatsIdentity.convexDeploymentURL,
            authProvider: authProvider as any AuthProvider<String>
        )
        authProvider.bind(client: client)
        observeAuthState()
    }

    func signInWithGoogle() async {
        await signIn(with: .google)
    }

    func signInWithApple() async {
        do {
            lastErrorMessage = nil
            lastStatusMessage = "Starting Sign in with Apple..."
            _ = try await Clerk.shared.auth.signInWithApple()
            lastStatusMessage = "Waiting for Clerk session confirmation..."
        } catch {
            lastErrorMessage = "Apple sign-in failed: \(error.localizedDescription)"
            lastStatusMessage = nil
        }
    }

    func signOut() async {
        do {
            try await Clerk.shared.auth.signOut()
            lastStatusMessage = "Signed out of Clerk dev."
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Sign-out failed: \(error.localizedDescription)"
        }
    }

    func refreshWorkspaces() {
        guard case .authenticated = authState else { return }

        isRefreshingWorkspaces = true
        lastErrorMessage = nil
        workspaceSubscription?.cancel()
        workspaceSubscription = client.subscribe(to: "workspaces:list")
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                guard let self else { return }
                guard case .failure(let error) = completion else { return }
                self.availableWorkspaces = []
                self.isRefreshingWorkspaces = false
                self.lastStatusMessage = nil
                self.lastErrorMessage = "Failed to load Kortex workspaces: \(error.localizedDescription)"
            } receiveValue: { [weak self] (workspaces: [KortexWorkspace]) in
                guard let self else { return }
                self.availableWorkspaces = workspaces.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                self.isRefreshingWorkspaces = false
                self.lastErrorMessage = nil
                self.lastStatusMessage = workspaces.isEmpty
                    ? "Connected, but no Kortex workspaces were found for this account."
                    : "Loaded \(workspaces.count) Kortex workspace(s)."
            }
    }

    /// Subscribes to the live list of meeting sessions on Convex for the given workspace.
    /// Updates `syncedSessionIds` reactively — so the Recordings UI stays in sync
    /// even when the user deletes a recording from the web app (local file is untouched).
    func subscribeSyncedSessions(settings: AppSettings) {
        guard settings.kortexSyncEnabled,
              case .authenticated = authState else {
            syncedSessionsSubscription?.cancel()
            syncedSessionIds = []
            return
        }
        let workspaceId = settings.kortexWorkspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspaceId.isEmpty else {
            syncedSessionsSubscription?.cancel()
            syncedSessionIds = []
            return
        }

        syncedSessionsSubscription?.cancel()
        syncedSessionsSubscription = client.subscribe(
            to: "meetingSessions:list",
            with: ["workspaceId": workspaceId]
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] completion in
            guard let self else { return }
            if case .failure = completion { self.syncedSessionIds = [] }
        } receiveValue: { [weak self] (sessions: [KortexMeetingRecord]) in
            guard let self else { return }
            self.syncedSessionIds = Set(sessions.map { $0.externalSessionId })
        }
    }

    func uploadMeeting(_ meeting: KortexMeetingUpload, settings: AppSettings) async {
        guard settings.kortexSyncEnabled else { return }
        guard case .authenticated = authState else {
            lastStatusMessage = "Skipped Kortex upload because Clerk is not signed in."
            return
        }

        let workspaceId = settings.kortexWorkspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspaceId.isEmpty else {
            lastStatusMessage = "Skipped Kortex upload because no workspace is selected."
            return
        }

        isUploading = true
        lastErrorMessage = nil
        lastStatusMessage = "Uploading \(meeting.externalSessionId) to Kortex..."

        do {
            let transcriptArtifact = try await uploadFile(
                fileURL: meeting.transcriptURL,
                contentType: "application/x-ndjson"
            )
            let sidecarArtifact = try await uploadFile(
                fileURL: meeting.sidecarURL,
                contentType: "application/json"
            )
            let audioArtifact = try await uploadOptionalFile(
                fileURL: meeting.audioURL,
                fallbackContentType: "audio/x-caf"
            )

            var args: [String: ConvexEncodable] = [
                "workspaceId": workspaceId,
                "externalSessionId": meeting.externalSessionId,
                "sourceApp": KortexOatsIdentity.sourceAppName,
                "startedAt": meeting.startedAt.timeIntervalSince1970 * 1000,
                "utteranceCount": Double(meeting.utteranceCount),
                "transcriptStorageId": transcriptArtifact.storageId,
                "transcriptFileName": transcriptArtifact.fileName,
                "transcriptContentType": transcriptArtifact.contentType,
                "transcriptSize": Double(transcriptArtifact.size),
                "sidecarStorageId": sidecarArtifact.storageId,
                "sidecarFileName": sidecarArtifact.fileName,
                "sidecarContentType": sidecarArtifact.contentType,
                "sidecarSize": Double(sidecarArtifact.size),
            ]

            if let title = meeting.title, !title.isEmpty {
                args["title"] = title
            }
            if let endedAt = meeting.endedAt {
                args["endedAt"] = endedAt.timeIntervalSince1970 * 1000
            }
            if let preview = meeting.transcriptPreview, !preview.isEmpty {
                args["transcriptPreview"] = preview
            }
            if let audioArtifact {
                args["audioStorageId"] = audioArtifact.storageId
                args["audioFileName"] = audioArtifact.fileName
                args["audioContentType"] = audioArtifact.contentType
                args["audioSize"] = Double(audioArtifact.size)
            }

            let _: String = try await client.mutation("meetingSessions:create", with: args)
            lastStatusMessage = "Uploaded \(meeting.externalSessionId) to Kortex."
        } catch {
            lastErrorMessage = "Kortex upload failed: \(error.localizedDescription)"
            lastStatusMessage = nil
        }

        isUploading = false
    }

    enum SyncError: LocalizedError {
        case notAuthenticated
        case noWorkspaceSelected
        var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "Sign in to Kortex in Settings to sync."
            case .noWorkspaceSelected: return "Select a Kortex workspace in Settings."
            }
        }
    }

    func uploadAudioRecording(url: URL, settings: AppSettings) async throws {
        guard case .authenticated = authState else { throw SyncError.notAuthenticated }
        let workspaceId = settings.kortexWorkspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspaceId.isEmpty else { throw SyncError.noWorkspaceSelected }

        let sessionId = url.deletingPathExtension().lastPathComponent
        let startedAt = Self.parseSessionDate(from: sessionId) ?? Date()

        // Convert CAF → M4A before uploading
        let uploadURL: URL
        let uploadContentType: String
        let convertedURL = try await convertToM4A(cafURL: url)
        uploadURL = convertedURL
        uploadContentType = "audio/mp4"

        defer {
            // Clean up temp file after upload
            try? FileManager.default.removeItem(at: uploadURL)
        }

        let artifact = try await uploadFile(fileURL: uploadURL, contentType: uploadContentType)

        let args: [String: ConvexEncodable] = [
            "workspaceId": workspaceId,
            "externalSessionId": sessionId,
            "sourceApp": KortexOatsIdentity.sourceAppName,
            "startedAt": startedAt.timeIntervalSince1970 * 1000,
            "utteranceCount": Double(0),
            "audioStorageId": artifact.storageId,
            "audioFileName": artifact.fileName,
            "audioContentType": artifact.contentType,
            "audioSize": Double(artifact.size),
        ]
        let _: String = try await client.mutation("meetingSessions:create", with: args)
    }

    private func convertToM4A(cafURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: cafURL)
        let sessionId = cafURL.deletingPathExtension().lastPathComponent
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(sessionId).m4a")

        // Remove any previous temp file
        try? FileManager.default.removeItem(at: outputURL)

        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ConversionError.exportSessionFailed
        }

        session.outputURL = outputURL
        session.outputFileType = .m4a

        await session.export()

        guard session.status == .completed else {
            throw ConversionError.exportFailed(session.error?.localizedDescription ?? "Unknown error")
        }

        return outputURL
    }

    enum ConversionError: LocalizedError {
        case exportSessionFailed
        case exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .exportSessionFailed: return "Could not create audio export session."
            case .exportFailed(let msg): return "Audio conversion failed: \(msg)"
            }
        }
    }

    private static func parseSessionDate(from sessionId: String) -> Date? {
        // Format: session_YYYY-MM-DD_HH-mm-ss
        let parts = sessionId.components(separatedBy: "_")
        guard parts.count >= 3 else { return nil }
        let dateStr = "\(parts[1]) \(parts[2].replacingOccurrences(of: "-", with: ":"))"
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: dateStr)
    }

    private func observeAuthState() {
        authTask?.cancel()
        authTask = Task { [weak self] in
            guard let self else { return }
            for await state in client.authState.values {
                self.authState = state

                switch state {
                case .loading:
                    self.lastStatusMessage = "Checking Clerk session..."
                case .unauthenticated:
                    self.workspaceSubscription?.cancel()
                    self.syncedSessionsSubscription?.cancel()
                    self.availableWorkspaces = []
                    self.syncedSessionIds = []
                    self.isRefreshingWorkspaces = false
                    self.lastErrorMessage = nil

                    // If Clerk still has an active session, the Convex WebSocket may have just
                    // dropped auth during reconnect or token rotation. Try a silent re-auth
                    // before showing the sign-in prompt (rate-limited to once per 30s).
                    let now = Date()
                    let canRetry = self.lastSilentReauthAt.map {
                        now.timeIntervalSince($0) > 30
                    } ?? true

                    if canRetry,
                       let session = Clerk.shared.session,
                       session.status == .active {
                        self.lastSilentReauthAt = now
                        self.lastStatusMessage = "Reconnecting to Kortex..."
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            _ = await self.client.loginFromCache()
                        }
                    } else {
                        self.lastStatusMessage = "Sign in with Clerk dev to enable Kortex uploads."
                    }
                case .authenticated:
                    self.lastSilentReauthAt = nil
                    self.lastErrorMessage = nil
                    self.lastStatusMessage = "Connected to Clerk dev. Syncing your Kortex account..."
                    do {
                        let _: KortexUserRecord = try await self.client.mutation(
                            "users:ensureUser"
                        )
                        self.refreshWorkspaces()
                    } catch {
                        self.lastErrorMessage =
                            "Connected to Clerk, but failed to initialize your Kortex user: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func uploadOptionalFile(
        fileURL: URL?,
        fallbackContentType: String
    ) async throws -> UploadedArtifact? {
        guard let fileURL else { return nil }
        return try await uploadFile(
            fileURL: fileURL,
            contentType: mimeType(for: fileURL) ?? fallbackContentType
        )
    }

    private func uploadFile(
        fileURL: URL,
        contentType: String
    ) async throws -> UploadedArtifact {
        let uploadURL: String = try await client.mutation(
            "meetingSessions:generateUploadUrl"
        )
        guard let url = URL(string: uploadURL) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let uploadResponse = try JSONDecoder().decode(ConvexUploadResponse.self, from: data)
        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return UploadedArtifact(
            storageId: uploadResponse.storageId,
            fileName: fileURL.lastPathComponent,
            contentType: contentType,
            size: fileSize
        )
    }

    private func mimeType(for fileURL: URL) -> String? {
        guard let type = UTType(filenameExtension: fileURL.pathExtension) else {
            return nil
        }
        return type.preferredMIMEType
    }

    private func signIn(with provider: OAuthProvider) async {
        do {
            lastErrorMessage = nil
            lastStatusMessage = "Starting \(providerName(for: provider)) sign-in..."
            _ = try await Clerk.shared.auth.signInWithOAuth(provider: provider)
            lastStatusMessage = "Waiting for Clerk session confirmation..."
        } catch {
            lastErrorMessage = "\(providerName(for: provider)) sign-in failed: \(error.localizedDescription)"
            lastStatusMessage = nil
        }
    }

    private func providerName(for provider: OAuthProvider) -> String {
        switch provider {
        case .google:
            return "Google"
        case .apple:
            return "Apple"
        default:
            return "OAuth"
        }
    }

    private static func configureClerkIfNeeded() {
        guard !hasConfiguredClerk else { return }
        Clerk.configure(
            publishableKey: KortexOatsIdentity.clerkPublishableKey,
            options: .init(
                keychainConfig: .init(service: KortexOatsIdentity.bundleIdentifier),
                redirectConfig: .init(
                    redirectUrl: "\(KortexOatsIdentity.deepLinkScheme)://callback",
                    callbackUrlScheme: KortexOatsIdentity.deepLinkScheme
                )
            )
        )
        hasConfiguredClerk = true
    }
}
