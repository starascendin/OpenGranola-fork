import SwiftUI
import AppKit

@main
struct OpenGranolaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var settings = AppSettings()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(settings: settings)
                .onAppear {
                    settings.applyScreenShareVisibility()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 320, height: 560)

        Settings {
            SettingsView(settings: settings)
        }

        MenuBarExtra {
            MenuBarMenuView(settings: settings)
        } label: {
            menuBarLabel
        }
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        if settings.isRecording {
            HStack(spacing: 3) {
                Image(systemName: "waveform.badge.mic")
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
            }
        } else {
            Image(systemName: "waveform.badge.mic")
        }
    }
}

// MARK: - Menu Bar Menu

private struct MenuBarMenuView: View {
    var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Status row
        if settings.isRecording {
            Label("Recording in progress", systemImage: "circle.fill")
                .foregroundStyle(.red)
        } else {
            Text("OpenGranola")
                .foregroundStyle(.secondary)
        }

        Divider()

        Button("Open OpenGranola") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Settings...") {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        Button("Quit OpenGranola") {
            NSApp.terminate(nil)
        }
    }
}

// MARK: - App Delegate

/// Observes new window creation and applies screen-share visibility setting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hidden = UserDefaults.standard.object(forKey: "hideFromScreenShare") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "hideFromScreenShare")
        let sharingType: NSWindow.SharingType = hidden ? .none : .readOnly

        for window in NSApp.windows {
            window.sharingType = sharingType
        }

        // Watch for new windows being created (e.g. Settings window)
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                let hide = UserDefaults.standard.object(forKey: "hideFromScreenShare") == nil
                    ? true
                    : UserDefaults.standard.bool(forKey: "hideFromScreenShare")
                let type: NSWindow.SharingType = hide ? .none : .readOnly
                for window in NSApp.windows {
                    window.sharingType = type
                }
            }
        }
    }
}
