# Dual-Spark MiniMax M2.7 AWQ Inference Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add spark-1 to the K3s cluster and replace the single-Spark Qwen3.6-35B-A3B deployment with MiniMax M2.7 AWQ running across both Sparks via Ray TP=2 (~38 tok/s, 196K context).

**Architecture:** spark-0 runs `vllm-head` (Ray head + vLLM serve), spark-1 runs `vllm-worker` (Ray worker). Pod anti-affinity enforces cross-node placement. Each Spark downloads its own model copy to a local-path PVC. External API is unchanged: `vllm` ClusterIP + `stpetersburg-vllm` Tailscale hostname. Ray cluster forms over Cilium pod network.

**Tech Stack:** Talos Linux v1.12.6, K3s v1.35.4, talhelper, vLLM (ghcr.io/aeon-7/vllm-spark-omni-q36:v2.0), Ray distributed executor, AWQ INT4, Flux GitOps

---

## Current state

- `spark-0` — single K3s control-plane node, 4 time-sliced virtual GPUs (1 physical GB10), running Qwen3.6-35B-A3B NVFP4+DFlash, ~84 tok/s
- `spark-1` — not yet in cluster, stacking cable being connected
- GPU time-slicing: `replicas: 4` in `time-slicing-config.yaml` → each node shows 4 virtual GPUs
- Model on disk: `AEON-7/Qwen3.6-35B-A3B-heretic-NVFP4` + `z-lab/Qwen3.6-35B-A3B-DFlash`

## Files

| File | Action |
|---|---|
| `clusters/talos-stpetersburg/apps/gpu-operator/app/time-slicing-config.yaml` | Disable time-slicing (replicas 4 → 1) |
| `clusters/talos-stpetersburg/bootstrap/talos/talconfig.yaml` | Add spark-1 as control-plane node |
| `clusters/talos-stpetersburg/bootstrap/talos/patches/node/spark-1.yaml` | Create node patch |
| `clusters/talos-stpetersburg/apps/ai/inference/vllm.yaml` | Replace entirely |
| `opencode.json` | Add MiniMax-M2.7 model entry |

---

## Task 0: Disable GPU time-slicing

**Files:**
- Modify: `clusters/talos-stpetersburg/apps/gpu-operator/app/time-slicing-config.yaml`

With time-slicing at `replicas: 4`, each Spark shows 4 virtual GPU devices. vLLM Ray TP=2 needs one real GPU per node — disabling time-slicing exposes the physical GPU directly, simplifies resource requests, and removes the need for `CUDA_VISIBLE_DEVICES` hacks.

- [ ] **Step 0.1: Set replicas to 1**

Replace the entire file:

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: time-slicing-config
  namespace: gpu-operator
data:
  any: |-
    version: v1
    sharing:
      timeSlicing:
        resources:
          - name: nvidia.com/gpu
            replicas: 1
```

- [ ] **Step 0.2: Commit**

```bash
git add clusters/talos-stpetersburg/apps/gpu-operator/app/time-slicing-config.yaml
git commit -m "fix(gpu-operator/stpetersburg): disable time-slicing for exclusive GPU access"
```

---

## Task 1: Add spark-1 to talconfig.yaml

**Files:**
- Modify: `clusters/talos-stpetersburg/bootstrap/talos/talconfig.yaml`

Before running: boot spark-1 from `metal-arm64.iso`, note its IP and NVMe serial (`talosctl disks --insecure --nodes <spark-1-ip>`).

- [ ] **Step 1.1: Add spark-1 to additionalMachineCertSans**

In `talconfig.yaml`, add to `additionalMachineCertSans:`:
```yaml
  - "192.168.73.207"       # spark-1 LAN IP
  - "spark-1.stpetersburg.internal"
```

- [ ] **Step 1.2: Add spark-1 node entry**

spark-1 is a **control-plane** node (same schematic as spark-0 — the existing `controlPlane:` block covers it automatically). Adding the VIP to spark-1 lets the API server float between both Sparks if one fails.

Add to `nodes:` list (replace `REPLACE_WITH_SPARK1_NVME_SERIAL` with spark-1's actual NVMe serial from `talosctl disks --insecure --nodes <spark-1-ip>`):
```yaml
  - hostname: "spark-1"
    ipAddress: "spark-1.stpetersburg.internal"
    installDiskSelector:
      serial: "REPLACE_WITH_SPARK1_NVME_SERIAL"
    controlPlane: true
    networkInterfaces:
      - interface: eth0
        dhcp: true
        vip:
          ip: "192.168.73.25"
    patches:
      - "@./patches/node/spark-1.yaml"
