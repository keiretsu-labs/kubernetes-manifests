package alerts

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.temporal.io/sdk/testsuite"
)

func TestAlertsWorkflow_ReceivesAndQueries(t *testing.T) {
	s := testsuite.WorkflowTestSuite{}
	env := s.NewTestWorkflowEnvironment()

	env.RegisterDelayedCallback(func() {
		env.SignalWorkflow(SignalAlert, Alert{
			ID: "crash-loop:test/default/pod1", Source: SourceClusterHealth,
			Detector: "crash-loop", Severity: "error",
			Cluster: "test", Namespace: "default", Name: "pod1",
			Count: 3, FirstSeen: time.Now(), LastSeen: time.Now(),
		})
	}, 100*time.Millisecond)

	env.RegisterDelayedCallback(func() {
		result, err := env.QueryWorkflow(QueryActive)
		require.NoError(t, err)
		var active []Alert
		require.NoError(t, result.Get(&active))
		assert.Len(t, active, 1)
		assert.Equal(t, "crash-loop", active[0].Detector)
		assert.Equal(t, SourceClusterHealth, active[0].Source)
	}, 200*time.Millisecond)

	env.ExecuteWorkflow(AlertsWorkflow, AlertsInput{})
	assert.True(t, env.IsWorkflowCompleted())
	err := env.GetWorkflowError()
	assert.NotNil(t, err)
	assert.Contains(t, err.Error(), "continue as new")
}

func TestAlertsWorkflow_DeduplicatesById(t *testing.T) {
	s := testsuite.WorkflowTestSuite{}
	env := s.NewTestWorkflowEnvironment()

	now := time.Now()
	env.RegisterDelayedCallback(func() {
		env.SignalWorkflow(SignalAlert, Alert{
			ID: "oom:test/default/pod1", Source: SourceClusterHealth,
			Count: 1, FirstSeen: now, LastSeen: now,
		})
	}, 100*time.Millisecond)

	env.RegisterDelayedCallback(func() {
		env.SignalWorkflow(SignalAlert, Alert{
			ID: "oom:test/default/pod1", Source: SourceClusterHealth,
			Count: 2, LastSeen: now.Add(time.Minute),
		})
	}, 200*time.Millisecond)

	env.RegisterDelayedCallback(func() {
		result, err := env.QueryWorkflow(QueryActive)
		require.NoError(t, err)
		var active []Alert
		require.NoError(t, result.Get(&active))
		assert.Len(t, active, 1)
		assert.Equal(t, 2, active[0].Count)
	}, 300*time.Millisecond)

	env.ExecuteWorkflow(AlertsWorkflow, AlertsInput{})
	assert.True(t, env.IsWorkflowCompleted())
}

func TestAlertsWorkflow_CarriesStateOnContinueAsNew(t *testing.T) {
	s := testsuite.WorkflowTestSuite{}
	env := s.NewTestWorkflowEnvironment()

	existing := AlertsInput{
		Active: []Alert{{ID: "old-alert", Source: SourceFluxReconciler, Detector: "flux-not-ready", Name: "app1"}},
		History: []Alert{{ID: "resolved", Source: SourceClusterHealth, Resolved: true}},
	}

	env.RegisterDelayedCallback(func() {
		result, err := env.QueryWorkflow(QueryActive)
		require.NoError(t, err)
		var active []Alert
		require.NoError(t, result.Get(&active))
		assert.Len(t, active, 1)
		assert.Equal(t, "app1", active[0].Name)

		result, err = env.QueryWorkflow(QueryHistory)
		require.NoError(t, err)
		var history []Alert
		require.NoError(t, result.Get(&history))
		assert.Len(t, history, 1)
	}, 100*time.Millisecond)

	env.ExecuteWorkflow(AlertsWorkflow, existing)
	assert.True(t, env.IsWorkflowCompleted())
}

func TestAlertsWorkflow_EmptyQueries(t *testing.T) {
	s := testsuite.WorkflowTestSuite{}
	env := s.NewTestWorkflowEnvironment()

	env.ExecuteWorkflow(AlertsWorkflow, AlertsInput{})

	result, err := env.QueryWorkflow(QueryHistory)
	require.NoError(t, err)
	var history []Alert
	require.NoError(t, result.Get(&history))
	assert.Empty(t, history)
}
