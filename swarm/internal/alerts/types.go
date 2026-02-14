package alerts

import "time"

const (
	WorkflowID       = "swarm-alerts"
	SignalAlert       = "alert"
	QueryActive      = "active-alerts"
	QueryHistory     = "alert-history"
	MaxAlertHistory  = 200
	ContinueInterval = 30 * time.Minute

	SourceClusterHealth  = "cluster-health"
	SourceFluxReconciler = "flux-reconciler"
)

type Alert struct {
	ID         string    `json:"id"`
	Source     string    `json:"source"`
	Detector   string    `json:"detector"`
	Severity   string    `json:"severity"`
	Cluster    string    `json:"cluster"`
	Namespace  string    `json:"namespace"`
	Name       string    `json:"name"`
	Kind       string    `json:"kind"`
	Message    string    `json:"message"`
	Count      int       `json:"count"`
	FirstSeen  time.Time `json:"firstSeen"`
	LastSeen   time.Time `json:"lastSeen"`
	Resolved   bool      `json:"resolved"`
	ResolvedAt time.Time `json:"resolvedAt,omitempty"`
}

type AlertsInput struct {
	Active  []Alert `json:"active,omitempty"`
	History []Alert `json:"history,omitempty"`
}
