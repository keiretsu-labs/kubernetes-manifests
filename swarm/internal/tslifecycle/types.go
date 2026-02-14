package tslifecycle

import "time"

const (
	TaskQueue                  = "swarm"
	SignalProbeResult          = "probe-result"
	QueryProbeResults          = "probe-results"
	QueryCleanupResults        = "cleanup-results"
	CleanupWorkflowID          = "swarm-ts-cleanup"
	ProbeWorkflowID            = "swarm-ts-probe"
	DefaultProbeTimeout        = 10 * time.Second
	DefaultCleanupInactiveDays = 30
)

type ProbeTarget struct {
	Name    string `json:"name"`
	Address string `json:"address"`
}

type ProbeResult struct {
	Name      string        `json:"name"`
	Address   string        `json:"address"`
	Reachable bool          `json:"reachable"`
	Latency   time.Duration `json:"latency"`
	Error     string        `json:"error,omitempty"`
	Timestamp time.Time     `json:"timestamp"`
}

type CleanupCandidate struct {
	DeviceID     string    `json:"deviceId"`
	Hostname     string    `json:"hostname"`
	LastSeen     time.Time `json:"lastSeen"`
	InactiveDays int       `json:"inactiveDays"`
	Tags         []string  `json:"tags"`
}

type CleanupResult struct {
	Candidates []CleanupCandidate `json:"candidates"`
	Removed    []CleanupCandidate `json:"removed"`
	DryRun     bool               `json:"dryRun"`
	Timestamp  time.Time          `json:"timestamp"`
}

type CleanupInput struct {
	Tags         []string `json:"tags"`
	InactiveDays int      `json:"inactiveDays"`
	DryRun       bool     `json:"dryRun"`
}

type ProbeInput struct {
	Targets []ProbeTarget `json:"targets"`
}
