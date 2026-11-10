locals {
  networks = { management = var.management_cidr, kubernetes = var.kubernetes_cidr, database = var.database_cidr }
  hosts = {
    bastion = { net = "management", size = "small", disk = 20 }
    admin   = { net = "management", size = "small", disk = 20 }
    cp      = { net = "kubernetes", size = "large", disk = 30 }
    worker1 = { net = "kubernetes", size = "large", disk = 30 }
    worker2 = { net = "kubernetes", size = "large", disk = 30 }
    pg      = { net = "database", size = "large", disk = 30 }
  }
}
resource "vkcs_networking_network" "net" {
  for_each = local.networks
  name     = "spike-${each.key}"
}
resource "vkcs_networking_subnet" "net" {
  for_each   = local.networks
  name       = "spike-${each.key}"
  network_id = vkcs_networking_network.net[each.key].id
  cidr       = each.value
}
resource "vkcs_networking_router" "main" {
  name                = "spike-router"
  external_network_id = var.external_network_id
}
resource "vkcs_networking_router_interface" "net" {
  for_each  = local.networks
  router_id = vkcs_networking_router.main.id
  subnet_id = vkcs_networking_subnet.net[each.key].id
}
resource "vkcs_networking_secgroup" "role" {
  for_each             = toset(["bastion", "admin", "node", "pg"])
  name                 = "spike-${each.key}"
  delete_default_rules = true
}
resource "vkcs_networking_secgroup_rule" "egress" {
  for_each          = vkcs_networking_secgroup.role
  security_group_id = each.value.id
  direction         = "egress"
  remote_ip_prefix  = "0.0.0.0/0"
}
locals {
  rules = {
    bastion_ssh = { role = "bastion", protocol = "tcp", min = 22, max = 22, cidr = var.ssh_source_cidr, group = null }
    admin_ssh   = { role = "admin", protocol = "tcp", min = 22, max = 22, cidr = null, group = "bastion" }
    node_ssh    = { role = "node", protocol = "tcp", min = 22, max = 22, cidr = null, group = "admin" }
    pg_ssh      = { role = "pg", protocol = "tcp", min = 22, max = 22, cidr = null, group = "admin" }
    pg_db       = { role = "pg", protocol = "tcp", min = 5432, max = 5432, cidr = var.kubernetes_cidr, group = null }
    node_tcp    = { role = "node", protocol = "tcp", min = null, max = null, cidr = null, group = "node" }
    node_udp    = { role = "node", protocol = "udp", min = null, max = null, cidr = null, group = "node" }
  }
}
resource "vkcs_networking_secgroup_rule" "ingress" {
  for_each          = local.rules
  security_group_id = vkcs_networking_secgroup.role[each.value.role].id
  direction         = "ingress"
  protocol          = each.value.protocol
  port_range_min    = each.value.min
  port_range_max    = each.value.max
  remote_ip_prefix  = each.value.cidr
  remote_group_id   = each.value.group == null ? null : vkcs_networking_secgroup.role[each.value.group].id
}
resource "vkcs_networking_secgroup_rule" "lb" {
  for_each          = var.lb_backend_source_cidrs
  security_group_id = vkcs_networking_secgroup.role["node"].id
  direction         = "ingress"
  protocol          = "tcp"
  port_range_min    = 30080
  port_range_max    = 30080
  remote_ip_prefix  = each.value
  lifecycle {
    precondition {
      condition     = (sum([for i, octet in split(".", cidrhost(each.value, 0)) : tonumber(octet) * pow(256, 3 - i)]) + pow(2, 32 - tonumber(split("/", each.value)[1])) <= sum([for i, octet in split(".", cidrhost(var.management_cidr, 0)) : tonumber(octet) * pow(256, 3 - i)])) || (sum([for i, octet in split(".", cidrhost(var.management_cidr, 0)) : tonumber(octet) * pow(256, 3 - i)]) + pow(2, 32 - tonumber(split("/", var.management_cidr)[1])) <= sum([for i, octet in split(".", cidrhost(each.value, 0)) : tonumber(octet) * pow(256, 3 - i)]))
      error_message = "LB source CIDRs must not overlap management; admin is the direct-bypass negative source."
    }
  }
}
resource "vkcs_compute_keypair" "ssh" {
  name       = "spike-key"
  public_key = var.ssh_public_key
}
resource "vkcs_networking_port" "vm" {
  for_each   = local.hosts
  name       = "spike-${each.key}"
  network_id = vkcs_networking_network.net[each.value.net].id
  fixed_ip { subnet_id = vkcs_networking_subnet.net[each.value.net].id }
  full_security_groups_control = true
  security_group_ids           = [vkcs_networking_secgroup.role[each.value.net == "kubernetes" ? "node" : each.key].id]
  depends_on                   = [vkcs_networking_router_interface.net]
}
resource "vkcs_compute_instance" "vm" {
  for_each          = local.hosts
  name              = "spike-${each.key}"
  availability_zone = var.availability_zone
  flavor_id         = each.value.size == "small" ? var.small_flavor_id : var.large_flavor_id
  key_pair          = vkcs_compute_keypair.ssh.name
  block_device {
    source_type           = "image"
    uuid                  = var.image_id
    destination_type      = "volume"
    volume_size           = each.value.disk
    volume_type           = var.volume_type
    delete_on_termination = true
  }
  network { port = vkcs_networking_port.vm[each.key].id }
}
resource "vkcs_networking_floatingip" "bastion" {
  pool       = var.floating_ip_pool
  port_id    = vkcs_networking_port.vm["bastion"].id
  depends_on = [vkcs_networking_router_interface.net]
}
resource "vkcs_lb_loadbalancer" "echo" {
  name              = "spike-echo"
  vip_subnet_id     = vkcs_networking_subnet.net["kubernetes"].id
  availability_zone = var.availability_zone
  depends_on        = [vkcs_networking_router_interface.net]
}
resource "vkcs_networking_floatingip" "lb" {
  pool    = var.floating_ip_pool
  port_id = vkcs_lb_loadbalancer.echo.vip_port_id
}
resource "vkcs_lb_listener" "echo" {
  loadbalancer_id = vkcs_lb_loadbalancer.echo.id
  protocol        = "HTTP"
  protocol_port   = 80
}
resource "vkcs_lb_pool" "echo" {
  listener_id = vkcs_lb_listener.echo.id
  protocol    = "HTTP"
  lb_method   = "ROUND_ROBIN"
}
resource "vkcs_lb_member" "echo" {
  for_each      = toset(["worker1", "worker2"])
  pool_id       = vkcs_lb_pool.echo.id
  address       = vkcs_networking_port.vm[each.key].all_fixed_ips[0]
  protocol_port = 30080
  subnet_id     = vkcs_networking_subnet.net["kubernetes"].id
}
resource "vkcs_lb_monitor" "echo" {
  pool_id     = vkcs_lb_pool.echo.id
  type        = "TCP"
  delay       = 10
  timeout     = 5
  max_retries = 3
}
