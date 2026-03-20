# IMPORTANCE

This document explains the core parts of this app that matter if another agent needs to copy the working behavior into a different system.

It is not a changelog. It is a transfer guide.

The goal is to preserve the product behavior, not to copy every file mechanically.

## What This App Actually Is

At its core, this app does five things:

1. detects that a meeting is happening
2. automatically starts a transcription session
3. captures live transcript data and suggestion context during the session
4. optionally saves the raw microphone recording
5. automatically finalizes, stores, and exposes the session after the meeting ends

Everything else is secondary.

If another agent is porting this app to a new codebase, they should treat the following as first-class product requirements:

- meeting auto-detection
- auto-start on detected meeting
- auto-stop on detected meeting end or silence timeout
- transcript persistence
- raw recording persistence
- remote transcription support for Groq and ZAI
- language-aware handling for multilingual and Chinese-heavy use cases

## Highest-Importance Rule

Do not port this app by copying isolated UI files.

The real behavior lives in the central runtime, coordinator, settings, and transcription pipeline. If those pieces are not reproduced together, the app will look similar but not behave correctly.

The most important rule is:

- the customization must live in the primary app flow, not in side scripts, one-off utilities, or fork-only codepaths

In this repo, that means the custom behavior was made part of the upstream architecture, especially:

- `OpenOats/Sources/OpenOats/App/AppCoordinator.swift`
- `OpenOats/Sources/OpenOats/Settings/AppSettings.swift`
- `OpenOats/Sources/OpenOats/Transcription/TranscriptionEngine.swift`
- `OpenOats/Sources/OpenOats/Views/ContentView.swift`

## Core System Map

### 1. Runtime Bootstrap

Start here:

- `OpenOats/Sources/OpenOats/App/AppRuntime.swift`
- `OpenOats/Sources/OpenOats/App/OpenOatsApp.swift`

Why this matters:

- this is where the app creates shared services
- this is where the app chooses storage locations
- this is where the app wires the coordinator, settings, engines, logger, recorder, and UI together

If another agent misses this layer, they will end up with disconnected objects and duplicated state.

What must be reproduced:

- one shared `AppCoordinator`
- one shared `AppSettings`
- one `TranscriptionEngine`
- one `TranscriptLogger`
- one `TranscriptRefinementEngine`
- one `AudioRecorder`
- one `KnowledgeBase`
- one `SuggestionEngine`

Important design point:

- service creation happens once and the services are injected into the coordinator and views

### 2. Settings Are Part of the Product

Start here:

- `OpenOats/Sources/OpenOats/Settings/AppSettings.swift`
- `OpenOats/Sources/OpenOats/Views/SettingsView.swift`

Why this matters:

- the app is driven by persisted settings
- the custom features only work correctly if these settings exist and are loaded early

Settings that are core to the product:

- `meetingAutoDetectEnabled`
- `saveAudioRecording`
- `transcriptionModel`
- `transcriptionLocale`
- `transcriptionCustomVocabulary`
- `groqApiKey`
- `zaiApiKey`
- `inputDeviceID`
- `showLiveTranscript`
- `enableTranscriptRefinement`
- `silenceTimeoutMinutes`
- `customMeetingAppBundleIDs`

Important rule for any port:

- the settings model must own the source of truth for feature flags and credentials
- API keys should be stored in the platform secret store, not plain text config if avoidable
- old key migrations matter because users may already have prior defaults like `autoDetectMeetings`

### 3. The Coordinator Is The Brain

Start here:

- `OpenOats/Sources/OpenOats/App/AppCoordinator.swift`
- `OpenOats/Sources/OpenOats/Meeting/MeetingState.swift`
- `OpenOats/Sources/OpenOats/Meeting/MeetingTypes.swift`

Why this matters:

- this is the session lifecycle owner
- this is where meeting detection becomes recording behavior
- this is where start, stop, finalization, and history refresh happen

This file is the single most important file in the app.

If another agent only ports one thing carefully, it should be this subsystem.

Responsibilities owned here:

- state transitions for idle, recording, and finalization
- start transcription when the user starts manually or detection triggers
- enable raw recording when configured
- finalize transcript and recordings on stop
- backfill refined transcript text before closing the session
- maintain session history
- manage meeting detector lifecycle
- apply auto-start behavior on detection
- apply auto-stop behavior on meeting end
- apply silence timeout behavior for detected sessions

