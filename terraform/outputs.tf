output "instance_ip" {
  description = "Public IP of the MicroK8s EC2 instance"
  value       = aws_instance.microk8s.public_ip
}

