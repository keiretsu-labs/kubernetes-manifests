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
  taskQueue: "swarm"
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
	if cfg.Temporal.TaskQueue != "swarm" {
		t.Errorf("got taskQueue %q, want swarm", cfg.Temporal.TaskQueue)
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
	if cfg.Temporal.TaskQueue != "swarm" {
		t.Errorf("got taskQueue %q, want swarm", cfg.Temporal.TaskQueue)
	}
}

func TestLoadLifecycleConfig(t *testing.T) {
	yaml := `
temporal:
  address: "temporal:7233"
tailscale:
  hostname: "test"
clusters: []
lifecycle:
  cleanupTags: ["tag:k8s", "tag:ottawa"]
  inactiveDays: 30
  dryRun: true
  probeTargets:
    - name: robbinsdale-k8s-api
      address: "robbinsdale-k8s-operator.keiretsu.ts.net:443"
  probeDynamicTags: ["tag:k8s"]
`
	tmp := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(tmp, []byte(yaml), 0644); err != nil {
		t.Fatal(err)
	}

	cfg, err := Load(tmp)
	if err != nil {
		t.Fatal(err)
	}

	if cfg.Lifecycle.InactiveDays != 30 {
		t.Errorf("got inactiveDays %d, want 30", cfg.Lifecycle.InactiveDays)
	}
	if len(cfg.Lifecycle.CleanupTags) != 2 {
		t.Fatalf("got %d cleanupTags, want 2", len(cfg.Lifecycle.CleanupTags))
	}
	if !cfg.Lifecycle.DryRun {
		t.Error("expected dryRun to be true")
	}
	if len(cfg.Lifecycle.ProbeTargets) != 1 {
		t.Fatalf("got %d probeTargets, want 1", len(cfg.Lifecycle.ProbeTargets))
	}
	if cfg.Lifecycle.ProbeTargets[0].Address != "robbinsdale-k8s-operator.keiretsu.ts.net:443" {
		t.Errorf("got probeTarget address %q", cfg.Lifecycle.ProbeTargets[0].Address)
	}
	if len(cfg.Lifecycle.ProbeDynamicTags) != 1 {
		t.Fatalf("got %d probeDynamicTags, want 1", len(cfg.Lifecycle.ProbeDynamicTags))
	}
}

func TestLoadLifecycleDefaults(t *testing.T) {
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

	if cfg.Lifecycle.InactiveDays != 30 {
		t.Errorf("got inactiveDays %d, want 30", cfg.Lifecycle.InactiveDays)
	}
	if cfg.Lifecycle.DryRun {
		t.Error("expected dryRun to default to false")
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