Most important customization retained here:

- upstream detection originally supported a prompt-driven acceptance path
- this fork changes that central path so meeting detection starts the session automatically

That behavior lives in:

- `handleMeetingDetected(app:)`
- `startDetectedSession(app:)`
- `handleMeetingEnded()`

If a port does not preserve those methods conceptually, it has lost the fork’s core behavior.

### 4. Meeting Detection Is A Product Feature, Not A Nice-To-Have

Start here:

- `OpenOats/Sources/OpenOats/Meeting/MeetingDetector.swift`
- `OpenOats/Sources/OpenOats/Meeting/MeetingTypes.swift`
- `OpenOats/Sources/OpenOats/Resources/meeting-apps.json`

Why this matters:

- the app is supposed to work without asking the user to click start every time
- meeting detection is what makes the app ambient and useful

What the port must preserve:

- detect relevant meeting apps and microphone activity
- feed detection events into the coordinator
- allow immediate evaluation at launch so already-running meetings are caught
- support auto-stop when the app exits or silence timeout is reached

Important product behavior:

- false positives are controlled by dismissal memory and configurable app bundle IDs
- detected sessions are different from manual sessions because they can auto-stop

### 5. Transcription Engine Is The Execution Layer

Start here:

- `OpenOats/Sources/OpenOats/Transcription/TranscriptionEngine.swift`
- `OpenOats/Sources/OpenOats/Transcription/TranscriptionBackend.swift`
- `OpenOats/Sources/OpenOats/Transcription/StreamingTranscriber.swift`

Why this matters:

- this is where live audio actually becomes transcript text
- this is where local and remote transcription options are abstracted behind one model selection flow

What must be preserved:

- dual-stream handling for microphone and system audio
- backend abstraction so different ASR models can be swapped cleanly
- model preparation and readiness checks
- audio recorder taps during live capture
- input device switching and restart behavior
- locale and vocabulary plumbing into the selected backend

Core design that must survive any port:

- the UI should choose a transcription model
- the settings should persist that model
- the engine should instantiate the correct backend from settings
- the coordinator should be the owner that tells the engine when to start and stop

### 6. Groq And ZAI Are Real First-Class Backends

Start here:

- `OpenOats/Sources/OpenOats/Transcription/RemoteWhisperBackend.swift`
- `OpenOats/Sources/OpenOats/Transcription/WhisperAPIClient.swift`
- `OpenOats/Sources/OpenOats/Settings/AppSettings.swift`

Why this matters:

- these are not hacks
- they are official selectable transcription models in this fork

What must be preserved:

- `TranscriptionModel.groq`
- `TranscriptionModel.zai`
- explicit API key fields
- explicit language support
- remote API backend creation through the same backend factory path as local models

Important implementation details:

- Groq uses an OpenAI-compatible Whisper transcription endpoint
- ZAI uses the ZhipuAI audio transcription endpoint
- both are fed 16 kHz mono WAV encoded from float samples
- the language field is optional and intentionally normalized to a compact language code

Chinese-focused importance:

- ZAI exists because multilingual and Chinese-heavy transcription quality was a real fork requirement
- the language hint path is not optional if another agent wants to preserve that use case

### 7. Raw Recording Is Core

Start here:

- `OpenOats/Sources/OpenOats/Audio/AudioRecorder.swift`
- `OpenOats/Sources/OpenOats/Views/RecordingsView.swift`
- `OpenOats/Sources/OpenOats/Views/ContentView.swift`

Why this matters:

- this fork intentionally preserves local raw audio files
- that is important for debugging, auditing, and recovering from transcription issues

What must be preserved:

- per-session raw microphone recording
- storage under the notes/documents directory
- a stable `recordings/` subdirectory
- ability to browse recordings from the app

Important current behavior:

- recordings are written as `.caf`
- raw recording is tied to the session lifecycle, not to a separate manual export step

This should be treated as a product feature, not just a debug artifact.

### 8. ContentView Is Where The App Actually Gets Wired Up

Start here:

- `OpenOats/Sources/OpenOats/Views/ContentView.swift`

Why this matters:

- this file initializes services through the runtime
- this file assigns those services into the coordinator
- this file starts detection on launch
- this file turns transcript updates into persisted records and suggestions

