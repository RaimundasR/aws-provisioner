# ------------------------
# outputs.tf
# ------------------------

output "instance_ips" {
  description = "Public IPs of all EC2 instances"
  value = { for k, inst in aws_instance.microk8s : k => inst.public_ip }
}