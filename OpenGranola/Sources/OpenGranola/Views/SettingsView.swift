import SwiftUI
import CoreAudio

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @State private var inputDevices: [(id: AudioDeviceID, name: String)] = []

    var body: some View {
        Form {
            Section("Knowledge Base") {
                HStack {
                    Text(settings.kbFolderPath.isEmpty ? "No folder selected" : settings.kbFolderPath)
                        .font(.system(size: 12))
                        .foregroundStyle(settings.kbFolderPath.isEmpty ? .tertiary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button("Choose...") {
                        chooseFolder()
                    }
                }
            }

            Section("Voyage AI") {
                SecureField("API Key", text: $settings.voyageApiKey)
                .font(.system(size: 12, design: .monospaced))
            }

            Section("OpenRouter API") {
                SecureField("API Key", text: $settings.openRouterApiKey)
                .font(.system(size: 12, design: .monospaced))

                TextField("Model", text: $settings.selectedModel, prompt: Text("e.g. google/gemini-3-flash-preview"))
                    .font(.system(size: 12, design: .monospaced))
            }

            Section("Audio Input") {
                Picker("Microphone", selection: $settings.inputDeviceID) {
                    Text("System Default").tag(AudioDeviceID(0))
                    ForEach(inputDevices, id: \.id) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .font(.system(size: 12))

                Toggle("Save mic audio to file", isOn: $settings.saveAudio)
                    .font(.system(size: 12))
                Text("Recordings saved to ~/Documents/OpenGranola/recordings/")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Transcription") {
                Picker("Engine", selection: $settings.transcriptionProvider) {
                    ForEach(TranscriptionProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .font(.system(size: 12))

                if settings.transcriptionProvider == .groq {
                    SecureField("Groq API Key", text: $settings.groqApiKey)
                        .font(.system(size: 12, design: .monospaced))
                }

                if settings.transcriptionProvider == .zai {
                    SecureField("ZhipuAI API Key", text: $settings.zaiApiKey)
                        .font(.system(size: 12, design: .monospaced))
                }

                if settings.transcriptionProvider.isRemote {
                    Picker("Language", selection: $settings.transcriptionLanguage) {
                        Text("Auto-detect").tag("")
                        Text("Mandarin Chinese (zh)").tag("zh")
                        Text("English (en)").tag("en")
                        Text("Cantonese (yue)").tag("yue")
                        Text("Japanese (ja)").tag("ja")
                        Text("Korean (ko)").tag("ko")
                    }
                    .font(.system(size: 12))
                    Text("Specify a language for faster, more accurate transcription.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Local engine (English only). Switch to Groq or ZhipuAI for Mandarin.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Meeting Detection") {
                Toggle("Auto-detect meetings", isOn: $settings.autoDetectMeetings)
                    .font(.system(size: 12))
                Text("Automatically starts recording when Zoom, Google Meet, Teams, FaceTime, or Webex is detected.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Toggle("Hide from screen sharing", isOn: $settings.hideFromScreenShare)
                    .font(.system(size: 12))
                Text("When enabled, the app is invisible during screen sharing and recording.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 580)
        .onAppear {
            inputDevices = MicCapture.availableInputDevices()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder containing your knowledge base documents (.md, .txt)"

        if panel.runModal() == .OK, let url = panel.url {
            settings.kbFolderPath = url.path
        }
    }
}
