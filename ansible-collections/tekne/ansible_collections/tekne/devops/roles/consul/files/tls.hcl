tls {
   defaults {
      ca_file = "/consul/config/certs/consul.tekne.sv-agent-ca.pem"
      cert_file = "/consul/config/certs/dc1-server-consul.tekne.sv-0.pem"
      key_file = "/consul/config/certs/dc1-server-consul.tekne.sv-0-key.pem"
      verify_incoming = true
      verify_outgoing = true
   }
   internal_rpc {
      verify_server_hostname = true
   }
}
auto_encrypt {
  allow_tls = true
}
ports {
  grpc_tls = 8503
}