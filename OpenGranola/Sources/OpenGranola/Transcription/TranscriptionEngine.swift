import AVFoundation
import CoreAudio
import FluidAudio
import Observation
import os

// AVAudioPCMBuffer is an ObjC class shared read-only across tasks; safe to mark Sendable.
extension AVAudioPCMBuffer: @unchecked Sendable {}

/// Simple file logger for diagnostics — writes to /tmp/opengranola.log
func diagLog(_ msg: String) {
    let line = "\(Date()): \(msg)\n"
    let path = "/tmp/opengranola.log"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
}

/// Orchestrates dual StreamingTranscriber instances for mic (you) and system audio (them).
@Observable
@MainActor
final class TranscriptionEngine {
    private(set) var isRunning = false
    private(set) var assetStatus: String = "Ready"
    private(set) var lastError: String?

    private let systemCapture = SystemAudioCapture()
    private let micCapture = MicCapture()
    private let transcriptStore: TranscriptStore

    /// Audio level from mic for the UI meter.
    var audioLevel: Float { micCapture.audioLevel }

    private var micTask: Task<Void, Never>?
    private var sysTask: Task<Void, Never>?
    /// Keeps the mic stream alive for the audio level meter when transcription isn't running.
    private var micKeepAliveTask: Task<Void, Never>?

    /// Active ASR backend (local Parakeet or remote Whisper API).
    private var asrBackend: ASRBackend?
    private var vadManager: VadManager?

    private let audioRecorder = AudioRecorder()
    private var recordingTask: Task<Void, Never>?

    /// Tracks the resolved mic device ID currently in use.
    private var currentMicDeviceID: AudioDeviceID = 0

    /// Tracks whether user selected "System Default" (0) or a specific device.
    private var userSelectedDeviceID: AudioDeviceID = 0

    /// Listens for default input device changes at the OS level.
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    init(transcriptStore: TranscriptStore) {
        self.transcriptStore = transcriptStore
    }

    func start(
        inputDeviceID: AudioDeviceID = 0,
        provider: TranscriptionProvider = .local,
        groqApiKey: String = "",
        zaiApiKey: String = "",
        transcriptionLanguage: String = "",
        saveAudio: Bool = false
    ) async {
        diagLog("[ENGINE-0] start() called, isRunning=\(isRunning), provider=\(provider.rawValue)")
        guard !isRunning else { return }
        lastError = nil

        guard await ensureMicrophonePermission() else { return }

        isRunning = true

        // 1. Build the ASR backend.
        //    Remote providers only need the VAD model (much faster startup, no 600MB download).
        //    Local provider loads both VAD + Parakeet-TDT v2.
        do {
            switch provider {
            case .local:
                assetStatus = "Loading ASR model (~600MB first run)..."
                diagLog("[ENGINE-1] loading FluidAudio ASR models...")
                let models = try await AsrModels.downloadAndLoad(version: .v2)
                assetStatus = "Initializing ASR..."
                let asr = AsrManager(config: .default)
                try await asr.initialize(models: models)
                assetStatus = "Loading VAD model..."
                diagLog("[ENGINE-1b] loading VAD model...")
                let vad = try await VadManager()
                self.vadManager = vad
                self.asrBackend = .local(asr)
                assetStatus = "Models ready"
                diagLog("[ENGINE-2] local models loaded")

            case .groq:
                guard !groqApiKey.isEmpty else {
                    lastError = "Groq API key is required. Add it in Settings > Transcription."
                    assetStatus = "Ready"
                    isRunning = false
                    return
                }
                assetStatus = "Loading VAD model..."
                diagLog("[ENGINE-1] loading VAD model for Groq backend...")
                let vad = try await VadManager()
                self.vadManager = vad
                self.asrBackend = .remote(WhisperAPIClient.groq(apiKey: groqApiKey, language: transcriptionLanguage))
                assetStatus = "VAD ready (Groq Whisper)"
                diagLog("[ENGINE-2] Groq backend ready")

            case .zai:
                guard !zaiApiKey.isEmpty else {
                    lastError = "ZhipuAI API key is required. Add it in Settings > Transcription."
                    assetStatus = "Ready"
                    isRunning = false
                    return
                }
                assetStatus = "Loading VAD model..."
                diagLog("[ENGINE-1] loading VAD model for ZhipuAI backend...")
                let vad = try await VadManager()
                self.vadManager = vad
                self.asrBackend = .remote(WhisperAPIClient.zai(apiKey: zaiApiKey, language: transcriptionLanguage))
                assetStatus = "VAD ready (ZhipuAI SenseVoice)"
                diagLog("[ENGINE-2] ZhipuAI backend ready")
            }
        } catch {
            let msg = "Failed to load models: \(error.localizedDescription)"
            diagLog("[ENGINE-2-FAIL] \(msg)")
            lastError = msg
            assetStatus = "Ready"
            isRunning = false
            return
        }

        guard let backend = asrBackend, let vadManager else { return }

        // 2. Start mic capture
        userSelectedDeviceID = inputDeviceID
        let targetMicID = inputDeviceID > 0 ? inputDeviceID : MicCapture.defaultInputDeviceID()
        currentMicDeviceID = targetMicID ?? 0
        diagLog("[ENGINE-3] starting mic capture, targetMicID=\(String(describing: targetMicID))")
        let rawMicStream = micCapture.bufferStream(deviceID: targetMicID)

        // Fork the mic stream: one branch for transcription, one for recording.
        let micStream: AsyncStream<AVAudioPCMBuffer>
        if saveAudio {
            let (recStream, recCont) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
            let (fwdStream, fwdCont) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
            Task.detached {
                for await buf in rawMicStream {
                    recCont.yield(buf)
                    fwdCont.yield(buf)
                }
                recCont.finish()
                fwdCont.finish()
            }
            let recorder = audioRecorder
            recordingTask = Task.detached {
                for await buf in recStream {
                    await recorder.write(buf)
                }
            }
            micStream = fwdStream
            diagLog("[ENGINE-3b] audio recording enabled")
        } else {
            micStream = rawMicStream
        }

        // 3. Start system audio capture
        diagLog("[ENGINE-4] starting system audio capture...")
        let sysStreams: SystemAudioCapture.CaptureStreams?
        do {
            sysStreams = try await systemCapture.bufferStream()
            diagLog("[ENGINE-5] system audio capture started OK")
        } catch {
            let msg = "Failed to start system audio: \(error.localizedDescription)"
            diagLog("[ENGINE-5-FAIL] \(msg)")
            lastError = msg
            sysStreams = nil
        }

        // 4. Start mic transcription
        let store = transcriptStore
        let micTranscriber = StreamingTranscriber(
            backend: backend,
            vadManager: vadManager,
            speaker: .you,
            onPartial: { text in
                Task { @MainActor in store.volatileYouText = text }
            },
            onFinal: { text in
                Task { @MainActor in
                    store.volatileYouText = ""
                    store.append(Utterance(text: text, speaker: .you))
                }
            }
        )
        micTask = Task.detached {
            await micTranscriber.run(stream: micStream)
        }

        // 5. Start system audio transcription
        if let sysStream = sysStreams?.systemAudio {
            let sysTranscriber = StreamingTranscriber(
                backend: backend,
                vadManager: vadManager,
                speaker: .them,
                onPartial: { text in
                    Task { @MainActor in store.volatileThemText = text }
                },
                onFinal: { text in
                    Task { @MainActor in
                        store.volatileThemText = ""
                        store.append(Utterance(text: text, speaker: .them))
                    }
                }
            )
            sysTask = Task.detached {
                await sysTranscriber.run(stream: sysStream)
            }
        }

        let engineLabel: String
        switch provider {
        case .local: engineLabel = "Parakeet-TDT v2 (local)"
        case .groq:  engineLabel = "Groq Whisper large-v3"
        case .zai:   engineLabel = "ZhipuAI SenseVoice"
        }
        assetStatus = "Transcribing (\(engineLabel))"
        diagLog("[ENGINE-6] all transcription tasks started")

        // Install CoreAudio listener for default input device changes
        installDefaultDeviceListener()
    }

