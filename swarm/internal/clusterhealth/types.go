package clusterhealth

import "time"

const (
	DetectorCrashLoop    = "crash-loop"
	DetectorOOMKilled    = "oom-killed"
	DetectorImagePull    = "image-pull"
	DetectorStuckRollout = "stuck-rollout"

	QueryActiveAlerts = "health-alerts"
)

// Event is the input to detectors. Mirrors kubevents.KubeEvent to avoid import cycles.
type Event struct {
	Cluster   string
	Namespace string
	Name      string
	Kind      string
	Reason    string
	Message   string
	Source    string
	LastSeen  time.Time
	Type      string
}

type EventWindow struct {
	Window     time.Duration `json:"window"`
	Timestamps []time.Time   `json:"timestamps"`
}

func NewEventWindow(window time.Duration) *EventWindow {
	return &EventWindow{Window: window}
}

func (w *EventWindow) Add(t time.Time) {
	w.Timestamps = append(w.Timestamps, t)
}

func (w *EventWindow) Count(now time.Time) int {
	w.prune(now)
	return len(w.Timestamps)
}

func (w *EventWindow) LastSeen() time.Time {
	if len(w.Timestamps) == 0 {
		return time.Time{}
	}
	return w.Timestamps[len(w.Timestamps)-1]
}

func (w *EventWindow) prune(now time.Time) {
	cutoff := now.Add(-w.Window)
	i := 0
	for i < len(w.Timestamps) && w.Timestamps[i].Before(cutoff) {
		i++
	}
	w.Timestamps = w.Timestamps[i:]
}

type DetectorState struct {
	PodWindows   map[string]*EventWindow `json:"podWindows"`
	OwnerWindows map[string]*EventWindow `json:"ownerWindows"`
	ActiveAlerts map[string]*AlertEntry  `json:"activeAlerts"`
}

type AlertEntry struct {
	Detector  string    `json:"detector"`
	Cluster   string    `json:"cluster"`
	Namespace string    `json:"namespace"`
	Name      string    `json:"name"`
	Kind      string    `json:"kind"`
	Message   string    `json:"message"`
	Count     int       `json:"count"`
	FirstSeen time.Time `json:"firstSeen"`
	LastSeen  time.Time `json:"lastSeen"`
}

func NewDetectorState() *DetectorState {
	return &DetectorState{
		PodWindows:   make(map[string]*EventWindow),
		OwnerWindows: make(map[string]*EventWindow),
		ActiveAlerts: make(map[string]*AlertEntry),
	}
}
