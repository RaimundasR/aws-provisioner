# ------------------------
# main.tf
# ------------------------

resource "aws_security_group" "allow_ssh" {
  name        = "microk8s-ssh"
  description = "Allow SSH and HTTP/HTTPS access to MicroK8s"

  ingress {
    description = "Allow SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
  }

  ingress {
    description = "Allow HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
  }

  ingress {
    description = "Allow HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
  }

  ingress {
    description = "Allow MicroK8s API (port 16443)"
    from_port   = 16443
    to_port     = 16443
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "microk8s" {
  for_each = var.instances

  ami           = each.value.ami
  instance_type = each.value.instance_type
  key_name      = each.value.key_name

  security_groups = [aws_security_group.allow_ssh.name]

  tags = {
    Name = each.key
  }
}