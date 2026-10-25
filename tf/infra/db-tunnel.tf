# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "db_tunnel" {
  description = "Launch parameters for the ephemeral instance tunnelling to the database"
  value = {
    ami                = data.aws_ami.ubuntu.id
    subnet_id          = aws_subnet.public_1.id
    security_group_ids = [aws_security_group.ssh.id, aws_security_group.db_access.id]
    key_name           = aws_key_pair.ssh.key_name
  }
}
