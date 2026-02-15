package platform

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"net/http"

	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"tailscale.com/tsnet"
)

func NewKubeRestConfig(srv *tsnet.Server, endpoint string) *rest.Config {
	return &rest.Config{
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
}

func NewKubeClient(srv *tsnet.Server, endpoint string) (*kubernetes.Clientset, error) {
	cfg := NewKubeRestConfig(srv, endpoint)
	cs, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		return nil, fmt.Errorf("kube client for %s: %w", endpoint, err)
	}
	return cs, nil
}

func NewDynamicKubeClient(srv *tsnet.Server, endpoint string) (dynamic.Interface, error) {
	cfg := NewKubeRestConfig(srv, endpoint)
	dc, err := dynamic.NewForConfig(cfg)
	if err != nil {
		return nil, fmt.Errorf("dynamic client for %s: %w", endpoint, err)
	}
	return dc, nil
}
