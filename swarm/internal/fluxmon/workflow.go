package fluxmon

import (
	"time"

	"github.com/keiretsu-labs/kubernetes-manifests/swarm/internal/alerts"
	"go.temporal.io/sdk/temporal"
	"go.temporal.io/sdk/workflow"
)

func FluxWatchWorkflow(ctx workflow.Context, input FluxWatchInput) error {
	logger := workflow.GetLogger(ctx)
	logger.Info("FluxWatchWorkflow started", "cluster", input.Name)

	resources := input.Resources
	if resources == nil {
		resources = make(map[string]FluxResourceStatus)
	}

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

	activityCtx := workflow.WithActivityOptions(ctx, workflow.ActivityOptions{
		StartToCloseTimeout: 60 * time.Second,
		RetryPolicy: &temporal.RetryPolicy{
			InitialInterval:    5 * time.Second,
			BackoffCoefficient: 2.0,
			MaximumInterval:    60 * time.Second,
			MaximumAttempts:    3,
		},
	})

	for i := 0; i < MaxPollIterations; i++ {
		var result PollFluxResult
		err := workflow.ExecuteActivity(activityCtx, "PollFluxResources", PollFluxInput{
			ClusterName: input.Name,
		}).Get(ctx, &result)

		if err != nil {
			logger.Warn("flux poll failed, will retry next iteration", "cluster", input.Name, "error", err)
		} else {
			// Mark all existing resources as potentially deleted
			seen := make(map[string]bool)
			for _, r := range result.Resources {
				key := ResourceKey(r)
				seen[key] = true
				resources[key] = r
			}
			// Mark resources not seen in this poll as deleted
			for key, r := range resources {
				if !seen[key] && !r.Deleted {
					r.Deleted = true
					resources[key] = r
				}
			}

			logger.Info("processed flux resources", "cluster", input.Name, "tracked", len(resources))
		}

		if err := workflow.Sleep(ctx, PollInterval); err != nil {
			return err
		}
	}

	logger.Info("continuing as new", "cluster", input.Name, "tracked", len(resources))
	return workflow.NewContinueAsNewError(ctx, FluxWatchWorkflow, FluxWatchInput{
		Name:      input.Name,
		Endpoint:  input.Endpoint,
		Resources: resources,
	})
}
