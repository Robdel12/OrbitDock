# OrbitDock Voice Control Roadmap

> Goal: Ship fluid, local-first voice interaction for OrbitDock, starting with excellent dictation in the conversation view and evolving to full voice control across the app.
>
> This plan is phased so each stage is shippable on its own and reduces risk for the next stage.

## Product Goal

Build a voice experience that feels fast, reliable, and safe:
- Great dictation quality for normal prompts in the Codex conversation composer.
- Voice commands for common actions (send, interrupt, resume, navigate).
- Optional hands-free control with global hotkey and low-friction command flow.

## Constraints and Principles

- Local-first by default. No cloud dependency required for core voice flows.
- Reuse existing action paths (`sendMessage`, `interruptSession`, `resumeSession`) rather than creating parallel behavior.
- Keep command safety explicit. Destructive actions require confirmation.
- Prefer deterministic command parsing over opaque LLM intent parsing in early phases.
- Start push-to-talk first. Always-listening comes later behind a feature flag.

## Recommendation Snapshot

- STT engine: `whisper.cpp` (MIT license) with Metal acceleration on Apple Silicon.
- Audio capture: `AVAudioEngine` with 16 kHz mono PCM pipeline.
- Dictation UX: push-to-talk, live partial transcript, final text inserted into composer.
- Intent UX: explicit command mode, confidence threshold, visible confirmation before execution.

## Current State

What already exists and can be reused:

- Composer and send flow: `CommandCenter/CommandCenter/Views/Codex/CodexInputBar.swift`
- Session actions:
  - `CommandCenter/CommandCenter/Services/Server/ServerAppState.swift:469`
  - `CommandCenter/CommandCenter/Services/Server/ServerAppState.swift:547`
  - `CommandCenter/CommandCenter/Services/Server/ServerAppState.swift:559`
- Session selection and navigation: `CommandCenter/CommandCenter/ContentView.swift`
- Command palette surface for reusable intents: `CommandCenter/CommandCenter/Views/QuickSwitcher.swift`
- Settings surface for user toggles: `CommandCenter/CommandCenter/Views/SettingsView.swift`

Gaps to fill:

- No microphone permission string in `Info.plist`.
- No voice services, no audio capture pipeline, no STT model management.
- No voice-specific settings, overlays, confidence states, or command safety policy.

## Target Architecture

### New modules

- `VoiceCaptureService`
  - Owns mic permission checks and audio capture lifecycle.
  - Produces PCM chunks from `AVAudioEngine`.
- `SpeechToTextEngine` protocol
  - `start()`, `stop()`, `appendAudio(_:)`, callback for partial/final transcript.
  - Enables swapping engine implementations without touching UI.
- `WhisperCppEngine`
  - Wraps local whisper inference.
  - Supports model selection and language hints.
- `VoiceIntentParser`
  - Deterministic parser from transcript text -> `VoiceIntent`.
  - Handles synonyms and confidence heuristics.
- `VoiceCommandRouter`
  - Maps `VoiceIntent` to existing app actions and navigation callbacks.
  - Applies confirmation policy for risky commands.
- `VoiceSettingsStore`
  - `AppStorage` backed settings and model profile.

### Suggested file layout

- `CommandCenter/CommandCenter/Services/Voice/VoiceCaptureService.swift`
- `CommandCenter/CommandCenter/Services/Voice/SpeechToTextEngine.swift`
- `CommandCenter/CommandCenter/Services/Voice/WhisperCppEngine.swift`
- `CommandCenter/CommandCenter/Services/Voice/VoiceIntentParser.swift`
- `CommandCenter/CommandCenter/Services/Voice/VoiceCommandRouter.swift`
- `CommandCenter/CommandCenter/Services/Voice/VoiceSettingsStore.swift`
- `CommandCenter/CommandCenter/Views/Codex/VoiceControlButton.swift`
- `CommandCenter/CommandCenter/Views/Codex/VoiceFeedbackStrip.swift`

## Command Taxonomy

### Safe commands (no confirmation)

- "send"
- "interrupt"
- "resume session"
- "open dashboard"
- "open quick switcher"
- "focus terminal"
- "show sidebar" / "hide sidebar"

### Risky commands (require confirmation)

- "end session"
- "close session"
- "delete approval history" (if added later)

### Dictation mode commands (phase 2+)

- "new line"
- "send now"
- "clear draft"
- "undo last sentence"

## Phase Plan

## Phase 1: High-Quality Dictation in Conversation View

### Objective

Make dictation in the Codex composer good enough to replace typing for normal prompts.

### In scope

- Push-to-talk mic button in `CodexInputBar`.
- Local transcription using whisper engine.
- Partial transcript preview while speaking.
- Final transcript inserted at cursor in message input.
- "Tap to retry" for failed transcription.
- Voice settings:
  - enable/disable dictation
  - model profile (`fast`, `balanced`, `accurate`)
  - language hint (`auto` or `en`)
- Add `NSMicrophoneUsageDescription` in `Info.plist`.

### Out of scope

- Global hotkeys.
- Voice commands beyond optional "send now".
- Always-listening mode.

### Acceptance criteria

- User can dictate text into active Codex composer with no network dependency.
- 95th percentile phrase latency under 1.8s for short prompts on Apple Silicon (M1+ baseline).
- Dictation cancel/stop never sends text automatically.
- User can edit dictated text before sending.
- No regressions to existing typed message flow.

### Estimated effort

- 1.5 to 2.5 weeks (single engineer).

### Ticket slices

