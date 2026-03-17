import SwiftUI
import Combine

private enum IdleTab { case meetings, recordings }

struct ContentView: View {
    @Bindable var settings: AppSettings
    @State private var transcriptStore = TranscriptStore()
    @State private var knowledgeBase: KnowledgeBase?
    @State private var transcriptionEngine: TranscriptionEngine?
    @State private var suggestionEngine: SuggestionEngine?
    @State private var sessionStore = SessionStore()
    @State private var transcriptLogger = TranscriptLogger()
    @State private var audioLevel: Float = 0
    @State private var isSuggestionsExpanded = false
    @State private var meetingStartTime: Date? = nil
    @State private var now = Date()
    @State private var pastMeetings: [URL] = []
    @State private var idleTab: IdleTab = .meetings
    @State private var meetingDetector = MeetingDetector()
    /// True when the current session was started by auto-detection (not the user).
    @State private var isAutoStarted = false

    var body: some View {
        VStack(spacing: 0) {
            if isRunning {
                activeMeetingHeader
            } else {
                idleHeader
            }

            Divider()

            if isRunning {
                activeMeetingContent
            } else {
                idleContent
            }
        }
        .frame(minWidth: 300, maxWidth: 400, minHeight: 480)
        .background(.ultraThinMaterial)
        .task {
            if knowledgeBase == nil {
                let kb = KnowledgeBase(settings: settings)
                knowledgeBase = kb
                transcriptionEngine = TranscriptionEngine(transcriptStore: transcriptStore)
                suggestionEngine = SuggestionEngine(
                    transcriptStore: transcriptStore,
                    knowledgeBase: kb,
                    settings: settings
                )
            }
            indexKBIfNeeded()
            loadPastMeetings()
            if settings.autoDetectMeetings {
                meetingDetector.start()
            }
        }
        .onChange(of: settings.autoDetectMeetings) { _, newValue in
            if newValue {
                meetingDetector.start()
            } else {
                meetingDetector.stopDetector()
            }
        }
        .onChange(of: meetingDetector.isInMeeting) { _, inMeeting in
            guard settings.autoDetectMeetings else { return }
            if inMeeting && !isRunning {
                startSession(autoStarted: true)
            } else if !inMeeting && isAutoStarted {
                stopSession()
            }
        }
        .onChange(of: settings.kbFolderPath) { indexKBIfNeeded() }
        .onChange(of: settings.voyageApiKey) { indexKBIfNeeded() }
        .onChange(of: settings.inputDeviceID) {
            if isRunning {
                transcriptionEngine?.restartMic(inputDeviceID: settings.inputDeviceID)
            }
        }
        .onChange(of: transcriptStore.utterances.count) {
            handleNewUtterance()
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { date in
            now = date
            if isRunning {
                audioLevel = transcriptionEngine?.audioLevel ?? 0
            } else if audioLevel != 0 {
                audioLevel = 0
            }
        }
    }

    // MARK: - Idle header

    private var idleHeader: some View {
        HStack(spacing: 8) {
            Text("OpenGranola")
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            if let kb = knowledgeBase {
                if !kb.indexingProgress.isEmpty {
                    Text(kb.indexingProgress)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if kb.isIndexed {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                        Text("\(kb.fileCount) files")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                }
            }

            Button("KB Folder...") { chooseKBFolder() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentTeal)

            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Image(systemName: "gear")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Active meeting header

    private var activeMeetingHeader: some View {
        VStack(spacing: 0) {
            if let error = transcriptionEngine?.lastError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }

            if let status = transcriptionEngine?.assetStatus,
               status != "Ready",
               !status.hasPrefix("Transcribing") {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }

            HStack(spacing: 10) {
                // Pulsing red dot
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .scaleEffect(1.0 + CGFloat(audioLevel) * 0.4)
                    .animation(.easeOut(duration: 0.1), value: audioLevel)

                // Elapsed timer
                Text(elapsedString)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)

                // Audio level bars
                AudioLevelView(level: audioLevel)
                    .frame(width: 40, height: 14)

                Spacer()

                // Model pill
                Text(modelShortName)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)

                // End button
                Button("End") { stopSession() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.red.opacity(0.12))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Meeting source / title (when auto-detected)
            if let source = meetingDetector.meetingSource {
                HStack(spacing: 6) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 9))
                    if let title = meetingDetector.meetingTitle {
                        Text("\(title) · \(source)")
                            .lineLimit(1)
                    } else {
                        Text(source)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }
        }
    }

    // MARK: - Idle content

    private var idleContent: some View {
        VStack(spacing: 0) {
            // Tab selector
            Picker("", selection: $idleTab) {
                Text("Meetings").tag(IdleTab.meetings)
                Text("Recordings").tag(IdleTab.recordings)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()

            if idleTab == .meetings {
                meetingsContent
            } else {
                RecordingsView()
            }

            Divider()

            // New Meeting button
            Button { startSession() } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                    Text("New Meeting")
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .background(Color.primary.opacity(0.04))
            .padding(12)
        }
    }

    private var meetingsContent: some View {
        Group {
            if pastMeetings.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("No meetings yet")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Start a meeting to begin recording and transcribing.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 220)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("PAST MEETINGS")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .tracking(1.5)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 4)

                        ForEach(pastMeetings, id: \.self) { url in
                            PastMeetingRow(url: url)
                            Divider().padding(.leading, 46)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Active meeting content

    private var activeMeetingContent: some View {
        VStack(spacing: 0) {
            // Transcript — primary view, fills all available space
            TranscriptView(
                utterances: transcriptStore.utterances,
                volatileYouText: transcriptStore.volatileYouText,
                volatileThemText: transcriptStore.volatileThemText
            )

            Divider()

            // Suggestions — collapsed by default, expand when there's content
            let suggestions = suggestionEngine?.suggestions ?? []
            let isGenerating = suggestionEngine?.isGenerating ?? false

            DisclosureGroup(isExpanded: $isSuggestionsExpanded) {
                SuggestionsView(
                    suggestions: suggestions,
                    isGenerating: isGenerating
                )
                .frame(height: 180)
            } label: {
                HStack(spacing: 6) {
                    Text("SUGGESTIONS")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .tracking(1.5)
                    if !suggestions.isEmpty {
                        Text("(\(suggestions.count))")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if isGenerating {
                        ProgressView().controlSize(.mini)
                    } else if !suggestions.isEmpty && !isSuggestionsExpanded {
                        Circle()
                            .fill(Color.accentTeal)
                            .frame(width: 6, height: 6)
                    }
                    if isSuggestionsExpanded && !transcriptStore.utterances.isEmpty {
                        Button { copyTranscript() } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy transcript")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Computed

    private var isRunning: Bool {
        transcriptionEngine?.isRunning ?? false
    }

    private var elapsedString: String {
        guard let start = meetingStartTime else { return "00:00" }
        let elapsed = Int(now.timeIntervalSince(start))
        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        let seconds = elapsed % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    private var modelShortName: String {
        settings.selectedModel.split(separator: "/").last.map(String.init) ?? settings.selectedModel
    }

    // MARK: - Actions

    private func startSession(autoStarted: Bool = false) {
        transcriptStore.clear()
        suggestionEngine?.clearSession()
        meetingStartTime = Date()
        isSuggestionsExpanded = false
        isAutoStarted = autoStarted
        settings.isRecording = true
        Task {
            await sessionStore.startSession()
            await transcriptLogger.startSession()
            await transcriptionEngine?.start(
                inputDeviceID: settings.inputDeviceID,
                provider: settings.transcriptionProvider,
                groqApiKey: settings.groqApiKey,
                zaiApiKey: settings.zaiApiKey,
                transcriptionLanguage: settings.transcriptionLanguage,
                saveAudio: true  // always save audio for meetings
            )
        }
    }

    private func stopSession() {
        transcriptionEngine?.stop()
        meetingStartTime = nil
        isAutoStarted = false
        settings.isRecording = false
        Task {
            await sessionStore.endSession()
            await transcriptLogger.endSession()
        }
        // Refresh past meetings list after a short delay (file flush)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            loadPastMeetings()
        }
    }

    private func chooseKBFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose your knowledge base folder"
        if panel.runModal() == .OK, let url = panel.url {
            settings.kbFolderPath = url.path
        }
    }

    private func indexKBIfNeeded() {
        guard let url = settings.kbFolderURL, let kb = knowledgeBase else { return }
        Task {
            kb.clear()
            await kb.index(folderURL: url)
        }
    }

    private func loadPastMeetings() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/OpenGranola")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        pastMeetings = files
            .filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func copyTranscript() {
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"
        let lines = transcriptStore.utterances.map { u in
            "[\(timeFmt.string(from: u.timestamp))] \(u.speaker == .you ? "You" : "Them"): \(u.text)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func handleNewUtterance() {
        let utterances = transcriptStore.utterances
        guard let last = utterances.last else { return }

        Task {
            await transcriptLogger.append(
                speaker: last.speaker == .you ? "You" : "Them",
                text: last.text,
                timestamp: last.timestamp
            )
        }

        if last.speaker == .them {
            suggestionEngine?.onThemUtterance(last)

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                let decision = suggestionEngine?.lastDecision
                let latestSuggestion = suggestionEngine?.suggestions.first
                let record = SessionRecord(
                    speaker: last.speaker,
                    text: last.text,
                    timestamp: last.timestamp,
                    suggestions: latestSuggestion.map { [$0.text] },
                    kbHits: latestSuggestion?.kbHits.map { $0.sourceFile },
                    suggestionDecision: decision,
                    surfacedSuggestionText: decision?.shouldSurface == true ? latestSuggestion?.text : nil,
                    conversationStateSummary: transcriptStore.conversationState.shortSummary.isEmpty
                        ? nil : transcriptStore.conversationState.shortSummary
                )
                await sessionStore.appendRecord(record)
            }
        } else {
            Task {
                await sessionStore.appendRecord(SessionRecord(
                    speaker: last.speaker,
                    text: last.text,
                    timestamp: last.timestamp
                ))
            }
        }
    }
}

// MARK: - Past Meeting Row

private struct PastMeetingRow: View {
    let url: URL

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTime)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Text(displayDate)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12))
                    .foregroundStyle(.quaternary)
            }
            .buttonStyle(.plain)
            .help("Open transcript")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            NSWorkspace.shared.open(url)
        }
    }

    /// "2025-06-15_14-30" → "2:30 PM"
    private var displayTime: String {
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.components(separatedBy: "_")
        if parts.count >= 2 {
            let timeParts = parts[1].components(separatedBy: "-")
            if timeParts.count >= 2,
               let h = Int(timeParts[0]),
               let m = Int(timeParts[1]) {
                let period = h >= 12 ? "PM" : "AM"
                let h12 = h == 0 ? 12 : (h > 12 ? h - 12 : h)
                return String(format: "%d:%02d %@", h12, m, period)
            }
        }
        return name
    }

    /// "2025-06-15_14-30" → "Today", "Yesterday", "Jun 15", etc.
    private var displayDate: String {
        let name = url.deletingPathExtension().lastPathComponent
        guard let datePart = name.components(separatedBy: "_").first else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        guard let date = fmt.date(from: datePart) else { return datePart }
        let rel = RelativeDateTimeFormatter()
        rel.dateTimeStyle = .named
        rel.unitsStyle = .full
        return rel.localizedString(for: date, relativeTo: Date())
    }
}
