package kubevents

import "time"

const (
	TaskQueue             = "swarm"
	SignalEvents          = "events"
	SignalResourceVersion = "resource-version"
	QueryRecentEvents     = "recent-events"
	MaxBufferSize         = 200
	ContinueAsNewInterval = 5 * time.Minute
	PollInterval          = 10 * time.Second
	PollWatchTimeout      = int64(8) // seconds for K8s watch per poll
	MaxPollIterations     = 30       // ~5min at 10s intervals before ContinueAsNew
)

type ClusterWatchInput struct {
	Name            string
	Endpoint        string
	ResourceVersion string
}

type KubeEvent struct {
	Cluster   string    `json:"cluster"`
	Namespace string    `json:"namespace"`
	Name      string    `json:"name"`
	Kind      string    `json:"kind"`
	Reason    string    `json:"reason"`
	Message   string    `json:"message"`
	Source    string    `json:"source"`
	FirstSeen time.Time `json:"firstSeen"`
	LastSeen  time.Time `json:"lastSeen"`
	Count     int32     `json:"count"`
	Type      string    `json:"type"`
}

type EventBatch struct {
	Events []KubeEvent `json:"events"`
}

type PollEventsInput struct {
	ClusterName     string `json:"clusterName"`
	ResourceVersion string `json:"resourceVersion"`
}

type PollEventsResult struct {
	Events          []KubeEvent `json:"events"`
	ResourceVersion string      `json:"resourceVersion"`
}
