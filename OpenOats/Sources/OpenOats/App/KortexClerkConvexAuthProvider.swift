import ClerkKit
@preconcurrency import ConvexMobile
import Foundation

@MainActor
final class KortexClerkConvexAuthProvider: AuthProvider {
    typealias T = String

    private var onIdToken: (@Sendable (String?) -> Void)?
    private var tokenRefreshListenerTask: Task<Void, Never>?
    private var sessionSyncTask: Task<Void, Never>?
    private weak var client: ConvexClientWithAuth<String>?

    init() {}

    func bind(client: ConvexClientWithAuth<String>) {
        self.client = client
        startSessionSync()
    }

    func login(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> String {
        try await authenticate(onIdToken: onIdToken)
    }

    func loginFromCache(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> String {
        try await authenticate(onIdToken: onIdToken)
    }

    func logout() async throws {
        tokenRefreshListenerTask?.cancel()
        tokenRefreshListenerTask = nil
        onIdToken = nil
        try await Clerk.shared.auth.signOut()
    }

    nonisolated func extractIdToken(from authResult: String) -> String {
        authResult
    }

    private func authenticate(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> String {
        self.onIdToken = onIdToken
        let token = try await fetchToken(skipCache: false)
        setupTokenRefreshListener()
        return token
    }

    private func fetchToken(skipCache: Bool) async throws -> String {
        guard Clerk.shared.isLoaded else {
            throw KortexClerkConvexAuthError.clerkNotLoaded
        }

        guard let session = Clerk.shared.session, session.status == .active else {
            throw KortexClerkConvexAuthError.noActiveSession
        }

        let options = Session.GetTokenOptions(
            template: KortexOatsIdentity.clerkConvexJWTTemplate,
            skipCache: skipCache
        )
        guard let token = try await session.getToken(options) else {
            throw KortexClerkConvexAuthError.tokenRetrievalFailed
        }

        return token
    }

    private func setupTokenRefreshListener() {
        tokenRefreshListenerTask?.cancel()

        tokenRefreshListenerTask = Task { [weak self] in
            guard let self else { return }

            for await event in Clerk.shared.auth.events {
                guard !Task.isCancelled else { break }

                switch event {
                case .tokenRefreshed:
                    do {
                        let token = try await fetchToken(skipCache: true)
                        onIdToken?(token)
                    } catch {
                        onIdToken?(nil)
                    }
                default:
                    break
                }
            }
        }
    }

    private func startSessionSync() {
        sessionSyncTask?.cancel()

        sessionSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }

            await syncSession(newSession: Clerk.shared.session)

            for await event in Clerk.shared.auth.events {
                guard !Task.isCancelled else { break }

                switch event {
                case .sessionChanged(let oldSession, let newSession):
                    await syncSession(oldSession: oldSession, newSession: newSession)
                default:
                    break
                }
            }
        }
    }

    private func syncSession(oldSession: Session? = nil, newSession: Session?) async {
        guard let client else { return }

        if shouldLogin(oldSession: oldSession, newSession: newSession) {
            _ = await client.loginFromCache()
        } else if shouldLogout(oldSession: oldSession, newSession: newSession) {
            await client.logout()
        }
    }

    private func shouldLogin(oldSession: Session?, newSession: Session?) -> Bool {
        newSession?.status == .active &&
        (oldSession?.status != .active || oldSession?.id != newSession?.id)
    }

    private func shouldLogout(oldSession: Session?, newSession: Session?) -> Bool {
        oldSession?.id != nil && newSession == nil
    }
}

enum KortexClerkConvexAuthError: LocalizedError {
    case clerkNotLoaded
    case noActiveSession
    case tokenRetrievalFailed

    var errorDescription: String? {
        switch self {
        case .clerkNotLoaded:
            return "Clerk has not finished loading yet."
        case .noActiveSession:
            return "No active Clerk session was found."
        case .tokenRetrievalFailed:
            return "Clerk returned no Convex token."
        }
    }
}