This file is not important because of the visual layout.

It is important because of these lifecycle hooks:

- create services once through `runtime.makeServices(...)`
- assign `transcriptionEngine`, `transcriptLogger`, `refinementEngine`, and `audioRecorder` into the coordinator
- call `setupMeetingDetection(settings:)` when detection is enabled
- call `evaluateImmediate()` after detection setup
- call `coordinator.noteUtterance()` when utterances arrive
- append transcript records into `SessionStore`
- feed THEM utterances into `SuggestionEngine`
- update logger and recorder directories when notes path changes

If another agent ports this app into a different UI framework, these lifecycle hookups still need to exist somewhere.

### 9. Persistence Is Part of Correctness

Start here:

- `OpenOats/Sources/OpenOats/Storage/SessionStore.swift`
- `OpenOats/Sources/OpenOats/Storage/TranscriptLogger.swift`
- `OpenOats/Sources/OpenOats/Models/TranscriptStore.swift`

Why this matters:

- the product is not just live transcription
- it is also session history, notes generation inputs, and durable records

What must be preserved:

- in-memory transcript state for live UI
- structured session records persisted during the session
- plain text transcript logging
- a final session index after completion
- backfill of refined text before final close

If another agent omits the finalization and persistence flow, they will lose important post-meeting behavior even if the live transcript works.

## Porting Priority Order

If an agent is rebuilding the app elsewhere, this is the correct order:

1. Port `AppSettings` and persistent configuration.
2. Port `AppCoordinator` and the meeting/session state machine.
3. Port `TranscriptionBackend` and `TranscriptionEngine`.
4. Port `WhisperAPIClient` and `RemoteWhisperBackend` for Groq and ZAI.
5. Port `MeetingDetector` and feed its events into the coordinator.
6. Port `SessionStore`, `TranscriptStore`, and `TranscriptLogger`.
7. Port `AudioRecorder`.
8. Rebuild the minimal UI needed to start, stop, view transcript, and browse recordings.

This order matters because the UI is replaceable, but the lifecycle and pipeline logic are not.

## Minimal Viable Port

If another agent needs the smallest useful subset, they should still preserve these parts:

- `AppSettings`
- `AppCoordinator`
- `MeetingDetector`
- `TranscriptionEngine`
- `TranscriptionBackend`
- `RemoteWhisperBackend`
- `WhisperAPIClient`
- `SessionStore`
- `TranscriptStore`
- `TranscriptLogger`
- `AudioRecorder`

That is the true minimum for preserving the product’s behavior.

## Things That Are Nice But Secondary

These matter, but they are not the core transfer target:

- menu bar extra and dock menu in `OpenOatsApp.swift`
- deeplinks in `OpenOatsDeepLink.swift`
- onboarding and consent screens
- UI smoke test harness
- Homebrew and packaging workflows
- stylistic UI details

An agent can defer those without losing the core app logic.

## Non-Negotiable Product Behaviors

Any port should be considered incomplete if it loses any of these:

- detected meetings do not auto-start
- detected sessions do not auto-stop
- Groq and ZAI are no longer selectable through normal settings
- language input for remote transcription disappears
- raw recording is no longer tied to the session lifecycle
- session data no longer persists after the live view ends

## Practical Guidance For Another Agent

When copying this app into another system:

- copy behavior, not just file names
- keep one coordinator as the session owner
- keep one settings model as the source of truth
- keep transcription backends behind one protocol
- keep detection events flowing into the coordinator, not directly into UI components
- keep raw recording attached to the same start and stop flow as transcription
- keep Groq and ZAI inside the normal model-selection path, not as special debug options

The easiest way to fail is to split the logic across too many places.

The easiest way to succeed is to preserve the current ownership model:

- settings decide configuration
- detector emits meeting signals
- coordinator owns session behavior
- engine performs transcription
- stores persist results
- UI only drives and reflects state

## Bottom Line

The most important parts of this app are not the screen layout.

They are:

- the coordinator-based meeting lifecycle
- the detector-to-auto-start flow
- the backend-based transcription architecture
- the Groq and ZAI remote transcription path
- the raw recording lifecycle
- the persistence and finalization path

If another agent preserves those pieces faithfully, they can rebuild the app in a different environment without losing what actually makes this fork valuable.
