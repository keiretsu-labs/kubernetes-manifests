---
name: Testing Strategies
description: >
  Identify missing test coverage, design test cases, recommend test strategies.
  Covers unit, integration, and end-to-end testing patterns with coverage
  gap analysis.

  Use when: You need to identify missing test coverage, design test cases
  for new or existing code, choose a testing approach, or validate that a
  fix includes proper tests.

  Don't use when: Reviewing code for correctness/security (use code-review).
  Don't use for debugging failures (use debug-troubleshooting). Don't use
  for validating Kubernetes manifests (use manifest-lint). Don't use for
  architecture discussions (use architecture-design).

  Outputs: Test coverage gap analysis, test case designs with expected
  behavior, or testing strategy recommendations.
requires: []
---

# Testing Strategies

## Routing

### Use This Skill When
- Identifying gaps in test coverage for a codebase
- Designing test cases for new features or bug fixes
- Choosing between unit, integration, and e2e testing approaches
- Validating that a PR includes adequate tests
- Someone asks "what tests do we need?" or "how should we test this?"

### Don't Use This Skill When
- Reviewing code for bugs or security issues → use **code-review**
- Debugging a test failure (the test exists but fails) → use **debug-troubleshooting**
- Validating YAML/JSON manifests → use **manifest-lint**
- Making architectural decisions about testability → use **architecture-design**
- Running infrastructure validation commands → use **manifest-lint** or **config-audit**

## Test Coverage Analysis

### Identify gaps

```bash
# Check existing tests
find . -name "*_test.go" -o -name "*.test.ts" -o -name "test_*.py" | wc -l

# Check test commands
grep -r "test" Makefile package.json 2>/dev/null
```

### Priority order for new tests

1. **Critical paths** — Auth, payments, data mutations
2. **Edge cases** — Nil inputs, empty collections, boundary values
3. **Error paths** — Network failures, invalid input, timeouts
4. **Integration points** — API boundaries, database queries, external services
5. **Regression** — Any bug that was found should get a test

## Test Design Principles

- **One assertion per test** — Tests should verify one behavior
- **Descriptive names** — `TestUserLogin_WithExpiredToken_ReturnsUnauthorized`
- **Arrange-Act-Assert** — Clear setup, action, verification
- **No test interdependence** — Each test runs independently
- **Test behavior, not implementation** — Don't test private methods directly

## Test Case Template

```markdown
### Test: <descriptive name>

**Scenario:** <what situation is being tested>
**Given:** <preconditions>
**When:** <action taken>
**Then:** <expected result>

**Edge cases:**
- <variation 1>
- <variation 2>
```

## Infrastructure Testing

For Kubernetes manifests:

```bash
# Syntax validation
jq . kustomization/openclaw.json > /dev/null
yq . kustomization/deployment.yaml > /dev/null

# Kustomize render
kustomize build kustomization/ > /dev/null

# Dry-run apply
kustomize build kustomization/ | kubectl apply --dry-run=client -f -
```

## Edge Cases

- **No existing tests:** Start with critical paths, don't try to add 100% coverage at once
- **Flaky tests:** Investigate timing, external dependencies, shared state — don't just re-run
- **Test infrastructure vs test code:** Infrastructure validation (kustomize build) is different from application unit tests — don't mix them
