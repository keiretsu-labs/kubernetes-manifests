package fluxmon

import (
	"time"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// ExtractStatus extracts FluxResourceStatus from an unstructured K8s object.
// Used by both fluxwatcher.go (watch loop) and activities.go (list).
func ExtractStatus(obj unstructured.Unstructured, cluster, kind string) FluxResourceStatus {
	s := FluxResourceStatus{
		Cluster:   cluster,
		Namespace: obj.GetNamespace(),
		Name:      obj.GetName(),
		Kind:      kind,
		LastSeen:  time.Now(),
	}

	if spec, ok := obj.Object["spec"].(map[string]any); ok {
		if suspended, ok := spec["suspend"].(bool); ok {
			s.Suspended = suspended
		}
	}

	status, ok := obj.Object["status"].(map[string]any)
	if !ok {
		return s
	}

	if rev, ok := status["lastAppliedRevision"].(string); ok && rev != "" {
		s.Revision = rev
	} else if rev, ok := status["lastAttemptedRevision"].(string); ok && rev != "" {
		s.Revision = rev
	}

	conditions, ok := status["conditions"].([]any)
	if !ok {
		return s
	}
	for _, c := range conditions {
		cond, ok := c.(map[string]any)
		if !ok {
			continue
		}
		if cond["type"] != "Ready" {
			continue
		}
		s.Ready = cond["status"] == "True"
		if reason, ok := cond["reason"].(string); ok {
			s.Reason = reason
		}
		if msg, ok := cond["message"].(string); ok {
			s.Message = msg
		}
		if lt, ok := cond["lastTransitionTime"].(string); ok {
			if t, err := time.Parse(time.RFC3339, lt); err == nil {
				s.LastTransition = t
			}
		}
		break
	}

	return s
}
