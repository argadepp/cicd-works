# Read only the single KV v2 secret required by the demo application.
path "secret/data/demo/database" {
  capabilities = ["read"]
}
