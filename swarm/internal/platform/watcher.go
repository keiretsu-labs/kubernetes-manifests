package platform

import (
	"context"
	"log/slog"
	"time"

	"github.com/keiretsu-labs/kubernetes-manifests/swarm/internal/kubevents"
	"go.temporal.io/sdk/client"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/kubernetes"
)

func WatchAndSignal(ctx context.Context, tc client.Client, cs *kubernetes.Clientset, clusterName, workflowID string) {
	for {
		if ctx.Err() != nil {
			return
		}
		watchOnce(ctx, tc, cs, clusterName, workflowID)

		select {
		case <-ctx.Done():
			return
		case <-time.After(5 * time.Second):
		}
	}
}

func watchOnce(ctx context.Context, tc client.Client, cs *kubernetes.Clientset, clusterName, workflowID string) {
	logger := slog.With("cluster", clusterName)

	list, err := cs.CoreV1().Events("").List(ctx, metav1.ListOptions{Limit: 1})
	if err != nil {
		logger.Error("failed to list events for resourceVersion", "error", err)
		return
	}
	rv := list.ResourceVersion

	watcher, err := cs.CoreV1().Events("").Watch(ctx, metav1.ListOptions{
		ResourceVersion: rv,
	})
	if err != nil {
		logger.Error("failed to start watch", "error", err)
		return
	}
	defer watcher.Stop()

	logger.Info("watch started", "resourceVersion", rv)

	var batch []kubevents.KubeEvent
	flushTicker := time.NewTicker(5 * time.Second)
	defer flushTicker.Stop()

	flush := func() {
		if len(batch) == 0 {
			return
		}
		err := tc.SignalWorkflow(ctx, workflowID, "", kubevents.SignalEvents, kubevents.EventBatch{Events: batch})
		if err != nil {
			logger.Error("failed to signal workflow", "error", err, "count", len(batch))
			return
		}
		logger.Info("signaled events", "count", len(batch))
		batch = batch[:0]
	}

	for {
		select {
		case <-ctx.Done():
			flush()
			return

		case <-flushTicker.C:
			flush()
			if rv != "" {
				_ = tc.SignalWorkflow(ctx, workflowID, "", kubevents.SignalResourceVersion, rv)
			}

		case event, ok := <-watcher.ResultChan():
			if !ok {
				logger.Warn("watch channel closed")
				flush()
				return
			}

			if event.Type == watch.Error {
				logger.Warn("watch error")
				flush()
				return
			}

			ev, ok := event.Object.(*corev1.Event)
			if !ok {
				continue
			}

			rv = ev.ResourceVersion
			ke := kubevents.KubeEvent{
				Cluster:   clusterName,
				Namespace: ev.Namespace,
				Name:      ev.InvolvedObject.Name,
				Kind:      ev.InvolvedObject.Kind,
				Reason:    ev.Reason,
				Message:   ev.Message,
				Source:    ev.Source.Component,
				Count:     ev.Count,
				Type:      ev.Type,
			}
			if !ev.FirstTimestamp.IsZero() {
				ke.FirstSeen = ev.FirstTimestamp.Time
			}
			if !ev.LastTimestamp.IsZero() {
				ke.LastSeen = ev.LastTimestamp.Time
			}
			batch = append(batch, ke)
		}
	}
}
