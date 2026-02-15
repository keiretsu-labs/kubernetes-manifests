package fluxmon

import (
	"context"
	"testing"
	"time"

	"github.com/keiretsu-labs/kubernetes-manifests/swarm/internal/alerts"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/mock"
	"github.com/stretchr/testify/require"
	"go.temporal.io/sdk/testsuite"
	"k8s.io/client-go/dynamic"
)

func setupFluxTestEnv(t *testing.T) *testsuite.TestWorkflowEnvironment {
	t.Helper()
	s := testsuite.WorkflowTestSuite{}
	env := s.NewTestWorkflowEnvironment()
	env.RegisterActivity(&FluxActivities{DynamicClients: make(map[string]dynamic.Interface)})
	return env
}

func mockPollFlux(resources []FluxResourceStatus) func(ctx context.Context, input PollFluxInput) (*PollFluxResult, error) {
	return func(ctx context.Context, input PollFluxInput) (*PollFluxResult, error) {
		return &PollFluxResult{Resources: resources}, nil
	}
}

func TestFluxWatchWorkflow_ReceivesStatuses(t *testing.T) {
	env := setupFluxTestEnv(t)

	resources := []FluxResourceStatus{
		{Cluster: "test", Kind: "Kustomization", Namespace: "flux-system", Name: "app1", Ready: true, Reason: "ReconciliationSucceeded"},
		{Cluster: "test", Kind: "HelmRelease", Namespace: "flux-system", Name: "chart1", Ready: true, Reason: "UpgradeSucceeded"},
	}
	env.OnActivity("PollFluxResources", mock.Anything, mock.Anything).Return(
		mockPollFlux(resources),
	)

	env.ExecuteWorkflow(FluxWatchWorkflow, FluxWatchInput{Name: "test", Endpoint: "test:443"})
	assert.True(t, env.IsWorkflowCompleted())
	err := env.GetWorkflowError()
	assert.NotNil(t, err)
	assert.Contains(t, err.Error(), "continue as new")
}

func TestFluxWatchWorkflow_QueryResources(t *testing.T) {
	env := setupFluxTestEnv(t)

	resources := []FluxResourceStatus{
		{Cluster: "test", Kind: "Kustomization", Namespace: "flux-system", Name: "app1", Ready: true},
	}
	env.OnActivity("PollFluxResources", mock.Anything, mock.Anything).Return(
		mockPollFlux(resources),
	)

	env.RegisterDelayedCallback(func() {
		result, err := env.QueryWorkflow(QueryResources)
		require.NoError(t, err)
		var got map[string]FluxResourceStatus
		require.NoError(t, result.Get(&got))
		assert.Len(t, got, 1)
		assert.True(t, got["Kustomization/flux-system/app1"].Ready)
	}, 200*time.Millisecond)

	env.ExecuteWorkflow(FluxWatchWorkflow, FluxWatchInput{Name: "test", Endpoint: "test:443"})
	assert.True(t, env.IsWorkflowCompleted())
}

func TestFluxWatchWorkflow_QuerySummary(t *testing.T) {
	env := setupFluxTestEnv(t)

	resources := []FluxResourceStatus{
		{Cluster: "test", Kind: "Kustomization", Namespace: "ns", Name: "ok", Ready: true},
		{Cluster: "test", Kind: "Kustomization", Namespace: "ns", Name: "bad", Ready: false, Reason: "Failed"},
		{Cluster: "test", Kind: "HelmRelease", Namespace: "ns", Name: "paused", Suspended: true},
	}
	env.OnActivity("PollFluxResources", mock.Anything, mock.Anything).Return(
		mockPollFlux(resources),
	)

	env.RegisterDelayedCallback(func() {
		result, err := env.QueryWorkflow(QuerySummary)
		require.NoError(t, err)
		var summary ClusterSummary
		require.NoError(t, result.Get(&summary))
		assert.Equal(t, 1, summary.Ready)
		assert.Equal(t, 1, summary.Failed)
		assert.Equal(t, 1, summary.Suspended)
		assert.Equal(t, 3, summary.Total)
	}, 200*time.Millisecond)

	env.ExecuteWorkflow(FluxWatchWorkflow, FluxWatchInput{Name: "test", Endpoint: "test:443"})
	assert.True(t, env.IsWorkflowCompleted())
}

func TestFluxWatchWorkflow_QueryAlerts(t *testing.T) {
	env := setupFluxTestEnv(t)

	resources := []FluxResourceStatus{
		{Cluster: "test", Kind: "Kustomization", Namespace: "ns", Name: "failing", Ready: false, Reason: "ReconciliationFailed", Message: "apply failed"},
	}
	env.OnActivity("PollFluxResources", mock.Anything, mock.Anything).Return(
		mockPollFlux(resources),
	)

	env.RegisterDelayedCallback(func() {
		result, err := env.QueryWorkflow(QueryAlerts)
		require.NoError(t, err)
		var alertList []alerts.Alert
		require.NoError(t, result.Get(&alertList))
		assert.Len(t, alertList, 1)
		assert.Equal(t, alerts.SourceFluxReconciler, alertList[0].Source)
		assert.Equal(t, "failing", alertList[0].Name)
	}, 200*time.Millisecond)

	env.ExecuteWorkflow(FluxWatchWorkflow, FluxWatchInput{Name: "test", Endpoint: "test:443"})
	assert.True(t, env.IsWorkflowCompleted())
}

func TestFluxWatchWorkflow_CarriesResourcesOnContinueAsNew(t *testing.T) {
	env := setupFluxTestEnv(t)

	// Return empty polls — existing resources should still be carried
	env.OnActivity("PollFluxResources", mock.Anything, mock.Anything).Return(
		&PollFluxResult{Resources: []FluxResourceStatus{
			{Cluster: "test", Kind: "Kustomization", Namespace: "ns", Name: "existing", Ready: true},
		}}, nil,
	)

	existing := FluxWatchInput{
		Name:     "test",
		Endpoint: "test:443",
		Resources: map[string]FluxResourceStatus{
			"Kustomization/ns/existing": {Cluster: "test", Kind: "Kustomization", Namespace: "ns", Name: "existing", Ready: true},
		},
	}

	env.RegisterDelayedCallback(func() {
		result, err := env.QueryWorkflow(QueryResources)
		require.NoError(t, err)
		var resources map[string]FluxResourceStatus
		require.NoError(t, result.Get(&resources))
		assert.Contains(t, resources, "Kustomization/ns/existing")
	}, 200*time.Millisecond)

	env.ExecuteWorkflow(FluxWatchWorkflow, existing)
	assert.True(t, env.IsWorkflowCompleted())
}
