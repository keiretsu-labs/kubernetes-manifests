# OpenClaw Workspace Refresh Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix config drift, harden the deployment, refresh all workspace content to reflect current model setup, add Ribak code-review skill, and migrate PVC to CephFS for RollingUpdate strategy.

**Architecture:** Four independent parallel tracks (Tasks 1–4) followed by one sequential cluster operation (Task 5). Each track produces a commit; Task 5 is a coordinated cluster operation.

**Tech Stack:** JSON (jq), YAML (yq/kustomize), Kubernetes, Flux, CephFS/Rook-Ceph

**Design doc:** `docs/plans/2026-02-20-workspace-refresh-design.md`

---

## Parallel Group A — Can run simultaneously (Tasks 1, 2, 3, 4)

---

### Task 1: Fix `kustomization/openclaw.json`

**Files:**
- Modify: `kustomization/openclaw.json`

**Step 1: Add `gateway.trustedProxies`**

In `kustomization/openclaw.json`, add `trustedProxies` to the `gateway` block.
Current:
```json
"gateway": {
  "port": 18789,
  "mode": "local",
  "bind": "lan",
  "auth": { ... },
  "controlUi": { ... }
}
```
After (double-dollar escaping for Flux):
```json
"gateway": {
  "port": 18789,
  "mode": "local",
  "bind": "lan",
  "trustedProxies": ["$${CLUSTER_POD_CIDR}", "$${CLUSTER_SERVICE_CIDR}"],
  "auth": { ... },
  "controlUi": { ... }
}
```

**Step 2: Fix Discord DM policy key**

Find the `channels.discord` block. It currently has:
```json
"dm": {
  "policy": "pairing"
}
```
Replace with:
```json
"dmPolicy": "pairing"
```
(Remove the entire `"dm": { ... }` block, add `"dmPolicy": "pairing"` at the same level as `"guilds"`)

**Step 3: Enable web search**

In the `tools.web.search` block, change:
```json
"search": {
  "enabled": false
}
```
to:
```json
"search": {
  "enabled": true
}
```

**Step 4: Validate**

```bash
jq . kustomization/openclaw.json > /dev/null && echo "JSON valid"
```

Expected: `JSON valid`

**Step 5: Run full validation**

```bash
bash scripts/validate-config.sh
```

Expected: All checks pass (no errors about gateway.bind, unescaped vars, etc.)

**Step 6: Commit**

```bash
git add kustomization/openclaw.json
git commit -m "config: add trustedProxies, fix dmPolicy, enable web search"
```

---

### Task 2: Harden `kustomization/deployment.yaml`

**Files:**
- Modify: `kustomization/deployment.yaml`

**Step 1: Add startup and readiness probes to `openclaw` container**

Find the `openclaw` container spec (the one with `image: oci.killinit.cc/openclaw/openclaw:latest`).
After the `ports:` block, add:

```yaml
        startupProbe:
          tcpSocket:
            port: 18789
          initialDelaySeconds: 5
          periodSeconds: 5
          failureThreshold: 12
        readinessProbe:
          tcpSocket:
            port: 18789
          initialDelaySeconds: 15
          periodSeconds: 10
          failureThreshold: 3
```

**Step 2: Pin busybox in init container**

Find the init container with `image: busybox:latest`.
Change to: `image: busybox:1.37.0`

**Step 3: Make config copy robust**

In the `init-workspace` init container `args`, find the config copy line:
```sh
cp /opt/config/openclaw.json /home/node/.openclaw/clawdbot.json
```
Change to:
```sh
rm -f /home/node/.openclaw/clawdbot.json
cp /opt/config/openclaw.json /home/node/.openclaw/clawdbot.json
```

**Step 4: Validate YAML**

```bash
yq . kustomization/deployment.yaml > /dev/null && echo "YAML valid"
kustomize build kustomization/ > /dev/null && echo "Kustomize build OK"
```

Expected: both print OK

**Step 5: Commit**

```bash
git add kustomization/deployment.yaml
git commit -m "deploy: add probes, pin busybox, harden config copy"
```

---

### Task 3: Refresh workspace content — model references + agent tables

**Files:**
- Modify: `workspaces/main/AGENTS.md`
- Modify: `workspaces/main/skills/cluster-context/SKILL.md`
- Modify: `workspaces/morty/AGENTS.md`
- Modify: `workspaces/morty/skills/openclaw-docs/SKILL.md`
- Modify: `workspaces/robert/IDENTITY.md`
- Modify: `workspaces/robert/AGENTS.md`
- Modify: `workspaces/ribak/AGENTS.md`
- Modify: `workspaces/dyson/AGENTS.md`
- Modify: `workspaces/leon/IDENTITY.md`
- Modify: `workspaces/leon/HEARTBEAT.md`

