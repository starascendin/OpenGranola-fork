import SwiftUI
import CoreAudio
import LaunchAtLogin
import Sparkle

struct SettingsView: View {
    private enum TemplateField: Hashable {
        case name
    }

    @Bindable var settings: AppSettings
    var updater: SPUUpdater
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(KortexSyncManager.self) private var kortexSyncManager
    @State private var inputDevices: [(id: AudioDeviceID, name: String)] = []
    @State private var automaticallyChecksForUpdates = false
    @State private var templates: [MeetingTemplate] = []
    @State private var isAddingTemplate = false
    @State private var newTemplateName = ""
    @State private var newTemplateIcon = "doc.text"
    @State private var newTemplatePrompt = ""
    @FocusState private var focusedTemplateField: TemplateField?
    @State private var showAutoDetectExplanation = false

    var body: some View {
        Form {
            meetingNotesSection
            llmProviderSection
            audioInputSection
            recordingSection
            kortexSyncSection
            transcriptionSection
            privacySection
            meetingDetectionSection
            advancedDetectionSection
            updatesSection
            meetingTemplatesSection
        }
        .accessibilityIdentifier("settings.form")
        .formStyle(.grouped)
        .frame(width: 450, height: 750)
        .onAppear {
            refreshViewState()
            syncWorkspaceSelection()
        }
        .onChange(of: kortexSyncManager.availableWorkspaces) {
            syncWorkspaceSelection()
        }
    }

    private func refreshViewState() {
        inputDevices = MicCapture.availableInputDevices()
        Task { @MainActor in
            automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
            templates = coordinator.templateStore.templates
        }
    }

    private func syncAutomaticUpdateChecks(to newValue: Bool) {
        Task { @MainActor in
            updater.automaticallyChecksForUpdates = newValue
        }
    }

    private func addTemplate(_ template: MeetingTemplate) {
        Task { @MainActor in
            coordinator.templateStore.add(template)
            templates = coordinator.templateStore.templates
        }
    }

    private func resetTemplate(id: UUID) {
        Task { @MainActor in
            coordinator.templateStore.resetBuiltIn(id: id)
            templates = coordinator.templateStore.templates
        }
    }

    private func deleteTemplate(id: UUID) {
        Task { @MainActor in
            coordinator.templateStore.delete(id: id)
            templates = coordinator.templateStore.templates
        }
    }

    private func chooseNotesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose where to save meeting transcripts"

