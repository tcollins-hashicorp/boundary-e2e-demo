# Reference copy of the policy created by bootstrap.sh.
# Boundary's Vault credential store uses a token bound to this policy to broker
# SSH certificates and Kubernetes service-account tokens on demand.

path "ssh/sign/boundary-client"      { capabilities = ["create", "update"] }
path "ssh/issue/boundary-client"     { capabilities = ["create", "update"] }
path "kubernetes/creds/boundary-k8s" { capabilities = ["create", "update"] }

path "auth/token/lookup-self"        { capabilities = ["read"] }
path "auth/token/renew-self"         { capabilities = ["update"] }
path "auth/token/revoke-self"        { capabilities = ["update"] }
path "sys/leases/renew"              { capabilities = ["update"] }
path "sys/leases/revoke"             { capabilities = ["update"] }
path "sys/capabilities-self"         { capabilities = ["update"] }