    /// Restart only the mic capture with a new device, keeping system audio and backend intact.
    func restartMic(inputDeviceID: AudioDeviceID) {
        guard isRunning, let backend = asrBackend, let vadManager else { return }

        if inputDeviceID != 0 || userSelectedDeviceID != 0 {
            userSelectedDeviceID = inputDeviceID
        }
        let targetMicID = inputDeviceID > 0 ? inputDeviceID : MicCapture.defaultInputDeviceID() ?? 0
        guard targetMicID != currentMicDeviceID else {
            diagLog("[ENGINE-MIC-SWAP] same device \(targetMicID), skipping")
            return
        }

        diagLog("[ENGINE-MIC-SWAP] switching mic from \(currentMicDeviceID) to \(targetMicID)")

        micTask?.cancel()
        micTask = nil
        micCapture.stop()
        currentMicDeviceID = targetMicID

        let micStream = micCapture.bufferStream(deviceID: targetMicID)
        let store = transcriptStore
        let micTranscriber = StreamingTranscriber(
            backend: backend,
            vadManager: vadManager,
            speaker: .you,
            onPartial: { text in
                Task { @MainActor in store.volatileYouText = text }
            },
            onFinal: { text in
                Task { @MainActor in
                    store.volatileYouText = ""
                    store.append(Utterance(text: text, speaker: .you))
                }
            }
        )
        micTask = Task.detached {
            await micTranscriber.run(stream: micStream)
        }

        diagLog("[ENGINE-MIC-SWAP] mic restarted on device \(targetMicID)")
    }

    // MARK: - Default Device Listener

    private func installDefaultDeviceListener() {
        guard defaultDeviceListenerBlock == nil else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.isRunning, self.userSelectedDeviceID == 0 else { return }
                self.restartMic(inputDeviceID: 0)
            }
        }
        defaultDeviceListenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    private func removeDefaultDeviceListener() {
        guard let block = defaultDeviceListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        defaultDeviceListenerBlock = nil
    }

    private func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                lastError = "Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone."
                assetStatus = "Ready"
            }
            return granted
        case .denied, .restricted:
            lastError = "Microphone access is disabled. Enable it in System Settings > Privacy & Security > Microphone."
            assetStatus = "Ready"
            return false
        @unknown default:
            lastError = "Unable to verify microphone permission."
            assetStatus = "Ready"
            return false
        }
    }

    func stop() {
        removeDefaultDeviceListener()
        micTask?.cancel()
        sysTask?.cancel()
        micKeepAliveTask?.cancel()
        recordingTask?.cancel()
        micTask = nil
        sysTask = nil
        micKeepAliveTask = nil
        recordingTask = nil
        Task { await systemCapture.stop() }
        micCapture.stop()
        currentMicDeviceID = 0
        isRunning = false
        assetStatus = "Ready"
        Task {
            if let url = await audioRecorder.stop() {
                diagLog("[ENGINE] audio saved to \(url.path)")
            }
        }
    }
}
