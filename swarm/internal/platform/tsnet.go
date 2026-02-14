package platform

import (
	"context"
	"fmt"
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
