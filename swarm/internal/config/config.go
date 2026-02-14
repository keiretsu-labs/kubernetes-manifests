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
