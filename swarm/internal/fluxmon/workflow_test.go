package fluxmon

import (
	"testing"
	"time"

	"github.com/keiretsu-labs/kubernetes-manifests/swarm/internal/alerts"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.temporal.io/sdk/testsuite"
)

func TestFluxWatchWorkflow_ReceivesStatuses(t *testing.T) {
	s := testsuite.WorkflowTestSuite{}
	env := s.NewTestWorkflowEnvironment()

	env.RegisterDelayedCallback(func() {
		env.SignalWorkflow(SignalStatusUpdate, FluxStatusBatch{
			Statuses: []FluxResourceStatus{
				{Cluster: "test", Kind: "Kustomization", Namespace: "flux-system", Name: "app1", Ready: true, Reason: "ReconciliationSucceeded"},
				{Cluster: "test", Kind: "HelmRelease", Namespace: "flux-system", Name: "chart1", Ready: true, Reason: "UpgradeSucceeded"},
			},
		})
	}, 100*time.Millisecond)

	env.ExecuteWorkflow(FluxWatchWorkflow, FluxWatchInput{Name: "test", Endpoint: "test:443"})
	assert.True(t, env.IsWorkflowCompleted())
	err := env.GetWorkflowError()
	assert.NotNil(t, err)
	assert.Contains(t, err.Error(), "continue as new")
}

func TestFluxWatchWorkflow_QueryResources(t *testing.T) {
	s := testsuite.WorkflowTestSuite{}
	env := s.NewTestWorkflowEnvironment()

	env.RegisterDelayedCallback(func() {
		env.SignalWorkflow(SignalStatusUpdate, FluxStatusBatch{
			Statuses: []FluxResourceStatus{
				{Cluster: "test", Kind: "Kustomization", Namespace: "flux-system", Name: "app1", Ready: true},
			},
		})
	}, 100*time.Millisecond)

	env.RegisterDelayedCallback(func() {
		result, err := env.QueryWorkflow(QueryResources)
		require.NoError(t, err)
		var resources map[string]FluxResourceStatus
		require.NoError(t, result.Get(&resources))
		assert.Len(t, resources, 1)
		assert.True(t, resources["Kustomization/flux-system/app1"].Ready)
	}, 200*time.Millisecond)

	env.ExecuteWorkflow(FluxWatchWorkflow, FluxWatchInput{Name: "test", Endpoint: "test:443"})
	assert.True(t, env.IsWorkflowCompleted())
}

func TestFluxWatchWorkflow_QuerySummary(t *testing.T) {
	s := testsuite.WorkflowTestSuite{}
	env := s.NewTestWorkflowEnvironment()

	env.RegisterDelayedCallback(func() {
		env.SignalWorkflow(SignalStatusUpdate, FluxStatusBatch{
			Statuses: []FluxResourceStatus{
				{Cluster: "test", Kind: "Kustomization", Namespace: "ns", Name: "ok", Ready: true},
				{Cluster: "test", Kind: "Kustomization", Namespace: "ns", Name: "bad", Ready: false, Reason: "Failed"},
				{Cluster: "test", Kind: "HelmRelease", Namespace: "ns", Name: "paused", Suspended: true},
			},
		})
	}, 100*time.Millisecond)

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
	s := testsuite.WorkflowTestSuite{}
	env := s.NewTestWorkflowEnvironment()

	env.RegisterDelayedCallback(func() {
		env.SignalWorkflow(SignalStatusUpdate, FluxStatusBatch{
			Statuses: []FluxResourceStatus{
				{Cluster: "test", Kind: "Kustomization", Namespace: "ns", Name: "failing", Ready: false, Reason: "ReconciliationFailed", Message: "apply failed"},
			},
		})
	}, 100*time.Millisecond)

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

func TestFluxWatchWorkflow_DeletedResource(t *testing.T) {
	s := testsuite.WorkflowTestSuite{}
	env := s.NewTestWorkflowEnvironment()

	env.RegisterDelayedCallback(func() {
		env.SignalWorkflow(SignalStatusUpdate, FluxStatusBatch{
			Statuses: []FluxResourceStatus{
				{Cluster: "test", Kind: "Kustomization", Namespace: "ns", Name: "app1", Ready: true},
			},
		})
	}, 100*time.Millisecond)

	env.RegisterDelayedCallback(func() {
		env.SignalWorkflow(SignalStatusUpdate, FluxStatusBatch{
			Statuses: []FluxResourceStatus{
				{Cluster: "test", Kind: "Kustomization", Namespace: "ns", Name: "app1", Deleted: true},
			},
		})
	}, 200*time.Millisecond)

	env.RegisterDelayedCallback(func() {
		result, err := env.QueryWorkflow(QueryResources)
		require.NoError(t, err)
		var resources map[string]FluxResourceStatus
		require.NoError(t, result.Get(&resources))
		assert.Len(t, resources, 0)
	}, 300*time.Millisecond)

	env.ExecuteWorkflow(FluxWatchWorkflow, FluxWatchInput{Name: "test", Endpoint: "test:443"})
	assert.True(t, env.IsWorkflowCompleted())
}

func TestFluxWatchWorkflow_CarriesResourcesOnContinueAsNew(t *testing.T) {
	s := testsuite.WorkflowTestSuite{}
	env := s.NewTestWorkflowEnvironment()

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
		assert.Len(t, resources, 1)
		assert.True(t, resources["Kustomization/ns/existing"].Ready)
	}, 100*time.Millisecond)

	env.ExecuteWorkflow(FluxWatchWorkflow, existing)
	assert.True(t, env.IsWorkflowCompleted())
}

func TestFluxWatchWorkflow_BufferOverflow(t *testing.T) {
	s := testsuite.WorkflowTestSuite{}
	env := s.NewTestWorkflowEnvironment()

	bigBatch := make([]FluxResourceStatus, MaxStatusBuffer+1)
	for i := range bigBatch {
		bigBatch[i] = FluxResourceStatus{Cluster: "test", Kind: "Kustomization", Namespace: "ns", Name: "filler", Ready: true}
	}

	env.RegisterDelayedCallback(func() {
		env.SignalWorkflow(SignalStatusUpdate, FluxStatusBatch{Statuses: bigBatch})
	}, 100*time.Millisecond)

	env.ExecuteWorkflow(FluxWatchWorkflow, FluxWatchInput{Name: "test", Endpoint: "test:443"})
	assert.True(t, env.IsWorkflowCompleted())
	err := env.GetWorkflowError()
	assert.NotNil(t, err)
	assert.Contains(t, err.Error(), "continue as new")
}
