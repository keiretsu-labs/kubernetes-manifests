package tslifecycle

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/mock"
	"go.temporal.io/sdk/testsuite"
)

func TestDeviceCleanupWorkflow_DryRun(t *testing.T) {
	testSuite := &testsuite.WorkflowTestSuite{}
	env := testSuite.NewTestWorkflowEnvironment()

	candidates := []CleanupCandidate{
		{DeviceID: "dev1", Hostname: "node-1", InactiveDays: 45},
		{DeviceID: "dev2", Hostname: "node-2", InactiveDays: 60},
	}

	var acts *Activities
	env.RegisterActivity(acts)
	env.OnActivity(acts.ListInactiveDevices, mock.Anything, mock.Anything).Return(candidates, nil)

	env.ExecuteWorkflow(DeviceCleanupWorkflow, CleanupInput{
		Tags:         []string{"tag:k8s"},
		InactiveDays: 30,
		DryRun:       true,
	})

	assert.True(t, env.IsWorkflowCompleted())
	assert.NoError(t, env.GetWorkflowError())

	var result CleanupResult
	assert.NoError(t, env.GetWorkflowResult(&result))
	assert.True(t, result.DryRun)
	assert.Len(t, result.Candidates, 2)
	assert.Empty(t, result.Removed)
}

func TestDeviceCleanupWorkflow_Removes(t *testing.T) {
	testSuite := &testsuite.WorkflowTestSuite{}
	env := testSuite.NewTestWorkflowEnvironment()

	candidates := []CleanupCandidate{
		{DeviceID: "dev1", Hostname: "node-1", InactiveDays: 45},
	}

	var acts *Activities
	env.RegisterActivity(acts)
	env.OnActivity(acts.ListInactiveDevices, mock.Anything, mock.Anything).Return(candidates, nil)
	env.OnActivity(acts.RemoveDevice, mock.Anything, mock.Anything).Return(nil)

	env.ExecuteWorkflow(DeviceCleanupWorkflow, CleanupInput{
		Tags:         []string{"tag:k8s"},
		InactiveDays: 30,
		DryRun:       false,
	})

	assert.True(t, env.IsWorkflowCompleted())
	assert.NoError(t, env.GetWorkflowError())

	var result CleanupResult
	assert.NoError(t, env.GetWorkflowResult(&result))
	assert.False(t, result.DryRun)
	assert.Len(t, result.Removed, 1)
}

func TestDeviceCleanupWorkflow_DefaultInactiveDays(t *testing.T) {
	testSuite := &testsuite.WorkflowTestSuite{}
	env := testSuite.NewTestWorkflowEnvironment()

	var acts *Activities
	env.RegisterActivity(acts)
	env.OnActivity(acts.ListInactiveDevices, mock.Anything, mock.MatchedBy(func(input CleanupInput) bool {
		return input.InactiveDays == DefaultCleanupInactiveDays
	})).Return(nil, nil)

	env.ExecuteWorkflow(DeviceCleanupWorkflow, CleanupInput{
		Tags:         []string{"tag:k8s"},
		InactiveDays: 0,
		DryRun:       true,
	})

	assert.True(t, env.IsWorkflowCompleted())
	assert.NoError(t, env.GetWorkflowError())
}

func TestConnectivityProbeWorkflow(t *testing.T) {
	testSuite := &testsuite.WorkflowTestSuite{}
	env := testSuite.NewTestWorkflowEnvironment()

	results := []ProbeResult{
		{Name: "node-1", Address: "10.0.0.1:6443", Reachable: true},
		{Name: "node-2", Address: "10.0.0.2:6443", Reachable: false, Error: "timeout"},
	}

	var acts *Activities
	env.RegisterActivity(acts)
	env.OnActivity(acts.ProbeTargets, mock.Anything, mock.Anything).Return(results, nil)

	env.ExecuteWorkflow(ConnectivityProbeWorkflow, ProbeInput{
		Targets: []ProbeTarget{
			{Name: "node-1", Address: "10.0.0.1:6443"},
			{Name: "node-2", Address: "10.0.0.2:6443"},
		},
	})

	assert.True(t, env.IsWorkflowCompleted())
	assert.NoError(t, env.GetWorkflowError())

	var probeResults []ProbeResult
	assert.NoError(t, env.GetWorkflowResult(&probeResults))
	assert.Len(t, probeResults, 2)
	assert.True(t, probeResults[0].Reachable)
	assert.False(t, probeResults[1].Reachable)
}
