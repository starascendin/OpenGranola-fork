import AppKit
import CoreAudio
import Foundation

// MARK: - Audio Signal Source Protocol

/// Abstraction for observing microphone activation status changes.
protocol AudioSignalSource: Sendable {
    /// Emits `true` when any physical input device becomes active, `false` when all go silent.
    var signals: AsyncStream<Bool> { get }
}

// MARK: - CoreAudio HAL Signal Source

/// Monitors kAudioDevicePropertyDeviceIsRunningSomewhere on all physical input devices.
/// Does NOT capture audio -- only reads activation status.
final class CoreAudioSignalSource: AudioSignalSource, @unchecked Sendable {
    private let listenerQueue = DispatchQueue(label: "com.openoats.mic-listener")
    private var deviceIDs: [AudioDeviceID] = []
    private var continuation: AsyncStream<Bool>.Continuation?
    private var lastEmittedValue: Bool = false

    let signals: AsyncStream<Bool>

    init() {
        var stream: AsyncStream<Bool>!
        var capturedContinuation: AsyncStream<Bool>.Continuation!

        stream = AsyncStream<Bool> { continuation in
            capturedContinuation = continuation
        }

        self.signals = stream

        // Install listeners inside listenerQueue.sync to prevent data races
        // between property initialization and the first callback.
        listenerQueue.sync {
            self.continuation = capturedContinuation
            self.deviceIDs = Self.physicalInputDeviceIDs()

            for deviceID in self.deviceIDs {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )

                let selfPtr = Unmanaged.passUnretained(self).toOpaque()
                AudioObjectAddPropertyListener(deviceID, &address, Self.listenerCallback, selfPtr)
            }
        }
    }

    deinit {
        for deviceID in deviceIDs {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            AudioObjectRemovePropertyListener(deviceID, &address, Self.listenerCallback, selfPtr)
        }
        continuation?.finish()
    }

    // MARK: - Listener Callback

    private static let listenerCallback: AudioObjectPropertyListenerProc = {
        _, _, _, clientData in
        guard let clientData else { return kAudioHardwareNoError }
        let source = Unmanaged<CoreAudioSignalSource>.fromOpaque(clientData).takeUnretainedValue()
        source.checkAndEmit()
        return kAudioHardwareNoError
    }

    private func checkAndEmit() {
        listenerQueue.async { [weak self] in
            guard let self else { return }
            let anyRunning = self.deviceIDs.contains { Self.isDeviceRunning($0) }
            if anyRunning != self.lastEmittedValue {
                self.lastEmittedValue = anyRunning
                self.continuation?.yield(anyRunning)
            }
        }
    }

    // MARK: - Helpers

    private static func physicalInputDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == kAudioHardwareNoError else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == kAudioHardwareNoError else { return [] }

        // Filter to devices that have input streams
        return deviceIDs.filter { deviceID in
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var inputSize: UInt32 = 0
            let status = AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &inputSize)
            return status == kAudioHardwareNoError && inputSize > 0
        }
    }

    private static func isDeviceRunning(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning)
        return status == kAudioHardwareNoError && isRunning != 0
    }
}

// MARK: - Meeting Detector Actor

