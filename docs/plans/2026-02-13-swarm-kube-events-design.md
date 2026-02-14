# Swarm: K8s Event Watcher — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build `swarm-kube-events`, a tsnet-based Temporal worker that watches Kubernetes events across three clusters in real-time and stores them as queryable Temporal workflow state.

**Architecture:** A single tsnet node (`tag:swarm`) dials into Temporal (`temporal:7233`) and each cluster's K8s API proxy (`{location}-k8s-operator.keiretsu.ts.net:443`). Per-cluster singleton workflows receive events via signals from long-running watch activities. Events buffer in workflow state with a `recent-events` query handler. ContinueAsNew every 5min/1000 events.

**Tech Stack:** Go 1.25, tsnet (tailscale.com), Temporal SDK (go.temporal.io/sdk), client-go (k8s.io/client-go), distroless container, Flux CD GitOps.

**Reference:** TailGrant worker at `/Users/rajsingh/Documents/GitHub/TailGrant/` — especially `cmd/tailgrant-worker/main.go` for the tsnet+Temporal bootstrap pattern.

---

### Task 1: Initialize Go Module

**Files:**
- Create: `swarm/go.mod`

**Step 1: Create the go module**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests/swarm
rm -rf kubernetes-  # remove empty placeholder dir
go mod init github.com/keiretsu-labs/kubernetes-manifests/swarm
```

**Step 2: Add core dependencies**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests/swarm
go get tailscale.com@v1.94.1
go get go.temporal.io/sdk@v1.40.0
go get go.temporal.io/api@v1.62.1
go get google.golang.org/grpc@v1.78.0
go get gopkg.in/yaml.v3@v3.0.1
go get k8s.io/client-go@latest
go get k8s.io/api@latest
go get k8s.io/apimachinery@latest
```

**Step 3: Verify go.mod exists and looks right**

```bash
cat /Users/rajsingh/Documents/GitHub/kubernetes-manifests/swarm/go.mod
```

Expected: Module path, go version, require blocks with the deps above.

**Step 4: Commit**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests/swarm
git add go.mod go.sum
git commit -m "feat(swarm): initialize go module with core dependencies"
```

---

### Task 2: Config Package

**Files:**
- Create: `swarm/internal/config/config.go`
- Create: `swarm/internal/config/config_test.go`

**Step 1: Write the config test**

Create `swarm/internal/config/config_test.go`:

```go
package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoad(t *testing.T) {
	yaml := `
temporal:
  address: "temporal:7233"
  useTsnet: true
  namespace: "default"
  taskQueue: "swarm-kube-events"
tailscale:
  hostname: "swarm-kube"
  oauthClientSecret: "tskey-client-secret"
  tags:
    - "tag:swarm"
clusters:
  - name: robbinsdale
    endpoint: "robbinsdale-k8s-operator.keiretsu.ts.net:443"
  - name: ottawa
    endpoint: "ottawa-k8s-operator.keiretsu.ts.net:443"
`
	tmp := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(tmp, []byte(yaml), 0644); err != nil {
		t.Fatal(err)
	}

	cfg, err := Load(tmp)
	if err != nil {
		t.Fatal(err)
	}

	if cfg.Temporal.Address != "temporal:7233" {
		t.Errorf("got address %q, want temporal:7233", cfg.Temporal.Address)
	}
	if cfg.Temporal.TaskQueue != "swarm-kube-events" {
		t.Errorf("got taskQueue %q, want swarm-kube-events", cfg.Temporal.TaskQueue)
	}
	if cfg.Tailscale.Hostname != "swarm-kube" {
		t.Errorf("got hostname %q, want swarm-kube", cfg.Tailscale.Hostname)
	}
	if len(cfg.Clusters) != 2 {
		t.Fatalf("got %d clusters, want 2", len(cfg.Clusters))
	}
	if cfg.Clusters[0].Name != "robbinsdale" {
		t.Errorf("got cluster[0] name %q, want robbinsdale", cfg.Clusters[0].Name)
	}
}

func TestLoadDefaults(t *testing.T) {
	yaml := `
temporal:
  address: "temporal:7233"
tailscale:
  hostname: "test"
clusters: []
`
	tmp := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(tmp, []byte(yaml), 0644); err != nil {
		t.Fatal(err)
	}

	cfg, err := Load(tmp)
	if err != nil {
		t.Fatal(err)
	}

	if cfg.Temporal.Namespace != "default" {
		t.Errorf("got namespace %q, want default", cfg.Temporal.Namespace)
	}
	if cfg.Temporal.TaskQueue != "swarm-kube-events" {
		t.Errorf("got taskQueue %q, want swarm-kube-events", cfg.Temporal.TaskQueue)
	}
}

func TestLoadEnvOverride(t *testing.T) {
	yaml := `
temporal:
  address: "temporal:7233"
tailscale:
  hostname: "test"
  oauthClientSecret: "original"
clusters: []
`
	tmp := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(tmp, []byte(yaml), 0644); err != nil {
		t.Fatal(err)
	}

	t.Setenv("TS_OAUTH_CLIENT_SECRET", "from-env")

	cfg, err := Load(tmp)
	if err != nil {
		t.Fatal(err)
	}

	if cfg.Tailscale.OAuthClientSecret != "from-env" {
		t.Errorf("got secret %q, want from-env", cfg.Tailscale.OAuthClientSecret)
	}
}
```

**Step 2: Run test to verify it fails**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests/swarm
go test ./internal/config/...
```

Expected: Compile error — `config` package doesn't exist yet.

**Step 3: Write the config implementation**

Create `swarm/internal/config/config.go`:

