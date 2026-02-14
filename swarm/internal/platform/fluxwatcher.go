package platform

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
)

// gvrKind maps GVR to the Kind string since list items don't have Kind set.
var gvrKind = map[schema.GroupVersionResource]string{
	{Group: "kustomize.toolkit.fluxcd.io", Version: "v1", Resource: "kustomizations"}:    "Kustomization",
	{Group: "helm.toolkit.fluxcd.io", Version: "v2", Resource: "helmreleases"}:            "HelmRelease",
	{Group: "source.toolkit.fluxcd.io", Version: "v1", Resource: "gitrepositories"}:       "GitRepository",
	{Group: "source.toolkit.fluxcd.io", Version: "v1", Resource: "helmrepositories"}:      "HelmRepository",
	{Group: "source.toolkit.fluxcd.io", Version: "v1beta2", Resource: "ocirepositories"}:  "OCIRepository",
}

type FluxResource struct {
	Cluster        string
	Namespace      string
	Name           string
	Kind           string
	Ready          bool
	Reason         string
	Message        string
	Revision       string
	Suspended      bool
	LastTransition time.Time
}

func NewDynamicClient(cfg *rest.Config) (dynamic.Interface, error) {
	return dynamic.NewForConfig(cfg)
}

func ListFluxResources(ctx context.Context, client dynamic.Interface, cluster string) ([]FluxResource, error) {
	var all []FluxResource

	for gvr, kind := range gvrKind {
		list, err := client.Resource(gvr).Namespace("").List(ctx, metav1.ListOptions{})
		if err != nil {
			slog.Debug("skipping flux GVR", "gvr", gvr.Resource, "error", err)
			continue
		}
		for _, item := range list.Items {
			fr := extractFluxResource(item, cluster, kind)
			all = append(all, fr)
		}
	}

	return all, nil
}

func extractFluxResource(obj unstructured.Unstructured, cluster, kind string) FluxResource {
	fr := FluxResource{
		Cluster:   cluster,
		Namespace: obj.GetNamespace(),
		Name:      obj.GetName(),
		Kind:      kind,
	}

	if suspended, found, err := unstructured.NestedBool(obj.Object, "spec", "suspend"); err == nil && found {
		fr.Suspended = suspended
	}

	conditions, found, err := unstructured.NestedSlice(obj.Object, "status", "conditions")
	if err != nil || !found {
		return fr
	}

	for _, c := range conditions {
		cond, ok := c.(map[string]any)
		if !ok {
			continue
		}
		condType, _, _ := unstructured.NestedString(cond, "type")
		if condType != "Ready" {
			continue
		}
		status, _, _ := unstructured.NestedString(cond, "status")
		fr.Ready = status == "True"
		fr.Reason, _, _ = unstructured.NestedString(cond, "reason")
		fr.Message, _, _ = unstructured.NestedString(cond, "message")
		if ts, _, _ := unstructured.NestedString(cond, "lastTransitionTime"); ts != "" {
			if t, err := time.Parse(time.RFC3339, ts); err == nil {
				fr.LastTransition = t
			}
		}
		break
	}

	if rev, found, err := unstructured.NestedString(obj.Object, "status", "lastAppliedRevision"); err == nil && found {
		fr.Revision = rev
	} else if rev, found, err := unstructured.NestedString(obj.Object, "status", "artifact", "revision"); err == nil && found {
		fr.Revision = rev
	}

	return fr
}

func FluxGVRs() []schema.GroupVersionResource {
	gvrs := make([]schema.GroupVersionResource, 0, len(gvrKind))
	for gvr := range gvrKind {
		gvrs = append(gvrs, gvr)
	}
	return gvrs
}

// FluxResourceKey returns a unique key for deduplication.
func FluxResourceKey(fr FluxResource) string {
	return fmt.Sprintf("%s/%s/%s/%s", fr.Cluster, fr.Kind, fr.Namespace, fr.Name)
}
