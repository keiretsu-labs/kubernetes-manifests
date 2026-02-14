package api

import (
	"context"
	"encoding/json"
	"io/fs"
	"log/slog"
	"net/http"

	"github.com/keiretsu-labs/kubernetes-manifests/swarm/internal/alerts"
	"github.com/keiretsu-labs/kubernetes-manifests/swarm/internal/config"
	"github.com/keiretsu-labs/kubernetes-manifests/swarm/internal/fluxmon"
	"go.temporal.io/sdk/client"
)

type Handler struct {
	tc       client.Client
	cfg      *config.Config
	staticFS fs.FS
}

func NewHandler(tc client.Client, cfg *config.Config, staticFS fs.FS) *Handler {
	return &Handler{tc: tc, cfg: cfg, staticFS: staticFS}
}

func (h *Handler) Mux() *http.ServeMux {
	mux := http.NewServeMux()

	// API routes
	mux.HandleFunc("GET /api/health", h.health)
	mux.HandleFunc("GET /api/clusters", h.clusters)
	mux.HandleFunc("GET /api/alerts", h.alerts)
	mux.HandleFunc("GET /api/flux", h.flux)
	mux.HandleFunc("GET /api/workflows", h.workflows)

	// Static UI files
	mux.Handle("/", http.FileServer(http.FS(h.staticFS)))

	return mux
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.Error("json encode failed", "error", err)
	}
}

func writeError(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

func (h *Handler) health(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]string{"status": "ok"})
}

func (h *Handler) clusters(w http.ResponseWriter, r *http.Request) {
	type clusterInfo struct {
		Name     string `json:"name"`
		Endpoint string `json:"endpoint"`
	}
	out := make([]clusterInfo, len(h.cfg.Clusters))
	for i, c := range h.cfg.Clusters {
		out[i] = clusterInfo{Name: c.Name, Endpoint: c.Endpoint}
	}
	writeJSON(w, out)
}

func (h *Handler) alerts(w http.ResponseWriter, r *http.Request) {
	resp, err := h.tc.QueryWorkflow(context.Background(), alerts.WorkflowID, "", alerts.QueryActive)
	if err != nil {
		writeError(w, 502, "failed to query alerts workflow")
		return
	}
	var active []alerts.Alert
	if err := resp.Get(&active); err != nil {
		writeError(w, 500, "failed to decode alerts")
		return
	}
	writeJSON(w, active)
}

type fluxClusterData struct {
	Ready     int                        `json:"ready"`
	Failed    int                        `json:"failed"`
	Suspended int                        `json:"suspended"`
	Total     int                        `json:"total"`
	Resources []fluxmon.FluxResourceStatus `json:"resources"`
}

func (h *Handler) flux(w http.ResponseWriter, r *http.Request) {
	out := make(map[string]*fluxClusterData)

	for _, cluster := range h.cfg.Clusters {
		workflowID := "flux-watch-" + cluster.Name
		cd := &fluxClusterData{}

		// Get summary
		resp, err := h.tc.QueryWorkflow(context.Background(), workflowID, "", fluxmon.QuerySummary)
		if err != nil {
			slog.Warn("failed to query flux summary", "cluster", cluster.Name, "error", err)
			out[cluster.Name] = cd
			continue
		}
		var summary fluxmon.ClusterSummary
		if err := resp.Get(&summary); err == nil {
			cd.Ready = summary.Ready
			cd.Failed = summary.Failed
			cd.Suspended = summary.Suspended
			cd.Total = summary.Total
		}

		// Get resources
		resp, err = h.tc.QueryWorkflow(context.Background(), workflowID, "", fluxmon.QueryResources)
		if err != nil {
			slog.Warn("failed to query flux resources", "cluster", cluster.Name, "error", err)
			out[cluster.Name] = cd
			continue
		}
		var resources map[string]fluxmon.FluxResourceStatus
		if err := resp.Get(&resources); err == nil {
			for _, r := range resources {
				cd.Resources = append(cd.Resources, r)
			}
		}

		out[cluster.Name] = cd
	}

	writeJSON(w, out)
}

type workflowInfo struct {
	ID        string `json:"id"`
	Type      string `json:"type"`
	Running   bool   `json:"running"`
	StartedAt string `json:"startedAt,omitempty"`
}

func (h *Handler) workflows(w http.ResponseWriter, r *http.Request) {
	var out []workflowInfo

	// Known workflow IDs
	ids := []struct {
		id   string
		kind string
	}{
		{alerts.WorkflowID, "AlertsWorkflow"},
	}
	for _, cluster := range h.cfg.Clusters {
		ids = append(ids,
			struct{ id, kind string }{"cluster-watch-" + cluster.Name, "ClusterWatchWorkflow"},
			struct{ id, kind string }{"flux-watch-" + cluster.Name, "FluxWatchWorkflow"},
		)
	}

	for _, wf := range ids {
		desc, err := h.tc.DescribeWorkflowExecution(context.Background(), wf.id, "")
		info := workflowInfo{ID: wf.id, Type: wf.kind}
		if err == nil && desc.WorkflowExecutionInfo != nil {
			info.Running = desc.WorkflowExecutionInfo.Status == 1 // RUNNING
			if desc.WorkflowExecutionInfo.StartTime != nil {
				info.StartedAt = desc.WorkflowExecutionInfo.StartTime.AsTime().Format("2006-01-02T15:04:05Z")
			}
		}
		out = append(out, info)
	}

	writeJSON(w, out)
}
