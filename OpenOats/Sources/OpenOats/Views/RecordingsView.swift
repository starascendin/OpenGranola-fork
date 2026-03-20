import SwiftUI
import AVFoundation

// MARK: - Audio Player Controller

@Observable
@MainActor
final class AudioPlayerController {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var currentURL: URL?

    private var player: AVAudioPlayer?

    func load(_ url: URL) {
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.prepareToPlay()
        player = p
        currentURL = url
        duration = p.duration
    }

    func togglePlayPause() {
        guard let p = player else { return }
        if p.isPlaying {
            p.pause()
            isPlaying = false
        } else {
            p.play()
            isPlaying = true
            startPolling()
        }
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
        currentTime = time
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        currentURL = nil
    }

    private func startPolling() {
        Task { @MainActor [weak self] in
            while let self, let p = self.player {
                self.currentTime = p.currentTime
                if !p.isPlaying {
                    self.isPlaying = false
                    self.currentTime = 0
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

// MARK: - Sync State

private enum SyncState: Equatable {
    case idle
    case uploading
    case synced
    case failed(String)
}

// MARK: - Recordings View

struct RecordingsView: View {
    let settings: AppSettings

    @AppStorage("notesFolderPath") private var notesFolderPath =
        KortexOatsIdentity.defaultNotesDirectory().path
    @Environment(KortexSyncManager.self) private var syncManager
    @State private var recordings: [(url: URL, duration: TimeInterval)] = []
    @State private var controller = AudioPlayerController()
    @State private var isDragging = false
    @State private var sliderValue: Double = 0
    @State private var syncStates: [URL: SyncState] = [:]
    @State private var isSyncingAll = false

    var body: some View {
        VStack(spacing: 0) {
            if recordings.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("No recordings yet")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Audio is saved automatically when you start a meeting.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 220)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("RECORDINGS")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .tracking(1.5)

                            Spacer()

                            Button {
                                syncAll()
                            } label: {
                                if isSyncingAll {
                                    HStack(spacing: 4) {
                                        ProgressView()
                                            .scaleEffect(0.6)
                                            .frame(width: 10, height: 10)
                                        Text("Syncing...")
                                            .font(.system(size: 10))
                                    }
                                } else {
                                    Label("Sync All", systemImage: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 10))
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(isSyncingAll)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                        ForEach(recordings, id: \.url) { item in
                            RecordingRow(
                                url: item.url,
                                duration: item.duration,
                                isActive: controller.currentURL == item.url,
                                isPlaying: controller.currentURL == item.url && controller.isPlaying,
                                syncState: syncStates[item.url] ?? .idle,
                                onTap: {
                                    if controller.currentURL == item.url {
                                        controller.togglePlayPause()
                                    } else {
                                        controller.load(item.url)
                                        controller.togglePlayPause()
                                    }
                                },
                                onSync: {
                                    syncOne(item.url)
                                }
                            )
                            Divider().padding(.leading, 46)
                        }
                    }
                }

                if controller.currentURL != nil {
                    Divider()
                    playerBar
                }
            }
        }
        .onAppear {
            loadRecordings()
            syncManager.subscribeSyncedSessions(settings: settings)
        }
        .onChange(of: notesFolderPath) { _, _ in
            loadRecordings()
        }
        .onChange(of: settings.kortexWorkspaceId) { _, _ in
            syncManager.subscribeSyncedSessions(settings: settings)
        }
        .onChange(of: syncManager.syncedSessionIds) { _, _ in
            updateSyncStatesFromConvex()
        }
        .onChange(of: controller.currentTime) { _, newTime in
            if !isDragging { sliderValue = newTime }
        }
    }

    // MARK: - Convex state reconciliation

    /// Updates local syncStates to reflect what Convex actually has.
    /// Called whenever the live Convex subscription delivers fresh data.
    /// Local files are never deleted — only their sync indicator changes.
    private func updateSyncStatesFromConvex() {
        for item in recordings {
            let sessionId = item.url.deletingPathExtension().lastPathComponent
            guard syncStates[item.url] != .uploading else { continue }
            if syncManager.syncedSessionIds.contains(sessionId) {
                syncStates[item.url] = .synced
            } else if case .synced = syncStates[item.url] {
                // Was marked synced locally, but no longer exists on Convex → reset
                syncStates[item.url] = .idle
            }
        }
    }

    // MARK: - Sync Actions

    private func syncOne(_ url: URL) {
        guard syncStates[url] != .uploading else { return }
        syncStates[url] = .uploading
        Task {
            do {
                try await syncManager.uploadAudioRecording(url: url, settings: settings)
                syncStates[url] = .synced
            } catch {
                syncStates[url] = .failed(error.localizedDescription)
            }
        }
    }

    private func syncAll() {
        guard !isSyncingAll else { return }
        isSyncingAll = true
        Task {
            for item in recordings {
                guard syncStates[item.url] != .synced,
                      syncStates[item.url] != .uploading else { continue }
                syncStates[item.url] = .uploading
                do {
                    try await syncManager.uploadAudioRecording(url: item.url, settings: settings)
                    syncStates[item.url] = .synced
                } catch {
                    syncStates[item.url] = .failed(error.localizedDescription)
                }
            }
            isSyncingAll = false
        }
    }

    // MARK: - Player bar

    private var playerBar: some View {
        VStack(spacing: 4) {
            // Scrubber
            Slider(
                value: $sliderValue,
                in: 0...(controller.duration > 0 ? controller.duration : 1),
                onEditingChanged: { editing in
                    isDragging = editing
                    if !editing { controller.seek(to: sliderValue) }
                }
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)

            HStack(spacing: 16) {
                Text(timeString(controller.currentTime))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)

                Spacer()

                Button {
                    controller.seek(to: max(0, controller.currentTime - 10))
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button { controller.togglePlayPause() } label: {
                    Image(systemName: controller.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 30))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentTeal)

                Button {
                    controller.seek(to: min(controller.duration, controller.currentTime + 10))
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Text(timeString(controller.duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Helpers

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        } else {
            return String(format: "%02d:%02d", m, sec)
        }
    }

    private func loadRecordings() {
        let dir = URL(fileURLWithPath: notesFolderPath, isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        recordings = files
            .filter { $0.pathExtension == "caf" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { url in
                let dur = (try? AVAudioPlayer(contentsOf: url))?.duration ?? 0
                return (url: url, duration: dur)
            }
        // Apply whatever Convex state we already have
        updateSyncStatesFromConvex()
    }
}

// MARK: - Recording Row

private struct RecordingRow: View {
    let url: URL
    let duration: TimeInterval
    let isActive: Bool
    let isPlaying: Bool
    let syncState: SyncState
    let onTap: () -> Void
    let onSync: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onTap) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(isActive ? Color.accentTeal : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text(displayTime)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                    Text(displayDate)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    HStack(spacing: 4) {
                        Text("CAF")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.07))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        Text("M4A")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.mint)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.mint.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                        Text("on sync")
                            .font(.system(size: 9))
                            .foregroundStyle(.quaternary)
                    }
                }

                Spacer()

                Text(durationString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.quaternary)

                syncButton

                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12))
                        .foregroundStyle(.quaternary)
                }
                .buttonStyle(.plain)
                .help("Show in Finder")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)

            if case .failed(let msg) = syncState {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }
        }
        .contentShape(Rectangle())
        .background(isActive ? Color.primary.opacity(0.04) : Color.clear)
        .onTapGesture { onTap() }
    }

    @ViewBuilder
    private var syncButton: some View {
        switch syncState {
        case .idle:
            Button(action: onSync) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Sync to Kortex")
        case .uploading:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)
        case .synced:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
                .help("Synced to Kortex")
        case .failed(let msg):
            Button(action: onSync) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help("Sync failed: \(msg). Tap to retry.")
        }
    }

    /// "session_2026-03-17_14-01-54" → "2:01 PM"
    private var displayTime: String {
        let name = url.deletingPathExtension().lastPathComponent
        // format: session_YYYY-MM-DD_HH-mm-ss
        let parts = name.components(separatedBy: "_")
        guard parts.count >= 3 else { return name }
        let timeParts = parts[2].components(separatedBy: "-")
        guard timeParts.count >= 2,
              let h = Int(timeParts[0]),
              let m = Int(timeParts[1]) else { return name }
        let period = h >= 12 ? "PM" : "AM"
        let h12 = h == 0 ? 12 : (h > 12 ? h - 12 : h)
        return String(format: "%d:%02d %@", h12, m, period)
    }

    /// "session_2026-03-17_14-01-54" → "Today", "Yesterday", "Mar 17"
    private var displayDate: String {
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.components(separatedBy: "_")
        guard parts.count >= 2 else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        guard let date = fmt.date(from: parts[1]) else { return parts[1] }
        let rel = RelativeDateTimeFormatter()
        rel.dateTimeStyle = .named
        rel.unitsStyle = .full
        return rel.localizedString(for: date, relativeTo: Date())
    }

    private var durationString: String {
        let t = Int(duration)
        let m = t / 60
        let s = t % 60
        return String(format: "%d:%02d", m, s)
    }
}
