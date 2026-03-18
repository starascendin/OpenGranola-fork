import AppKit
import EventKit
import Observation

/// Watches for active meetings via native app detection and browser tab URL scanning.
/// Publishes `isInMeeting`, `meetingSource`, and `meetingTitle` (from calendar).
@Observable
@MainActor
final class MeetingDetector {
    private(set) var isInMeeting = false
    /// Human-readable source, e.g. "Zoom", "Chrome (meet.google.com)"
    private(set) var meetingSource: String?
    /// Title from the nearest calendar event, if calendar access was granted.
    private(set) var meetingTitle: String?

    private var workspaceObservers: [Any] = []
    private var pollTask: Task<Void, Never>?
    private let eventStore = EKEventStore()
    private var calendarAuthorized = false

    // MARK: - Known apps and patterns

    /// Native meeting app bundle IDs → display names.
    private let nativeApps: [String: String] = [
        "us.zoom.xos":              "Zoom",
        "com.microsoft.teams2":     "Microsoft Teams",
        "com.microsoft.teams":      "Microsoft Teams",
        "com.apple.facetime":       "FaceTime",
        "com.cisco.webexmeetings":  "Webex",
        "com.cisco.webex.meetings": "Webex",
        "com.loom.desktop":         "Loom",
        "com.whereby.app":          "Whereby",
        "com.amazon.chime":         "Amazon Chime",
    ]

    /// Browsers we can query via AppleScript.
    private struct Browser {
        let bundleID: String
        let displayName: String
        let scriptName: String   // exact name for `tell application "…"`
        let isChromium: Bool     // true = Chromium tab model
    }

    private let browsers: [Browser] = [
        Browser(bundleID: "com.google.Chrome",          displayName: "Chrome",  scriptName: "Google Chrome",   isChromium: true),
        Browser(bundleID: "com.apple.Safari",            displayName: "Safari",  scriptName: "Safari",          isChromium: false),
        Browser(bundleID: "company.thebrowser.Browser",  displayName: "Arc",     scriptName: "Arc",             isChromium: true),
        Browser(bundleID: "com.brave.Browser",           displayName: "Brave",   scriptName: "Brave Browser",   isChromium: true),
        Browser(bundleID: "com.microsoft.edgemac",       displayName: "Edge",    scriptName: "Microsoft Edge",  isChromium: true),
        // Firefox has no useful AppleScript support — skip
    ]

    /// URL substrings that indicate an active video meeting.
    private let meetingPatterns: [String] = [
        "meet.google.com/",
        "zoom.us/j/",
        "zoom.us/wc/",
        "teams.microsoft.com/l/meetup-join",
        "teams.live.com/meet/",
        "app.webex.com/",
        "whereby.com/",
        "around.co/",
        "gather.town/app/",
        "cal.com/video/",
        "discord.com/channels/",
    ]

    // MARK: - Lifecycle

    func start() {
        installWorkspaceObservers()
        startBrowserPoll()
        requestCalendarAccess()
        // Check browsers immediately in case a meeting is already open
        Task { await pollBrowsers() }
    }

    func stopDetector() {
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        workspaceObservers.removeAll()
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Native app watching (NSWorkspace)

    private func installWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter

        let launchObs = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier,
                  let name = self.nativeApps[bid] else { return }
            Task { @MainActor in
                // Small delay so the app is ready before we start capturing
                try? await Task.sleep(for: .seconds(2))
                let title = await self.nearestCalendarEventTitle()
                self.setMeeting(source: name, title: title)
            }
        }

