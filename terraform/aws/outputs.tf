output "instance_ips" {
  description = "Public IPs of the MicroK8s EC2 instances"
  value = {
    for name, instance in aws_instance.microk8s :
    name => instance.public_ip
  }
}