#### 3a. `workspaces/main/AGENTS.md`

Change 3 lines in the "Other Agents" table (lines 34, 35, 37):
- `Kimi K2.5` → `MiniMax M2.5` (all occurrences in this file)

Also add Ribak row to the table. After the Leon row add:
```markdown
| **Ribak** | `ribak` | Code review assistant for Leon | MiniMax M2.5 | Leon's sub-agent, not spawnable directly |
```

#### 3b. `workspaces/main/skills/cluster-context/SKILL.md`

Line 57 — update the provider table row:

Old:
```markdown
| `nvidia` | `moonshotai/kimi-k2.5` | Default — strong reasoning, 131k context |
```
New:
```markdown
| `aperture` | `MiniMax-M2.5` | Default — strong reasoning, 204k context |
```

Also update any inline text above the table that references nvidia as the default provider.

#### 3c. `workspaces/morty/AGENTS.md`

Lines 9, 10, 12 — replace `Kimi K2.5` with `MiniMax M2.5` in the agent table.

#### 3d. `workspaces/morty/skills/openclaw-docs/SKILL.md`

Lines 65, 67, 76 — replace `nvidia/moonshotai/kimi-k2.5` with `aperture/MiniMax-M2.5` in the JSON config examples.

#### 3e. `workspaces/robert/IDENTITY.md`

Line 7:
Old: `- **Model:** nvidia/moonshotai/kimi-k2.5 (Kimi K2.5)`
New: `- **Model:** aperture/MiniMax-M2.5 (MiniMax M2.5)`

#### 3f. `workspaces/robert/AGENTS.md`

Lines 40–44 — update the agent table:
- Lines 40, 41, 42, 44: `Kimi K2.5` → `MiniMax M2.5`
- Line 43: `Claude Opus 4.6` → `MiniMax M2.5`

#### 3g. `workspaces/ribak/AGENTS.md`

Line 27:
Old: `Default: \`nvidia/moonshotai/kimi-k2.5\` (configurable per-task)`
New: `Default: \`aperture/MiniMax-M2.5\` (configurable per-task)`

#### 3h. `workspaces/dyson/AGENTS.md`

Lines 9–12:
- Lines 9, 10, 12: `Kimi K2.5` → `MiniMax M2.5`
- Line 11: `Claude Opus 4.6` → `MiniMax M2.5`

#### 3i. `workspaces/leon/IDENTITY.md`

Line 6:
Old: `- **Model:** anthropic/claude-opus-4-6 (Claude Opus 4.6 — 200k context, multimodal)`
New: `- **Model:** aperture/MiniMax-M2.5 (MiniMax M2.5 — 204k context)`

#### 3j. `workspaces/leon/HEARTBEAT.md`

Line 4:
Old: `Model: Claude Opus 4.6. Target: Discord.`
New: `Model: aperture/MiniMax-M2.5. Target: Discord.`

**Step: Verify no old model refs remain**

```bash
grep -r "nvidia/moonshotai\|kimi-k2.5\|Kimi K2.5\|claude-opus-4-6\|Claude Opus 4.6" \
  workspaces/ --include="*.md"
```

Expected: **no output** (zero matches)

Note: `nvidia-smi` in `dyson/skills/cluster-health/SKILL.md` is a GPU tool command — leave it alone. The grep above targets specific model ID patterns only.

**Step: Commit**

```bash
git add workspaces/
git commit -m "workspaces: update model refs to aperture/MiniMax-M2.5, add Ribak to agent tables"
```

---

### Task 4: Add Ribak code-review skill

**Files:**
- Create: `workspaces/ribak/skills/code-review/skill.md`

**Step 1: Create directory**

```bash
mkdir -p workspaces/ribak/skills/code-review
```

**Step 2: Write skill file**

Create `workspaces/ribak/skills/code-review/skill.md` with this exact content:

