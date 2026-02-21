---
name: OpenSpec Workflow
description: >
  Spec-driven development workflow — proposals, requirements, design docs,
  task breakdowns, and implementation using the OpenSpec framework.

  Use when: Starting a new feature or change that needs planning, someone
  says "I want to build X", creating proposals or specs, breaking down
  requirements into tasks, or transitioning from planning to implementation.

  Don't use when: Debugging or troubleshooting (use appropriate troubleshooting skill).
  Don't use for Kubernetes manifest changes (use pr-workflow). Don't use
  for reviewing existing code (use code-review).

  Outputs: OpenSpec change folder with proposal.md, specs/, design.md,
  and tasks.md. Implementation follows directly from tasks.md.
requires: []
---

# OpenSpec Skill

Document templates and workflow patterns for spec-driven development.

## Routing

### Use This Skill When
- Starting a new feature or change that needs planning
- Someone says "I want to build X" or "let's add Y"
- Creating proposals, requirements, or design documents
- Breaking down a feature into implementable tasks
- Transitioning from planning to implementation
- Running `/opsx:new`, `/opsx:ff`, `/opsx:apply`, or `/opsx:archive`

### Don't Use This Skill When
- Debugging a runtime issue -> use the appropriate troubleshooting skill
- Changing Kubernetes manifests -> use **pr-workflow** (dyson)
- Reviewing a PR -> use **code-review**
- The task is small enough to just do without a spec -> skip planning

## Philosophy

OpenSpec is built on these principles:

```text
> fluid not rigid
> iterative not waterfall
> easy not complex
> built for brownfield not just greenfield
> scalable from personal projects to enterprises
```

Key insight: **Actions, not phases.** Commands are things you can do, not stages you're stuck in.

## Workflow Commands

### /opsx:new <change-name>

Creates a new change folder structure:

```
openspec/changes/<change-name>/
├── proposal.md          # Why we're doing this
├── specs/               # Requirements and scenarios
│   ├── requirements.md
│   └── scenarios.md
├── design.md            # Technical approach
├── tasks.md             # Implementation checklist
└── .state               # Current workflow state
```

**When to use:** Starting any new change, feature, or fix.

### /opsx:ff (fast-forward)

Generates all planning documents in sequence:

1. Creates `proposal.md` — captures the "why"
2. Creates `specs/` requirements and scenarios
3. Creates `design.md` — technical approach
4. Creates `tasks.md` — implementation breakdown
5. Sets state to "ready for implementation"

**When to use:** Requirements are clear enough to plan the full scope.

### /opsx:apply

Signals ready for implementation. Planning is complete; proceed with implementation from `tasks.md`.

**Context available:**
- Path to `tasks.md`
- Path to `specs/` for reference
- Path to `design.md` for technical context
- Any risks or gotchas discovered

**When to use:** Planning is complete and approved by Raj.

### /opsx:archive

Moves completed change to archive:

```
openspec/changes/archive/YYYY-MM-DD-<change-name>/
```

Updates any merged specs in the main documentation.

**When to use:** Implementation is complete and change is merged.

## Document Templates

### proposal.md

```markdown
# Proposal: <Change Title>

## Problem

What's the current situation? What problem are we solving?

## Solution

What are we proposing to do?

## Success Criteria

How do we know this worked?
- [ ] Criterion 1
- [ ] Criterion 2

## Alternatives Considered

| Alternative | Why Not Selected |
|-------------|------------------|
| Option A    | Reason it was rejected |
| Option B    | Reason it was rejected |

## Scope

### In Scope
- Thing 1
- Thing 2

### Out of Scope
- Thing that sounds related but isn't included
- Future enhancements

## Risks

| Risk | Mitigation |
|------|------------|
| Risk description | How we'll handle it |
```

### specs/requirements.md

```markdown
# Requirements: <Change Title>

## Functional Requirements

| ID | Requirement | Priority | Acceptance Criteria |
|----|-------------|----------|---------------------|
| FR-1 | System shall do X | Must | Can verify by... |
| FR-2 | System shall do Y | Should | Can verify by... |

## Non-Functional Requirements

| ID | Requirement | Target |
|----|-------------|--------|
| NFR-1 | Performance: operation completes within | 100ms |
| NFR-2 | Compatibility: works with | existing API |

## Constraints

- Must work with existing architecture
- Must not break backward compatibility
- Must follow existing patterns in codebase
```

