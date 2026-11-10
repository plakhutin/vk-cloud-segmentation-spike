variable "region" { type = string }
variable "availability_zone" { type = string }
variable "image_id" { type = string }
variable "small_flavor_id" { type = string }
variable "large_flavor_id" { type = string }
variable "volume_type" { type = string }
variable "external_network_id" { type = string }
variable "floating_ip_pool" { type = string }
variable "ssh_public_key" { type = string }
variable "ssh_source_cidr" { type = string }
variable "management_cidr" { type = string }
variable "kubernetes_cidr" { type = string }
variable "database_cidr" { type = string }
variable "lb_backend_source_cidrs" {
  type = set(string)
  validation {
    condition     = length(var.lb_backend_source_cidrs) > 0 && alltrue([for c in var.lb_backend_source_cidrs : can(cidrnetmask(c)) && c != "0.0.0.0/0"])
    error_message = "Provide observed or documented IPv4 LB and health-check source CIDRs, not 0.0.0.0/0."
  }
}
