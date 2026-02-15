package kubevents

import (
	"context"
	"fmt"

	"go.temporal.io/sdk/activity"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/kubernetes"
)

type Activities struct {
	KubeClients map[string]*kubernetes.Clientset
}

func (a *Activities) PollKubeEvents(ctx context.Context, input PollEventsInput) (*PollEventsResult, error) {
	logger := activity.GetLogger(ctx)

	cs, ok := a.KubeClients[input.ClusterName]
	if !ok {
		return nil, fmt.Errorf("no kube client for cluster %s", input.ClusterName)
	}

	rv := input.ResourceVersion
	if rv == "" {
		list, err := cs.CoreV1().Events("").List(ctx, metav1.ListOptions{Limit: 1})
		if err != nil {
			return nil, fmt.Errorf("listing events for initial rv: %w", err)
		}
		rv = list.ResourceVersion
	}

	timeout := PollWatchTimeout
	watcher, err := cs.CoreV1().Events("").Watch(ctx, metav1.ListOptions{
		ResourceVersion: rv,
		TimeoutSeconds:  &timeout,
	})
	if err != nil {
		return nil, fmt.Errorf("starting watch from rv %s: %w", rv, err)
	}
	defer watcher.Stop()

	var events []KubeEvent
	for event := range watcher.ResultChan() {
		if event.Type == watch.Error {
			break
		}
		ev, ok := event.Object.(*corev1.Event)
		if !ok {
			continue
		}
		rv = ev.ResourceVersion
		ke := KubeEvent{
			Cluster:   input.ClusterName,
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
		events = append(events, ke)
	}

	logger.Info("polled events", "cluster", input.ClusterName, "count", len(events), "rv", rv)
	return &PollEventsResult{Events: events, ResourceVersion: rv}, nil
}
