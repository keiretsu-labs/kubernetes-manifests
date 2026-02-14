package clusterhealth

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
)

func TestEventWindow_AddAndCount(t *testing.T) {
	now := time.Now()
	w := NewEventWindow(10 * time.Minute)
	w.Add(now.Add(-5 * time.Minute))
	w.Add(now.Add(-1 * time.Minute))
	w.Add(now)
	assert.Equal(t, 3, w.Count(now))
}

func TestEventWindow_Prune(t *testing.T) {
	now := time.Now()
	w := NewEventWindow(10 * time.Minute)
	w.Add(now.Add(-15 * time.Minute))
	w.Add(now.Add(-5 * time.Minute))
	w.Add(now)
	assert.Equal(t, 2, w.Count(now))
}

func TestEventWindow_LastSeen(t *testing.T) {
	now := time.Now()
	w := NewEventWindow(10 * time.Minute)
	assert.True(t, w.LastSeen().IsZero())
	w.Add(now)
	assert.Equal(t, now, w.LastSeen())
}

func TestEventWindow_Empty(t *testing.T) {
	now := time.Now()
	w := NewEventWindow(10 * time.Minute)
	assert.Equal(t, 0, w.Count(now))
}

func TestDetectCrashLoop_TriggersAfterThreshold(t *testing.T) {
	now := time.Now()
	state := NewDetectorState()

	for i := 0; i < 3; i++ {
		DetectCrashLoop(Event{
			Cluster: "test", Namespace: "default", Name: "my-pod",
			Kind: "Pod", Reason: "BackOff", Type: "Warning",
			LastSeen: now.Add(time.Duration(i) * time.Minute),
		}, state, now)
	}

	assert.Len(t, state.ActiveAlerts, 1)
	for _, a := range state.ActiveAlerts {
		assert.Equal(t, DetectorCrashLoop, a.Detector)
		assert.Equal(t, "my-pod", a.Name)
		assert.Equal(t, 3, a.Count)
	}
}

func TestDetectCrashLoop_NoAlertBelowThreshold(t *testing.T) {
	now := time.Now()
	state := NewDetectorState()

	for i := 0; i < 2; i++ {
		DetectCrashLoop(Event{
			Cluster: "test", Namespace: "default", Name: "my-pod",
			Kind: "Pod", Reason: "BackOff", Type: "Warning",
			LastSeen: now,
		}, state, now)
	}

	assert.Empty(t, state.ActiveAlerts)
}

func TestDetectCrashLoop_IgnoresNonBackOff(t *testing.T) {
	now := time.Now()
	state := NewDetectorState()

	DetectCrashLoop(Event{
		Cluster: "test", Namespace: "default", Name: "my-pod",
		Kind: "Pod", Reason: "Scheduled", Type: "Normal",
		LastSeen: now,
	}, state, now)

	assert.Empty(t, state.PodWindows)
}

func TestDetectCrashLoop_Resolves(t *testing.T) {
	now := time.Now()
	state := NewDetectorState()

	for i := 0; i < 3; i++ {
		DetectCrashLoop(Event{
			Cluster: "test", Namespace: "default", Name: "my-pod",
			Kind: "Pod", Reason: "BackOff", Type: "Warning",
			LastSeen: now,
		}, state, now)
	}
	assert.Len(t, state.ActiveAlerts, 1)

	future := now.Add(11 * time.Minute)
	ResolveStaleAlerts(state, future)
	assert.Empty(t, state.ActiveAlerts)
}

func TestDetectOOMKilled_ImmediateAlert(t *testing.T) {
	now := time.Now()
	state := NewDetectorState()

	DetectOOMKilled(Event{
		Cluster: "test", Namespace: "kube-system", Name: "oom-pod",
		Kind: "Pod", Reason: "OOMKilling", Source: "kernel-monitor",
		LastSeen: now,
	}, state, now)

	assert.Len(t, state.ActiveAlerts, 1)
	for _, a := range state.ActiveAlerts {
		assert.Equal(t, DetectorOOMKilled, a.Detector)
	}
}

func TestDetectOOMKilled_MatchesOOMKilledReason(t *testing.T) {
	now := time.Now()
	state := NewDetectorState()

	DetectOOMKilled(Event{
		Cluster: "test", Namespace: "default", Name: "oom-pod",
		Kind: "Pod", Reason: "OOMKilled", Source: "kubelet",
		LastSeen: now,
	}, state, now)

	assert.Len(t, state.ActiveAlerts, 1)
}

