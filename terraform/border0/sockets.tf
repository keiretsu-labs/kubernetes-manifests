resource "border0_socket" "ottawa_k8s_admin" {
  name          = "ottawa-k8s-admin"
  socket_type   = "kubernetes"
  connector_ids = [local.connectors.ottawa]

  kubernetes_configuration {
    service_type          = "standard"
    impersonation_enabled = true
  }
}

resource "border0_socket" "ottawa_k8s_readonly" {
  name          = "ottawa-k8s-readonly"
  socket_type   = "kubernetes"
  connector_ids = [local.connectors.ottawa]

  kubernetes_configuration {
    service_type = "standard"
  }
}
