variable "region" {
  type        = string
  description = "AWS region to deploy resources"
}

variable "key_name" {
  type        = string
  description = "Name of the AWS key pair"
}

variable "private_key_path" {
  type        = string
  description = "Path to the private key for SSH"
}

variable "ami" {
  type        = string
  description = "AMI ID to use for the EC2 instance"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type"
}

variable "ssh_ingress_cidr" {
  type        = string
  description = "CIDR block to allow SSH access from"
}
variable "instance_name" {
  description = "The name to assign to the EC2 instance"
  type        = string
}

