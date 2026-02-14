package tslifecycle

import (
	"time"

	"go.temporal.io/sdk/temporal"
	"go.temporal.io/sdk/workflow"
)

func DeviceCleanupWorkflow(ctx workflow.Context, input CleanupInput) (CleanupResult, error) {
	logger := workflow.GetLogger(ctx)
	logger.Info("DeviceCleanupWorkflow started", "tags", input.Tags, "dryRun", input.DryRun)

	if input.InactiveDays <= 0 {
		input.InactiveDays = DefaultCleanupInactiveDays
	}

	ao := workflow.ActivityOptions{
		StartToCloseTimeout: 30 * time.Second,
		RetryPolicy: &temporal.RetryPolicy{
			MaximumAttempts: 3,
		},
	}
	ctx = workflow.WithActivityOptions(ctx, ao)

	var acts *Activities
	var candidates []CleanupCandidate
	if err := workflow.ExecuteActivity(ctx, acts.ListInactiveDevices, input).Get(ctx, &candidates); err != nil {
		return CleanupResult{}, err
	}

	result := CleanupResult{
		Candidates: candidates,
		DryRun:     input.DryRun,
		Timestamp:  workflow.Now(ctx),
	}

	if input.DryRun {
		logger.Info("dry-run mode, skipping removal", "candidates", len(candidates))
		return result, nil
	}

	for _, c := range candidates {
		if err := workflow.ExecuteActivity(ctx, acts.RemoveDevice, c).Get(ctx, nil); err != nil {
			logger.Warn("failed to remove device", "deviceId", c.DeviceID, "error", err)
			continue
		}
		result.Removed = append(result.Removed, c)
	}

	logger.Info("cleanup complete", "removed", len(result.Removed), "total", len(candidates))
	return result, nil
}
