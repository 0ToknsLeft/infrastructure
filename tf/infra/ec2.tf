# Generate the SSH key pair; the private key lives in the encrypted state
resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "ssh" {
  key_name   = "app-server-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

# -----------------------------------------------------------------------------
# Security Group (Port 22 for SSH)
# -----------------------------------------------------------------------------
resource "aws_security_group" "ssh" {
  name        = "app-server-ssh-sg"
  description = "Allow inbound SSH traffic from anywhere"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH public access"
    from_port   = 22
    to_port     = 22
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
    Name = "app-server-ssh-sg"
  }
}

# -----------------------------------------------------------------------------
# Security Group (Port 80 for HTTP)
# -----------------------------------------------------------------------------
resource "aws_security_group" "http" {
  name        = "app-server-http-sg"
  description = "Allow inbound HTTP traffic from anywhere"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP public access"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "app-server-http-sg"
  }
}

# -----------------------------------------------------------------------------
# IAM Role the app instances run as
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "app_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "app-server-role"
  assume_role_policy = data.aws_iam_policy_document.app_assume_role.json
}

resource "aws_iam_instance_profile" "app" {
  name = "app-server-profile"
  role = aws_iam_role.app.name
}

# -----------------------------------------------------------------------------
# EC2 Instances (Ubuntu 24.04 on t2.micro), one per public subnet
# -----------------------------------------------------------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

resource "aws_instance" "app" {
  count                  = 2
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t2.micro"
  subnet_id              = [aws_subnet.public_1.id, aws_subnet.public_2.id][count.index]
  key_name               = aws_key_pair.ssh.key_name
  vpc_security_group_ids = [aws_security_group.ssh.id, aws_security_group.http.id]
  iam_instance_profile   = aws_iam_instance_profile.app.name

  # Ship the app's journal to CloudWatch with Fluent Bit.
  # cloud-init runs this on first boot only, so changing it replaces the instance
  user_data = templatefile("${path.module}/fluent-bit.yaml.tftpl", {
    fluent_bit_key = file("${path.module}/fluent-bit.key")
    region         = var.aws_region
    app_log_group  = aws_cloudwatch_log_group.app.name
    log_stream     = "app-server-${count.index + 1}"
  })
  user_data_replace_on_change = true

  # Avoid replacing the instance whenever a newer AMI is published
  lifecycle {
    ignore_changes = [ami]
  }

  tags = {
    Name = "app-server-${count.index + 1}"
    Role = "app"
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "ec2_instances" {
  description = "SSH connection details for each EC2 instance, keyed by instance id"
  value = {
    for instance in aws_instance.app : instance.id => {
      host = instance.public_ip
      user = "ubuntu"
    }
  }
}

output "ssh_private_key" {
  description = "Private SSH key shared by all EC2 instances"
  value       = tls_private_key.ssh.private_key_openssh
  sensitive   = true
}
