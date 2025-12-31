variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP region for the cluster"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for the cluster (for zonal clusters)"
  type        = string
  default     = "us-central1-a"
}

variable "cluster_name" {
  description = "Name of the GKE cluster"
  type        = string
  default     = "raj-cluster"
}

variable "node_count" {
  description = "Number of nodes in the node pool"
  type        = number
  default     = 3
}

variable "machine_type" {
  description = "Machine type for nodes"
  type        = string
  default     = "e2-standard-4"
}

variable "disk_size_gb" {
  description = "Disk size in GB for nodes"
  type        = number
  default     = 100
}

variable "disk_type" {
  description = "Disk type for nodes"
  type        = string
  default     = "pd-standard"
}

variable "kubernetes_version" {
  description = "Kubernetes version (use 'latest' for most recent)"
  type        = string
  default     = "latest"
}

# Network settings matching cluster-settings.yaml
variable "pod_cidr" {
  description = "CIDR for pods"
  type        = string
  default     = "10.7.0.0/16"
}

variable "service_cidr" {
  description = "CIDR for services"
  type        = string
  default     = "10.6.0.0/16"
}

variable "enable_cilium" {
  description = "Install Cilium CNI (disables default GKE networking)"
  type        = bool
  default     = true
}

variable "cilium_version" {
  description = "Cilium Helm chart version"
  type        = string
  default     = "1.18.3"
}

variable "flux_version" {
  description = "Flux version for bootstrap"
  type        = string
  default     = "v2.7.5"
}

variable "github_repo" {
  description = "GitHub repository for Flux"
  type        = string
  default     = "keiretsu-labs/kubernetes-manifests"
}
