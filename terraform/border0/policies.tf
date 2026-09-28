locals {
  groups = {
    superuser = "d45f6ceb-eaa5-48ba-ae96-a7b456cb5d88"
    member    = "e48fd2d4-d3dc-4014-82c9-30bb8e8f9f50"
  }

  k8s_policies = {
    admin = {
      socket = border0_socket.ottawa_k8s_admin.id
      group  = local.groups.superuser
      verbs  = ["*"]
    }
    readonly = {
      socket = border0_socket.ottawa_k8s_readonly.id
      group  = local.groups.member
      verbs  = ["get", "list", "watch"]
    }
  }
}

resource "border0_policy" "ottawa_k8s" {
  for_each = local.k8s_policies

  name    = "ottawa-k8s-${each.key}"
  version = "v2"
  policy_data = jsonencode({
    permissions = {
      kubernetes = {
        rules = [{
          api_groups     = ["*"]
          namespaces     = ["*"]
          verbs          = each.value.verbs
          resources      = ["*"]
          resource_names = ["*"]
        }]
      }
    }
    condition = {
      who = {
        email           = []
        group           = [each.value.group]
        service_account = []
      }
      when = {
        after              = "2022-02-02T22:22:22Z"
        before             = null
        time_of_day_after  = ""
        time_of_day_before = ""
      }
    }
  })
}

resource "border0_policy_attachment" "ottawa_k8s" {
  for_each = local.k8s_policies

  policy_id = border0_policy.ottawa_k8s[each.key].id
  socket_id = each.value.socket
}