```

---

## Task 2: Create spark-1 node patch

**Files:**
- Create: `clusters/talos-stpetersburg/bootstrap/talos/patches/node/spark-1.yaml`

- [ ] **Step 2.1: Write node patch**

```yaml
# Node-specific configuration for spark-1 (DGX Spark)
machine:
  nodeLabels:
    node.kubernetes.io/instance-type: dgx-spark
    nvidia.com/gpu.product: Blackwell
```

- [ ] **Step 2.2: Commit Talos config changes**

```bash
git add clusters/talos-stpetersburg/bootstrap/talos/talconfig.yaml \
        clusters/talos-stpetersburg/bootstrap/talos/patches/node/spark-1.yaml
git commit -m "feat(talos/stpetersburg): add spark-1 as HA control-plane node"
```

---

## Task 3: Apply Talos config to spark-1 (manual, out-of-band)

These steps run on your local machine, not through GitOps.

- [ ] **Step 3.1: Generate machine configs**

```bash
cd clusters/talos-stpetersburg/bootstrap/talos
talhelper genconfig
# Outputs: clusterconfig/k8s.stpetersburg.internal-spark-1.yaml
```

- [ ] **Step 3.2: Apply to spark-1**

```bash
talosctl apply-config \
  --insecure \
  --nodes 192.168.73.207 \
  --file clusterconfig/k8s.stpetersburg.internal-spark-1.yaml
```

- [ ] **Step 3.3: Wait for spark-1 to join**

```bash
# Set talosconfig for the cluster
export TALOSCONFIG=clusters/talos-stpetersburg/bootstrap/talos/talosconfig

# Watch until spark-1 appears
kubectl --context stpetersburg-k8s-operator.keiretsu.ts.net get nodes -w
# Expected: spark-1 Ready (may take 3-5 min)
```

- [ ] **Step 3.4: Verify GPU on both nodes**

```bash
kubectl --context stpetersburg-k8s-operator.keiretsu.ts.net get nodes \
  -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable."nvidia\.com/gpu"
# Expected: spark-0=1, spark-1=1 (time-slicing disabled → 1 physical GPU each)
# Note: if spark-0 still shows 4, the GPU operator may need a moment to reconcile
# after the time-slicing ConfigMap change. It will self-correct.
```

---

## Task 4: Replace vllm.yaml

**Files:**
- Modify: `clusters/talos-stpetersburg/apps/ai/inference/vllm.yaml`

Replace the entire file content:

- [ ] **Step 4.1: Write PVCs (split 200Gi single → two 250Gi)**

```yaml
# MiniMax M2.7 AWQ dual-Spark inference
# Model: cyankiwi/MiniMax-M2.7-AWQ-4bit
# Forum recipe: https://forums.developer.nvidia.com/t/minimax-m2-7-nfvp4-recipe-benchmarks/366324
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vllm-models-head
  namespace: ai
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 250Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vllm-models-worker
  namespace: ai
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 250Gi
```

- [ ] **Step 4.2: Write download ConfigMap**

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: vllm-download-script
  namespace: ai
data:
  download.py: |
    import os
    from huggingface_hub import snapshot_download

    token = os.environ.get('HUGGING_FACE_HUB_TOKEN')
    models = [
        ('cyankiwi/MiniMax-M2.7-AWQ-4bit', '/models/minimax-m27-awq'),
    ]
    for repo, path in models:
        if not os.path.exists(os.path.join(path, 'config.json')):
            print(f'Downloading {repo}...', flush=True)
            snapshot_download(repo_id=repo, local_dir=path, token=token)
            print(f'Done: {repo}', flush=True)
        else:
            print(f'Already cached: {repo}', flush=True)
```

- [ ] **Step 4.3: Write Ray head headless service**

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: vllm-ray-head
  namespace: ai
spec:
  type: ClusterIP
  clusterIP: None
  ports:
  - name: ray-gcs
    port: 6379
    protocol: TCP
    targetPort: 6379
  selector:
    app: vllm-head
