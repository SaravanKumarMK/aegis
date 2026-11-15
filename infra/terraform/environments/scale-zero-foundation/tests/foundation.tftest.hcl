mock_provider "aws" {
  # Computed attributes that other expressions slice or interpolate must look
  # like what AWS returns, or the mock produces unparsable strings.
  mock_resource "aws_vpc" {
    defaults = {
      ipv6_cidr_block = "2600:1f14:abcd:1200::/56"
    }
  }

  mock_resource "aws_rds_cluster" {
    defaults = {
      cluster_resource_id = "cluster-ABCDEFGHIJKLMNOPQRSTUVWXYZ"
      endpoint            = "aegis-test.cluster-abc.us-west-2.rds.amazonaws.com"
      master_username     = "aegis_admin"
      master_user_secret = [{
        secret_arn    = "arn:aws:secretsmanager:us-west-2:123456789012:secret:rds!cluster-test-abcdef"
        kms_key_id    = "alias/aws/secretsmanager"
        secret_status = "active"
      }]
    }
  }
}

override_data {
  target = data.aws_region.current
  values = { name = "us-west-2" }
}

override_data {
  target = data.aws_caller_identity.current
  values = { account_id = "123456789012" }
}

override_data {
  target = data.aws_iam_policy_document.github_assume
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}

override_data {
  target = data.aws_iam_policy_document.github_plan
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}

override_data {
  target = data.aws_iam_policy_document.github_release_assume
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}

override_data {
  target = data.aws_iam_policy_document.github_release
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}

override_data {
  target = data.aws_iam_policy_document.lambda_assume
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}

override_data {
  target = data.aws_iam_policy_document.lambda_runtime
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}

override_data {
  target = data.aws_iam_policy_document.worker_assume
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}

override_data {
  target = data.aws_iam_policy_document.worker_runtime
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}

override_data {
  target = data.aws_iam_policy_document.ecs_execution_migrate_secret
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}

override_data {
  target = data.aws_iam_policy_document.sfn_assume
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}

override_data {
  target = data.aws_iam_policy_document.sfn
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}

override_data {
  target = data.aws_iam_policy_document.artifacts
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}

override_data {
  target = data.aws_iam_policy_document.alarms_topic
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}

variables {
  github_repository          = "example/aegis"
  github_oidc_provider_arn   = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  terraform_state_bucket_arn = "arn:aws:s3:::example-terraform-state"
  terraform_lock_table_arn   = "arn:aws:dynamodb:us-west-2:123456789012:table/example-terraform-lock"
  cors_allowed_origins       = "https://app.example.com"
  firebase_project_id        = "example-project"
}

run "idle_cost_contract" {
  command = plan

  assert {
    condition     = aws_rds_cluster.this.serverlessv2_scaling_configuration[0].min_capacity == 0
    error_message = "Aurora must retain the zero-ACU pause floor."
  }

  assert {
    condition     = aws_rds_cluster_instance.writer.instance_class == "db.serverless"
    error_message = "The only Aurora writer must use Serverless v2 capacity."
  }

  assert {
    condition     = aws_rds_cluster_instance.writer.performance_insights_enabled == false && aws_rds_cluster_instance.writer.monitoring_interval == 0
    error_message = "Performance Insights and Enhanced Monitoring must stay off: they complicate pausing and add idle cost."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.artifacts.restrict_public_buckets
    error_message = "Artifact storage must remain private."
  }

  assert {
    condition     = aws_subnet.data["us-west-2a"].map_public_ip_on_launch == false
    error_message = "Data subnets must never assign public addresses."
  }

  assert {
    condition     = aws_sfn_state_machine.investigation.type == "STANDARD"
    error_message = "Orchestration must be a Standard state machine: durable, idempotent by execution name."
  }

  assert {
    condition     = aws_apigatewayv2_api.this.protocol_type == "HTTP"
    error_message = "The edge must be an HTTP API: no hourly charge, no load balancer."
  }

  assert {
    condition     = aws_apigatewayv2_stage.default.default_route_settings[0].throttling_rate_limit <= 50
    error_message = "API throttling is the cost and concurrency bound and must stay low."
  }

  assert {
    condition     = aws_lambda_function.api.timeout < 30
    error_message = "The API function must time out before API Gateway's 30 s integration limit."
  }

  assert {
    condition     = aws_lambda_function.api.vpc_config[0].ipv6_allowed_for_dual_stack
    error_message = "The VPC Lambda needs dual-stack for NAT-free egress."
  }

  assert {
    condition     = contains(aws_ecs_task_definition.worker.requires_compatibilities, "FARGATE")
    error_message = "Workers are Fargate task definitions started per job."
  }
}

run "every_log_group_expires" {
  command = plan

  assert {
    condition = alltrue([
      aws_cloudwatch_log_group.api.retention_in_days > 0,
      aws_cloudwatch_log_group.sweep.retention_in_days > 0,
      aws_cloudwatch_log_group.worker.retention_in_days > 0,
      aws_cloudwatch_log_group.sfn.retention_in_days > 0,
      aws_cloudwatch_log_group.api_access.retention_in_days > 0,
      aws_cloudwatch_log_group.aurora_postgresql.retention_in_days > 0,
    ])
    error_message = "Every log group needs finite retention; an unbounded one is a growing idle cost."
  }
}

run "recovery_sweep_is_infrequent" {
  command = plan

  assert {
    condition     = !can(regex("minute", aws_cloudwatch_event_rule.sweep.schedule_expression))
    error_message = "A per-minute sweep would keep Aurora awake; it is a recovery path, not a poller."
  }
}

run "rejects_nonzero_aurora_floor" {
  command = plan

  variables {
    aurora_min_acu = 1
  }

  expect_failures = [var.aurora_min_acu]
}
