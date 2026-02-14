package kubevents

import "time"

const (
	TaskQueue             = "swarm-kube-events"
	SignalEvents          = "events"
	SignalResourceVersion = "resource-version"
	QueryRecentEvents     = "recent-events"
	MaxBufferSize         = 1000
	ContinueAsNewInterval = 5 * time.Minute
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

type WatchClusterEventsInput struct {
	ClusterName     string
	Endpoint        string
	ResourceVersion string
}