- `P1-T1` Voice service scaffolding and mic permission flow.
- `P1-T2` Whisper engine integration and model profile switching.
- `P1-T3` Composer integration (mic button, partial/final transcript UX).
- `P1-T4` Settings tab updates and persistence.
- `P1-T5` Unit/integration tests and performance smoke script.

## Phase 2: In-View Voice Commands (Intent Routing)

### Objective

Enable command-based control while a session is open, without requiring mouse or keyboard for core actions.

### In scope

- Explicit command mode toggle in session view.
- Intent parser for core commands and synonyms.
- Router that reuses existing action methods:
  - `sendMessage`
  - `interruptSession`
  - `resumeSession`
  - navigation callbacks from `ContentView`
- Safety confirmation UI for risky commands.
- Feedback strip:
  - recognized text
  - matched command
  - execution status

### Out of scope

- Always-listening.
- Cross-window global commands.
- Natural language free-form reasoning for command interpretation.

### Acceptance criteria

- Common commands execute correctly with no UI desync.
- False-positive risky command executions are zero in validation scenarios.
- Unknown transcript defaults to dictation/no-op, not accidental command execution.
- Voice command path maintains current session context correctly.

### Estimated effort

- 2 to 3 weeks (single engineer).

### Ticket slices

- `P2-T1` Deterministic parser + confidence thresholds.
- `P2-T2` Command router and confirmation policy.
- `P2-T3` Session-level command mode UI + feedback strip.
- `P2-T4` Navigation/action integration in `ContentView` and `SessionDetailView`.
- `P2-T5` End-to-end tests for command safety and session targeting.

## Phase 3: Fluid Full Voice Control

### Objective

Deliver a low-friction voice workflow that feels hands-free for regular use.

### In scope

- Global push-to-talk hotkey (works from any OrbitDock view).
- Optional always-listening mode behind feature flag.
- Voice session targeting:
  - "switch to <session name>"
  - "select latest waiting session"
- Multi-step command support:
  - "switch to API session, then interrupt"
  - "open quick switcher and search billing"
- Voice accessibility polish:
  - audible/visual listening indicator
  - graceful fallback when mic unavailable

### Out of scope

- Text-to-speech responses.
- Wake-word training/custom model fine-tuning.
- External automation outside OrbitDock process boundaries.

### Acceptance criteria

- User can complete core workflow (navigate, dictate, send, interrupt, resume) by voice only.
- Global hotkey round-trip from key press to listening state under 200ms.
- Always-listening mode remains opt-in and disabled by default.
- User can disable voice features globally in one setting.

### Estimated effort

- 3 to 4 weeks (single engineer).

### Ticket slices

- `P3-T1` Global shortcut manager and app-wide voice coordinator.
- `P3-T2` Session targeting and disambiguation logic.
- `P3-T3` Multi-step command execution model.
- `P3-T4` Always-listening feature flag + safety guardrails.
- `P3-T5` QA hardening, thermal/perf checks, release readiness.

## Cross-Phase Technical Work

## Model Management

- Store models under `~/.orbitdock/models/whisper/`.
- First-run model bootstrap flow with progress UI.
- Keep default model lightweight; allow upgrade to higher accuracy profile.
- Verify license attribution in app docs and settings.

## Reliability and Safety

- Command execution policy table:
  - `auto_execute`
  - `confirm_before_execute`
  - `never_execute_by_voice`
- Debounce duplicate intent executions from repeated transcript finalization.
- Centralized voice error types (permission denied, model missing, decode failure).

## Logging and Diagnostics

- Add voice log category to app logger output:
  - mic start/stop
  - transcription latency
  - command parse result
  - command execution outcome
- Keep sensitive transcript logging opt-in or redacted by default.

## Testing Strategy

### Unit tests

- Intent parser with deterministic command fixtures.
- Command router policy decisions.
- Transcript-to-message insertion logic.

### Integration tests

- Session action routing for send/interrupt/resume.
- Mic permission states and fallbacks.
- Settings persistence and model profile changes.

### Manual smoke matrix

- Apple Silicon classes: M1, M2/M3, M4 where available.
- Quiet room vs moderate background noise.
- Short prompts vs long prompts with code/file names.

## Risks and Mitigations

- Latency too high on weaker hardware.
  - Mitigation: default to `fast` model profile and expose quick profile switching.
- False command triggers in dictation.
  - Mitigation: explicit command mode in phase 2, confidence gating, confirmation policy.
- Thermal load during long sessions.
  - Mitigation: cap continuous inference window, provide quick pause, measure in QA.
- Model download friction.
  - Mitigation: clear first-run UX and fallback to dictation-disabled state with guided setup.

## Delivery Timeline (Single Engineer)

- Phase 1: Weeks 1-2
- Phase 2: Weeks 3-5
- Phase 3: Weeks 6-9
- Buffer for polish/release hardening: 1 week

Total expected: 7 to 10 weeks to reach stable phase 3.

## Go/No-Go Gates

- Gate A (after Phase 1): Dictation quality and latency are good enough for daily prompt entry.
- Gate B (after Phase 2): Command safety is proven, especially for risky actions.
- Gate C (after Phase 3): Voice-only workflow is reliable across primary user journeys.

If a gate fails, stop expansion and harden the current phase before moving forward.

## Next Actions

1. Approve this roadmap and lock phase boundaries.
2. Create phase tickets using `plans/phase-ticket-template.md`:
   - `P1-T1` through `P1-T5`
   - `P2-T1` through `P2-T5`
   - `P3-T1` through `P3-T5`
3. Build a 2-day spike for `whisper.cpp` integration and benchmark latency on your primary machine.
4. Start Phase 1 implementation behind a `voiceDictationEnabled` feature flag.
