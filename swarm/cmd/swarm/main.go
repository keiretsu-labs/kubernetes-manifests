package main

import (
	"context"
	"flag"
	"fmt"
	"io/fs"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"

	"github.com/keiretsu-labs/kubernetes-manifests/swarm/internal/alerts"
	swarmapi "github.com/keiretsu-labs/kubernetes-manifests/swarm/internal/api"
	"github.com/keiretsu-labs/kubernetes-manifests/swarm/internal/config"
	"github.com/keiretsu-labs/kubernetes-manifests/swarm/internal/fluxmon"
	"github.com/keiretsu-labs/kubernetes-manifests/swarm/internal/kubevents"
	"github.com/keiretsu-labs/kubernetes-manifests/swarm/internal/platform"
	"github.com/keiretsu-labs/kubernetes-manifests/swarm/internal/tslifecycle"
	"github.com/keiretsu-labs/kubernetes-manifests/swarm/ui"
	enumspb "go.temporal.io/api/enums/v1"
	"go.temporal.io/sdk/client"
	"go.temporal.io/sdk/worker"
	"k8s.io/client-go/kubernetes"
)

func main() {
	configPath := flag.String("config", os.Getenv("CONFIG_PATH"), "path to config file")
	flag.Parse()

	if *configPath == "" {
		slog.Error("config path required: set -config flag or CONFIG_PATH env")
		os.Exit(1)
	}

	cfg, err := config.Load(*configPath)
	if err != nil {
		slog.Error("failed to load config", "error", err)
		os.Exit(1)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	srv := platform.NewTsnetServer(&cfg.Tailscale)
	var closeOnce sync.Once
	closeSrv := func() { closeOnce.Do(func() { _ = srv.Close() }) }
	defer closeSrv()

	if err := platform.StartTsnet(ctx, srv); err != nil {
		slog.Error("tsnet failed", "error", err)
		os.Exit(1)
	}

	tc, err := platform.NewTemporalClient(ctx, &cfg.Temporal, srv)
	if err != nil {
		slog.Error("temporal client failed", "error", err)
		os.Exit(1)
	}
	defer tc.Close()

	kubeClients := make(map[string]*kubernetes.Clientset)
	for _, cluster := range cfg.Clusters {
		cs, err := platform.NewKubeClient(srv, cluster.Endpoint)
		if err != nil {
			slog.Error("kube client failed", "cluster", cluster.Name, "error", err)
			os.Exit(1)
		}
		kubeClients[cluster.Name] = cs
		slog.Info("kube client created", "cluster", cluster.Name, "endpoint", cluster.Endpoint)
	}

	w := worker.New(tc, cfg.Temporal.TaskQueue, worker.Options{})

	// Register kube-events workflows and activities
	kubeActivities := &kubevents.Activities{KubeClients: kubeClients}
	w.RegisterWorkflow(kubevents.ClusterWatchWorkflow)
	w.RegisterActivity(kubeActivities)

	// Register flux monitoring workflow
	w.RegisterWorkflow(fluxmon.FluxWatchWorkflow)

	// Register alerts workflow
	w.RegisterWorkflow(alerts.AlertsWorkflow)

	// Register tslifecycle workflows and activities
	tsActivities := &tslifecycle.Activities{}
	w.RegisterWorkflow(tslifecycle.DeviceCleanupWorkflow)
	w.RegisterWorkflow(tslifecycle.ConnectivityProbeWorkflow)
	w.RegisterActivity(tsActivities)

	// Start cluster watch workflows (kube events + health detection)
	for _, cluster := range cfg.Clusters {
		workflowID := fmt.Sprintf("cluster-watch-%s", cluster.Name)
		_, err := tc.ExecuteWorkflow(ctx, client.StartWorkflowOptions{
			ID:                    workflowID,
			TaskQueue:             cfg.Temporal.TaskQueue,
			WorkflowIDConflictPolicy: enumspb.WORKFLOW_ID_CONFLICT_POLICY_TERMINATE_EXISTING,
		}, kubevents.ClusterWatchWorkflow, kubevents.ClusterWatchInput{
			Name:     cluster.Name,
			Endpoint: cluster.Endpoint,
		})
		if err != nil {
			slog.Warn("workflow start failed", "workflow", workflowID, "error", err)
		} else {
			slog.Info("started workflow", "workflow", workflowID)
		}

		cs := kubeClients[cluster.Name]
		go platform.WatchAndSignal(ctx, tc, cs, cluster.Name, workflowID)
	}

	// Start flux watch workflows
	for _, cluster := range cfg.Clusters {
		workflowID := fmt.Sprintf("flux-watch-%s", cluster.Name)
		_, err := tc.ExecuteWorkflow(ctx, client.StartWorkflowOptions{
			ID:                    workflowID,
			TaskQueue:             cfg.Temporal.TaskQueue,
			WorkflowIDConflictPolicy: enumspb.WORKFLOW_ID_CONFLICT_POLICY_TERMINATE_EXISTING,
		}, fluxmon.FluxWatchWorkflow, fluxmon.FluxWatchInput{
			Name:     cluster.Name,
			Endpoint: cluster.Endpoint,
		})
		if err != nil {
			slog.Warn("workflow start failed", "workflow", workflowID, "error", err)
		} else {
			slog.Info("started workflow", "workflow", workflowID)
		}
	}

	// Start alerts aggregation workflow
	_, err = tc.ExecuteWorkflow(ctx, client.StartWorkflowOptions{
		ID:                    alerts.WorkflowID,
		TaskQueue:             cfg.Temporal.TaskQueue,
		WorkflowIDConflictPolicy: enumspb.WORKFLOW_ID_CONFLICT_POLICY_TERMINATE_EXISTING,
	}, alerts.AlertsWorkflow, alerts.AlertsInput{})
	if err != nil {
		slog.Warn("alerts workflow start failed", "error", err)
	} else {
		slog.Info("started alerts workflow")
	}

	// Start HTTP UI server on tsnet (accessible via Tailscale)
	staticFS, _ := fs.Sub(ui.StaticFiles, "static")
	apiHandler := swarmapi.NewHandler(tc, cfg, staticFS)
	ln, err := srv.Listen("tcp", ":80")
	if err != nil {
		slog.Error("failed to listen on tsnet", "error", err)
		os.Exit(1)
	}
	httpSrv := &http.Server{Handler: apiHandler.Mux()}
	go func() {
		slog.Info("UI server started", "url", fmt.Sprintf("http://%s", srv.Hostname))
		if err := httpSrv.Serve(ln); err != nil && err != http.ErrServerClosed {
			slog.Error("http server error", "error", err)
		}
	}()

	// Serve full API on regular network for gateway routing and kubelet probes
	healthSrv := &http.Server{Addr: ":8080", Handler: apiHandler.Mux()}
	go func() {
		if err := healthSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("health server error", "error", err)
		}
	}()

	slog.Info("swarm worker started",
		"clusters", len(cfg.Clusters),
		"taskQueue", cfg.Temporal.TaskQueue,
	)

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		<-sigCh
		slog.Info("shutting down")
		_ = httpSrv.Shutdown(context.Background())
		_ = healthSrv.Shutdown(context.Background())
		cancel()
		closeSrv()
	}()

	if err := w.Run(worker.InterruptCh()); err != nil {
		cancel()
		slog.Error("worker exited with error", "error", err)
		os.Exit(1)
	}
}
