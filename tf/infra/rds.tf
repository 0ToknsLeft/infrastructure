# Generate a strong background password for the RDS root admin account
resource "random_password" "master_password" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_db_subnet_group" "main" {
  name       = "rds-sqlserver-private-subnet-group"
  subnet_ids = [aws_subnet.private_1.id, aws_subnet.private_2.id]

  tags = {
    Name = "RDS SQL Server private subnet group"
  }
}

# -----------------------------------------------------------------------------
# Security Group marking the instances allowed to reach the database
# -----------------------------------------------------------------------------
resource "aws_security_group" "db_access" {
  name        = "db-access-sg"
  description = "Instances allowed to connect to the database"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "db-access-sg"
  }
}

# -----------------------------------------------------------------------------
# Security Group (Port 1433 for MS SQL Server)
# -----------------------------------------------------------------------------
resource "aws_security_group" "rds" {
  name        = "rds-sqlserver-private-sg"
  description = "Allow inbound MS SQL Server traffic from the db-access security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "MS SQL Server access from db-access instances"
    from_port       = 1433
    to_port         = 1433
    protocol        = "tcp"
    security_groups = [aws_security_group.db_access.id]
  }

  tags = {
    Name = "rds-sqlserver-private-sg"
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
  publicly_accessible    = false
  skip_final_snapshot    = true

  # RDS cannot move to another subnet group in the same VPC, so recreate it instead
  lifecycle {
    replace_triggered_by = [aws_db_subnet_group.main]
  }
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
