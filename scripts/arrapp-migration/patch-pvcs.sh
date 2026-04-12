#!/usr/bin/env bash
set -e

echo "=== robbinsdale-k8s-operator.keiretsu.ts.net ==="
kubectl patch pvc audioarr-config -n media --context robbinsdale-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc autobrr-config -n media --context robbinsdale-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc bazarr-config -n media --context robbinsdale-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc bazarr-1080p-config -n media --context robbinsdale-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc bazarr-4k-config -n media --context robbinsdale-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc bazarr-4kremux-config -n media --context robbinsdale-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc bazarr-anime-config -n media --context robbinsdale-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc jellyseerr-config -n media --context robbinsdale-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc lidarr-config -n media --context robbinsdale-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc overseerr-config -n media --context robbinsdale-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc prowlarr-config -n media --context robbinsdale-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc radarr-config -n media --context robbinsdale-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc radarr-1080p-config -n media --context robbinsdale-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc radarr-4k-config -n media --context robbinsdale-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc radarr-4kremux-config -n media --context robbinsdale-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc radarr-anime-config -n media --context robbinsdale-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc readarr-config -n media --context robbinsdale-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc sabnzbd-config -n media --context robbinsdale-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc sonarr-config -n media --context robbinsdale-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc sonarr-1080p-config -n media --context robbinsdale-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc sonarr-4k-config -n media --context robbinsdale-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc sonarr-anime-config -n media --context robbinsdale-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc tautulli-config -n media --context robbinsdale-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc wizarr-config -n media --context robbinsdale-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true

echo "=== ottawa-k8s-operator.keiretsu.ts.net ==="
kubectl patch pvc autobrr-config -n media --context ottawa-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc bazarr-1080p-config -n media --context ottawa-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc bazarr-4k-config -n media --context ottawa-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc bazarr-4kremux-config -n media --context ottawa-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc bazarr-anime-config -n media --context ottawa-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc jellyseerr-config -n media --context ottawa-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc lidarr-config -n media --context ottawa-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc overseerr-config -n media --context ottawa-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc prowlarr-config -n media --context ottawa-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc radarr-1080p-config -n media --context ottawa-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc radarr-4k-config -n media --context ottawa-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc radarr-4kremux-config -n media --context ottawa-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc radarr-anime-config -n media --context ottawa-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc sabnzbd-config -n media --context ottawa-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc sonarr-1080p-config -n media --context ottawa-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc sonarr-4k-config -n media --context ottawa-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc sonarr-anime-config -n media --context ottawa-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc tautulli-config -n media --context ottawa-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true
kubectl patch pvc wizarr-config -n media --context ottawa-k8s-operator.keiretsu.ts.net --type=json -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' 2>/dev/null || true

