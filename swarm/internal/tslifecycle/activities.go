package tslifecycle

import (
	"context"
	"net"
	"sync"
	"time"

	"go.temporal.io/sdk/activity"
)

const maxConcurrentProbes = 10

type Activities struct{}

func (a *Activities) ProbeTargets(ctx context.Context, targets []ProbeTarget) ([]ProbeResult, error) {
	logger := activity.GetLogger(ctx)
	logger.Info("probing targets", "count", len(targets))

	results := make([]ProbeResult, len(targets))
	var wg sync.WaitGroup
	sem := make(chan struct{}, maxConcurrentProbes)

	for i, target := range targets {
		wg.Add(1)
		sem <- struct{}{}
		go func(idx int, t ProbeTarget) {
			defer wg.Done()
			defer func() { <-sem }()
			results[idx] = probeOne(ctx, t)
		}(i, target)
	}

	wg.Wait()
	return results, nil
}

func probeOne(ctx context.Context, target ProbeTarget) ProbeResult {
	start := time.Now()
	d := net.Dialer{Timeout: DefaultProbeTimeout}
	conn, err := d.DialContext(ctx, "tcp", target.Address)
	latency := time.Since(start)

	result := ProbeResult{
		Name:      target.Name,
		Address:   target.Address,
		Timestamp: start,
		Latency:   latency,
	}

	if err != nil {
		result.Reachable = false
		result.Error = err.Error()
		return result
	}
	_ = conn.Close()
	result.Reachable = true
	return result
}

func (a *Activities) ListInactiveDevices(ctx context.Context, input CleanupInput) ([]CleanupCandidate, error) {
	logger := activity.GetLogger(ctx)
	logger.Info("listing inactive devices", "tags", input.Tags, "inactiveDays", input.InactiveDays)
	// Placeholder -- real implementation calls Tailscale API
	return nil, nil
}

func (a *Activities) RemoveDevice(ctx context.Context, candidate CleanupCandidate) error {
	logger := activity.GetLogger(ctx)
	logger.Info("removing device", "deviceId", candidate.DeviceID, "hostname", candidate.Hostname)
	// Placeholder -- real implementation calls Tailscale API
	return nil
}
