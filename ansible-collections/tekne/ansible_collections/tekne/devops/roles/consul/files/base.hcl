node_name = "consul-server"
server = true
bootstrap_expect = 1
bind_addr = "192.168.75.11"
client_addr = "192.168.75.11"

ui_config {
  enabled = true
}

acl {
  enabled = true
  default_policy = "deny"
  down_policy = "extend-cache"
  role_ttl = "30s"
  policy_ttl = "30s"
  token_ttl = "30s"
  enable_token_persistence = true
}