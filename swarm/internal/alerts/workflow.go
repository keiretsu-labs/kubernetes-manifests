package alerts

import (
	"go.temporal.io/sdk/workflow"
)

func AlertsWorkflow(ctx workflow.Context, input AlertsInput) error {
	logger := workflow.GetLogger(ctx)
	logger.Info("AlertsWorkflow started", "active", len(input.Active), "history", len(input.History))

	active := input.Active
	history := input.History

	if err := workflow.SetQueryHandler(ctx, QueryActive, func() ([]Alert, error) {
		return active, nil
	}); err != nil {
		return err
	}

	if err := workflow.SetQueryHandler(ctx, QueryHistory, func() ([]Alert, error) {
		return history, nil
	}); err != nil {
		return err
	}

	alertCh := workflow.GetSignalChannel(ctx, SignalAlert)
	timer := workflow.NewTimer(ctx, ContinueInterval)

	for {
		sel := workflow.NewSelector(ctx)

		sel.AddReceive(alertCh, func(ch workflow.ReceiveChannel, more bool) {
			var alert Alert
			ch.Receive(ctx, &alert)

			// Deduplicate: update existing alert with same ID
			updated := false
			for i := range active {
				if active[i].ID == alert.ID {
					active[i].Count = alert.Count
					active[i].LastSeen = alert.LastSeen
					active[i].Message = alert.Message
					updated = true
					break
				}
			}
			if !updated {
				active = append(active, alert)
			}

			logger.Info("received alert", "source", alert.Source, "detector", alert.Detector, "name", alert.Name)
		})

		sel.AddFuture(timer, func(f workflow.Future) {
			_ = f.Get(ctx, nil)
		})

		sel.Select(ctx)

		if timer.IsReady() {
			break
		}
	}

	// Move resolved alerts to history
	var remaining []Alert
	for _, a := range active {
		if a.Resolved {
			history = append(history, a)
		} else {
			remaining = append(remaining, a)
		}
	}
	if len(history) > MaxAlertHistory {
		history = history[len(history)-MaxAlertHistory:]
	}

	logger.Info("continuing as new", "active", len(remaining), "history", len(history))
	return workflow.NewContinueAsNewError(ctx, AlertsWorkflow, AlertsInput{
		Active:  remaining,
		History: history,
	})
}
