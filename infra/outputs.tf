output "bastion_public_ip" { value = vkcs_networking_floatingip.bastion.address }
output "lb_public_ip" { value = vkcs_networking_floatingip.lb.address }
output "private_ips" { value = { for name, port in vkcs_networking_port.vm : name => port.all_fixed_ips[0] } }
output "lb_backend_source_cidrs" { value = var.lb_backend_source_cidrs }
output "network_cidrs" { value = local.networks }