```markdown
---
name: Code Review
description: >
  Detailed code analysis support for Leon — per-file review, security scan,
  correctness checks, and structured findings output.

  Use when: Leon assigns a PR or file for review, when you need to analyze
  specific changed files in depth, or when producing a findings report that
  Leon will compile into a full PR review.

  Don't use when: The task is architectural design (report back to Leon).
  Don't use for runtime debugging or pod failures. Don't post reviews directly
  to PRs — output findings to /tmp/outputs/ for Leon to review and post.

  Outputs: Findings report at /tmp/outputs/review-<pr-number>.md, grouped
  by severity (Critical/High/Medium/Low).
requires: [gh, git]
---

# Code Review (Ribak)

## Role

You are Leon's analysis sub-agent. Leon delegates specific review tasks to you.
Your job: thorough analysis, structured findings, hand back to Leon.

Do NOT post reviews to GitHub yourself. Write findings to `/tmp/outputs/`
and report back. Leon decides what to post.

## Steps

### 1. Understand the Assignment

Leon will specify:
- The repo and PR number (or branch/diff)
- Which files or areas to focus on
- What type of review (security, correctness, style, infrastructure)

### 2. Get the Diff

```bash
gh pr diff <number> --repo rajsinghtech/<repo>
```

### 3. Review Checklist

**Correctness**
- Logic matches PR description
- Edge cases: nil/null, empty inputs, overflow, concurrency
- Error handling: caught, logged, propagated correctly

**Security**
- No hardcoded secrets, tokens, credentials
- No `${VAR}` patterns that bypass Flux substitution escaping (`$${VAR}` required)
- Input validation on external data
- SOPS files not modified or incorrectly re-encrypted

**Style & Maintainability**
- Follows existing conventions in the repo
- No unnecessary complexity
- Tests present for new logic

**Infrastructure (for K8s/Flux changes)**
- `jq .` / `yq .` valid
- `$${VAR}` Flux escaping correct
- Resource limits set
- Container names correct (`openclaw`, not `main`)

### 4. Output Findings

Write to `/tmp/outputs/review-<pr-number>.md`:

```markdown
## Ribak Analysis: PR #<number>

**Scope:** <what files/areas you reviewed>

### Critical
- <file:line> — <description>

### High
- None

### Medium
- <finding>

### Low
- <nit>

### Security Checklist
- [ ] No hardcoded credentials
- [ ] Flux ${VAR} escaping correct (`$${VAR}` in repo)
- [ ] SOPS files intact
- [ ] Resource limits present
```

Then report back to Leon with a summary and the output file path.
```

**Step 3: Verify file exists and is readable**

```bash
cat workspaces/ribak/skills/code-review/skill.md | head -5
```

Expected: shows the YAML frontmatter `---` header

**Step 4: Commit**

```bash
git add workspaces/ribak/skills/code-review/
git commit -m "workspaces: add code-review skill to ribak"
```

---

## Sequential Group B — Run after Group A lands on main

---

### Task 5: PVC Migration — RBD → CephFS + RollingUpdate strategy

**Context:** The current PVC uses `ceph-block-replicated` (Ceph RBD, `ReadWriteOnce`).
RWO means only one pod can mount it — requiring `strategy: Recreate`, which causes
full downtime on every update. Migrating to `rook-cephfs` (CephFS, `ReadWriteMany`)
enables `RollingUpdate`.

**Files:**
- Modify: `kustomization/pvc.yaml`
- Modify: `kustomization/deployment.yaml`

**WARNING:** This is a live cluster operation. The pod will be scaled to 0 during
data migration. Plan for 5–10 minutes of downtime.

---

#### 5a. Create a new CephFS PVC

Apply this manifest directly to the cluster (NOT via Flux yet — apply manually):

```bash
kubectl -n openclaw apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: openclaw-data-cephfs
  namespace: openclaw
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: rook-cephfs
  resources:
    requests:
      storage: 5Gi
EOF
```

Verify it binds:
```bash
kubectl -n openclaw get pvc openclaw-data-cephfs
```
Expected: `STATUS = Bound`

---

#### 5b. Scale deployment to 0

```bash
kubectl -n openclaw scale deployment openclaw --replicas=0
kubectl -n openclaw wait --for=delete pod -l app.kubernetes.io/name=openclaw --timeout=60s
```

Verify no openclaw pods are running:
```bash
kubectl -n openclaw get pods -l app.kubernetes.io/name=openclaw
```
Expected: `No resources found`

---

#### 5c. Run data migration job

```bash
kubectl -n openclaw apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: openclaw-pvc-migrate
  namespace: openclaw
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: migrate
        image: busybox:1.37.0
        command:
          - sh
          - -c
          - |
            echo "Starting migration..."
            cp -a /src/. /dst/
            echo "Migration complete. Files:"
            ls /dst/
        volumeMounts:
        - name: src
          mountPath: /src
          readOnly: true
        - name: dst
          mountPath: /dst
      volumes:
      - name: src
        persistentVolumeClaim:
          claimName: openclaw-data
      - name: dst
        persistentVolumeClaim:
          claimName: openclaw-data-cephfs
EOF
```

Wait for completion:
```bash
kubectl -n openclaw wait --for=condition=complete job/openclaw-pvc-migrate --timeout=120s
```

Check migration output:
```bash
kubectl -n openclaw logs job/openclaw-pvc-migrate
```
Expected: logs show "Migration complete" and lists expected directories (workspaces, cron, etc.)

---

#### 5d. Update `kustomization/pvc.yaml`

Change the storage class and access mode:
```yaml
# Before
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: openclaw-data
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ceph-block-replicated
  resources:
    requests:
      storage: 5Gi
```

