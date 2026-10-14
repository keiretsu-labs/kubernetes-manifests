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

locals {
  pg_readonly = {
    teslamate  = { host = "teslamate-postgres-r.teslamate.svc.cluster.local", database = "teslamate" }
    forgejo    = { host = "forgejo-postgres-r.forgejo.svc.cluster.local", database = "forgejo" }
    conference = { host = "lobby-postgres-r.tailscale-pam.svc.cluster.local", database = "conference" }
  }
}

resource "border0_socket" "ottawa_pg_readonly" {
  for_each = local.pg_readonly

  name          = "ottawa-pg-${each.key}"
  socket_type   = "database"
  connector_ids = [local.connectors.ottawa]

  database_configuration {
    protocol            = "postgres"
    service_type        = "standard"
    hostname            = each.value.host
    port                = 5432
    authentication_type = "username_and_password"
    username            = "pam_readonly"
    password            = var.pam_readonly_password
    database_name       = each.value.database
  }
}
