terraform {
  required_version = "= 1.10.5"
  required_providers {
    vkcs = { source = "vk-cs/vkcs", version = "= 0.19.0" }
  }
}
provider "vkcs" {
  region = var.region
}