```

- [ ] **Step 4.4: Write vllm-head Deployment**

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-head
  namespace: ai
  labels:
    app: vllm-head
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: vllm-head
  template:
    metadata:
      labels:
        app: vllm-head
    spec:
      enableServiceLinks: false
      initContainers:
      - name: download-models
        image: ghcr.io/aeon-7/vllm-spark-omni-q36:v2.0
        command: [python3, /scripts/download.py]
        env:
        - name: HUGGING_FACE_HUB_TOKEN
          valueFrom:
            secretKeyRef:
              name: hf-secret
              key: HF_TOKEN
        - name: HF_HOME
          value: "/models/huggingface"
        volumeMounts:
        - name: models
          mountPath: /models
        - name: download-script
          mountPath: /scripts
        resources:
          requests:
            memory: "4Gi"
            cpu: "2000m"
          limits:
            memory: "8Gi"
      containers:
      - name: vllm
        image: ghcr.io/aeon-7/vllm-spark-omni-q36:v2.0
        command: [bash, -c]
        args:
        - |
          ray start --head --port=6379 --dashboard-host=0.0.0.0 --num-gpus=1
          echo "Waiting for Ray worker (need 2 total GPUs)..."
          python3 -c "
          import ray, time
          ray.init(address='auto')
          for i in range(120):
              gpus = ray.available_resources().get('GPU', 0)
              print(f'GPUs in cluster: {gpus}/2', flush=True)
              if gpus >= 2:
                  break
              time.sleep(5)
          else:
              raise RuntimeError('Ray worker did not join within 10 minutes')
          print('Ray cluster ready, starting vLLM', flush=True)
          "
          exec vllm serve /models/minimax-m27-awq \
            --served-model-name MiniMax-M2.7 minimax-fast minimax-deep \
            --host 0.0.0.0 \
            --port 8000 \
            --dtype auto \
            --max-model-len 196608 \
            --gpu-memory-utilization 0.85 \
            --max-num-seqs 4 \
            --max-num-batched-tokens 8192 \
            --enable-prefix-caching \
            --enable-chunked-prefill \
            --enable-auto-tool-choice \
            --tool-call-parser minimax_m2 \
            --reasoning-parser minimax_m2 \
            --attention-backend flashinfer \
            --kv-cache-dtype fp8 \
            --disable-custom-all-reduce \
            --trust-remote-code \
            --tensor-parallel-size 2 \
            --load-format fastsafetensors \
            --distributed-executor-backend ray
        ports:
        - containerPort: 8000
          name: http
          protocol: TCP
        - containerPort: 6379
          name: ray-gcs
          protocol: TCP
        env:
        - name: VLLM_USE_FLASHINFER_MOE_FP16
          value: "1"
        - name: VLLM_USE_DEEP_GEMM
          value: "0"
        - name: VLLM_USE_FLASHINFER_SAMPLER
          value: "0"
        - name: VLLM_ALLOW_LONG_MAX_MODEL_LEN
          value: "1"
        - name: VLLM_FLOAT32_MATMUL_PRECISION
          value: "high"
        - name: VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS
          value: "1"
        - name: VLLM_FLASHINFER_MOE_BACKEND
          value: "throughput"
        - name: OMP_NUM_THREADS
          value: "8"
        - name: NCCL_IB_DISABLE
          value: "0"
        - name: NCCL_P2P_DISABLE
          value: "1"
        - name: NCCL_IGNORE_CPU_AFFINITY
          value: "1"
        - name: NVIDIA_FORWARD_COMPAT
          value: "1"
        - name: PYTORCH_CUDA_ALLOC_CONF
          value: "expandable_segments:True"
        - name: RAY_DEDUP_LOGS
          value: "0"
        - name: HUGGING_FACE_HUB_TOKEN
          valueFrom:
            secretKeyRef:
              name: hf-secret
              key: HF_TOKEN
        - name: HF_HOME
          value: "/models/huggingface"
        - name: VLLM_COMPILE_CACHE_DIR
          value: "/models/compile-cache"
        - name: VLLM_CACHE_ROOT
          value: "/models/vllm-cache"
        resources:
          requests:
            memory: "16Gi"
            cpu: "4000m"
            nvidia.com/gpu: "1"
          limits:
            memory: "96Gi"
            nvidia.com/gpu: "1"
        volumeMounts:
        - name: models
          mountPath: /models
        - name: shm
          mountPath: /dev/shm
        - name: download-script
          mountPath: /scripts
        startupProbe:
          httpGet:
            path: /health
            port: http
          initialDelaySeconds: 60
          periodSeconds: 30
          timeoutSeconds: 10
          failureThreshold: 90
        livenessProbe:
          httpGet:
            path: /health
            port: http
          initialDelaySeconds: 600
          periodSeconds: 30
          timeoutSeconds: 10
          failureThreshold: 5
        readinessProbe:
          httpGet:
            path: /health
            port: http
          initialDelaySeconds: 300
          periodSeconds: 10
          timeoutSeconds: 5
      volumes:
      - name: models
        persistentVolumeClaim:
          claimName: vllm-models-head
      - name: shm
        emptyDir:
          medium: Memory
          sizeLimit: 16Gi
      - name: download-script
        configMap:
          name: vllm-download-script
      nodeSelector:
        nvidia.com/gpu.present: "true"
        kubernetes.io/hostname: spark-0
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app: vllm-worker
            topologyKey: kubernetes.io/hostname
      terminationGracePeriodSeconds: 120
```