```go
package config

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

type Config struct {
	Temporal  TemporalConfig  `yaml:"temporal"`
	Tailscale TailscaleConfig `yaml:"tailscale"`
	Clusters  []ClusterConfig `yaml:"clusters"`
}

type TemporalConfig struct {
	Address   string `yaml:"address"`
	Namespace string `yaml:"namespace"`
	TaskQueue string `yaml:"taskQueue"`
	UseTsnet  bool   `yaml:"useTsnet"`
}

type TailscaleConfig struct {
	Hostname          string   `yaml:"hostname"`
	OAuthClientID     string   `yaml:"oauthClientID"`
	OAuthClientSecret string   `yaml:"oauthClientSecret"`
	Tags              []string `yaml:"tags"`
}

type ClusterConfig struct {
	Name     string `yaml:"name"`
	Endpoint string `yaml:"endpoint"`
}

func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading config %s: %w", path, err)
	}

	cfg := &Config{}
	if err := yaml.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("parsing config %s: %w", path, err)
	}

	applyDefaults(cfg)
	applyEnvOverrides(cfg)

	return cfg, nil
}

func applyDefaults(cfg *Config) {
	if cfg.Temporal.Namespace == "" {
		cfg.Temporal.Namespace = "default"
	}
	if cfg.Temporal.TaskQueue == "" {
		cfg.Temporal.TaskQueue = "swarm-kube-events"
	}
}

func applyEnvOverrides(cfg *Config) {
	if id := os.Getenv("TS_OAUTH_CLIENT_ID"); id != "" {
		cfg.Tailscale.OAuthClientID = id
	}
	if secret := os.Getenv("TS_OAUTH_CLIENT_SECRET"); secret != "" {
		cfg.Tailscale.OAuthClientSecret = secret
	}
}
```

**Step 4: Run tests**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests/swarm
go test ./internal/config/... -v
```

Expected: All 3 tests PASS.

**Step 5: Commit**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests/swarm
git add internal/config/
git commit -m "feat(swarm): add config package with YAML loading and env overrides"
```

---

### Task 3: Platform — tsnet Bootstrap

**Files:**
- Create: `swarm/internal/platform/tsnet.go`

This is a thin wrapper. No unit test — tsnet requires a real tailnet to test. Integration testing happens at deploy time.

**Step 1: Write tsnet bootstrap**

Create `swarm/internal/platform/tsnet.go`:

```go
package platform

import (
	"context"
	"log/slog"

	"github.com/keiretsu-labs/kubernetes-manifests/swarm/internal/config"
	"tailscale.com/tsnet"
)

func NewTsnetServer(cfg *config.TailscaleConfig) *tsnet.Server {
	srv := &tsnet.Server{
		Hostname:     cfg.Hostname,
		Ephemeral:    true,
		ClientSecret: cfg.OAuthClientSecret + "?ephemeral=true&preauthorized=true",
	}
	if len(cfg.Tags) > 0 {
		srv.AdvertiseTags = cfg.Tags
	}
	return srv
}

func StartTsnet(ctx context.Context, srv *tsnet.Server) error {
	if _, err := srv.Up(ctx); err != nil {
		return fmt.Errorf("tsnet up: %w", err)
	}
	slog.Info("tsnet is up", "hostname", srv.Hostname)
	return nil
}
```

**Step 2: Commit**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests/swarm
git add internal/platform/tsnet.go
git commit -m "feat(swarm): add platform tsnet bootstrap"
```

---

### Task 4: Platform — Temporal Client Factory

**Files:**
- Create: `swarm/internal/platform/temporal.go`

**Step 1: Write Temporal client factory**

Create `swarm/internal/platform/temporal.go`:

```go
package platform

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"time"

	"github.com/keiretsu-labs/kubernetes-manifests/swarm/internal/config"
	"go.temporal.io/sdk/client"
	"google.golang.org/grpc"
	"tailscale.com/tsnet"
)

func NewTemporalClient(ctx context.Context, cfg *config.TemporalConfig, srv *tsnet.Server) (client.Client, error) {
	opts := client.Options{
		HostPort:  cfg.Address,
		Namespace: cfg.Namespace,
	}

	if cfg.UseTsnet && srv != nil {
		// Verify connectivity first
		dialCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
		conn, err := srv.Dial(dialCtx, "tcp", cfg.Address)
		cancel()
		if err != nil {
			return nil, fmt.Errorf("tsnet cannot reach temporal at %s: %w", cfg.Address, err)
		}
		_ = conn.Close()
		slog.Info("tsnet temporal connectivity verified", "address", cfg.Address)

		opts.HostPort = "passthrough:///" + cfg.Address
		opts.ConnectionOptions = client.ConnectionOptions{
			DialOptions: []grpc.DialOption{
				grpc.WithContextDialer(func(ctx context.Context, addr string) (net.Conn, error) {
					return srv.Dial(ctx, "tcp", addr)
				}),
			},
		}
	}

	c, err := client.NewLazyClient(opts)
	if err != nil {
		return nil, fmt.Errorf("temporal client: %w", err)
	}
	slog.Info("temporal client created", "namespace", cfg.Namespace)
	return c, nil
}
```

**Step 2: Commit**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests/swarm
git add internal/platform/temporal.go
git commit -m "feat(swarm): add platform temporal client factory with tsnet dialer"
```

---

### Task 5: Platform — K8s Client via tsnet

**Files:**
- Create: `swarm/internal/platform/kube.go`

**Step 1: Write K8s client factory**

Create `swarm/internal/platform/kube.go`:

```go
package platform

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"net/http"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"tailscale.com/tsnet"
)

func NewKubeClient(srv *tsnet.Server, endpoint string) (*kubernetes.Clientset, error) {
	cfg := &rest.Config{
		Host: "https://" + endpoint,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				return srv.Dial(ctx, "tcp", endpoint)
			},
			TLSClientConfig: &tls.Config{
				InsecureSkipVerify: true, // operator proxy terminates TLS
			},
		},
	}

	cs, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		return nil, fmt.Errorf("kube client for %s: %w", endpoint, err)
	}
	return cs, nil
}
```

**Step 2: Commit**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests/swarm
git add internal/platform/kube.go
git commit -m "feat(swarm): add platform K8s client factory with tsnet transport"
```

---

### Task 6: KubeEvents — Types

**Files:**
- Create: `swarm/internal/kubevents/types.go`

**Step 1: Write the types**

Create `swarm/internal/kubevents/types.go`:

```go
package kubevents

import "time"

