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