func TestDetectOOMKilled_DeduplicatesSamePod(t *testing.T) {
	now := time.Now()
	state := NewDetectorState()

	for i := 0; i < 3; i++ {
		DetectOOMKilled(Event{
			Cluster: "test", Namespace: "default", Name: "oom-pod",
			Kind: "Pod", Reason: "OOMKilling", Source: "kernel-monitor",
			LastSeen: now.Add(time.Duration(i) * time.Minute),
		}, state, now)
	}

	assert.Len(t, state.ActiveAlerts, 1)
	for _, a := range state.ActiveAlerts {
		assert.Equal(t, 3, a.Count)
	}
}

func TestDetectOOMKilled_IgnoresNonOOM(t *testing.T) {
	now := time.Now()
	state := NewDetectorState()

	DetectOOMKilled(Event{
		Cluster: "test", Namespace: "default", Name: "pod",
		Kind: "Pod", Reason: "Killing", Source: "kubelet",
		LastSeen: now,
	}, state, now)

	assert.Empty(t, state.ActiveAlerts)
}

func TestDetectImagePull_TriggersAfterThreshold(t *testing.T) {
	now := time.Now()
	state := NewDetectorState()

	for i := 0; i < 3; i++ {
		DetectImagePull(Event{
			Cluster: "test", Namespace: "default", Name: "bad-image-pod",
			Kind: "Pod", Reason: "Failed", Message: "Error: ImagePullBackOff",
			Type: "Warning", LastSeen: now.Add(time.Duration(i) * time.Minute),
		}, state, now)
	}

	assert.Len(t, state.ActiveAlerts, 1)
	for _, a := range state.ActiveAlerts {
		assert.Equal(t, DetectorImagePull, a.Detector)
	}
}

func TestDetectImagePull_MatchesErrImagePull(t *testing.T) {
	now := time.Now()
	state := NewDetectorState()

	for i := 0; i < 3; i++ {
		DetectImagePull(Event{
			Cluster: "test", Namespace: "default", Name: "pod",
			Kind: "Pod", Reason: "Failed", Message: "Error: ErrImagePull",
			Type: "Warning", LastSeen: now,
		}, state, now)
	}

	assert.Len(t, state.ActiveAlerts, 1)
}

func TestDetectImagePull_IgnoresNonImageErrors(t *testing.T) {
	now := time.Now()
	state := NewDetectorState()

	DetectImagePull(Event{
		Cluster: "test", Namespace: "default", Name: "pod",
		Kind: "Pod", Reason: "Failed", Message: "exec format error",
		Type: "Warning", LastSeen: now,
	}, state, now)

	assert.Empty(t, state.PodWindows)
}

func TestDetectStuckRollout_TriggersAfterThreshold(t *testing.T) {
	now := time.Now()
	state := NewDetectorState()

	for i := 0; i < 5; i++ {
		DetectStuckRollout(Event{
			Cluster: "test", Namespace: "default", Name: "my-rs-abc123",
			Kind: "ReplicaSet", Reason: "FailedCreate", Type: "Warning",
			LastSeen: now.Add(time.Duration(i) * time.Minute),
		}, state, now)
	}

	assert.Len(t, state.ActiveAlerts, 1)
	for _, a := range state.ActiveAlerts {
		assert.Equal(t, DetectorStuckRollout, a.Detector)
		assert.Equal(t, 5, a.Count)
	}
}

func TestDetectStuckRollout_MatchesFailedScheduling(t *testing.T) {
	now := time.Now()
	state := NewDetectorState()

	for i := 0; i < 5; i++ {
		DetectStuckRollout(Event{
			Cluster: "test", Namespace: "default", Name: "pending-pod",
			Kind: "Pod", Reason: "FailedScheduling", Type: "Warning",
			LastSeen: now,
		}, state, now)
	}

	assert.Len(t, state.ActiveAlerts, 1)
}

func TestDetectStuckRollout_IgnoresNonMatchingKind(t *testing.T) {
	now := time.Now()
	state := NewDetectorState()

	DetectStuckRollout(Event{
		Cluster: "test", Namespace: "default", Name: "svc",
		Kind: "Service", Reason: "FailedCreate", Type: "Warning",
		LastSeen: now,
	}, state, now)

	assert.Empty(t, state.OwnerWindows)
}

func TestDetectStuckRollout_BelowThreshold(t *testing.T) {
	now := time.Now()
	state := NewDetectorState()

	for i := 0; i < 4; i++ {
		DetectStuckRollout(Event{
			Cluster: "test", Namespace: "default", Name: "my-rs",
			Kind: "ReplicaSet", Reason: "FailedCreate", Type: "Warning",
			LastSeen: now,
		}, state, now)
	}

	assert.Empty(t, state.ActiveAlerts)
}