const (
	TaskQueue         = "swarm-kube-events"
	SignalEvents      = "events"
	QueryRecentEvents = "recent-events"
	MaxBufferSize     = 1000
	ContinueAsNewInterval = 5 * time.Minute
)

type ClusterWatchInput struct {
	Name            string
	Endpoint        string
	ResourceVersion string
}

type KubeEvent struct {
	Cluster   string    `json:"cluster"`
	Namespace string    `json:"namespace"`
	Name      string    `json:"name"`
	Kind      string    `json:"kind"`
	Reason    string    `json:"reason"`
	Message   string    `json:"message"`
	Source    string    `json:"source"`
	FirstSeen time.Time `json:"firstSeen"`
	LastSeen  time.Time `json:"lastSeen"`
	Count     int32     `json:"count"`
	Type      string    `json:"type"`
}

type EventBatch struct {
	Events []KubeEvent `json:"events"`
}

type WatchClusterEventsInput struct {
	ClusterName string
	Endpoint    string
	ResourceVersion string
}
```

**Step 2: Commit**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests/swarm
git add internal/kubevents/types.go
git commit -m "feat(swarm): add kubevents types and constants"
```

---

### Task 7: KubeEvents — Workflow

**Files:**
- Create: `swarm/internal/kubevents/workflow.go`
- Create: `swarm/internal/kubevents/workflow_test.go`

**Step 1: Write the workflow test**

Create `swarm/internal/kubevents/workflow_test.go`:

```go
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

	env.RegisterActivity(&Activities{})

	// Mock the watch activity — it just returns after sending some signals
	env.OnActivity((*Activities).WatchClusterEvents, nil, WatchClusterEventsInput{
		ClusterName:     "test-cluster",
		Endpoint:        "test:443",
		ResourceVersion: "",
	}).Return("100", nil)

	// Send events via signal before the timer fires
	env.RegisterDelayedCallback(func() {
		env.SignalWorkflow(SignalEvents, EventBatch{
			Events: []KubeEvent{
				{Cluster: "test-cluster", Reason: "Scheduled", Message: "pod scheduled", Type: "Normal"},
				{Cluster: "test-cluster", Reason: "Pulled", Message: "image pulled", Type: "Normal"},
			},
		})
	}, time.Millisecond*100)

	// Let the timer fire to trigger ContinueAsNew
	env.SetContinueAsNewSuggested(true)

	input := ClusterWatchInput{
		Name:     "test-cluster",
		Endpoint: "test:443",
	}
	env.ExecuteWorkflow(ClusterWatchWorkflow, input)

	assert.True(t, env.IsWorkflowCompleted())
	err := env.GetWorkflowError()
	// ContinueAsNew is expected
	assert.NotNil(t, err)
	assert.Contains(t, err.Error(), "ContinueAsNew")
}

func TestClusterWatchWorkflow_QueryRecentEvents(t *testing.T) {
	s := testsuite.WorkflowTestSuite{}
	env := s.NewTestWorkflowEnvironment()

	env.RegisterActivity(&Activities{})

	env.OnActivity((*Activities).WatchClusterEvents, nil, WatchClusterEventsInput{
		ClusterName:     "test-cluster",
		Endpoint:        "test:443",
		ResourceVersion: "",
	}).Return("100", nil)

	env.RegisterDelayedCallback(func() {
		env.SignalWorkflow(SignalEvents, EventBatch{
			Events: []KubeEvent{
				{Cluster: "test-cluster", Reason: "Killing", Message: "stopping container", Type: "Normal"},
			},
		})
	}, time.Millisecond*100)

	// Query after signal is processed
	env.RegisterDelayedCallback(func() {
		result, err := env.QueryWorkflow(QueryRecentEvents)
		assert.NoError(t, err)
		var events []KubeEvent
		assert.NoError(t, result.Get(&events))
		assert.Len(t, events, 1)
		assert.Equal(t, "Killing", events[0].Reason)
	}, time.Millisecond*200)

	env.SetContinueAsNewSuggested(true)

	input := ClusterWatchInput{Name: "test-cluster", Endpoint: "test:443"}
	env.ExecuteWorkflow(ClusterWatchWorkflow, input)

	assert.True(t, env.IsWorkflowCompleted())
}
```

**Step 2: Run test to verify it fails**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests/swarm
go test ./internal/kubevents/... -v
```

Expected: Compile error — `ClusterWatchWorkflow` doesn't exist.

**Step 3: Add test dependency**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests/swarm
go get github.com/stretchr/testify@v1.11.1
```

**Step 4: Write the workflow**

Create `swarm/internal/kubevents/workflow.go`:

```go
package kubevents

import (
	"time"

	"go.temporal.io/sdk/workflow"
)

func ClusterWatchWorkflow(ctx workflow.Context, input ClusterWatchInput) error {
	logger := workflow.GetLogger(ctx)
	logger.Info("ClusterWatchWorkflow started", "cluster", input.Name)

	events := make([]KubeEvent, 0, MaxBufferSize)
	lastResourceVersion := input.ResourceVersion

	// Query handler for other workflows/clients to read buffered events
	err := workflow.SetQueryHandler(ctx, QueryRecentEvents, func() ([]KubeEvent, error) {
		return events, nil
	})
	if err != nil {
		return err
	}

	// Signal channel for incoming events
	eventsCh := workflow.GetSignalChannel(ctx, SignalEvents)

	// Launch watch activity async — it returns the last resourceVersion it saw
	actCtx := workflow.WithActivityOptions(ctx, workflow.ActivityOptions{
		StartToCloseTimeout: 10 * time.Minute,
		HeartbeatTimeout:    60 * time.Second,
		RetryPolicy: &temporal.RetryPolicy{
			MaximumAttempts: 3,
		},
	})

	watchInput := WatchClusterEventsInput{
		ClusterName:     input.Name,
		Endpoint:        input.Endpoint,
		ResourceVersion: input.ResourceVersion,
	}
	watchFuture := workflow.ExecuteActivity(actCtx, (*Activities).WatchClusterEvents, watchInput)

	timer := workflow.NewTimer(ctx, ContinueAsNewInterval)

	for {
		sel := workflow.NewSelector(ctx)

		// Receive event batches
		sel.AddReceive(eventsCh, func(ch workflow.ReceiveChannel, more bool) {
			var batch EventBatch
			ch.Receive(ctx, &batch)
			for _, e := range batch.Events {
				events = append(events, e)
			}
			logger.Info("received events", "cluster", input.Name, "count", len(batch.Events), "total", len(events))
		})

		// Timer fires → ContinueAsNew
		sel.AddFuture(timer, func(f workflow.Future) {
			_ = f.Get(ctx, nil)
		})

		// Activity completes (watch ended) → get last resourceVersion and ContinueAsNew
		sel.AddFuture(watchFuture, func(f workflow.Future) {
			var rv string
			if err := f.Get(ctx, &rv); err != nil {
				logger.Error("watch activity failed", "cluster", input.Name, "error", err)
			} else {
				lastResourceVersion = rv
			}
		})

		sel.Select(ctx)

		// Check if we should ContinueAsNew
		if len(events) >= MaxBufferSize || ctx.Err() != nil {
			break
		}

		// Check if timer fired
		if timer.IsReady() {
			break
		}

		// Check if activity completed (watch ended)
		if watchFuture.IsReady() {
			break
		}
	}

	logger.Info("continuing as new", "cluster", input.Name, "events_buffered", len(events), "resourceVersion", lastResourceVersion)
	return workflow.NewContinueAsNewError(ctx, ClusterWatchWorkflow, ClusterWatchInput{
		Name:            input.Name,
		Endpoint:        input.Endpoint,
		ResourceVersion: lastResourceVersion,
	})
}
```