```yaml
# After
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: openclaw-data
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: rook-cephfs
  resources:
    requests:
      storage: 5Gi
```

**Note:** Flux manages this PVC. Because the PVC name stays `openclaw-data`, Flux
will try to patch the existing PVC. However, `storageClassName` and `accessModes` are
immutable on existing PVCs. We need to delete the old PVC first (after verifying
migration) and let Flux recreate it. See step 5f.

---

#### 5e. Update `kustomization/deployment.yaml` — change strategy

Find the `strategy:` block in deployment.yaml:
```yaml
  strategy:
    type: Recreate
```
Replace with:
```yaml
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
```

---

#### 5f. Commit and let Flux apply

```bash
git add kustomization/pvc.yaml kustomization/deployment.yaml
git commit -m "deploy: migrate PVC to CephFS, switch to RollingUpdate strategy"
git push
```

Then wait for Flux to reconcile:
```bash
flux -n flux-system reconcile kustomization openclaw --with-source
```

---

#### 5g. Delete old PVC and let Flux recreate with CephFS

After confirming Flux reconciled but the PVC update failed (expected, immutable field):

```bash
# Verify migration job succeeded before deleting old PVC
kubectl -n openclaw get pvc openclaw-data-cephfs  # must be Bound

# Scale down to 0 if not already
kubectl -n openclaw scale deployment openclaw --replicas=0

# Delete old RBD PVC
kubectl -n openclaw delete pvc openclaw-data

# Flux will now create a new openclaw-data PVC using rook-cephfs
# Force reconcile:
flux -n flux-system reconcile kustomization openclaw

# Verify new PVC is created and bound
kubectl -n openclaw get pvc openclaw-data
```
Expected: `openclaw-data` is now bound with `rook-cephfs`

---

#### 5h. Populate new PVC from migration PVC

```bash
kubectl -n openclaw apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: openclaw-pvc-migrate-2
  namespace: openclaw
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: migrate
        image: busybox:1.37.0
        command:
          - sh
          - -c
          - |
            echo "Copying from migration PVC to new openclaw-data..."
            cp -a /src/. /dst/
            echo "Done."
        volumeMounts:
        - name: src
          mountPath: /src
          readOnly: true
        - name: dst
          mountPath: /dst
      volumes:
      - name: src
        persistentVolumeClaim:
          claimName: openclaw-data-cephfs
      - name: dst
        persistentVolumeClaim:
          claimName: openclaw-data
EOF

kubectl -n openclaw wait --for=condition=complete job/openclaw-pvc-migrate-2 --timeout=120s
kubectl -n openclaw logs job/openclaw-pvc-migrate-2
```

---

#### 5i. Scale back up and verify

```bash
kubectl -n openclaw scale deployment openclaw --replicas=1
kubectl -n openclaw rollout status deployment/openclaw --timeout=120s
```

Check pod is healthy:
```bash
kubectl -n openclaw get pods -l app.kubernetes.io/name=openclaw
kubectl -n openclaw logs -l app.kubernetes.io/name=openclaw -c openclaw --tail=20
```

Expected:
- Pod shows `2/2 Running`
- Logs show `[gateway] listening on ws://0.0.0.0:18789`
- No "tailscale serve" errors

---

#### 5j. Cleanup migration artifacts

```bash
kubectl -n openclaw delete job openclaw-pvc-migrate openclaw-pvc-migrate-2
kubectl -n openclaw delete pvc openclaw-data-cephfs
```

---

## Verification Checklist

After all tasks complete:

```bash
# 1. JSON/YAML valid
jq . kustomization/openclaw.json > /dev/null && echo "openclaw.json OK"
kustomize build kustomization/ > /dev/null && echo "kustomize build OK"

# 2. No old model refs
grep -r "nvidia/moonshotai\|kimi-k2.5\|Kimi K2.5\|claude-opus-4-6\|Claude Opus 4.6" \
  workspaces/ --include="*.md" && echo "FAIL: stale refs found" || echo "No stale refs"

# 3. Pod healthy
kubectl -n openclaw get pods -l app.kubernetes.io/name=openclaw
kubectl -n openclaw logs -l app.kubernetes.io/name=openclaw -c openclaw --tail=5

# 4. Verify trustedProxies in running config
kubectl -n openclaw exec deploy/openclaw -c openclaw -- \
  cat /home/node/.openclaw/clawdbot.json | jq '.gateway.trustedProxies'

# 5. Verify web search enabled
kubectl -n openclaw exec deploy/openclaw -c openclaw -- \
  cat /home/node/.openclaw/clawdbot.json | jq '.tools.web.search.enabled'

# 6. Verify PVC storage class
kubectl -n openclaw get pvc openclaw-data -o jsonpath='{.spec.storageClassName}'
# Expected: rook-cephfs
```
