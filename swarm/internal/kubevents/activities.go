package kubevents

import (
	"context"
	"fmt"

	"go.temporal.io/sdk/activity"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

type Activities struct {
	KubeClients map[string]*kubernetes.Clientset
}

func (a *Activities) ListRecentEvents(ctx context.Context, input WatchClusterEventsInput) ([]KubeEvent, error) {
	logger := activity.GetLogger(ctx)

	cs, ok := a.KubeClients[input.ClusterName]
	if !ok {
		return nil, fmt.Errorf("no kube client for cluster %s", input.ClusterName)
	}

	list, err := cs.CoreV1().Events("").List(ctx, metav1.ListOptions{
		Limit: 100,
	})
	if err != nil {
		return nil, fmt.Errorf("listing events: %w", err)
	}

	var events []KubeEvent
	for _, ev := range list.Items {
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

	logger.Info("listed events", "cluster", input.ClusterName, "count", len(events))
	return events, nil
}