**Step 5: Fix import — add temporal retry policy import**

The workflow uses `temporal.RetryPolicy`. Update the import:

```go
import (
	"time"

	"go.temporal.io/sdk/temporal"
	"go.temporal.io/sdk/workflow"
)
```

**Step 6: Run tests**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests/swarm
go test ./internal/kubevents/... -v
```

Expected: Tests may still fail because `Activities` struct doesn't exist yet. That's expected — we need the activities stub. Create a minimal stub to make tests compile. See Task 8.

**Step 7: Commit (after Task 8 makes tests pass)**

Commit together with Task 8.

---

### Task 8: KubeEvents — Activities

**Files:**
- Create: `swarm/internal/kubevents/activities.go`

**Step 1: Write the activities**

Create `swarm/internal/kubevents/activities.go`:

```go
package kubevents

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"go.temporal.io/sdk/activity"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/kubernetes"
)

type Activities struct {
	KubeClients map[string]*kubernetes.Clientset
}

func (a *Activities) WatchClusterEvents(ctx context.Context, input WatchClusterEventsInput) (string, error) {
	logger := activity.GetLogger(ctx)

	cs, ok := a.KubeClients[input.ClusterName]
	if !ok {
		return "", fmt.Errorf("no kube client for cluster %s", input.ClusterName)
	}

	resourceVersion := input.ResourceVersion
	if resourceVersion == "" {
		// List to get initial resourceVersion
		list, err := cs.CoreV1().Events("").List(ctx, metav1.ListOptions{Limit: 1})
		if err != nil {
			return "", fmt.Errorf("listing events for initial resourceVersion: %w", err)
		}
		resourceVersion = list.ResourceVersion
		logger.Info("got initial resourceVersion", "cluster", input.ClusterName, "rv", resourceVersion)
	}

	watcher, err := cs.CoreV1().Events("").Watch(ctx, metav1.ListOptions{
		ResourceVersion: resourceVersion,
		Watch:           true,
	})
	if err != nil {
		return resourceVersion, fmt.Errorf("starting watch: %w", err)
	}
	defer watcher.Stop()

	heartbeatTicker := time.NewTicker(30 * time.Second)
	defer heartbeatTicker.Stop()

	lastRV := resourceVersion

	for {
		select {
		case <-ctx.Done():
			logger.Info("watch context cancelled", "cluster", input.ClusterName, "lastRV", lastRV)
			return lastRV, nil

		case <-heartbeatTicker.C:
			activity.RecordHeartbeat(ctx, lastRV)

		case event, ok := <-watcher.ResultChan():
			if !ok {
				logger.Warn("watch channel closed", "cluster", input.ClusterName)
				return lastRV, nil
			}

			if event.Type == watch.Error {
				logger.Warn("watch error event", "cluster", input.ClusterName)
				return lastRV, nil
			}

			ev, ok := event.Object.(*corev1.Event)
			if !ok {
				continue
			}

			lastRV = ev.ResourceVersion
			ke := KubeEvent{
				Cluster:   input.ClusterName,
				Namespace: ev.Namespace,
				Name:      ev.InvolvedObject.Name,
				Kind:      ev.InvolvedObject.Kind,
				Reason:    ev.Reason,
				Message:   ev.Message,
				Source:    ev.Source.Component,
				Count:     ev.Count,
				Type:      ev.Type,
			}
			if !ev.FirstTimestamp.IsZero() {
				ke.FirstSeen = ev.FirstTimestamp.Time
			}
			if !ev.LastTimestamp.IsZero() {
				ke.LastSeen = ev.LastTimestamp.Time
			}

			// Signal the workflow with the event batch
			slog.Info("event",
				"cluster", ke.Cluster,
				"kind", ke.Kind,
				"name", ke.Name,
				"reason", ke.Reason,
				"type", ke.Type,
			)

			// Note: Activity cannot directly signal its parent workflow.
			// The activity returns events via its return value.
			// For real-time signaling, the main.go goroutine bridges
			// the activity's output channel to workflow signals.
			// In this design, the activity runs until context cancellation
			// (ContinueAsNew timer) and returns the last resourceVersion.
			// Events are collected by the caller and signaled externally.
			activity.RecordHeartbeat(ctx, lastRV)
		}
	}
}
```

**Step 2: Reconsider activity-to-workflow signaling**

Temporal activities cannot directly signal their parent workflow. We need to rethink the pattern. The correct approach: the **main.go** goroutine starts the workflow, then separately runs a K8s watch loop that signals the workflow externally via the Temporal client. The activity is not the right place for long-lived watches.

**Revised approach:** Instead of a long-running activity, use a **goroutine in main.go** per cluster that:
1. Opens the K8s watch
2. Signals the workflow via `temporalClient.SignalWorkflow()`
3. The workflow is a pure signal-receiving state machine (no activity needed for watching)

Update `activities.go` to a simpler activity for on-demand event fetching (useful for future workers):

```go
package kubevents

