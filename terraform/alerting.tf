# Alerting.
#
# Opt-in, and the sequencing is deliberate rather than an oversight. The load
# balancer is created by the AWS Load Balancer Controller in response to the
# Ingress, not by Terraform, so its ARN does not exist during the first apply
# and cannot be referenced then. The alarms are therefore discovered by tag and
# gated behind var.alert_email:
#
#   terraform apply                              # infrastructure
#   kubectl apply -k k8s/base                    # ingress -> controller -> ALB
#   terraform apply -var alert_email=me@x.com    # alarms bind to the ALB
#
# Hiding that ordering behind a data source that silently returns nothing would
# produce alarms in INSUFFICIENT_DATA forever, which is worse than none.

locals {
  alerting_enabled = var.alert_email != ""
}

# Discovered rather than declared: the controller owns this load balancer.
data "aws_lb" "app" {
  count = local.alerting_enabled ? 1 : 0

  tags = {
    "elbv2.k8s.aws/cluster" = module.eks.cluster_name
    "ingress.k8s.aws/stack" = "${local.name}/${local.name}"
  }
}

resource "aws_sns_topic" "alerts" {
  count = local.alerting_enabled ? 1 : 0

  name = "${local.name}-alerts"
  tags = local.tags
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count = local.alerting_enabled ? 1 : 0

  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email

  # Email subscriptions require the recipient to click a confirmation link.
  # Until they do, the subscription sits in "PendingConfirmation" and delivers
  # nothing — worth knowing before concluding the alarms are broken.
}

# The alarm that matters most: is the service actually answering?
#
# 5xx from the *target*, not from the load balancer. ELB 5xx largely means the
# ALB had no healthy target to route to, which the unhealthy-host alarm below
# already covers; target 5xx means the application itself is failing, which is
# the signal worth waking someone for.
resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  count = local.alerting_enabled ? 1 : 0

  alarm_name        = "${local.name}-target-5xx"
  alarm_description = "The greeter is returning server errors through the ALB."

  namespace   = "AWS/ApplicationELB"
  metric_name = "HTTPCode_Target_5XX_Count"
  statistic   = "Sum"

  dimensions = {
    LoadBalancer = data.aws_lb.app[0].arn_suffix
  }

  # Two consecutive minutes, so a single blip during a rollout does not page.
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"

  # No data means no traffic, not an outage. Treating it as breaching would
  # page every quiet night.
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts[0].arn]
  ok_actions    = [aws_sns_topic.alerts[0].arn]
  tags          = local.tags
}

# Capacity: replicas exist but the ALB cannot use them.
resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  count = local.alerting_enabled ? 1 : 0

  alarm_name        = "${local.name}-unhealthy-targets"
  alarm_description = "One or more greeter pods are failing ALB health checks."

  namespace   = "AWS/ApplicationELB"
  metric_name = "UnHealthyHostCount"
  statistic   = "Maximum"

  dimensions = {
    LoadBalancer = data.aws_lb.app[0].arn_suffix
  }

  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"

  # Three minutes tolerates a rolling update, where a target is briefly
  # unhealthy by design while it drains.
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts[0].arn]
  ok_actions    = [aws_sns_topic.alerts[0].arn]
  tags          = local.tags
}

# Latency, as a leading indicator. This fires before errors do, when the
# service is degrading rather than failing.
resource "aws_cloudwatch_metric_alarm" "target_latency" {
  count = local.alerting_enabled ? 1 : 0

  alarm_name        = "${local.name}-target-latency-p99"
  alarm_description = "p99 latency is elevated; the service is degrading."

  namespace          = "AWS/ApplicationELB"
  metric_name        = "TargetResponseTime"
  extended_statistic = "p99"

  dimensions = {
    LoadBalancer = data.aws_lb.app[0].arn_suffix
  }

  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  # The greeter does no I/O, so anything approaching a second is pathological
  # rather than merely slow.
  threshold           = 1
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts[0].arn]
  ok_actions    = [aws_sns_topic.alerts[0].arn]
  tags          = local.tags
}

# Node-level failure, which the ALB metrics would only show indirectly and late.
resource "aws_cloudwatch_metric_alarm" "cluster_failed_nodes" {
  count = local.alerting_enabled ? 1 : 0

  alarm_name        = "${local.name}-failed-nodes"
  alarm_description = "The EKS cluster reports one or more failed nodes."

  namespace   = "ContainerInsights"
  metric_name = "cluster_failed_node_count"
  statistic   = "Maximum"

  dimensions = {
    ClusterName = module.eks.cluster_name
  }

  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"

  # ContainerInsights publishes nothing unless the CloudWatch observability
  # addon is installed, so this alarm sits in INSUFFICIENT_DATA until it is.
  # Left in place as the hook for that, and called out in the README.
  treat_missing_data = "missing"

  alarm_actions = [aws_sns_topic.alerts[0].arn]
  tags          = local.tags
}
