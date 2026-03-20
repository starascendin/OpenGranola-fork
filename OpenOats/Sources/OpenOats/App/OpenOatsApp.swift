import SwiftUI
import AppKit
import ClerkKit
import Sparkle

public struct OpenOatsRootApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var settings: AppSettings
    @State private var coordinator: AppCoordinator
    @State private var runtime: AppRuntime
    @State private var kortexSyncManager: KortexSyncManager
    private let updaterController: AppUpdaterController
    private let defaults: UserDefaults

    public init() {
        let context = AppRuntime.bootstrap()
        self._settings = State(initialValue: context.settings)
        self._coordinator = State(initialValue: context.coordinator)
        self._runtime = State(initialValue: context.runtime)
        self._kortexSyncManager = State(initialValue: KortexSyncManager())
        self.updaterController = context.updaterController
        self.defaults = context.runtime.defaults
    }

    public var body: some Scene {
        Window("", id: "main") {
            ContentView(settings: settings)
                .environment(runtime)
                .environment(coordinator)
                .environment(kortexSyncManager)
                .environment(Clerk.shared)
                .defaultAppStorage(defaults)
                .onAppear {
                    appDelegate.coordinator = coordinator
                    appDelegate.defaults = defaults
                    coordinator.kortexSyncManager = kortexSyncManager
                    settings.applyScreenShareVisibility()
                }
                .onOpenURL { url in
                    guard let command = OpenOatsDeepLink.parse(url) else { return }
                    switch command {
                    case .openNotes(let sessionID):
                        coordinator.queueSessionSelection(sessionID)
                        openNotesWindow()
                    default:
                        coordinator.queueExternalCommand(command)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 420, height: 600)
        .commands {
            CommandGroup(after: .appInfo) {
                if case .live = runtime.mode {
                    CheckForUpdatesView(updater: updaterController.updater)

                    Divider()
                }

                Button("Past Meetings") {
                    openNotesWindow()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Button("GitHub Repository...") {
                    if let url = URL(string: "https://github.com/starascendin/OpenGranola-fork") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        Window("Notes", id: "notes") {
            NotesView(settings: settings)
                .environment(runtime)
                .environment(coordinator)
                .environment(kortexSyncManager)
                .environment(Clerk.shared)
                .defaultAppStorage(defaults)
        }
        .defaultSize(width: 700, height: 550)

        Settings {
            SettingsView(settings: settings, updater: updaterController.updater)
                .environment(runtime)
                .environment(coordinator)
                .environment(kortexSyncManager)
                .environment(Clerk.shared)
                .defaultAppStorage(defaults)
        }

        MenuBarExtra {
            MenuBarMenuView()
                .environment(coordinator)
        } label: {
            menuBarLabel
        }
    }
}

extension OpenOatsRootApp {
    private func openNotesWindow() {
        openWindow(id: "notes")
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        if coordinator.isRecording {
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

private struct MenuBarMenuView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if coordinator.isRecording {
            Label("Recording in progress", systemImage: "circle.fill")
                .foregroundStyle(.red)
        } else {
            Text(KortexOatsIdentity.appDisplayName)
                .foregroundStyle(.secondary)
        }

        Divider()

        Button("Open \(KortexOatsIdentity.appDisplayName)") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Settings...") {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        Button("Quit \(KortexOatsIdentity.appDisplayName)") {
            NSApp.terminate(nil)
        }
    }
}

/// Observes new window creation and applies screen-share visibility setting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObserver: Any?
    var coordinator: AppCoordinator?
    var defaults: UserDefaults = .standard

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let coordinator else { return nil }
        let menu = NSMenu()
        if coordinator.isRecording {
            let item = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        } else {
            let item = NSMenuItem(title: "Start Recording", action: #selector(startRecording), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func startRecording() {
        coordinator?.queueExternalCommand(.startSession)
    }

    @objc private func stopRecording() {
        coordinator?.queueExternalCommand(.stopSession)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hidden = defaults.object(forKey: "hideFromScreenShare") == nil
            ? true
            : defaults.bool(forKey: "hideFromScreenShare")
        let sharingType: NSWindow.SharingType = hidden ? .none : .readOnly

        for window in NSApp.windows {
            window.sharingType = sharingType
            window.titleVisibility = .hidden
        }

        // Watch for new windows being created (e.g. Settings window)
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                let hide = self.defaults.object(forKey: "hideFromScreenShare") == nil
                    ? true
                    : self.defaults.bool(forKey: "hideFromScreenShare")
                let type: NSWindow.SharingType = hide ? .none : .readOnly
                for window in NSApp.windows {
                    window.sharingType = type
                    window.titleVisibility = .hidden
                }
            }
        }
    }
}