### specs/scenarios.md

```markdown
# Scenarios: <Change Title>

## Happy Path

**Given** initial state
**When** user action
**Then** expected result

## Edge Cases

### Edge Case 1: <Description>

**Given** unusual but valid state
**When** user action
**Then** expected handling

### Edge Case 2: <Description>
...

## Error Scenarios

| Scenario | Trigger | Expected Behavior |
|----------|---------|-------------------|
| Invalid input | Malformed request | Return 400 with specific error |
| Dependency down | Service unavailable | Return 503, retry logic |
```

### design.md

```markdown
# Design: <Change Title>

## Overview

High-level approach: what components change and how.

## Architecture

[Diagram or description of component interactions]

### Component A

- Responsibility
- Interface changes
- Dependencies

### Component B

...

## Data Flow

1. Step 1
2. Step 2
3. Step 3

## Dependencies

| Dependency | What we need from it |
|------------|---------------------|
| Package X  | Version bump, new API |
| Service Y  | Endpoint available |

## Migration Plan

If this changes existing behavior:

1. Phase 1: Deploy X
2. Phase 2: Migrate Y
3. Phase 3: Clean up Z

## Testing Strategy

- Unit tests for: component A, component B
- Integration tests for: end-to-end flow
- Manual verification: specific scenario
```

### tasks.md

```markdown
# Tasks: <Change Title>

## Task Group 1: <Descriptive Name>

- [ ] 1.1 Task description
  - Notes: implementation context
  - Files: relevant files to modify
  - Tests: what to verify

- [ ] 1.2 Task description
  - Depends on: 1.1
  - Notes: implementation hints

## Task Group 2: <Descriptive Name>

- [ ] 2.1 Task description
  - Notes: specific considerations
  - Edge case: handle X

## Verification

- [ ] All acceptance criteria from proposal.md met
- [ ] All scenarios from specs/scenarios.md pass
- [ ] Code review completed
- [ ] Tests passing
```

## Pattern from Landlord

Landlord demonstrates spec-driven infrastructure patterns applicable to software:

1. **Declarative desired state** — specs say what should be, not how
2. **Workflow orchestration** — clear steps from spec to reality
3. **State reconciliation** — actual state vs desired state
4. **Pluggable backends** — designs that allow future flexibility

Apply to planning documents:
- `specs/` = declarative desired state (what the system should do)
- `tasks.md` = workflow orchestration (steps to get there)
- `design.md` = state reconciliation model (how we track progress)
- Implementation approach can vary based on context

## Working with Raj

**Typical flow:**

1. Raj says: "I want to add dark mode"
2. Leon asks: "Scope questions..."
3. Leon runs: `/opsx:new add-dark-mode`
4. Leon runs: `/opsx:ff` -> generates all docs
5. Raj reviews and approves
6. Leon runs: `/opsx:apply` -> proceeds with implementation
7. Leon implements from `tasks.md`
8. Leon runs: `/opsx:archive` when complete

**Brownfield considerations:**

- Always check existing patterns in codebase
- Note any migration steps in design.md
- Highlight compatibility concerns in risks
- Reference existing implementations when relevant

## Command Quick Reference

| Command | Creates/Updates | State After |
|---------|-----------------|-------------|
| `/opsx:new` | Change folder structure | proposal pending |
| `/opsx:ff` | proposal, specs, design, tasks | ready for implementation |
| `/opsx:apply` | Transitions to implementation | in progress |
| `/opsx:archive` | Archive folder | complete |

## Edge Cases

- **Scope creep during planning:** If requirements keep expanding, pause and re-scope with Raj before continuing
- **Brownfield conflicts:** If the proposed design conflicts with existing architecture, document the conflict in design.md and flag it
- **Multiple concurrent changes:** Each change gets its own folder — don't mix changes in the same spec

## Compaction Notes

For long planning sessions:
- `mkdir -p /tmp/outputs` before writing any artifacts
- Write each document (proposal, specs, design, tasks) to disk as you go
- The OpenSpec folder structure itself serves as persistent state — commit early
