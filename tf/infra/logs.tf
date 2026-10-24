# -----------------------------------------------------------------------------
# CloudWatch Log Group for the app
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "app" {
  name              = "/todoapp/app"
  retention_in_days = 30
}

# -----------------------------------------------------------------------------
# Let the app instances write to the log group
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "app_logs" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.app.arn}:*"]
  }
}

resource "aws_iam_role_policy" "app_logs" {
  name   = "app-server-logs"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app_logs.json
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "log_groups" {
  description = "CloudWatch log groups of the app"
  value = {
    app = aws_cloudwatch_log_group.app.name
  }
}
