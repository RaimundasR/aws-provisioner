variable "region" {
  type        = string
  description = "AWS region to deploy resources"
}

variable "ami" {
  type        = string
  description = "AMI ID to use for the EC2 instance"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type"
}

variable "key_name" {
  type        = string
  description = "Name of the AWS key pair"
}

variable "ssh_ingress_cidr" {
  type        = string
  description = "CIDR block to allow SSH access from"
}

variable "instances" {
  description = "Instances to create"
  type = map(object({
    ami           = string
    instance_type = string
    key_name      = string
  }))
  default = {}
}
