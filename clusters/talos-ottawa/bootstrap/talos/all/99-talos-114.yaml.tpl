{{- if semverCompare ">= 1.14.0-0" (.Node.RuntimeData.TalosVersion | default .TalosVersion) }}
---
apiVersion: v1alpha1
kind: KubeletConfig
$patch: delete
---
apiVersion: v1alpha1
kind: ResolverConfig
$patch: delete
---
apiVersion: v1alpha1
kind: KubeNodeConfig
$patch: delete
---
apiVersion: v1alpha1
kind: KubeNetworkConfig
$patch: delete
---
apiVersion: v1alpha1
kind: KubeFlannelCNIConfig
$patch: delete
---
apiVersion: v1alpha1
kind: FilesystemTrimConfig
$patch: delete
---
apiVersion: v1alpha1
kind: VolumeConfig
name: EPHEMERAL
$patch: delete
---
apiVersion: v1alpha1
kind: SecurityProfileConfig
workloadIsolation: false
---
machine:
  kubelet:
    image: ghcr.io/siderolabs/kubelet:v{{ trimPrefix "v" .KubernetesVersion }}
    defaultRuntimeSeccompProfileEnabled: true
    disableManifestsDirectory: true
{{- end }}