        if panel.runModal() == .OK, let url = panel.url {
            settings.notesFolderPath = url.path
        }
    }

    private var trimmedTemplateName: String {
        newTemplateName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedTemplatePrompt: String {
        newTemplatePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSaveNewTemplate: Bool {
        !trimmedTemplateName.isEmpty && !trimmedTemplatePrompt.isEmpty
    }

    private func resetNewTemplateForm() {
        isAddingTemplate = false
        newTemplateName = ""
        newTemplateIcon = "doc.text"
        newTemplatePrompt = ""
        focusedTemplateField = nil
    }

    private func syncWorkspaceSelection() {
        let workspaces = kortexSyncManager.availableWorkspaces
        guard !workspaces.isEmpty else { return }

        let currentSelection = settings.kortexWorkspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let validWorkspaceIDs = Set(workspaces.map(\.id))

        guard !validWorkspaceIDs.contains(currentSelection) else { return }
        settings.kortexWorkspaceId = workspaces[0].id
    }

    @ViewBuilder
    private var meetingNotesSection: some View {
        Section("Meeting Notes") {
            Text("Where meeting transcripts are saved as plain text files.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack {
                Text(settings.notesFolderPath)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button("Choose...") {
                    chooseNotesFolder()
                }
            }
        }
    }

    @ViewBuilder
    private var llmProviderSection: some View {
        Section("LLM Provider") {
            Picker("Provider", selection: $settings.llmProvider) {
                ForEach(LLMProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .font(.system(size: 12))
            .accessibilityIdentifier("settings.llmProviderPicker")

            switch settings.llmProvider {
            case .openRouter:
                SecureField("API Key", text: $settings.openRouterApiKey)
                    .font(.system(size: 12, design: .monospaced))

                TextField("Model", text: $settings.selectedModel, prompt: Text("e.g. google/gemini-3-flash-preview"))
                    .font(.system(size: 12, design: .monospaced))
            case .ollama:
                TextField("Ollama URL", text: $settings.ollamaBaseURL, prompt: Text("http://localhost:11434"))
                    .font(.system(size: 12, design: .monospaced))

                TextField("Model", text: $settings.ollamaLLMModel, prompt: Text("e.g. qwen3:8b"))
                    .font(.system(size: 12, design: .monospaced))
            case .mlx:
                TextField("MLX Server URL", text: $settings.mlxBaseURL, prompt: Text("http://localhost:8080"))
                    .font(.system(size: 12, design: .monospaced))

                TextField("Model", text: $settings.mlxModel, prompt: Text("e.g. mlx-community/Llama-3.2-3B-Instruct-4bit"))
                    .font(.system(size: 12, design: .monospaced))
            }
        }
    }

    @ViewBuilder
    private var audioInputSection: some View {
        Section("Audio Input") {
            Picker("Microphone", selection: $settings.inputDeviceID) {
                Text("System Default").tag(AudioDeviceID(0))
                ForEach(inputDevices, id: \.id) { device in
                    Text(device.name).tag(device.id)
                }
            }
            .font(.system(size: 12))
            .accessibilityIdentifier("settings.microphonePicker")
        }
    }

    @ViewBuilder
    private var recordingSection: some View {
        Section("Recording") {
            Toggle("Save audio recording", isOn: $settings.saveAudioRecording)
                .font(.system(size: 12))
            Text("Save a local raw microphone recording (.caf) for each session. Audio never leaves your device.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var kortexSyncSection: some View {
        Section("Kortex Sync") {
            Toggle("Upload sessions to Kortex", isOn: $settings.kortexSyncEnabled)
                .font(.system(size: 12))
                .onChange(of: settings.kortexSyncEnabled) {
                    if settings.kortexSyncEnabled {
                        settings.saveAudioRecording = true
                    }
                }

            Text("Use your Kortex Clerk dev account. When enabled, \(KortexOatsIdentity.appDisplayName) uploads the session transcript, metadata, and raw audio recording to the Kortex dev Convex project.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            workspaceAuthContent

            if let status = kortexSyncManager.lastStatusMessage, !status.isEmpty {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if let error = kortexSyncManager.lastErrorMessage, !error.isEmpty {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var workspaceAuthContent: some View {
        switch kortexSyncManager.authState {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking Clerk session…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case .unauthenticated:
            HStack {
                Button("Sign in with Google") {
                    Task {
                        await kortexSyncManager.signInWithGoogle()
                    }
                }
                .font(.system(size: 12))

                Button("Sign in with Apple") {
                    Task {
                        await kortexSyncManager.signInWithApple()
                    }
                }
                .font(.system(size: 12))
            }

            Text("Sign in to load your Kortex workspaces and enable uploads.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .authenticated:
            authenticatedWorkspaceContent
        }
    }

    @ViewBuilder
    private var authenticatedWorkspaceContent: some View {
        HStack {
            Label("Connected to Clerk dev", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
            Spacer()
            Button("Refresh Workspaces") {
                kortexSyncManager.refreshWorkspaces()
            }
            .font(.system(size: 12))
            Button("Sign Out") {
                Task {
                    await kortexSyncManager.signOut()
                }
            }
            .font(.system(size: 12))
        }

        if kortexSyncManager.isRefreshingWorkspaces {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading workspaces…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } else if kortexSyncManager.availableWorkspaces.isEmpty {
            Text("No Kortex workspaces are available for this account yet.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            workspaceSelectionList
        }
    }

    @ViewBuilder
    private var workspaceSelectionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Main Workspace")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Text("This workspace is used as the default upload destination for every meeting.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                ForEach(kortexSyncManager.availableWorkspaces) { workspace in
                    workspaceRow(for: workspace)
                }
            }
        }
    }

    private func workspaceRow(for workspace: KortexWorkspace) -> some View {
        let isSelected = settings.kortexWorkspaceId == workspace.id

        return Button {
            settings.kortexWorkspaceId = workspace.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.7))

                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)

                    workspaceMeta(for: workspace)
                }

                Spacer()

                if isSelected {
                    Text("Default")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(workspaceRowBackground(isSelected: isSelected))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func workspaceMeta(for workspace: KortexWorkspace) -> some View {
        HStack(spacing: 6) {
            if let slug = workspace.slug, !slug.isEmpty {
                Text(slug)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text(workspace.role.capitalized)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06))
                .clipShape(Capsule())
        }
    }

    private func workspaceRowBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
    }

    @ViewBuilder
    private var transcriptionSection: some View {
        Section("Transcription") {
            Picker("Model", selection: $settings.transcriptionModel) {
                ForEach(TranscriptionModel.allCases) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .font(.system(size: 12))
            .accessibilityIdentifier("settings.transcriptionModelPicker")

            if settings.transcriptionModel == .groq {
                SecureField("Groq API Key", text: $settings.groqApiKey)
                    .font(.system(size: 12, design: .monospaced))
            } else if settings.transcriptionModel == .zai {
                SecureField("ZhipuAI API Key", text: $settings.zaiApiKey)
                    .font(.system(size: 12, design: .monospaced))
            }

            if settings.transcriptionModel.supportsExplicitLanguageHint {
                TextField(
                    "\(settings.transcriptionModel.localeFieldTitle) (e.g. zh)",
                    text: $settings.transcriptionLocale
                )
                .font(.system(size: 12, design: .monospaced))
            }

            Text(settings.transcriptionModel.localeHelpText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Show live transcript", isOn: $settings.showLiveTranscript)
                .font(.system(size: 12))
            Text("When disabled, the transcript panel is hidden during meetings while transcription continues in the background.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text("Custom Keywords")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                ZStack(alignment: .topLeading) {
                    if settings.transcriptionCustomVocabulary.isEmpty {
                        Text("One term per line. Optional aliases: KortexOats: kortex oats")
                            .font(.system(size: 11))
                            .foregroundStyle(.quaternary)
                            .padding(.top, 6)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $settings.transcriptionCustomVocabulary)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 90)
                        .frame(maxWidth: .infinity)
                        .scrollContentBackground(.hidden)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(.quaternary)
                )

                Text(
                    "Optional. Boost meeting-specific jargon, names, and product terms for Groq or ZAI transcription. Enter one term per line, or use `Preferred Term: alias one, alias two`."
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var privacySection: some View {
        Section("Privacy") {
            Toggle("Hide from screen sharing", isOn: $settings.hideFromScreenShare)
                .font(.system(size: 12))
            Text("When enabled, the app is invisible during screen sharing and recording.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var meetingDetectionSection: some View {
        Section("Meeting Detection") {
            Toggle("Auto-detect meetings", isOn: $settings.meetingAutoDetectEnabled)
                .font(.system(size: 12))
                .onChange(of: settings.meetingAutoDetectEnabled) {
                    if settings.meetingAutoDetectEnabled && !settings.hasShownAutoDetectExplanation {
                        settings.meetingAutoDetectEnabled = false
                        showAutoDetectExplanation = true
                    }
                }

            Text("When enabled, \(KortexOatsIdentity.appDisplayName) monitors microphone activation to detect when a meeting app starts a call and automatically starts transcribing when it detects one.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            LaunchAtLogin.Toggle("Launch at login")
                .font(.system(size: 12))
        }
        .sheet(isPresented: $showAutoDetectExplanation) {
            autoDetectExplanationSheet
        }
    }

    private var autoDetectExplanationSheet: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            Text("How Meeting Detection Works")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                Label("\(KortexOatsIdentity.appDisplayName) watches for microphone activation by meeting apps (Zoom, Teams, FaceTime, etc.)", systemImage: "mic")
                Label("Only activation status is checked to detect meetings. Captured audio still stays local.", systemImage: "lock.shield")
                Label("When a meeting is detected, \(KortexOatsIdentity.appDisplayName) automatically starts transcribing.", systemImage: "waveform")
                Label("Auto-detected sessions stop automatically when the meeting ends or when the silence timeout is reached.", systemImage: "stop.circle")
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button("Cancel") {
                    showAutoDetectExplanation = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Enable Detection") {
                    settings.hasShownAutoDetectExplanation = true
                    settings.meetingAutoDetectEnabled = true
                    showAutoDetectExplanation = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    @ViewBuilder
    private var advancedDetectionSection: some View {
        if settings.meetingAutoDetectEnabled {
            DisclosureGroup("Advanced Detection Settings") {
                HStack {
                    Text("Silence timeout")
                        .font(.system(size: 12))
                    Spacer()
                    TextField("", value: $settings.silenceTimeoutMinutes, format: .number)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 50)
                        .multilineTextAlignment(.trailing)
                    Text("min")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text("Auto-detected sessions stop after this many minutes of silence.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Toggle("Detection log", isOn: $settings.detectionLogEnabled)
                    .font(.system(size: 12))
                Text("Print detection events to the system console for debugging.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
        }
    }

    @ViewBuilder
    private var updatesSection: some View {
        Section("Updates") {
            Toggle("Automatically check for updates", isOn: $automaticallyChecksForUpdates)
            .font(.system(size: 12))
            .onChange(of: automaticallyChecksForUpdates) { _, newValue in
                syncAutomaticUpdateChecks(to: newValue)
            }
        }
    }

    @ViewBuilder
    private var meetingTemplatesSection: some View {
        Section("Meeting Templates") {
            ForEach(templates) { template in
                HStack {
                    Image(systemName: template.icon)
                        .frame(width: 20)
                        .foregroundStyle(.secondary)
                    Text(template.name)
                        .font(.system(size: 12))
                    Spacer()
                    if template.isBuiltIn {
                        Image(systemName: "lock")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Button("Reset") {
                            resetTemplate(id: template.id)
                        }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                    } else {
                        Button {
                            deleteTemplate(id: template.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if isAddingTemplate {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Name")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField("e.g. Sprint Planning", text: $newTemplateName)
                            .font(.system(size: 12))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                            .focused($focusedTemplateField, equals: .name)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Icon")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        IconPickerGrid(selected: $newTemplateIcon)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Notes Prompt")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("Instructions for how the AI should format notes for this meeting type.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        ZStack(alignment: .topLeading) {
                            if newTemplatePrompt.isEmpty {
                                Text("e.g. You are a meeting notes assistant. Given a transcript, produce structured notes with sections for...")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.quaternary)
                                    .padding(.top, 6)
                                    .padding(.leading, 4)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $newTemplatePrompt)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(height: 100)
                                .frame(maxWidth: .infinity)
                                .scrollContentBackground(.hidden)
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(.quaternary)
                        )
                    }

                    HStack {
                        Button("Cancel") {
                            resetNewTemplateForm()
                        }
                        .buttonStyle(.plain)
                        Button("Save") {
                            let template = MeetingTemplate(
                                id: UUID(),
                                name: trimmedTemplateName,
                                icon: newTemplateIcon,
                                systemPrompt: trimmedTemplatePrompt,
                                isBuiltIn: false
                            )
                            addTemplate(template)
                            resetNewTemplateForm()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSaveNewTemplate)
                    }
                }
                .padding(.vertical, 4)
            } else {
                Button("New Template") {
                    isAddingTemplate = true
                    Task { @MainActor in
                        focusedTemplateField = .name
                    }
                }
                .font(.system(size: 12))
            }
        }
    }
}

// MARK: - Icon Picker

private struct IconPickerGrid: View {
    @Binding var selected: String

    private static let icons = [
        "doc.text", "person.2", "person.3", "person.badge.plus",
        "calendar", "clock", "arrow.up.circle", "magnifyingglass",
        "lightbulb", "star", "flag", "bolt",
        "bubble.left.and.bubble.right", "phone", "video",
        "briefcase", "chart.bar", "list.bullet",
        "checkmark.circle", "gear", "globe", "book",
        "pencil", "megaphone",
    ]

    private let columns = Array(repeating: GridItem(.fixed(28), spacing: 4), count: 8)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Self.icons, id: \.self) { icon in
                Button {
                    selected = icon
                } label: {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selected == icon ? Color.accentColor.opacity(0.2) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(selected == icon ? Color.accentColor : Color.clear, lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected == icon ? .primary : .secondary)
            }
        }
    }
}