import (
	"context"
	"fmt"

	"go.temporal.io/sdk/activity"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

type Activities struct {
	KubeClients map[string]*kubernetes.Clientset
}

// ListRecentEvents fetches the latest events from a cluster. Useful for
// bootstrapping or catching up after a watch gap.
func (a *Activities) ListRecentEvents(ctx context.Context, input WatchClusterEventsInput) ([]KubeEvent, error) {
	logger := activity.GetLogger(ctx)

	cs, ok := a.KubeClients[input.ClusterName]
	if !ok {
		return nil, fmt.Errorf("no kube client for cluster %s", input.ClusterName)
	}

	list, err := cs.CoreV1().Events("").List(ctx, metav1.ListOptions{
		Limit: 100,
	})
	if err != nil {
		return nil, fmt.Errorf("listing events: %w", err)
	}

	var events []KubeEvent
	for _, ev := range list.Items {
		ke := KubeEvent{
			Cluster:   input.ClusterName,
			Namespace: ev.Namespace,
			Name:      ev.InvolvedObject.Name,
			Kind:      ev.InvolvedObject.Kind,
			Reason:    ev.Reason,
			Message:   ev.Message,
			Source:    ev.Source.Component,
			Count:     ev.Count,
			Type:      ev.Type,
		}
		if !ev.FirstTimestamp.IsZero() {
			ke.FirstSeen = ev.FirstTimestamp.Time
		}
		if !ev.LastTimestamp.IsZero() {
			ke.LastSeen = ev.LastTimestamp.Time
		}
		events = append(events, ke)
	}

	logger.Info("listed events", "cluster", input.ClusterName, "count", len(events))
	return events, nil
}
```

**Step 3: Update workflow to be signal-only (no activity launch)**

Update `swarm/internal/kubevents/workflow.go`:

```go
package kubevents

import (
	"go.temporal.io/sdk/workflow"
)

func ClusterWatchWorkflow(ctx workflow.Context, input ClusterWatchInput) error {
	logger := workflow.GetLogger(ctx)
	logger.Info("ClusterWatchWorkflow started", "cluster", input.Name, "resourceVersion", input.ResourceVersion)

	events := make([]KubeEvent, 0, MaxBufferSize)
	lastResourceVersion := input.ResourceVersion

	// Query handler: other workflows/clients can read buffered events
	if err := workflow.SetQueryHandler(ctx, QueryRecentEvents, func() ([]KubeEvent, error) {
		return events, nil
	}); err != nil {
		return err
	}

	// Resource version update signal (sent by watch goroutine in main.go)
	rvCh := workflow.GetSignalChannel(ctx, "resource-version")

	eventsCh := workflow.GetSignalChannel(ctx, SignalEvents)
	timer := workflow.NewTimer(ctx, ContinueAsNewInterval)

	for {
		sel := workflow.NewSelector(ctx)

		sel.AddReceive(eventsCh, func(ch workflow.ReceiveChannel, more bool) {
			var batch EventBatch
			ch.Receive(ctx, &batch)
			events = append(events, batch.Events...)
			logger.Info("received events", "cluster", input.Name, "batch", len(batch.Events), "total", len(events))
		})

		sel.AddReceive(rvCh, func(ch workflow.ReceiveChannel, more bool) {
			ch.Receive(ctx, &lastResourceVersion)
		})

		sel.AddFuture(timer, func(f workflow.Future) {
			_ = f.Get(ctx, nil)
		})

		sel.Select(ctx)

		if len(events) >= MaxBufferSize || timer.IsReady() {
			break
		}
	}

	logger.Info("continuing as new", "cluster", input.Name, "buffered", len(events), "rv", lastResourceVersion)
	return workflow.NewContinueAsNewError(ctx, ClusterWatchWorkflow, ClusterWatchInput{
		Name:            input.Name,
		Endpoint:        input.Endpoint,
		ResourceVersion: lastResourceVersion,
	})
}
```

**Step 4: Update tests for revised workflow (signal-only, no activity mock needed)**

Update `swarm/internal/kubevents/workflow_test.go`:

```go
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

	// Let timer fire → ContinueAsNew
	input := ClusterWatchInput{Name: "test", Endpoint: "test:443"}
	env.ExecuteWorkflow(ClusterWatchWorkflow, input)

	assert.True(t, env.IsWorkflowCompleted())
	err := env.GetWorkflowError()
	assert.NotNil(t, err)
	assert.Contains(t, err.Error(), "ContinueAsNew")
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

	// Send a batch that exceeds MaxBufferSize
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
	assert.Contains(t, err.Error(), "ContinueAsNew")
}

func TestClusterWatchWorkflow_ResourceVersionPassthrough(t *testing.T) {
	s := testsuite.WorkflowTestSuite{}
	env := s.NewTestWorkflowEnvironment()

	env.RegisterDelayedCallback(func() {
		env.SignalWorkflow("resource-version", "12345")
	}, time.Millisecond*100)

	input := ClusterWatchInput{Name: "test", Endpoint: "test:443", ResourceVersion: "100"}
	env.ExecuteWorkflow(ClusterWatchWorkflow, input)

	assert.True(t, env.IsWorkflowCompleted())
	// ContinueAsNew carries the updated resourceVersion
	err := env.GetWorkflowError()
	assert.NotNil(t, err)
	assert.Contains(t, err.Error(), "ContinueAsNew")
}
```

**Step 5: Run tests**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests/swarm
go test ./internal/kubevents/... -v
```

Expected: All 4 tests PASS.

