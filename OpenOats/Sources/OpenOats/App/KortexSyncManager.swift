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

    private(set) var authState: AuthState<String> = .loading
    private(set) var availableWorkspaces: [KortexWorkspace] = []
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
                "startedAt": Int(meeting.startedAt.timeIntervalSince1970 * 1000),
                "utteranceCount": meeting.utteranceCount,
                "transcriptStorageId": transcriptArtifact.storageId,
                "transcriptFileName": transcriptArtifact.fileName,
                "transcriptContentType": transcriptArtifact.contentType,
                "transcriptSize": transcriptArtifact.size,
                "sidecarStorageId": sidecarArtifact.storageId,
                "sidecarFileName": sidecarArtifact.fileName,
                "sidecarContentType": sidecarArtifact.contentType,
                "sidecarSize": sidecarArtifact.size,
            ]

            if let title = meeting.title, !title.isEmpty {
                args["title"] = title
            }
            if let endedAt = meeting.endedAt {
                args["endedAt"] = Int(endedAt.timeIntervalSince1970 * 1000)
            }
            if let preview = meeting.transcriptPreview, !preview.isEmpty {
                args["transcriptPreview"] = preview
            }
            if let audioArtifact {
                args["audioStorageId"] = audioArtifact.storageId
                args["audioFileName"] = audioArtifact.fileName
                args["audioContentType"] = audioArtifact.contentType
                args["audioSize"] = audioArtifact.size
            }

            let _: String = try await client.mutation("meetingSessions:create", with: args)
            lastStatusMessage = "Uploaded \(meeting.externalSessionId) to Kortex."
        } catch {
            lastErrorMessage = "Kortex upload failed: \(error.localizedDescription)"
            lastStatusMessage = nil
        }

        isUploading = false
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
                    self.availableWorkspaces = []
                    self.isRefreshingWorkspaces = false
                    self.lastErrorMessage = nil
                    self.lastStatusMessage = "Sign in with Clerk dev to enable Kortex uploads."
                case .authenticated:
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
