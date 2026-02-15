package fluxmon

import (
	"context"
	"fmt"
	"time"

	"github.com/keiretsu-labs/kubernetes-manifests/swarm/internal/platform"
	"go.temporal.io/sdk/activity"
	"k8s.io/client-go/dynamic"
)

type FluxActivities struct {
	DynamicClients map[string]dynamic.Interface
}

func (a *FluxActivities) PollFluxResources(ctx context.Context, input PollFluxInput) (*PollFluxResult, error) {
	logger := activity.GetLogger(ctx)

	dc, ok := a.DynamicClients[input.ClusterName]
	if !ok {
		return nil, fmt.Errorf("no dynamic client for cluster %s", input.ClusterName)
	}

	raw, err := platform.ListFluxResources(ctx, dc, input.ClusterName)
	if err != nil {
		return nil, fmt.Errorf("listing flux resources: %w", err)
	}

	now := time.Now()
	resources := make([]FluxResourceStatus, 0, len(raw))
	for _, r := range raw {
		resources = append(resources, FluxResourceStatus{
			Cluster:        r.Cluster,
			Namespace:      r.Namespace,
			Name:           r.Name,
			Kind:           r.Kind,
			Ready:          r.Ready,
			Reason:         r.Reason,
			Message:        r.Message,
			Revision:       r.Revision,
			Suspended:      r.Suspended,
			LastTransition: r.LastTransition,
			LastSeen:       now,
		})
	}

	logger.Info("polled flux resources", "cluster", input.ClusterName, "count", len(resources))
	return &PollFluxResult{Resources: resources}, nil
}
