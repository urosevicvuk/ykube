output "vault_init_file" {
  description = "Absolute path to the vault-init.json file holding unseal keys + root token. Stage 07 reads this; back it up to Bitwarden."
  value       = abspath("${path.module}/secrets/vault-init.json")
}