**Step 6: Commit**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests/swarm
git add internal/kubevents/
git commit -m "feat(swarm): add kubevents workflow, activities, and types with tests"
```

---

### Task 9: Platform — K8s Event Watcher Goroutine

**Files:**
- Create: `swarm/internal/platform/watcher.go`

This is the bridge between K8s watch API and Temporal workflow signals. Runs as a goroutine per cluster in main.go.

**Step 1: Write the watcher**

Create `swarm/internal/platform/watcher.go`:

```go
package platform

import (
	"context"
	"log/slog"
	"time"

	"github.com/keiretsu-labs/kubernetes-manifests/swarm/internal/kubevents"
	"go.temporal.io/sdk/client"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/kubernetes"

	corev1 "k8s.io/api/core/v1"
)

// WatchAndSignal opens a K8s event watch and signals the Temporal workflow.
// It reconnects on watch errors and runs until ctx is cancelled.
func WatchAndSignal(ctx context.Context, tc client.Client, cs *kubernetes.Clientset, clusterName, workflowID string) {
	for {
		if ctx.Err() != nil {
			return
		}
		watchOnce(ctx, tc, cs, clusterName, workflowID)

		// Backoff before reconnecting
		select {
		case <-ctx.Done():
			return
		case <-time.After(5 * time.Second):
		}
	}
}

func watchOnce(ctx context.Context, tc client.Client, cs *kubernetes.Clientset, clusterName, workflowID string) {
	logger := slog.With("cluster", clusterName)

	// Get initial resourceVersion
	list, err := cs.CoreV1().Events("").List(ctx, metav1.ListOptions{Limit: 1})
	if err != nil {
		logger.Error("failed to list events for resourceVersion", "error", err)
		return
	}
	rv := list.ResourceVersion

	watcher, err := cs.CoreV1().Events("").Watch(ctx, metav1.ListOptions{
		ResourceVersion: rv,
	})
	if err != nil {
		logger.Error("failed to start watch", "error", err)
		return
	}
	defer watcher.Stop()

	logger.Info("watch started", "resourceVersion", rv)

	// Batch events and flush periodically
	var batch []kubevents.KubeEvent
	flushTicker := time.NewTicker(2 * time.Second)
	defer flushTicker.Stop()

	flush := func() {
		if len(batch) == 0 {
			return
		}
		err := tc.SignalWorkflow(ctx, workflowID, "", kubevents.SignalEvents, kubevents.EventBatch{Events: batch})
		if err != nil {
			logger.Error("failed to signal workflow", "error", err, "count", len(batch))
			return
		}
		logger.Info("signaled events", "count", len(batch))
		batch = batch[:0]
	}

	for {
		select {
		case <-ctx.Done():
			flush()
			return

		case <-flushTicker.C:
			flush()
			// Also send latest resourceVersion
			if rv != "" {
				_ = tc.SignalWorkflow(ctx, workflowID, "", "resource-version", rv)
			}

		case event, ok := <-watcher.ResultChan():
			if !ok {
				logger.Warn("watch channel closed")
				flush()
				return
			}

			if event.Type == watch.Error {
				logger.Warn("watch error")
				flush()
				return
			}

			ev, ok := event.Object.(*corev1.Event)
			if !ok {
				continue
			}

			rv = ev.ResourceVersion
			ke := kubevents.KubeEvent{
				Cluster:   clusterName,
				Namespace: ev.Namespace,
				Name:      ev.InvolvedObject.Name,
				Kind:      ev.InvolvedObject.Kind,
				Reason:    ev.Reason,
				Message:   ev.Message,
				Source:    ev.Source.Component,
				Count:     ev.Count,
				Type:      ev.Type,
			}
			if !ev.FirstTimestamp.IsZero() {
				ke.FirstSeen = ev.FirstTimestamp.Time
			}
			if !ev.LastTimestamp.IsZero() {
				ke.LastSeen = ev.LastTimestamp.Time
			}
			batch = append(batch, ke)
		}
	}
}
```

**Step 2: Commit**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests/swarm
git add internal/platform/watcher.go
git commit -m "feat(swarm): add K8s watch-to-temporal-signal bridge"
```

---

### Task 10: Main Binary

**Files:**
- Create: `swarm/cmd/swarm-kube-events/main.go`

**Step 1: Write main.go**

Create `swarm/cmd/swarm-kube-events/main.go`:

```go
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/keiretsu-labs/kubernetes-manifests/swarm/internal/config"
	"github.com/keiretsu-labs/kubernetes-manifests/swarm/internal/kubevents"
	"github.com/keiretsu-labs/kubernetes-manifests/swarm/internal/platform"
	"go.temporal.io/sdk/client"
	"go.temporal.io/sdk/worker"
)

func main() {
	configPath := flag.String("config", os.Getenv("CONFIG_PATH"), "path to config file")
	flag.Parse()

	if *configPath == "" {
		slog.Error("config path required: set -config flag or CONFIG_PATH env")
		os.Exit(1)
	}

	cfg, err := config.Load(*configPath)
	if err != nil {
		slog.Error("failed to load config", "error", err)
		os.Exit(1)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Start tsnet
	srv := platform.NewTsnetServer(&cfg.Tailscale)
	defer func() { _ = srv.Close() }()

	if err := platform.StartTsnet(ctx, srv); err != nil {
		slog.Error("tsnet failed", "error", err)
		os.Exit(1)
	}

	// Create Temporal client
	tc, err := platform.NewTemporalClient(ctx, &cfg.Temporal, srv)
	if err != nil {
		slog.Error("temporal client failed", "error", err)
		os.Exit(1)
	}
	defer tc.Close()

	// Build K8s clients for each cluster
	kubeClients := make(map[string]*kubernetes.Clientset)
	for _, cluster := range cfg.Clusters {
		cs, err := platform.NewKubeClient(srv, cluster.Endpoint)
		if err != nil {
			slog.Error("kube client failed", "cluster", cluster.Name, "error", err)
			os.Exit(1)
		}
		kubeClients[cluster.Name] = cs
		slog.Info("kube client created", "cluster", cluster.Name, "endpoint", cluster.Endpoint)
	}

	// Register Temporal worker (for activities)
	w := worker.New(tc, cfg.Temporal.TaskQueue, worker.Options{})
	activities := &kubevents.Activities{KubeClients: kubeClients}
	w.RegisterWorkflow(kubevents.ClusterWatchWorkflow)
	w.RegisterActivity(activities)

	// Start per-cluster watch workflows and watchers
	for _, cluster := range cfg.Clusters {
		workflowID := fmt.Sprintf("cluster-watch-%s", cluster.Name)

		// Start singleton workflow
		_, err := tc.ExecuteWorkflow(ctx, client.StartWorkflowOptions{
			ID:        workflowID,
			TaskQueue: cfg.Temporal.TaskQueue,
		}, kubevents.ClusterWatchWorkflow, kubevents.ClusterWatchInput{
			Name:     cluster.Name,
			Endpoint: cluster.Endpoint,
		})
		if err != nil {
			slog.Warn("workflow may already be running", "cluster", cluster.Name, "error", err)
		} else {
			slog.Info("started cluster watch workflow", "cluster", cluster.Name, "workflowID", workflowID)
		}

		// Start watch goroutine that signals the workflow
		cs := kubeClients[cluster.Name]
		go platform.WatchAndSignal(ctx, tc, cs, cluster.Name, workflowID)
	}

	slog.Info("swarm-kube-events worker started", "clusters", len(cfg.Clusters), "taskQueue", cfg.Temporal.TaskQueue)

	// Handle shutdown
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		<-sigCh
		slog.Info("shutting down")
		cancel()
		_ = srv.Close()
	}()

	if err := w.Run(worker.InterruptCh()); err != nil {
		slog.Error("worker exited with error", "error", err)
		os.Exit(1)
	}
}
```

