package kubevents

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"go.temporal.io/sdk/testsuite"
)

func TestClusterWatchWorkflow_ReceivesEvents(t *testing.T) {
	s := testsuite.WorkflowTestSuite{}
	env := s.NewTestWorkflowEnvironment()

	env.RegisterDelayedCallback(func() {
		env.SignalWorkflow(SignalEvents, EventBatch{
			Events: []KubeEvent{
				{Cluster: "test", Reason: "Scheduled", Message: "pod scheduled", Type: "Normal"},
				{Cluster: "test", Reason: "Pulled", Message: "image pulled", Type: "Normal"},
			},
		})
	}, time.Millisecond*100)

	input := ClusterWatchInput{Name: "test", Endpoint: "test:443"}
	env.ExecuteWorkflow(ClusterWatchWorkflow, input)

	assert.True(t, env.IsWorkflowCompleted())
	err := env.GetWorkflowError()
	assert.NotNil(t, err)
	assert.Contains(t, err.Error(), "continue as new")
}

func TestClusterWatchWorkflow_Query(t *testing.T) {
	s := testsuite.WorkflowTestSuite{}
	env := s.NewTestWorkflowEnvironment()

	env.RegisterDelayedCallback(func() {
		env.SignalWorkflow(SignalEvents, EventBatch{
			Events: []KubeEvent{
				{Cluster: "test", Reason: "Killing", Type: "Normal"},
			},
		})
	}, time.Millisecond*100)

	env.RegisterDelayedCallback(func() {
		result, err := env.QueryWorkflow(QueryRecentEvents)
		assert.NoError(t, err)
		var events []KubeEvent
		assert.NoError(t, result.Get(&events))
		assert.Len(t, events, 1)
		assert.Equal(t, "Killing", events[0].Reason)
	}, time.Millisecond*200)

	input := ClusterWatchInput{Name: "test", Endpoint: "test:443"}
	env.ExecuteWorkflow(ClusterWatchWorkflow, input)

	assert.True(t, env.IsWorkflowCompleted())
}

func TestClusterWatchWorkflow_BufferOverflow(t *testing.T) {
	s := testsuite.WorkflowTestSuite{}
	env := s.NewTestWorkflowEnvironment()

	bigBatch := make([]KubeEvent, MaxBufferSize+1)
	for i := range bigBatch {
		bigBatch[i] = KubeEvent{Cluster: "test", Reason: "Filler", Type: "Normal"}
	}

	env.RegisterDelayedCallback(func() {
		env.SignalWorkflow(SignalEvents, EventBatch{Events: bigBatch})
	}, time.Millisecond*100)

	input := ClusterWatchInput{Name: "test", Endpoint: "test:443"}
	env.ExecuteWorkflow(ClusterWatchWorkflow, input)

	assert.True(t, env.IsWorkflowCompleted())
	err := env.GetWorkflowError()
	assert.NotNil(t, err)
	assert.Contains(t, err.Error(), "continue as new")
}

func TestClusterWatchWorkflow_ResourceVersionPassthrough(t *testing.T) {
	s := testsuite.WorkflowTestSuite{}
	env := s.NewTestWorkflowEnvironment()

	env.RegisterDelayedCallback(func() {
		env.SignalWorkflow(SignalResourceVersion, "12345")
	}, time.Millisecond*100)

	input := ClusterWatchInput{Name: "test", Endpoint: "test:443", ResourceVersion: "100"}
	env.ExecuteWorkflow(ClusterWatchWorkflow, input)

	assert.True(t, env.IsWorkflowCompleted())
	err := env.GetWorkflowError()
	assert.NotNil(t, err)
	assert.Contains(t, err.Error(), "continue as new")
}