- [ ] **Step 4.5: Write vllm-worker Deployment**

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-worker
  namespace: ai
  labels:
    app: vllm-worker
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: vllm-worker
  template:
    metadata:
      labels:
        app: vllm-worker
    spec:
      enableServiceLinks: false
      initContainers:
      - name: download-models
        image: ghcr.io/aeon-7/vllm-spark-omni-q36:v2.0
        command: [python3, /scripts/download.py]
        env:
        - name: HUGGING_FACE_HUB_TOKEN
          valueFrom:
            secretKeyRef:
              name: hf-secret
              key: HF_TOKEN
        - name: HF_HOME
          value: "/models/huggingface"
        volumeMounts:
        - name: models
          mountPath: /models
        - name: download-script
          mountPath: /scripts
        resources:
          requests:
            memory: "4Gi"
            cpu: "2000m"
          limits:
            memory: "8Gi"
      - name: wait-for-ray-head
        image: ghcr.io/nicolaka/netshoot:latest
        command: ['sh', '-c', 'until nc -z vllm-ray-head 6379; do echo "waiting for ray head..."; sleep 5; done; echo "ray head ready"']
      containers:
      - name: vllm-worker
        image: ghcr.io/aeon-7/vllm-spark-omni-q36:v2.0
        command: [bash, -c]
        args:
        - |
          exec ray start --address=vllm-ray-head:6379 --num-gpus=1 --block
        env:
        - name: NCCL_IB_DISABLE
          value: "0"
        - name: NCCL_P2P_DISABLE
          value: "1"
        - name: NCCL_IGNORE_CPU_AFFINITY
          value: "1"
        - name: NVIDIA_FORWARD_COMPAT
          value: "1"
        - name: PYTORCH_CUDA_ALLOC_CONF
          value: "expandable_segments:True"
        - name: RAY_DEDUP_LOGS
          value: "0"
        - name: OMP_NUM_THREADS
          value: "8"
        - name: HF_HOME
          value: "/models/huggingface"
        resources:
          requests:
            memory: "16Gi"
            cpu: "4000m"
            nvidia.com/gpu: "1"
          limits:
            memory: "96Gi"
            nvidia.com/gpu: "1"
        volumeMounts:
        - name: models
          mountPath: /models
        - name: shm
          mountPath: /dev/shm
        - name: download-script
          mountPath: /scripts
      volumes:
      - name: models
        persistentVolumeClaim:
          claimName: vllm-models-worker
      - name: shm
        emptyDir:
          medium: Memory
          sizeLimit: 16Gi
      - name: download-script
        configMap:
          name: vllm-download-script
      nodeSelector:
        nvidia.com/gpu.present: "true"
        kubernetes.io/hostname: spark-1
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app: vllm-head
            topologyKey: kubernetes.io/hostname
      terminationGracePeriodSeconds: 60
```

- [ ] **Step 4.6: Write Services**

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: vllm
  namespace: ai
  labels:
    app: vllm-head
spec:
  type: ClusterIP
  ports:
  - name: http
    port: 8000
    protocol: TCP
    targetPort: http
  selector:
    app: vllm-head
---
apiVersion: v1
kind: Service
metadata:
  name: vllm-ts
  namespace: ai
  annotations:
    tailscale.com/hostname: "${LOCATION}-vllm"
    tailscale.com/proxy-group: common-ingress
    tailscale.com/tags: "tag:singh360,tag:k8s,tag:${LOCATION}"
spec:
  type: LoadBalancer
  loadBalancerClass: tailscale
  ports:
  - name: http
    port: 80
    protocol: TCP
    targetPort: 8000
  selector:
    app: vllm-head
```

