package fluxmon

import "time"

const (
	TaskQueue             = "swarm"
	SignalStatusUpdate    = "status-update"
	QueryResources        = "resources"
	QueryAlerts           = "alerts"
	QuerySummary          = "summary"
	MaxStatusBuffer       = 2000
	ContinueAsNewInterval = 10 * time.Minute
	PollInterval          = 30 * time.Second
	MaxPollIterations     = 20 // ~10min at 30s intervals before ContinueAsNew
)

type FluxWatchInput struct {
	Name      string                        `json:"name"`
	Endpoint  string                        `json:"endpoint"`
	Resources map[string]FluxResourceStatus `json:"resources,omitempty"`
}

type FluxResourceStatus struct {
	Cluster        string    `json:"cluster"`
	Namespace      string    `json:"namespace"`
	Name           string    `json:"name"`
	Kind           string    `json:"kind"`
	Ready          bool      `json:"ready"`
	Reason         string    `json:"reason"`
	Message        string    `json:"message"`
	Revision       string    `json:"revision"`
	Suspended      bool      `json:"suspended"`
	Deleted        bool      `json:"deleted"`
	LastTransition time.Time `json:"lastTransition"`
	LastSeen       time.Time `json:"lastSeen"`
}

type FluxStatusBatch struct {
	Statuses []FluxResourceStatus `json:"statuses"`
}

type ClusterSummary struct {
	Ready     int `json:"ready"`
	Failed    int `json:"failed"`
	Suspended int `json:"suspended"`
	Unknown   int `json:"unknown"`
	Total     int `json:"total"`
}

func ResourceKey(s FluxResourceStatus) string {
	return s.Kind + "/" + s.Namespace + "/" + s.Name
}

type PollFluxInput struct {
	ClusterName string `json:"clusterName"`
}

type PollFluxResult struct {
	Resources []FluxResourceStatus `json:"resources"`
}