        let termObs = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier,
                  let name = self.nativeApps[bid] else { return }
            Task { @MainActor in
                if self.meetingSource == name { self.clearMeeting() }
            }
        }

        workspaceObservers = [launchObs, termObs]
    }

    // MARK: - Browser tab polling

    private func startBrowserPoll() {
        pollTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                await self?.pollBrowsers()
            }
        }
    }

    private func pollBrowsers() async {
        let running = NSWorkspace.shared.runningApplications

        for browser in browsers {
            guard running.contains(where: { $0.bundleIdentifier == browser.bundleID }) else { continue }

            guard let tabs = await fetchBrowserTabs(browser) else { continue }

            for tab in tabs {
                guard let pattern = meetingPatterns.first(where: { tab.url.contains($0) }) else { continue }
                // Skip if the tab title indicates the meeting has ended
                if isMeetingEndedTitle(tab.title) { continue }

                let domain = pattern
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    .components(separatedBy: "/").first ?? pattern
                let source = "\(browser.displayName) (\(domain))"
                let title = await nearestCalendarEventTitle()
                setMeeting(source: source, title: title)
                return
            }
        }

        // No active meeting tabs found in any browser — clear if we were tracking a browser meeting
        if let src = meetingSource, src.contains("(") {
            clearMeeting()
        }
    }

    /// Returns whether a tab title indicates the user has already left the meeting.
    private func isMeetingEndedTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        return lower.contains("you left") ||
               lower.contains("left the meeting") ||
               lower.contains("meeting ended") ||
               lower.contains("you were removed") ||
               lower.contains("call ended")
    }

    /// Returns all open tab (url, title) pairs for the given browser.
    private func fetchBrowserTabs(_ browser: Browser) async -> [(url: String, title: String)]? {
        let script: String

        if browser.bundleID == "com.apple.Safari" {
            script = """
            try
                tell application "Safari"
                    set out to ""
                    repeat with w in every window
                        repeat with t in every tab of w
                            try
                                set out to out & (URL of t) & "|||" & (name of t) & "\\n"
                            end try
                        end repeat
                    end repeat
                    return out
                end tell
            on error
                return ""
            end try
            """
        } else if browser.isChromium {
            let appName = browser.scriptName
            script = """
            try
                tell application "\(appName)"
                    set out to ""
                    repeat with w in every window
                        repeat with t in every tab of w
                            try
                                set out to out & (URL of t) & "|||" & (title of t) & "\\n"
                            end try
                        end repeat
                    end repeat
                    return out
                end tell
            on error
                return ""
            end try
            """
        } else {
            return nil
        }

        guard let result = await runOsascript(script) else { return nil }
        return result
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .map { line in
                let parts = line.components(separatedBy: "|||")
                let url = parts[0]
                let title = parts.count > 1 ? parts[1...].joined(separator: "|||") : ""
                return (url: url, title: title)
            }
    }

    private func runOsascript(_ script: String) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                let outPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = Pipe()  // suppress permission-denied noise
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let str = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    cont.resume(returning: str.flatMap { $0.isEmpty ? nil : $0 })
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Calendar

    private func requestCalendarAccess() {
        Task {
            do {
                let granted = try await eventStore.requestFullAccessToEvents()
                calendarAuthorized = granted
                diagLog("[DETECTOR] calendar access: \(granted)")
            } catch {
                calendarAuthorized = false
                diagLog("[DETECTOR] calendar access error: \(error.localizedDescription)")
            }
        }
    }

    /// Returns the title of the calendar event closest to now (±5 min window).
    private func nearestCalendarEventTitle() async -> String? {
        guard calendarAuthorized else { return nil }
        let now = Date()
        let pred = eventStore.predicateForEvents(
            withStart: now.addingTimeInterval(-300),
            end: now.addingTimeInterval(900),
            calendars: nil
        )
        return eventStore.events(matching: pred)
            .filter { !$0.isAllDay }
            .min(by: { abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now)) })?
            .title
    }

    // MARK: - State

    private func setMeeting(source: String, title: String?) {
        guard !isInMeeting else { return }
        isInMeeting = true
        meetingSource = source
        meetingTitle = title
        diagLog("[DETECTOR] meeting detected: \(source), title=\(title ?? "nil")")
    }

    private func clearMeeting() {
        guard isInMeeting else { return }
        isInMeeting = false
        meetingSource = nil
        meetingTitle = nil
        diagLog("[DETECTOR] meeting ended")
    }
}