- [ ] **Step 4.7: Commit vllm.yaml**

```bash
git add clusters/talos-stpetersburg/apps/ai/inference/vllm.yaml
git commit -m "feat(ai): dual-Spark MiniMax M2.7 AWQ via Ray TP=2

Replace single-Spark Qwen3.6-35B-A3B with MiniMax M2.7 AWQ across
spark-0 (head) and spark-1 (worker). ~38 tok/s at 196K context.

Forum recipe: https://forums.developer.nvidia.com/t/minimax-m2-7-nfvp4-recipe-benchmarks/366324"
```

---

## Task 5: Update opencode.json

**Files:**
- Modify: `opencode.json`

- [ ] **Step 5.1: Add MiniMax-M2.7 model and keep Qwen as fallback**

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "anthropic/claude-sonnet-4-6",
  "provider": {
    "aperture": {
      "name": "Aperture (self-hosted)",
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "http://aperture/v1",
        "apiKey": "-"
      },
      "models": {
        "MiniMax-M2.7": {
          "name": "MiniMax M2.7 (Dual Spark, AWQ)",
          "attachment": false,
          "reasoning": true,
          "tool_call": true,
          "temperature": true,
          "limit": { "context": 196608, "output": 16384 }
        },
        "Qwen3.6-35B-A3B": {
          "name": "Qwen3.6 35B MoE (DFlash)",
          "attachment": false,
          "reasoning": true,
          "tool_call": true,
          "temperature": true,
          "limit": { "context": 262144, "output": 16384 }
        }
      }
    }
  }
}
```

- [ ] **Step 5.2: Commit**

```bash
git add opencode.json
git commit -m "feat(opencode): add MiniMax M2.7 dual-Spark model"
```

---

## Task 6: Open PR

- [ ] **Step 6.1: Push and create PR**

```bash
git push origin main
gh pr create \
  --title "feat(ai): dual-Spark MiniMax M2.7 AWQ inference" \
  --body "$(cat <<'EOF'
## Summary
- Disables GPU time-slicing (replicas 4 → 1) for exclusive physical GPU access
- Adds spark-1 as HA control-plane node with VIP float (192.168.73.25)
- Replaces Qwen3.6-35B-A3B single-Spark with MiniMax M2.7 AWQ dual-Spark
- Ray TP=2 across spark-0 (head) and spark-1 (worker): ~38 tok/s, 196K context
- Each Spark gets its own 250Gi PVC; model downloaded independently on each node
- Tailscale hostname unchanged: stpetersburg-vllm
- Jetson Orin Nano can join as worker node when ready (no further control-plane changes needed)

## Forum recipe
https://forums.developer.nvidia.com/t/minimax-m2-7-nfvp4-recipe-benchmarks/366324

## Test plan
- [ ] spark-1 joins cluster: `kubectl get nodes` shows 2x Ready
- [ ] GPU allocatable per node: both spark-0 and spark-1 show `1` (time-slicing disabled)
- [ ] vllm-head pod running on spark-0, vllm-worker on spark-1
- [ ] Ray cluster formed: check vllm-head logs for "Ray cluster ready"
- [ ] Models downloaded (init containers complete on both pods)
- [ ] vLLM healthy: `curl http://stpetersburg-vllm/health`
- [ ] Inference works: `curl http://stpetersburg-vllm/v1/models`
EOF
)"
```

---

## Known risks / iteration points

| Item | Risk | Fallback |
|---|---|---|
| `--tool-call-parser minimax_m2` | Parser may not exist in AEON-7 image | Remove flag, use `hermes` |
| `--reasoning-parser minimax_m2` | Same as above | Remove flag |
| `--load-format fastsafetensors` | May not be in image version | Change to `safetensors` |
| `NCCL_P2P_DISABLE=1` | Disables NVLink P2P; stacking cable unused for NCCL | Set to `0` once NVLink fabric validated |
| Model download size | MiniMax M2.7 AWQ is large; 250Gi may be tight | Expand PVC to 350Gi |
| `--max-num-seqs 4` | Low concurrency per forum recipe | Tune up once stable |
