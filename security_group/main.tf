#--------------------------#
# Security Group Module
#--------------------------#
terraform {
  required_version = ">= 1.13.3"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 6.0" // 6.0 以上, 7.0未満
    }
  }
}

variable "name" {
  type = string
  description = "セキュリティグループ名"
}

variable "vpc_id" {
  type = string
  description = "VPC ID"
}

variable "port" {
  type = string
  description = "port"
}

variable "cidr_blocks" {
  type = list(string)
  description = "cidr_blocks"
}

# SG はネットワークレベルでパケットのフィルタリングが可能
resource "aws_security_group" "default" {
  name = var.name
  vpc_id = var.vpc_id
}

# インバウンドルール
resource "aws_security_group_rule" "ingress" {
  type = "ingress"
  from_port = var.port
  to_port = var.port
  protocol = "tcp"
  cidr_blocks = var.cidr_blocks
  security_group_id = aws_security_group.default.id
}

# アウトバウンドルール
resource "aws_security_group_rule" "egress" {
  type = "egress"
  from_port = "0"
  to_port = "0"
  protocol = "-1"
  cidr_blocks = ["0.0.0.0/0"]
  security_group_id = aws_security_group.default.id
}

output "security_group_id" {
  value = aws_security_group.default.id
}
