terraform {
  required_version = ">= 1.11"

  # Pinned to the releases current at bootstrap-design time (2026-11). bpg and
  # talos are pre-1.0 and break things in minor releases, so those two only
  # float patch versions. Taskfile runs `tofu init -upgrade`, so the
  # (gitignored) lock files follow these constraints.
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.124.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.12.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.5"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.3"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.4"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.4"
    }
  }
}

provider "proxmox" {
  endpoint = var.proxmox_endpoint
  username = var.proxmox_username
  password = var.proxmox_password
  insecure = var.proxmox_insecure

  # None of the resources here currently need SSH (VM create, disk
  # passthrough and ISO download all go through the API), but the provider
  # falls back to it for some operations. Every host is listed explicitly.
  ssh {
    agent    = true
    username = "root"

    dynamic "node" {
      for_each = local.pve_hosts
      content {
        name    = node.key
        address = node.value[0]
      }
    }
  }
}
