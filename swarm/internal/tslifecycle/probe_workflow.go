package tslifecycle

import (
	"time"

	"go.temporal.io/sdk/temporal"
	"go.temporal.io/sdk/workflow"
)

func ConnectivityProbeWorkflow(ctx workflow.Context, input ProbeInput) ([]ProbeResult, error) {
	logger := workflow.GetLogger(ctx)
	logger.Info("ConnectivityProbeWorkflow started", "targets", len(input.Targets))

	ao := workflow.ActivityOptions{
		StartToCloseTimeout: 60 * time.Second,
		RetryPolicy: &temporal.RetryPolicy{
			MaximumAttempts: 2,
		},
	}
	ctx = workflow.WithActivityOptions(ctx, ao)

	var acts *Activities
	var results []ProbeResult
	if err := workflow.ExecuteActivity(ctx, acts.ProbeTargets, input.Targets).Get(ctx, &results); err != nil {
		return nil, err
	}

	logger.Info("probing complete", "results", len(results))
	return results, nil
}
