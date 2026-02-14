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
				InsecureSkipVerify: true,
			},
		},
	}

	cs, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		return nil, fmt.Errorf("kube client for %s: %w", endpoint, err)
	}
	return cs, nil
}
