# New Session Starport Launchpad Plan (Creative Simplification Pass)

Date: 2026-04-02  
Owner: OrbitDock Native Team  
Status: Ready for implementation

## 1. Problem And Intent
- Problem: The sheet feels like stacked controls, not a designed launch flow.
- Intent: Make session creation feel like a compact command deck with clear hierarchy and playful confidence.
- Outcome: Users should scan once, choose quickly, and trust the launch action.

## 2. Experience North Star
- Narrative spine: `Pilot -> Target -> Flight Plan -> Ignition`.
- Emotional target: calm, competent, slightly whimsical.
- Success feel:
  - Quick mode feels like “launch now.”
  - Full mode feels like “configure with confidence.”
  - Both modes still behave as one shared system.

## 3. Non-Negotiable Layout Contract

| Zone | Purpose | Content | Priority |
|---|---|---|---|
| Header | Orientation + escape | Title, close | Low visual weight |
| Workflow Card | Mode framing | Full/Quick segmented control + one-line explanation | Medium |
| Pilot Card | Engine selection | Provider toggle, server/runtime picker, connection status | High |
| Target Card | Where to launch | Recent first, browse fallback, optional Finder action | Highest in Quick |
| Flight Plan Card | Final sanity check | Session behavior summary row | Medium |
| Ignition Footer | Commitment | Cancel + Launch + launch sentence | Primary action anchor |

Guardrails:
- One accent color story per zone (no competing highlights).
- Section titles are short, all-caps labels with supportive one-line descriptions.
- No floating controls detached from the content stack.

## 4. Architecture And File Ownership
- `OrbitDockNative/OrbitDock/Views/NewSession/NewSessionSheet.swift`
  - Own orchestration and mode-specific composition.
  - Keep one state source: `NewSessionModel`.
- `OrbitDockNative/OrbitDock/Views/NewSession/NewSessionFormSections.swift`
  - Own macro layout containers and section ordering.
  - Encode spacing rhythm and card grouping.
- `OrbitDockNative/OrbitDock/Views/NewSession/NewSessionShellSections.swift`
  - Own reusable visual components, tokens, and micro-interaction styling.
  - Keep whimsy token-driven and restrained.

## 5. Mode Behavior Contract

| Behavior | Full | Quick |
|---|---|---|
| Core controls | Fully visible | Condensed, progressive disclosure |
| Target selection | Flexible workflow | Recent-first with browse fallback |
| Launch path | Explicit confirmation | Fast path (`<= 2` interactions from recent target) |
| Data model | `NewSessionModel` | `NewSessionModel` (same fields, different density) |

## 6. Execution Phases

### Phase 1: Layout Spine
Goal: Lock hierarchy before visual polish.
- [ ] Integrate workflow mode card into primary content flow.
- [ ] Re-stack sections into the fixed narrative order.
- [ ] Stabilize footer as a persistent ignition bar.

### Phase 2: Quick Launchpad
Goal: Make Quick mode distinct and decisive.
- [ ] Prioritize recent targets with clear first-action affordance.
- [ ] Demote browse/finder to secondary actions.
- [ ] Add concise launch sentence near CTA for confidence.

### Phase 3: Whimsy And Hardening
Goal: Add delight without losing clarity.
- [ ] Apply subtle motion cues (orbital accent, ignition pulse) only where intent is clear.
- [ ] Run token audit against `docs/design-system.md`.
- [ ] Validate compile and manual launch flows.

## 7. Parallel Worker Plan

| Lane | Scope | Files | Can Start | Merge Order |
|---|---|---|---|---|
| A: Structure | Layout hierarchy and containers | `NewSessionFormSections.swift` | Immediately | 1 |
| B: Orchestration | Mode composition and narrative flow | `NewSessionSheet.swift` | Immediately | 2 |
| C: Visual System | Cards, chips, micro-motion, shell polish | `NewSessionShellSections.swift` | After A baseline | 3 |
| D: Verification | Build + manual QA + screenshots | N/A | After A+B+C | 4 |

Coordination rules:
- Do not fork behavior logic between modes.
- Keep shared helper names stable across lanes.
- Never introduce new design tokens unless blocked.

## 8. Acceptance Checklist
- [ ] Visual hierarchy reads in under 3 seconds.
- [ ] Quick mode launch path hits `<= 2` interactions for recent target.
- [ ] Full mode preserves complete configuration capability.
- [ ] Mode switching does not unexpectedly drop selected target.
- [ ] No token drift from `docs/design-system.md`.
- [ ] macOS build succeeds:
  - `xcodebuild -project OrbitDockNative/OrbitDock.xcodeproj -scheme OrbitDock -destination 'platform=macOS' build`

## 9. Risks, Rollback, Next Step
- Risks:
  - Over-decorating can blur hierarchy.
  - Parallel edits can introduce layout inconsistency.
  - Quick and Full can drift behaviorally if orchestration is split.
- Mitigations:
  - Finish Phase 1 before visual amplification.
  - Merge in lane order and run screenshot checkpoints each merge.
  - Validate both modes against the same launch outcomes.
- Rollback scope:
  - Revert only:
    - `NewSessionSheet.swift`
    - `NewSessionFormSections.swift`
    - `NewSessionShellSections.swift`
- Immediate next step:
  - [ ] Start Phase 1 patch (Lane A + Lane B coordination kickoff).
