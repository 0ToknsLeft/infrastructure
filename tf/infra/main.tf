terraform {
  required_version = ">= 1.16.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------
variable "aws_region" {
  description = "AWS region to deploy resources into"
  type        = string
  default     = "eu-central-1"
}

# Generate a strong background password for the RDS root admin account
resource "random_password" "master_password" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# -----------------------------------------------------------------------------
# VPC and Networking
# -----------------------------------------------------------------------------
data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "rds-sqlserver-vpc"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "rds-sqlserver-igw"
  }
}

resource "aws_subnet" "public_1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "rds-public-subnet-1"
  }
}

resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true

  tags = {
    Name = "rds-public-subnet-2"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "rds-public-rt"
  }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}

resource "aws_db_subnet_group" "main" {
  name       = "rds-sqlserver-subnet-group"
  subnet_ids = [aws_subnet.public_1.id, aws_subnet.public_2.id]

  tags = {
    Name = "RDS SQL Server public subnet group"
  }
}

# -----------------------------------------------------------------------------
# Security Group (Port 1433 for MS SQL Server)
# -----------------------------------------------------------------------------
resource "aws_security_group" "rds" {
  name        = "rds-sqlserver-public-sg"
  description = "Allow inbound MS SQL Server traffic from anywhere"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "MS SQL Server public access"
    from_port   = 1433
    to_port     = 1433
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "rds-sqlserver-public-sg"
  }
}

# -----------------------------------------------------------------------------
# RDS Instance (SQL Server Express 2025 on db.t3.micro)
# -----------------------------------------------------------------------------
resource "aws_db_instance" "default" {
  identifier             = "minimal-sqlserver-db"
  allocated_storage      = 20
  max_allocated_storage  = 20
  storage_type           = "gp3"
  engine                 = "sqlserver-ex"
  engine_version         = "17.00.4075.5.v1" # SQL Server 2025 CU8
  license_model          = "license-included"
  instance_class         = "db.t3.micro"
  username               = "rdsadmin_root"
  password               = random_password.master_password.result
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = true
  skip_final_snapshot    = true
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "db_endpoint" {
  description = "The database endpoint (host:port)"
  value       = aws_db_instance.default.endpoint
}

output "db_address" {
  description = "The database hostname"
  value       = aws_db_instance.default.address
}

output "db_port" {
  description = "The database port"
  value       = aws_db_instance.default.port
}

output "db_admin_username" {
  description = "The RDS root admin username"
  value       = aws_db_instance.default.username
}

output "db_admin_password" {
  description = "The RDS root admin password"
  value       = random_password.master_password.result
  sensitive   = true
}
