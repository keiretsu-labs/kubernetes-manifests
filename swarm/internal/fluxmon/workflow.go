package fluxmon

import (
	"github.com/keiretsu-labs/kubernetes-manifests/swarm/internal/alerts"
	"go.temporal.io/sdk/workflow"
)

func FluxWatchWorkflow(ctx workflow.Context, input FluxWatchInput) error {
	logger := workflow.GetLogger(ctx)
	logger.Info("FluxWatchWorkflow started", "cluster", input.Name)

	resources := input.Resources
	if resources == nil {
		resources = make(map[string]FluxResourceStatus)
	}
	var updateCount int

	if err := workflow.SetQueryHandler(ctx, QueryResources, func() (map[string]FluxResourceStatus, error) {
		return resources, nil
	}); err != nil {
		return err
	}

	if err := workflow.SetQueryHandler(ctx, QueryAlerts, func() ([]alerts.Alert, error) {
		var result []alerts.Alert
		for _, r := range resources {
			if !r.Ready && !r.Suspended && !r.Deleted {
				result = append(result, alerts.Alert{
					ID:        "flux-not-ready:" + r.Cluster + "/" + r.Namespace + "/" + r.Name,
					Source:    alerts.SourceFluxReconciler,
					Detector:  "flux-not-ready",
					Severity:  "error",
					Cluster:   r.Cluster,
					Namespace: r.Namespace,
					Name:      r.Name,
					Kind:      r.Kind,
					Message:   r.Reason + ": " + r.Message,
					FirstSeen: r.LastTransition,
					LastSeen:  r.LastSeen,
				})
			}
		}
		return result, nil
	}); err != nil {
		return err
	}

	if err := workflow.SetQueryHandler(ctx, QuerySummary, func() (ClusterSummary, error) {
		var s ClusterSummary
		for _, r := range resources {
			if r.Deleted {
				continue
			}
			s.Total++
			switch {
			case r.Suspended:
				s.Suspended++
			case r.Ready:
				s.Ready++
			case !r.Ready && r.Reason != "":
				s.Failed++
			default:
				s.Unknown++
			}
		}
		return s, nil
	}); err != nil {
		return err
	}

	statusCh := workflow.GetSignalChannel(ctx, SignalStatusUpdate)
	timer := workflow.NewTimer(ctx, ContinueAsNewInterval)

	for {
		sel := workflow.NewSelector(ctx)

		sel.AddReceive(statusCh, func(ch workflow.ReceiveChannel, more bool) {
			var batch FluxStatusBatch
			ch.Receive(ctx, &batch)
			for _, s := range batch.Statuses {
				key := ResourceKey(s)
				if s.Deleted {
					delete(resources, key)
				} else {
					resources[key] = s
				}
				updateCount++
			}
			logger.Info("received statuses", "cluster", input.Name, "batch", len(batch.Statuses), "tracked", len(resources))
		})

		sel.AddFuture(timer, func(f workflow.Future) {
			_ = f.Get(ctx, nil)
		})

		sel.Select(ctx)

		if updateCount >= MaxStatusBuffer || timer.IsReady() {
			break
		}
	}

	logger.Info("continuing as new", "cluster", input.Name, "tracked", len(resources))
	return workflow.NewContinueAsNewError(ctx, FluxWatchWorkflow, FluxWatchInput{
		Name:      input.Name,
		Endpoint:  input.Endpoint,
		Resources: resources,
	})
}