/// Observes microphone activation and correlates with running meeting apps
/// to determine whether the user is in a meeting.
actor MeetingDetector {
    private let audioSource: any AudioSignalSource
    private let knownApps: [MeetingAppEntry]
    private let customBundleIDs: [String]
    private let selfBundleID: String
    private let knownBundleIDs: Set<String>

    /// Set to true once the debounce expires and we have confirmed detection.
    private(set) var isActive = false

    /// The meeting app that was detected, if any.
    private(set) var detectedApp: MeetingApp?

    /// Emits detection events (true = meeting detected, false = meeting ended).
    let events: AsyncStream<MeetingDetectionEvent>
    private let eventContinuation: AsyncStream<MeetingDetectionEvent>.Continuation

    private var monitorTask: Task<Void, Never>?
    private var browserMonitorTask: Task<Void, Never>?
    private var micActiveAt: Date?

    /// Debounce duration: mic must stay active for this long before we confirm.
    private let debounceSeconds: TimeInterval = 5.0

    /// URL substrings that identify an active browser-based meeting tab.
    private static let browserMeetingURLPatterns: [String] = [
        "meet.google.com/",
        "teams.microsoft.com/",
        "teams.live.com/",
        "zoom.us/wc/",
        "whereby.com/",
        "around.co/",
    ]

    enum MeetingDetectionEvent: Sendable {
        case detected(MeetingApp?)
        case ended
    }

    init(
        audioSource: (any AudioSignalSource)? = nil,
        customBundleIDs: [String] = []
    ) {
        self.audioSource = audioSource ?? CoreAudioSignalSource()
        self.customBundleIDs = customBundleIDs
        self.selfBundleID = Bundle.main.bundleIdentifier ?? KortexOatsIdentity.bundleIdentifier

        // Known meeting apps (embedded to avoid Bundle.module issues in
        // manually-constructed .app bundles)
        self.knownApps = Self.defaultMeetingApps
        self.knownBundleIDs = Set(Self.defaultMeetingApps.map(\.bundleID) + customBundleIDs)
            .subtracting([selfBundleID])

        var capturedContinuation: AsyncStream<MeetingDetectionEvent>.Continuation!
        self.events = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        self.eventContinuation = capturedContinuation
    }

    deinit {
        monitorTask?.cancel()
        browserMonitorTask?.cancel()
        eventContinuation.finish()
    }

    // MARK: - Lifecycle

    func start() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            guard let self else { return }
            for await micIsActive in self.audioSource.signals {
                guard !Task.isCancelled else { break }
                await self.handleMicSignal(micIsActive)
            }
        }
        startBrowserMonitor()
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        browserMonitorTask?.cancel()
        browserMonitorTask = nil
        if isActive {
            isActive = false
            detectedApp = nil
            eventContinuation.yield(.ended)
        }
        micActiveAt = nil
    }

    // MARK: - Query

    /// Query the current state: is a meeting app running with active mic?
    func queryCurrentState() async -> (micActive: Bool, meetingApp: MeetingApp?) {
        let app = await scanForMeetingApp()
        let micActive = micActiveAt != nil
        return (micActive, app)
    }

    // MARK: - Signal Handling

    private func handleMicSignal(_ micIsActive: Bool) async {
        if micIsActive {
            if micActiveAt == nil {
                micActiveAt = Date()
            }

            // Wait for debounce period
            let activeSince = micActiveAt!
            try? await Task.sleep(for: .seconds(debounceSeconds))
            guard !Task.isCancelled else { return }

            // Verify mic is still considered active (debounce passed)
            guard micActiveAt == activeSince else { return }

            // Scan for meeting app
            let app = await scanForMeetingApp()

            if !isActive {
                isActive = true
                detectedApp = app
                eventContinuation.yield(.detected(app))
            }
        } else {
            micActiveAt = nil
            if isActive {
                isActive = false
                detectedApp = nil
                eventContinuation.yield(.ended)
            }
        }
    }

    // MARK: - Browser Tab Monitor

    /// Polls Chrome and Safari every 5 s while `isActive && detectedApp == nil`.
    /// If no meeting URL is found in any open tab, emit `.ended` to stop the recording.
    private func startBrowserMonitor() {
        browserMonitorTask?.cancel()
        // [weak self] makes the closure non-isolated; cross-actor access requires await.
        browserMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                guard let self else { break }
                // Only watch for meeting end when active via audio (no known app matched).
                guard await self.isActive, await self.detectedApp == nil else { continue }
                let hasMeeting = await self.browserHasMeetingTab()
                if !hasMeeting {
                    await self.handleBrowserMeetingEnded()
                }
            }
        }
    }

    private func handleBrowserMeetingEnded() {
        guard isActive, detectedApp == nil else { return }
        isActive = false
        micActiveAt = nil
        eventContinuation.yield(.ended)
    }

    /// Returns true if Chrome, Chromium, or Safari has any tab whose URL
    /// matches one of the known browser-meeting URL patterns.
    private func browserHasMeetingTab() async -> Bool {
        for browser in ["Google Chrome", "Chromium", "Microsoft Edge"] {
            if let urls = await tabURLs(for: browser), urls.contains(where: isMeetingURL) {
                return true
            }
        }
        if let urls = await safariTabURLs(), urls.contains(where: isMeetingURL) {
            return true
        }
        return false
    }

    private func isMeetingURL(_ url: String) -> Bool {
        Self.browserMeetingURLPatterns.contains { url.contains($0) }
    }

    /// Uses AppleScript to retrieve all open tab URLs from a Chromium-family browser.
    private func tabURLs(for browserName: String) async -> [String]? {
        let script = """
        tell application "\(browserName)"
            if it is running then
                set urls to {}
                repeat with w in windows
                    repeat with t in tabs of w
                        set end of urls to URL of t
                    end repeat
                end repeat
                return urls
            end if
        end tell
        """
        return await runAppleScript(script)
    }

    /// Uses AppleScript to retrieve all open tab URLs from Safari.
    private func safariTabURLs() async -> [String]? {
        let script = """
        tell application "Safari"
            if it is running then
                set urls to {}
                repeat with w in windows
                    if exists tabs of w then
                        repeat with t in tabs of w
                            set end of urls to URL of t
                        end repeat
                    end if
                end repeat
                return urls
            end if
        end tell
        """
        return await runAppleScript(script)
    }

    /// Runs an AppleScript string and returns the result as an array of strings.
    private func runAppleScript(_ source: String) async -> [String]? {
        return await Task.detached(priority: .utility) {
            var error: NSDictionary?
            let script = NSAppleScript(source: source)
            guard let descriptor = script?.executeAndReturnError(&error),
                  error == nil else { return nil }
            // Result is a list descriptor; numberOfItems == 0 means empty or scalar.
            let count = descriptor.numberOfItems
            guard count > 0 else {
                // Scalar result (single URL): try stringValue directly.
                if let str = descriptor.stringValue, !str.isEmpty {
                    return [str]
                }
                return nil
            }
            var urls: [String] = []
            for i in 1...count {
                if let item = descriptor.atIndex(i), let str = item.stringValue {
                    urls.append(str)
                }
            }
            return urls.isEmpty ? nil : urls
        }.value
    }

    // MARK: - Process Scanning

    private func scanForMeetingApp() async -> MeetingApp? {
        let runningApps = await MainActor.run {
            NSWorkspace.shared.runningApplications
        }

        for app in runningApps {
            guard let bundleID = app.bundleIdentifier else { continue }
            if knownBundleIDs.contains(bundleID) {
                let name = app.localizedName
                    ?? knownApps.first(where: { $0.bundleID == bundleID })?.displayName
                    ?? bundleID
                return MeetingApp(bundleID: bundleID, name: name)
            }
        }
        return nil
    }

    // MARK: - Default Meeting Apps

    static var bundledMeetingApps: [MeetingAppEntry] {
        defaultMeetingApps
    }

    private static let defaultMeetingApps: [MeetingAppEntry] = [
        MeetingAppEntry(bundleID: "us.zoom.xos", displayName: "Zoom"),
        MeetingAppEntry(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams"),
        MeetingAppEntry(bundleID: "com.apple.FaceTime", displayName: "FaceTime"),
        MeetingAppEntry(bundleID: "com.cisco.webexmeetingsapp", displayName: "Webex"),
        MeetingAppEntry(bundleID: "app.tuple.app", displayName: "Tuple"),
        MeetingAppEntry(bundleID: "co.around.Around", displayName: "Around"),
        MeetingAppEntry(bundleID: "com.slack.Slack", displayName: "Slack"),
        MeetingAppEntry(bundleID: "com.hnc.Discord", displayName: "Discord"),
    ]
}
