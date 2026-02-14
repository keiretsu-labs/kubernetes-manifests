package kubevents

import (
	"go.temporal.io/sdk/workflow"
)

func ClusterWatchWorkflow(ctx workflow.Context, input ClusterWatchInput) error {
	logger := workflow.GetLogger(ctx)
	logger.Info("ClusterWatchWorkflow started", "cluster", input.Name, "resourceVersion", input.ResourceVersion)

	events := make([]KubeEvent, 0, MaxBufferSize)
	lastResourceVersion := input.ResourceVersion

	if err := workflow.SetQueryHandler(ctx, QueryRecentEvents, func() ([]KubeEvent, error) {
		return events, nil
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
			logger.Info("received events", "cluster", input.Name, "batch", len(batch.Events), "total", len(events))
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

	logger.Info("continuing as new", "cluster", input.Name, "buffered", len(events), "rv", lastResourceVersion)
	return workflow.NewContinueAsNewError(ctx, ClusterWatchWorkflow, ClusterWatchInput{
		Name:            input.Name,
		Endpoint:        input.Endpoint,
		ResourceVersion: lastResourceVersion,
	})
}
