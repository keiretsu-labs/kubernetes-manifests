package kubevents

import (
	"github.com/keiretsu-labs/kubernetes-manifests/swarm/internal/clusterhealth"
	"go.temporal.io/sdk/workflow"
)

// clusterWatchState is the internal state carried through ContinueAsNew.
type clusterWatchState struct {
	Input         ClusterWatchInput            `json:"input"`
	DetectorState *clusterhealth.DetectorState `json:"detectorState,omitempty"`
}

func ClusterWatchWorkflow(ctx workflow.Context, input ClusterWatchInput) error {
	return clusterWatchWorkflowImpl(ctx, clusterWatchState{Input: input})
}

// ClusterWatchWorkflowWithState is the ContinueAsNew entrypoint that carries detector state.
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

	events := make([]KubeEvent, 0, MaxBufferSize)
	lastResourceVersion := input.ResourceVersion

	detectorState := state.DetectorState
	if detectorState == nil {
		detectorState = clusterhealth.NewDetectorState()
	}

	if err := workflow.SetQueryHandler(ctx, QueryRecentEvents, func() ([]KubeEvent, error) {
		return events, nil
	}); err != nil {
		return err
	}

	if err := workflow.SetQueryHandler(ctx, clusterhealth.QueryActiveAlerts, func() (map[string]*clusterhealth.AlertEntry, error) {
		return detectorState.ActiveAlerts, nil
	}); err != nil {
		return err
	}

	rvCh := workflow.GetSignalChannel(ctx, SignalResourceVersion)
	eventsCh := workflow.GetSignalChannel(ctx, SignalEvents)
	timer := workflow.NewTimer(ctx, ContinueAsNewInterval)

	for {
		sel := workflow.NewSelector(ctx)

		sel.AddReceive(eventsCh, func(ch workflow.ReceiveChannel, more bool) {
			var batch EventBatch
			ch.Receive(ctx, &batch)
			events = append(events, batch.Events...)

			now := workflow.Now(ctx)
			for _, ev := range batch.Events {
				he := toHealthEvent(ev)
				clusterhealth.DetectCrashLoop(he, detectorState, now)
				clusterhealth.DetectOOMKilled(he, detectorState, now)
				clusterhealth.DetectImagePull(he, detectorState, now)
				clusterhealth.DetectStuckRollout(he, detectorState, now)
			}
			clusterhealth.ResolveStaleAlerts(detectorState, now)

			logger.Info("received events", "cluster", input.Name, "batch", len(batch.Events), "total", len(events), "alerts", len(detectorState.ActiveAlerts))
		})

		sel.AddReceive(rvCh, func(ch workflow.ReceiveChannel, more bool) {
			ch.Receive(ctx, &lastResourceVersion)
		})

		sel.AddFuture(timer, func(f workflow.Future) {
			_ = f.Get(ctx, nil)
		})

		sel.Select(ctx)

		if len(events) >= MaxBufferSize || timer.IsReady() {
			break
		}
	}

	logger.Info("continuing as new", "cluster", input.Name, "buffered", len(events), "rv", lastResourceVersion, "alerts", len(detectorState.ActiveAlerts))
	return workflow.NewContinueAsNewError(ctx, ClusterWatchWorkflowWithState, clusterWatchState{
		Input: ClusterWatchInput{
			Name:            input.Name,
			Endpoint:        input.Endpoint,
			ResourceVersion: lastResourceVersion,
		},
		DetectorState: detectorState,
	})
}
