---
name: Architecture Design
description: >
  Evaluate system design, recommend refactors, review boundaries and coupling.

  Use when: Evaluating a new feature design before implementation, choosing
  between implementation approaches, reviewing component boundaries, or
  creating architectural decision records. Also use when refactoring
  existing code for maintainability.

  Don't use when: Reviewing a specific PR's code changes (use code-review).
  Don't use for debugging runtime failures (use debug-troubleshooting).
  Don't use for Kubernetes manifest or infrastructure design (use the
  appropriate ops skill). Don't use for writing tests (use
  testing-strategies).

  Outputs: Architecture analysis document with current state assessment,
  recommendations with tradeoffs, and incremental migration steps.
requires: []
---

# Architecture Design

## Routing

### Use This Skill When
- Evaluating a new feature design before implementation
- Choosing between two or more implementation approaches
- Refactoring existing code to improve maintainability
- Reviewing system boundaries and interfaces
- Creating an ADR (Architectural Decision Record)
- Someone asks "how should we build this?" or "should we refactor this?"

### Don't Use This Skill When
- Reviewing a specific PR diff → use **code-review**
- Debugging a runtime error → use **debug-troubleshooting**
- Designing Kubernetes manifests or Flux config → use ops skills
- Writing or designing test cases → use **testing-strategies**
- The question is about deployment process → use **gitops-deploy**

## Analysis Framework

### 1. Understand Current State

```bash
# Clone and explore
git clone https://github.com/rajsinghtech/<repo>.git /tmp/arch-review
cd /tmp/arch-review

# File structure
find . -type f -name "*.go" -o -name "*.ts" -o -name "*.py" | head -50

# Dependencies
cat go.mod 2>/dev/null || cat package.json 2>/dev/null || cat requirements.txt 2>/dev/null
```

### 2. Evaluate

- **Separation of concerns** — Does each module have a clear, single responsibility?
- **Dependencies** — Are dependency directions clean? Circular dependencies?
- **Interfaces** — Are boundaries well-defined? Can components be tested independently?
- **Data flow** — How does data move through the system? Any unnecessary transformations?
- **Error handling** — Is it consistent? Do errors propagate with context?
- **Scalability** — What breaks first under load? What's the bottleneck?

### 3. Recommend

Provide recommendations with:
- **What** to change
- **Why** it improves the system
- **How** to migrate (incremental steps, not big-bang rewrites)
- **Tradeoffs** — what you gain vs what you give up

## Architecture Review Template

```markdown
## Architecture Review: <Component/System>

### Current State
<Overview of the current architecture, key components, and how they interact>

### Strengths
- <What's working well>
- <Good patterns in use>

### Concerns
| Concern | Severity | Impact |
|---------|----------|--------|
| <description> | High/Med/Low | <what breaks or degrades> |

### Recommendations

#### 1. <Recommendation Title>
- **What:** <specific change>
- **Why:** <benefit>
- **How:** <migration steps>
- **Tradeoff:** <what you gain vs lose>

### Decision
<Recommended approach and rationale>
```

## ADR (Architectural Decision Record) Template

```markdown
# ADR-<number>: <Title>

**Status:** Proposed | Accepted | Deprecated | Superseded
**Date:** <date>
**Deciders:** <who>

## Context
<What is the issue or question that needs a decision?>

## Decision
<What is the change that we're proposing/doing?>

## Consequences
### Positive
- <benefit>

### Negative
- <cost or risk>

### Neutral
- <observation>
```

## Edge Cases

- **Premature optimization:** If the system works and is maintainable, don't refactor for theoretical future scale
- **Brownfield vs greenfield:** Existing code has existing users — always consider migration cost
- **Cross-directory dependencies:** Changes spanning openclaw/ and cluster configs in the same monorepo should be coordinated in a single PR
