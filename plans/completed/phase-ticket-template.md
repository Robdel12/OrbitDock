# Phase Ticket Template

Use this template for any phase in `plans/agent-workbench-ux-plan.md` (or related roadmap work).

Treat plans as directional, not absolute. This ticket must capture the current reality before implementation starts.

## Ticket Metadata

- Phase:
- Ticket title:
- Owner:
- Collaborators:
- Status: `Not Started` | `In Progress` | `In Review` | `Done`
- Last updated:
- Links:
- Related docs:
- Related issues/PRs:

## Objective

What outcome should this ticket achieve?

## Scope

### In scope
- [ ]
- [ ]

### Out of scope
- [ ]
- [ ]

## Preflight (Required)

Complete before implementation.

- [ ] Re-validated scope against current app state and in-flight changes.
- [ ] Reviewed existing patterns in target files before introducing new abstractions.
- [ ] Confirmed dependencies and sequencing for this phase.
- [ ] Documented deltas between plan and current reality.
- [ ] Restated acceptance criteria in implementation terms.
- [ ] Defined a minimal verification plan (unit/integration/UI smoke).

### Research Notes

Summarize what you verified and what changed since the original plan.

- Current reality:
- Key constraints:
- Risks discovered:

### Plan Deltas

`Plan says X` -> `Current reality is Y` -> `Adjusted approach`

- 

## UX + Interaction Spec

### Primary user flow

List the intended start-to-finish interaction.

1. 
2. 
3. 

### Edge cases

- 
- 

### States

- Empty:
- Loading:
- Success:
- Error:
- Partial/paused:

## Implementation Plan

### Target files/surfaces

- 
- 
- 

### Data/state changes

- New models:
- Updated models:
- Persistence changes:
- Migration needed: `Yes/No`

### Execution steps

1. 
2. 
3. 

## Role Deliverables

### Designer output

- [ ] Interaction flow and component states.
- [ ] Visual direction aligned to current design system.
- [ ] Accessibility notes (keyboard, contrast, reduced motion).

### Developer output

- [ ] Implementation merged and working end-to-end.
- [ ] Instrumentation hooks added (if phase requires metrics).
- [ ] No regressions in adjacent workflows.

### LLM output

- [ ] Implementation checklist completed.
- [ ] Test plan executed and results documented.
- [ ] Review notes mapped to acceptance criteria.

## Acceptance Criteria (Definition of Done)

Copy from the phase and refine for this slice.

- [ ]
- [ ]
- [ ]

## Verification Plan

### Automated checks

- [ ] Unit:
- [ ] Integration:
- [ ] UI smoke:

### Manual checks

1. 
2. 
3. 

### Demo script

Provide a short walkthrough proving the objective is met.

1. 
2. 
3. 

## Rollout + Follow-ups

### Rollout strategy

- Feature flag needed: `Yes/No`
- Gradual rollout needed: `Yes/No`
- Rollback plan:

### Deferred work

Explicitly list anything intentionally deferred.

- 
- 

## Completion Summary

Fill this in when closing the ticket.

- What shipped:
- What changed from initial scope:
- Validation results:
- Remaining risks:
