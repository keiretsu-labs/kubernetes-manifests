package clusterhealth

import (
	"fmt"
	"strings"
	"time"
)

const (
	crashLoopWindow    = 10 * time.Minute
	crashLoopThreshold = 3
	imagePullWindow    = 5 * time.Minute
	imagePullThreshold = 3
	imagePullClear     = 10 * time.Minute
	stuckWindow        = 15 * time.Minute
	stuckThreshold     = 5
	oomClear           = 10 * time.Minute
)

func podKey(detector string, ev Event) string {
	return fmt.Sprintf("%s:%s/%s/%s", detector, ev.Cluster, ev.Namespace, ev.Name)
}

func alertID(detector string, ev Event) string {
	return fmt.Sprintf("%s:%s/%s/%s", detector, ev.Cluster, ev.Namespace, ev.Name)
}

func DetectCrashLoop(ev Event, state *DetectorState, now time.Time) {
	if ev.Reason != "BackOff" || ev.Type != "Warning" {
		return
	}

	key := podKey(DetectorCrashLoop, ev)
	w, ok := state.PodWindows[key]
	if !ok {
		w = NewEventWindow(crashLoopWindow)
		state.PodWindows[key] = w
	}

	ts := ev.LastSeen
	if ts.IsZero() {
		ts = now
	}
	w.Add(ts)

	id := alertID(DetectorCrashLoop, ev)
	if existing, ok := state.ActiveAlerts[id]; ok {
		existing.Count = w.Count(now)
		existing.LastSeen = ts
		return
	}

	if w.Count(now) >= crashLoopThreshold {
		state.ActiveAlerts[id] = &AlertEntry{
			Detector:  DetectorCrashLoop,
			Cluster:   ev.Cluster,
			Namespace: ev.Namespace,
			Name:      ev.Name,
			Kind:      ev.Kind,
			Message:   fmt.Sprintf("Pod %s/%s in CrashLoopBackOff (%d restarts in %s)", ev.Namespace, ev.Name, w.Count(now), crashLoopWindow),
			Count:     w.Count(now),
			FirstSeen: w.Timestamps[0],
			LastSeen:  ts,
		}
	}
}

func DetectOOMKilled(ev Event, state *DetectorState, now time.Time) {
	if !strings.Contains(ev.Reason, "OOM") {
		return
	}

	ts := ev.LastSeen
	if ts.IsZero() {
		ts = now
	}

	id := alertID(DetectorOOMKilled, ev)
	if existing, ok := state.ActiveAlerts[id]; ok {
		existing.Count++
		existing.LastSeen = ts
		return
	}

	state.ActiveAlerts[id] = &AlertEntry{
		Detector:  DetectorOOMKilled,
		Cluster:   ev.Cluster,
		Namespace: ev.Namespace,
		Name:      ev.Name,
		Kind:      ev.Kind,
		Message:   fmt.Sprintf("Pod %s/%s OOMKilled", ev.Namespace, ev.Name),
		Count:     1,
		FirstSeen: ts,
		LastSeen:  ts,
	}
}

func DetectImagePull(ev Event, state *DetectorState, now time.Time) {
	if ev.Reason != "Failed" {
		return
	}
	if !strings.Contains(ev.Message, "ImagePullBackOff") && !strings.Contains(ev.Message, "ErrImagePull") {
		return
	}

	key := podKey(DetectorImagePull, ev)
	w, ok := state.PodWindows[key]
	if !ok {
		w = NewEventWindow(imagePullWindow)
		state.PodWindows[key] = w
	}

	ts := ev.LastSeen
	if ts.IsZero() {
		ts = now
	}
	w.Add(ts)

	id := alertID(DetectorImagePull, ev)
	if existing, ok := state.ActiveAlerts[id]; ok {
		existing.Count = w.Count(now)
		existing.LastSeen = ts
		return
	}

	if w.Count(now) >= imagePullThreshold {
		state.ActiveAlerts[id] = &AlertEntry{
			Detector:  DetectorImagePull,
			Cluster:   ev.Cluster,
			Namespace: ev.Namespace,
			Name:      ev.Name,
			Kind:      ev.Kind,
			Message:   fmt.Sprintf("Pod %s/%s failing to pull image (%d failures in %s)", ev.Namespace, ev.Name, w.Count(now), imagePullWindow),
			Count:     w.Count(now),
			FirstSeen: w.Timestamps[0],
			LastSeen:  ts,
		}
	}
}

func DetectStuckRollout(ev Event, state *DetectorState, now time.Time) {
	if ev.Reason != "FailedCreate" && ev.Reason != "FailedScheduling" {
		return
	}
	if ev.Kind != "ReplicaSet" && ev.Kind != "Pod" {
		return
	}

	key := fmt.Sprintf("%s/%s/%s", ev.Cluster, ev.Namespace, ev.Name)
	w, ok := state.OwnerWindows[key]
	if !ok {
		w = NewEventWindow(stuckWindow)
		state.OwnerWindows[key] = w
	}

	ts := ev.LastSeen
	if ts.IsZero() {
		ts = now
	}
	w.Add(ts)

	id := alertID(DetectorStuckRollout, ev)
	if existing, ok := state.ActiveAlerts[id]; ok {
		existing.Count = w.Count(now)
		existing.LastSeen = ts
		return
	}

	if w.Count(now) >= stuckThreshold {
		state.ActiveAlerts[id] = &AlertEntry{
			Detector:  DetectorStuckRollout,
			Cluster:   ev.Cluster,
			Namespace: ev.Namespace,
			Name:      ev.Name,
			Kind:      ev.Kind,
			Message:   fmt.Sprintf("%s %s/%s stuck (%d failures in %s)", ev.Kind, ev.Namespace, ev.Name, w.Count(now), stuckWindow),
			Count:     w.Count(now),
			FirstSeen: w.Timestamps[0],
			LastSeen:  ts,
		}
	}
}

func ResolveStaleAlerts(state *DetectorState, now time.Time) {
	for id, alert := range state.ActiveAlerts {
		switch alert.Detector {
		case DetectorCrashLoop:
			key := fmt.Sprintf("%s:%s/%s/%s", DetectorCrashLoop, alert.Cluster, alert.Namespace, alert.Name)
			if w, ok := state.PodWindows[key]; ok {
				if w.Count(now) == 0 {
					delete(state.ActiveAlerts, id)
					delete(state.PodWindows, key)
				}
			}
		case DetectorOOMKilled:
			if now.Sub(alert.LastSeen) > oomClear {
				delete(state.ActiveAlerts, id)
			}
		case DetectorImagePull:
			key := fmt.Sprintf("%s:%s/%s/%s", DetectorImagePull, alert.Cluster, alert.Namespace, alert.Name)
			if w, ok := state.PodWindows[key]; ok {
				if now.Sub(w.LastSeen()) > imagePullClear {
					delete(state.ActiveAlerts, id)
					delete(state.PodWindows, key)
				}
			}
		case DetectorStuckRollout:
			key := fmt.Sprintf("%s:%s/%s/%s", DetectorStuckRollout, alert.Cluster, alert.Namespace, alert.Name)
			if w, ok := state.OwnerWindows[key]; ok {
				if w.Count(now) == 0 {
					delete(state.ActiveAlerts, id)
					delete(state.OwnerWindows, key)
				}
			}
		}
	}
}
