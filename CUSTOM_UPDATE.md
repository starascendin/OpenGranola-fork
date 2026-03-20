# CUSTOM_UPDATE

This file documents the custom fork work added in this repo beyond upstream OpenOats.

Reviewed on 2026-03-20 against:

- `4908a1f` `cp -- chinese work; auto detect owkrs`
- `7576f25` `cp -- auto end`
- `1d2ac3d` `Merge upstream/main: add Qwen3 ASR, Sparkle updater, Notes window`
- Current uncommitted worktree changes in `OpenOats/`

## Summary

The custom work in this fork falls into four main buckets:

- meeting auto-detection
- automatic session start and automatic end behavior
- saving raw audio recordings and adding a recordings browser
- adding remote transcription support for Groq and ZAI, with Chinese-oriented transcription support

## 1. Meeting Auto-Detection

Fork work introduced local meeting detection before upstream's newer meeting-detection architecture.

What we added:

- A custom detector at `OpenGranola/Sources/OpenGranola/Detection/MeetingDetector.swift`
- App settings support for `autoDetectMeetings`
- UI wiring in `ContentView` to start the detector and react to meeting state changes

Behavior added by the fork:

- start watching for meeting activity automatically
- treat meeting detection as a trigger for recording logic
- make meeting auto-detection a user setting, defaulting to enabled

This work first appeared in `4908a1f`.

## 2. Auto-Start And Auto-End Recording

Fork work added automation on top of meeting detection.

What we added:

- auto-start a session when the detector decides the user is in a meeting
- track whether a session was auto-started
- auto-stop the session when the detected meeting ends

History notes:

- `4908a1f` introduced the meeting-detection direction
- `7576f25` added the follow-up auto-end behavior

In the current uncommitted OpenOats tree, this logic shows up as:

- `meetingDetector.start()` on launch when `autoDetectMeetings` is enabled
- `startSession(autoStarted: true)` when a meeting is detected
- `stopSession()` when the meeting ends and the session was auto-started

## 3. Raw Audio Recording And Recordings UI

Fork work added raw recording persistence before upstream's later merged-audio recording flow.

What we added:

- `AudioRecorder.swift` to write raw mic audio buffers to disk as `.caf`
- `RecordingsView.swift` to browse saved recordings
- idle-state UI to switch between sessions and recordings

Behavior added by the fork:

- lazily create a recording file on first audio write
- save recordings under the app documents directory
- surface a recordings list in the app UI

History notes:

- `4908a1f` added `AudioRecorder.swift`
- `7576f25` added `RecordingsView.swift`

In the current uncommitted OpenOats tree, the carry-forward work also updates the storage path from:

- `~/Documents/OpenGranola/recordings`

to:

- `~/Documents/OpenOats/recordings`

## 4. Groq And ZAI Remote Transcription

Fork work added an OpenAI-compatible remote transcription client and provider-specific factories.

What we added:

- `WhisperAPIClient.swift`
- multipart WAV upload logic for remote speech-to-text APIs
- `Groq` using `whisper-large-v3`
- `ZhipuAI / ZAI` using `glm-asr-2512`

History notes:

- `WhisperAPIClient.swift` was introduced in `4908a1f`
- `git blame` shows nearly the entire file still traces back to `4908a1f`

The original fork work also touched:

- transcription model selection in settings
- language hint plumbing
- transcription engine wiring
- settings UI for provider API keys

In the current uncommitted OpenOats tree, the carry-forward work reintroduces:

- `TranscriptionModel.groq`
- `TranscriptionModel.zai`
- `groqApiKey` and `zaiApiKey`
- `StreamingTranscriber` remote backend support
- `TranscriptionEngine` routing for Groq and ZAI
- settings fields for Groq and ZAI API keys

## 5. Chinese-Focused Transcription Work

The `4908a1f` commit was explicitly the fork's "chinese work" commit.

That effort included:

- adding ZAI as a Chinese-oriented transcription provider
- adding explicit language support for remote transcription
- exposing language input in settings for non-local transcription paths

The intent was to improve transcription quality for Chinese and multilingual usage beyond the default local models.

## 6. Upstream Merge And Carry-Forward Status

The `1d2ac3d` merge moved the fork from the old `OpenGranola` tree into the upstream `OpenOats` tree.

Important detail:

- not all earlier fork customizations were fully preserved in committed OpenOats wiring after the merge
- some custom code survived directly, especially `WhisperAPIClient`
- some carry-forward work currently exists only as uncommitted changes in the working tree

As of 2026-03-20, the uncommitted files continuing this custom work are:

- `OpenOats/Sources/OpenOats/Audio/AudioRecorder.swift`
- `OpenOats/Sources/OpenOats/Settings/AppSettings.swift`
- `OpenOats/Sources/OpenOats/Transcription/StreamingTranscriber.swift`
- `OpenOats/Sources/OpenOats/Transcription/TranscriptionEngine.swift`
- `OpenOats/Sources/OpenOats/Transcription/WhisperAPIClient.swift`
- `OpenOats/Sources/OpenOats/Views/ContentView.swift`
- `OpenOats/Sources/OpenOats/Views/RecordingsView.swift`
- `OpenOats/Sources/OpenOats/Views/SettingsView.swift`

## Bottom Line

The fork-specific work we added was:

- local meeting auto-detection
- automatic meeting-driven recording start/stop behavior
- raw audio recording persistence plus a recordings UI
- Groq transcription support
- ZAI transcription support
- Chinese-oriented transcription configuration and language handling

The committed history for that work is mainly concentrated in `4908a1f` and `7576f25`, with additional carry-forward edits currently present as uncommitted work in the OpenOats tree.
