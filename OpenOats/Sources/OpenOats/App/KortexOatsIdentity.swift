import Foundation

enum KortexOatsIdentity {
    static let appDisplayName = "KortexOats(Dev)"
    static let sourceAppName = "KortexOats(Dev)"
    static let bundleIdentifier = "com.mwopenoats.app"
    static let deepLinkScheme = "kortexoatsdev"
    static let appSupportFolderName = "KortexOatsDev"
    static let documentsFolderName = "KortexOatsDev"
    static let clerkConvexJWTTemplate = "convex"
    static let clerkPublishableKey =
        "pk_test_c3RpcnJpbmctaGFsaWJ1dC00My5jbGVyay5hY2NvdW50cy5kZXYk"
    static let convexDeploymentURL = "https://compassionate-duck-541.convex.cloud"

    static func appSupportDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(appSupportFolderName, isDirectory: true)
    }

    static func defaultNotesDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/\(documentsFolderName)", isDirectory: true)
    }
}