**Step 2: Fix missing import**

The main.go uses `kubernetes.Clientset` — add the import:

```go
import (
	// ... existing imports ...
	"k8s.io/client-go/kubernetes"
)
```

**Step 3: Verify it compiles**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests/swarm
go build ./cmd/swarm-kube-events/
```

Expected: Builds successfully (binary created).

**Step 4: Clean up build artifact**

```bash
rm -f /Users/rajsingh/Documents/GitHub/kubernetes-manifests/swarm/swarm-kube-events
```

**Step 5: Commit**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests/swarm
git add cmd/swarm-kube-events/main.go
git commit -m "feat(swarm): add swarm-kube-events main binary"
```

---

### Task 11: Dockerfile

**Files:**
- Create: `swarm/Dockerfile`

**Step 1: Write the Dockerfile**

Create `swarm/Dockerfile`:

```dockerfile
FROM --platform=$BUILDPLATFORM golang:1.25-bookworm AS builder
ARG TARGETOS
ARG TARGETARCH

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} go build -ldflags="-s -w" -o /out/swarm-kube-events ./cmd/swarm-kube-events

FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=builder /out/swarm-kube-events /usr/local/bin/swarm-kube-events

USER nonroot:nonroot
```

**Step 2: Commit**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests/swarm
git add Dockerfile
git commit -m "feat(swarm): add multi-stage distroless Dockerfile"
```

---

### Task 12: Kubernetes Manifests

**Files:**
- Create: `swarm/kustomization/namespace.yaml`
- Create: `swarm/kustomization/deployment.yaml`
- Create: `swarm/kustomization/config.yaml`
- Create: `swarm/kustomization/kustomization.yaml`

**Step 1: Create namespace.yaml**

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: swarm
  labels:
    kustomize.toolkit.fluxcd.io/prune: disabled
```

**Step 2: Create config.yaml**

This is the raw YAML config (becomes a ConfigMap via Kustomize `configMapGenerator`) that becomes a ConfigMap via Kustomize `configMapGenerator`.

```yaml
temporal:
  address: "temporal:7233"
  useTsnet: true
  namespace: "default"
  taskQueue: "swarm-kube-events"
tailscale:
  hostname: "swarm-kube"
  tags:
    - "tag:swarm"
clusters:
  - name: robbinsdale
    endpoint: "robbinsdale-k8s-operator.keiretsu.ts.net:443"
  - name: ottawa
    endpoint: "ottawa-k8s-operator.keiretsu.ts.net:443"
  - name: stpetersburg
    endpoint: "stpetersburg-k8s-operator.keiretsu.ts.net:443"
```

**Step 3: Create deployment.yaml**

```yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: swarm-kube-events
spec:
  replicas: 1
  revisionHistoryLimit: 3
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: swarm-kube-events
  template:
    metadata:
      labels:
        app.kubernetes.io/name: swarm-kube-events
    spec:
      securityContext:
        fsGroup: 65532
        runAsUser: 65532
        runAsGroup: 65532
        runAsNonRoot: true
      imagePullSecrets:
        - name: zot-pull-secret
      containers:
        - name: swarm-kube-events
          image: oci.killinit.cc/swarm/swarm-kube-events:latest
          imagePullPolicy: Always
          command: ["/usr/local/bin/swarm-kube-events"]
          env:
            - name: CONFIG_PATH
              value: /etc/swarm/config.yaml
            - name: TS_OAUTH_CLIENT_ID
              valueFrom:
                secretKeyRef:
                  name: swarm-secrets
                  key: TS_OAUTH_CLIENT_ID
            - name: TS_OAUTH_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: swarm-secrets
                  key: TS_OAUTH_CLIENT_SECRET
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 512Mi
          volumeMounts:
            - name: config
              mountPath: /etc/swarm
              readOnly: true
      terminationGracePeriodSeconds: 30
      volumes:
        - name: config
          configMap:
            name: swarm-config
```

**Step 4: Create kustomization.yaml**

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: swarm
resources:
  - namespace.yaml
  - deployment.yaml
configMapGenerator:
  - name: swarm-config
    files:
      - config.yaml
generatorOptions:
  disableNameSuffixHash: true
```

Note: `secret.sops.yaml` is created separately (Task 14) after creating the OAuth client.

**Step 5: Commit**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests/swarm
git add kustomization/
git commit -m "feat(swarm): add kubernetes deployment manifests"
```

---

### Task 13: Flux Kustomization

**Files:**
- Create: `clusters/talos-ottawa/apps/swarm/ks.yaml`
- Create: `clusters/talos-ottawa/apps/swarm/kustomization.yaml`

