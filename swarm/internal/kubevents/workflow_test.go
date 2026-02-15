package kubevents

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/mock"
	"go.temporal.io/sdk/testsuite"
	"k8s.io/client-go/kubernetes"
)

func setupKubeTestEnv(t *testing.T) *testsuite.TestWorkflowEnvironment {
	t.Helper()
	s := testsuite.WorkflowTestSuite{}
	env := s.NewTestWorkflowEnvironment()
	env.RegisterActivity(&Activities{KubeClients: make(map[string]*kubernetes.Clientset)})
	return env
}

func mockPollEvents(events []KubeEvent, rv string) func(ctx context.Context, input PollEventsInput) (*PollEventsResult, error) {
	called := false
	return func(ctx context.Context, input PollEventsInput) (*PollEventsResult, error) {
		if !called {
			called = true
			return &PollEventsResult{Events: events, ResourceVersion: rv}, nil
		}
		return &PollEventsResult{ResourceVersion: rv}, nil
	}
}

func TestClusterWatchWorkflow_ReceivesEvents(t *testing.T) {
	env := setupKubeTestEnv(t)

	events := []KubeEvent{
		{Cluster: "test", Reason: "Scheduled", Message: "pod scheduled", Type: "Normal"},
		{Cluster: "test", Reason: "Pulled", Message: "image pulled", Type: "Normal"},
	}
	env.OnActivity("PollKubeEvents", mock.Anything, mock.Anything).Return(
		mockPollEvents(events, "200"),
	)

	input := ClusterWatchInput{Name: "test", Endpoint: "test:443"}
	env.ExecuteWorkflow(ClusterWatchWorkflow, input)

	assert.True(t, env.IsWorkflowCompleted())
	err := env.GetWorkflowError()
	assert.NotNil(t, err)
	assert.Contains(t, err.Error(), "continue as new")
}

func TestClusterWatchWorkflow_Query(t *testing.T) {
	env := setupKubeTestEnv(t)

	events := []KubeEvent{
		{Cluster: "test", Reason: "Killing", Type: "Normal"},
	}
	env.OnActivity("PollKubeEvents", mock.Anything, mock.Anything).Return(
		mockPollEvents(events, "100"),
	)

	env.RegisterDelayedCallback(func() {
		result, err := env.QueryWorkflow(QueryRecentEvents)
		assert.NoError(t, err)
		var got []KubeEvent
		assert.NoError(t, result.Get(&got))
		assert.GreaterOrEqual(t, len(got), 1)
		assert.Equal(t, "Killing", got[0].Reason)
	}, 200*time.Millisecond)

	input := ClusterWatchInput{Name: "test", Endpoint: "test:443"}
	env.ExecuteWorkflow(ClusterWatchWorkflow, input)

	assert.True(t, env.IsWorkflowCompleted())
}

func TestClusterWatchWorkflow_ContinuesAsNew(t *testing.T) {
	env := setupKubeTestEnv(t)

	env.OnActivity("PollKubeEvents", mock.Anything, mock.Anything).Return(
		&PollEventsResult{ResourceVersion: "500"}, nil,
	)

	input := ClusterWatchInput{Name: "test", Endpoint: "test:443", ResourceVersion: "100"}
	env.ExecuteWorkflow(ClusterWatchWorkflow, input)

	assert.True(t, env.IsWorkflowCompleted())
	err := env.GetWorkflowError()
	assert.NotNil(t, err)
	assert.Contains(t, err.Error(), "continue as new")
}

func TestClusterWatchWorkflow_DetectsAlerts(t *testing.T) {
	env := setupKubeTestEnv(t)

	now := time.Now()
	crashEvents := make([]KubeEvent, 5)
	for i := range crashEvents {
		crashEvents[i] = KubeEvent{
			Cluster:  "test",
			Name:     "bad-pod",
			Kind:     "Pod",
			Reason:   "BackOff",
			Type:     "Warning",
			LastSeen: now.Add(time.Duration(i) * time.Second),
		}
	}
	env.OnActivity("PollKubeEvents", mock.Anything, mock.Anything).Return(
		mockPollEvents(crashEvents, "300"),
	)

	input := ClusterWatchInput{Name: "test", Endpoint: "test:443"}
	env.ExecuteWorkflow(ClusterWatchWorkflow, input)

	assert.True(t, env.IsWorkflowCompleted())
	err := env.GetWorkflowError()
	assert.NotNil(t, err)
	assert.Contains(t, err.Error(), "continue as new")
}
