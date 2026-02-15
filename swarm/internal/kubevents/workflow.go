package kubevents

import (
	"time"

	"github.com/keiretsu-labs/kubernetes-manifests/swarm/internal/clusterhealth"
	"go.temporal.io/sdk/temporal"
	"go.temporal.io/sdk/workflow"
)

type clusterWatchState struct {
	Input         ClusterWatchInput           `json:"input"`
	DetectorState *clusterhealth.DetectorState `json:"detectorState,omitempty"`
}

func ClusterWatchWorkflow(ctx workflow.Context, input ClusterWatchInput) error {
	return clusterWatchWorkflowImpl(ctx, clusterWatchState{Input: input})
}

func ClusterWatchWorkflowWithState(ctx workflow.Context, state clusterWatchState) error {
	return clusterWatchWorkflowImpl(ctx, state)
}

func toHealthEvent(ev KubeEvent) clusterhealth.Event {
	return clusterhealth.Event{
		Cluster:   ev.Cluster,
		Namespace: ev.Namespace,
		Name:      ev.Name,
		Kind:      ev.Kind,
		Reason:    ev.Reason,
		Message:   ev.Message,
		Source:    ev.Source,
		LastSeen:  ev.LastSeen,
		Type:      ev.Type,
	}
}

func clusterWatchWorkflowImpl(ctx workflow.Context, state clusterWatchState) error {
	logger := workflow.GetLogger(ctx)
	input := state.Input
	logger.Info("ClusterWatchWorkflow started", "cluster", input.Name, "resourceVersion", input.ResourceVersion)

	rv := input.ResourceVersion
	detectorState := state.DetectorState
	if detectorState == nil {
		detectorState = clusterhealth.NewDetectorState()
	}

	var recentEvents []KubeEvent

	if err := workflow.SetQueryHandler(ctx, QueryRecentEvents, func() ([]KubeEvent, error) {
		return recentEvents, nil
	}); err != nil {
		return err
	}

	if err := workflow.SetQueryHandler(ctx, clusterhealth.QueryActiveAlerts, func() (map[string]*clusterhealth.AlertEntry, error) {
		return detectorState.ActiveAlerts, nil
	}); err != nil {
		return err
	}

	activityCtx := workflow.WithActivityOptions(ctx, workflow.ActivityOptions{
		StartToCloseTimeout: 30 * time.Second,
		RetryPolicy: &temporal.RetryPolicy{
			InitialInterval:    2 * time.Second,
			BackoffCoefficient: 2.0,
			MaximumInterval:    30 * time.Second,
			MaximumAttempts:    3,
		},
	})

	for i := 0; i < MaxPollIterations; i++ {
		var result PollEventsResult
		err := workflow.ExecuteActivity(activityCtx, "PollKubeEvents", PollEventsInput{
			ClusterName:     input.Name,
			ResourceVersion: rv,
		}).Get(ctx, &result)

		if err != nil {
			logger.Warn("poll failed, will retry next iteration", "cluster", input.Name, "error", err)
		} else {
			rv = result.ResourceVersion
			now := workflow.Now(ctx)
			for _, ev := range result.Events {
				he := toHealthEvent(ev)
				clusterhealth.DetectCrashLoop(he, detectorState, now)
				clusterhealth.DetectOOMKilled(he, detectorState, now)
				clusterhealth.DetectImagePull(he, detectorState, now)
				clusterhealth.DetectStuckRollout(he, detectorState, now)
			}
			clusterhealth.ResolveStaleAlerts(detectorState, now)

			recentEvents = append(recentEvents, result.Events...)
			if len(recentEvents) > MaxBufferSize {
				recentEvents = recentEvents[len(recentEvents)-MaxBufferSize:]
			}

			if len(result.Events) > 0 {
				logger.Info("processed events", "cluster", input.Name, "batch", len(result.Events), "alerts", len(detectorState.ActiveAlerts))
			}
		}

		if err := workflow.Sleep(ctx, PollInterval); err != nil {
			return err
		}
	}

	logger.Info("continuing as new", "cluster", input.Name, "rv", rv, "alerts", len(detectorState.ActiveAlerts))
	return workflow.NewContinueAsNewError(ctx, ClusterWatchWorkflowWithState, clusterWatchState{
		Input: ClusterWatchInput{
			Name:            input.Name,
			Endpoint:        input.Endpoint,
			ResourceVersion: rv,
		},
		DetectorState: detectorState,
	})
}