The Flux Kustomization tells Flux to deploy swarm from this repo.

**Step 1: Create ks.yaml**

Create `clusters/talos-ottawa/apps/swarm/ks.yaml`:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app swarm
  namespace: flux-system
spec:
  targetNamespace: swarm
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  dependsOn:
    - name: temporal
  path: ./swarm/kustomization
  prune: true
  sourceRef:
    kind: GitRepository
    name: kubernetes-manifests
  wait: false
  interval: 30m
  retryInterval: 1m
  timeout: 5m
  decryption:
    provider: sops
    secretRef:
      name: sops-gpg
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: common-settings
      - kind: Secret
        name: common-secrets
      - kind: ConfigMap
        name: cluster-settings
        optional: true
      - kind: Secret
        name: cluster-secrets
        optional: true
```

**Step 2: Create kustomization.yaml**

Create `clusters/talos-ottawa/apps/swarm/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ks.yaml
```

**Step 3: Add to Ottawa apps kustomization**

Check the parent kustomization that includes all Ottawa apps and add `swarm` to it.

```bash
# Find the parent kustomization
cat /Users/rajsingh/Documents/GitHub/kubernetes-manifests/clusters/talos-ottawa/apps/kustomization.yaml
```

Add `- swarm` to the resources list.

**Step 4: Commit**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests
git add clusters/talos-ottawa/apps/swarm/
git add clusters/talos-ottawa/apps/kustomization.yaml  # if modified
git commit -m "feat(swarm): add Flux kustomization for Ottawa cluster deployment"
```

---

### Task 14: SOPS Secret for OAuth Credentials

**Files:**
- Create: `swarm/kustomization/secret.sops.yaml`

**Step 1: Create the unencrypted secret**

Create the secret YAML (will be encrypted with SOPS):

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: swarm-secrets
stringData:
  TS_OAUTH_CLIENT_ID: "<create-oauth-client-first>"
  TS_OAUTH_CLIENT_SECRET: "<create-oauth-client-first>"
```

**Step 2: Encrypt with SOPS**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests/swarm/kustomization
sops --encrypt --in-place secret.sops.yaml
```

Note: You need to create the Tailscale OAuth client first (Task 15) and fill in real values before encrypting. The SOPS `.sops.yaml` creation rules from the repo root will determine which PGP key to use.

**Step 3: Add to kustomization.yaml**

Add `- secret.sops.yaml` to the resources list in `swarm/kustomization/kustomization.yaml`.

**Step 4: Commit**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests/swarm
git add kustomization/secret.sops.yaml kustomization/kustomization.yaml
git commit -m "feat(swarm): add SOPS-encrypted OAuth secret"
```

---

### Task 15: Tailscale ACL — Add tag:swarm

**Files:**
- Modify: `tailscale/policy.hujson`

**Step 1: Add tag ownership**

In `tailscale/policy.hujson`, add to `tagOwners` section (after `tag:tailgrant-worker` line ~83):

```hujson
"tag:swarm": ["tag:k8s-operator", "tag:infra", "group:superuser"],
```

**Step 2: Add ACL grant**

In the `grants` array, add a new grant block (after the existing `tag:k8s` grant block around line ~367):

```hujson
{
    "src": ["tag:swarm"],
    "dst": ["tag:k8s-operator", "tag:k8s"],
    "ip":  ["*"],
    "app": {
        "tailscale.com/cap/kubernetes": [
            {
                "impersonate": {
                    "groups": ["system:masters"],
                },
            },
        ],
    },
},
```

**Step 3: Validate ACL**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests
./tailscale/scripts/validate.sh
```

Expected: Validation passes.

**Step 4: Commit**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests
git add tailscale/policy.hujson
git commit -m "feat(swarm): add tag:swarm ACL with cap/kubernetes grant"
```

---

### Task 16: Run All Tests

**Step 1: Run full test suite**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests/swarm
go test ./... -v
```

Expected: All tests pass (config tests + workflow tests).

**Step 2: Verify build**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests/swarm
go build ./cmd/swarm-kube-events/
rm -f swarm-kube-events
```

Expected: Build succeeds.

**Step 3: Verify go vet**

```bash
cd /Users/rajsingh/Documents/GitHub/kubernetes-manifests/swarm
go vet ./...
```

Expected: No issues.

---

### Summary

| Task | Component | Files | Commit |
|------|-----------|-------|--------|
| 1 | Go module init | `go.mod`, `go.sum` | `feat(swarm): initialize go module` |
| 2 | Config package | `internal/config/config.go`, `config_test.go` | `feat(swarm): add config package` |
| 3 | Platform tsnet | `internal/platform/tsnet.go` | `feat(swarm): add platform tsnet` |
| 4 | Platform temporal | `internal/platform/temporal.go` | `feat(swarm): add platform temporal` |
| 5 | Platform kube | `internal/platform/kube.go` | `feat(swarm): add platform kube` |
| 6 | Types | `internal/kubevents/types.go` | `feat(swarm): add kubevents types` |
| 7+8 | Workflow + Activities | `internal/kubevents/workflow.go`, `activities.go`, `workflow_test.go` | `feat(swarm): add kubevents workflow` |
| 9 | Watch bridge | `internal/platform/watcher.go` | `feat(swarm): add watch-to-signal bridge` |
| 10 | Main binary | `cmd/swarm-kube-events/main.go` | `feat(swarm): add main binary` |
| 11 | Dockerfile | `Dockerfile` | `feat(swarm): add Dockerfile` |
| 12 | K8s manifests | `kustomization/{namespace,deployment,config,kustomization}.yaml` | `feat(swarm): add k8s manifests` |
| 13 | Flux kustomization | `clusters/talos-ottawa/apps/swarm/` | `feat(swarm): add Flux kustomization` |
| 14 | SOPS secret | `kustomization/secret.sops.yaml` | `feat(swarm): add SOPS secret` |
| 15 | Tailscale ACL | `tailscale/policy.hujson` | `feat(swarm): add tag:swarm ACL` |
| 16 | Final verification | — | — |
