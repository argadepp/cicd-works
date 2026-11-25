# The same Vault role is used by Agent Injector and direct hvac SDK login.
path "database/creds/app-role" {
  capabilities = ["read"]
}
path "secret/data/jwt" {
  capabilities = ["read"]
}
path "pki/issue/vault-auth-demo" {
  capabilities = ["update"]
}
