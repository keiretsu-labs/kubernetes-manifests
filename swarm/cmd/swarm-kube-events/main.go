package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/keiretsu-labs/kubernetes-manifests/swarm/internal/config"
	"github.com/keiretsu-labs/kubernetes-manifests/swarm/internal/kubevents"
	"github.com/keiretsu-labs/kubernetes-manifests/swarm/internal/platform"
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
	defer func() { _ = srv.Close() }()

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
	activities := &kubevents.Activities{KubeClients: kubeClients}
	w.RegisterWorkflow(kubevents.ClusterWatchWorkflow)
	w.RegisterActivity(activities)

	for _, cluster := range cfg.Clusters {
		workflowID := fmt.Sprintf("cluster-watch-%s", cluster.Name)

		_, err := tc.ExecuteWorkflow(ctx, client.StartWorkflowOptions{
			ID:        workflowID,
			TaskQueue: cfg.Temporal.TaskQueue,
		}, kubevents.ClusterWatchWorkflow, kubevents.ClusterWatchInput{
			Name:     cluster.Name,
			Endpoint: cluster.Endpoint,
		})
		if err != nil {
			slog.Warn("workflow may already be running", "cluster", cluster.Name, "error", err)
		} else {
			slog.Info("started cluster watch workflow", "cluster", cluster.Name, "workflowID", workflowID)
		}

		cs := kubeClients[cluster.Name]
		go platform.WatchAndSignal(ctx, tc, cs, cluster.Name, workflowID)
	}

	slog.Info("swarm-kube-events started", "clusters", len(cfg.Clusters), "taskQueue", cfg.Temporal.TaskQueue)

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		<-sigCh
		slog.Info("shutting down")
		cancel()
		_ = srv.Close()
	}()

	if err := w.Run(worker.InterruptCh()); err != nil {
		slog.Error("worker exited with error", "error", err)
		os.Exit(1)
	}
}
