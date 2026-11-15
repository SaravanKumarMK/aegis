locals {
  # One environment for the API, the sweep and the worker: the same composition
  # root must make the same policy and persistence decisions everywhere.
  runtime_env = {
    AEGIS_ENV              = "production"
    AEGIS_ENVIRONMENT_NAME = local.name
    AEGIS_MODE             = "live"
    LOG_FORMAT             = "json"
    AUTH_DEV_MODE          = "false"
    AUTONOMY_ENABLED       = "false"
    SANDBOX_ENABLED        = "false"
    HORIZON_DRIVER         = "horizon"
    API_RUN_MIGRATIONS     = "false"
    WORKER_RUN_MIGRATIONS  = "false"
    CORS_ALLOWED_ORIGINS   = var.cors_allowed_origins
    FIREBASE_PROJECT_ID    = var.firebase_project_id
    BEDROCK_MODEL_ID       = var.bedrock_model_id
    AEGIS_ARTIFACTS_BUCKET = aws_s3_bucket.artifacts.bucket

    BEDROCK_FALLBACK_MODEL_ID = var.bedrock_fallback_model_id
    AEGIS_FIXTURES_DIR        = "/app/tests/fixtures"

    POSTGRES_HOST     = aws_rds_cluster.this.endpoint
    POSTGRES_PORT     = "5432"
    POSTGRES_DB       = "aegis"
    POSTGRES_USER     = local.app_db_role
    POSTGRES_IAM_AUTH = "true"

    WORKFLOW_DISPATCH_BACKEND = "step_functions"
    # Referenced by name, not by attribute: the state machine's definition
    # depends on the sweep function, which shares this map.
    STEP_FUNCTIONS_STATE_MACHINE_ARN = "arn:aws:states:${var.aws_region}:${local.account_id}:stateMachine:${local.name}-investigation"
    WORKFLOW_MAX_IN_FLIGHT           = tostring(var.max_concurrent_workers)
    WORKFLOW_MAX_QUEUED_JOBS         = tostring(var.max_queued_jobs)

    # Optional backends are not deployed here. Empty means "not deployed", which
    # the product reports as an evidence gap, never as healthy or as "found
    # nothing", and never as a connection timeout.
    REDIS_HOST               = ""
    NEO4J_URI                = ""
    PROMETHEUS_URL           = ""
    TEMPO_URL                = ""
    LOKI_URL                 = ""
    WORKLOAD_METRICS_TARGETS = ""
    OTEL_TRACES_ENABLED      = "false"
  }
}

# --------------------------------------------------------------------------- #
# Images                                                                       #
# --------------------------------------------------------------------------- #

#checkov:skip=CKV_AWS_51:Tags are mutable on purpose; the release workflow tags each build with its commit and moves `latest`.
# Reviewed: tags are mutable on purpose (release moves latest); role trust is pinned to the reviewed workflow. See docs/scale-zero-runbook.md section 6.
#trivy:ignore:AWS-0031
resource "aws_ecr_repository" "backend" {
  #checkov:skip=CKV_AWS_51:Tags are mutable on purpose; the release workflow tags each build with its commit and moves `latest`.
  name                 = "${local.name}/backend"
  image_tag_mutability = "MUTABLE"
  force_delete         = false

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.data.arn
  }
  tags = { Name = "${local.name}-backend" }
}

#checkov:skip=CKV_AWS_51:Tags are mutable on purpose; the release workflow tags each build with its commit and moves `latest`.
# Reviewed: tags are mutable on purpose (release moves latest); role trust is pinned to the reviewed workflow. See docs/scale-zero-runbook.md section 6.
#trivy:ignore:AWS-0031
resource "aws_ecr_repository" "lambda" {
  #checkov:skip=CKV_AWS_51:Tags are mutable on purpose; the release workflow tags each build with its commit and moves `latest`.
  name                 = "${local.name}/lambda"
  image_tag_mutability = "MUTABLE"
  force_delete         = false

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.data.arn
  }
  tags = { Name = "${local.name}-lambda" }
}

# Untagged layers and old builds are the only unbounded storage cost here.
resource "aws_ecr_lifecycle_policy" "keep_recent" {
  for_each   = { backend = aws_ecr_repository.backend.name, lambda = aws_ecr_repository.lambda.name }
  repository = each.value
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after a day"
        selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 1 }
        action       = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the ten most recent builds"
        selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
        action       = { type = "expire" }
      },
    ]
  })
}

# --------------------------------------------------------------------------- #
# Logs: every group has finite retention                                       #
# --------------------------------------------------------------------------- #

#checkov:skip=CKV_AWS_158:The data key's default policy does not grant CloudWatch Logs; log content is covered by finite retention and IAM.
resource "aws_cloudwatch_log_group" "api" {
  #checkov:skip=CKV_AWS_158:The data key's default policy does not grant CloudWatch Logs; log content is covered by finite retention and IAM.
  name              = "/aws/lambda/${local.name}-api"
  retention_in_days = var.log_retention_days
}

#checkov:skip=CKV_AWS_158:The data key's default policy does not grant CloudWatch Logs; log content is covered by finite retention and IAM.
resource "aws_cloudwatch_log_group" "sweep" {
  #checkov:skip=CKV_AWS_158:The data key's default policy does not grant CloudWatch Logs; log content is covered by finite retention and IAM.
  name              = "/aws/lambda/${local.name}-sweep"
  retention_in_days = var.log_retention_days
}

#checkov:skip=CKV_AWS_158:The data key's default policy does not grant CloudWatch Logs; log content is covered by finite retention and IAM.
resource "aws_cloudwatch_log_group" "worker" {
  #checkov:skip=CKV_AWS_158:The data key's default policy does not grant CloudWatch Logs; log content is covered by finite retention and IAM.
  name              = "/aws/ecs/${local.name}"
  retention_in_days = var.log_retention_days
}

# --------------------------------------------------------------------------- #
# API and recovery sweep: Lambda container images in the data subnets          #
# --------------------------------------------------------------------------- #

# The Lambda quota in this account is 10 concurrent executions, so reserved
# concurrency cannot be carved out of it. API Gateway throttling (edge.tf) is
# the bound; raise the quota before introducing reserved concurrency.
#checkov:skip=CKV_AWS_115:Account concurrency quota (10) leaves nothing to reserve; bounded by API Gateway throttling instead.
#checkov:skip=CKV_AWS_116:Invoked synchronously by API Gateway; failures surface to the caller, so a DLQ would never receive them.
#checkov:skip=CKV_AWS_173:Environment variables hold no secrets (they are read from SSM at start); the AWS-managed key is sufficient.
#checkov:skip=CKV_AWS_272:Image digest signing is a deployment-gate decision.
#checkov:skip=CKV_AWS_50:X-Ray adds a per-trace charge and a daemon dependency; structured logs carry correlation ids instead.
resource "aws_lambda_function" "api" {
  #checkov:skip=CKV_AWS_115:Account concurrency quota (10) leaves nothing to reserve; bounded by API Gateway throttling instead.
  #checkov:skip=CKV_AWS_116:Invoked synchronously by API Gateway; failures surface to the caller, so a DLQ would never receive them.
  #checkov:skip=CKV_AWS_173:Environment variables hold no secrets (they are read from SSM at start); the AWS-managed key is sufficient.
  #checkov:skip=CKV_AWS_272:Image digest signing is a deployment-gate decision.
  #checkov:skip=CKV_AWS_50:X-Ray adds a per-trace charge and a daemon dependency; structured logs carry correlation ids instead.
  function_name = "${local.name}-api"
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.lambda.repository_url}:${var.image_tag}"
  role          = aws_iam_role.lambda_runtime.arn
  architectures = ["x86_64"]
  memory_size   = var.api_memory_mb
  # Under API Gateway's 30 s integration limit so the function, not the gateway,
  # decides how a slow request ends.
  timeout = 28

  vpc_config {
    subnet_ids                  = values(aws_subnet.data)[*].id
    security_group_ids          = [aws_security_group.lambda.id]
    ipv6_allowed_for_dual_stack = true
  }

  environment {
    variables = merge(local.runtime_env, {
      API_RUNTIME             = "lambda"
      AEGIS_SSM_PREFIX        = "${local.ssm_prefix}/api"
      AWS_DUALSTACK_ENDPOINTS = "true"
      POSTGRES_POOL_MIN       = "0"
      POSTGRES_POOL_MAX       = "3"
      # A frozen Lambda cannot close its own idle connection, and an open one
      # keeps Aurora from pausing; the server ends the session instead.
      POSTGRES_IDLE_SESSION_TIMEOUT_MS = "60000"
    })
  }

  depends_on = [aws_cloudwatch_log_group.api, aws_iam_role_policy.lambda_runtime]

  lifecycle { ignore_changes = [image_uri] }
  tags = { Name = "${local.name}-api" }
}

#checkov:skip=CKV_AWS_115:Account concurrency quota (10) leaves nothing to reserve; two invocations at most are possible by construction (Step Functions settle plus the schedule).
#checkov:skip=CKV_AWS_116:Invoked by Step Functions and EventBridge, which retry and alarm on failure.
#checkov:skip=CKV_AWS_173:Environment variables hold no secrets (they are read from SSM at start); the AWS-managed key is sufficient.
#checkov:skip=CKV_AWS_272:Image digest signing is a deployment-gate decision.
#checkov:skip=CKV_AWS_50:X-Ray adds a per-trace charge and a daemon dependency; structured logs carry correlation ids instead.
resource "aws_lambda_function" "sweep" {
  #checkov:skip=CKV_AWS_115:Account concurrency quota (10) leaves nothing to reserve; two invocations at most are possible by construction (Step Functions settle plus the schedule).
  #checkov:skip=CKV_AWS_116:Invoked by Step Functions and EventBridge, which retry and alarm on failure.
  #checkov:skip=CKV_AWS_173:Environment variables hold no secrets (they are read from SSM at start); the AWS-managed key is sufficient.
  #checkov:skip=CKV_AWS_272:Image digest signing is a deployment-gate decision.
  #checkov:skip=CKV_AWS_50:X-Ray adds a per-trace charge and a daemon dependency; structured logs carry correlation ids instead.
  function_name = "${local.name}-sweep"
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.lambda.repository_url}:${var.image_tag}"
  role          = aws_iam_role.lambda_runtime.arn
  architectures = ["x86_64"]
  memory_size   = 1024
  timeout       = 60

  image_config { command = ["aegis.worker.sweep_lambda.handler"] }

  vpc_config {
    subnet_ids                  = values(aws_subnet.data)[*].id
    security_group_ids          = [aws_security_group.lambda.id]
    ipv6_allowed_for_dual_stack = true
  }

  environment {
    variables = merge(local.runtime_env, {
      API_RUNTIME                      = "lambda"
      AEGIS_SSM_PREFIX                 = "${local.ssm_prefix}/api"
      AWS_DUALSTACK_ENDPOINTS          = "true"
      POSTGRES_POOL_MIN                = "0"
      POSTGRES_POOL_MAX                = "2"
      POSTGRES_IDLE_SESSION_TIMEOUT_MS = "60000"
    })
  }

  depends_on = [aws_cloudwatch_log_group.sweep, aws_iam_role_policy.lambda_runtime]

  lifecycle { ignore_changes = [image_uri] }
  tags = { Name = "${local.name}-sweep" }
}

# --------------------------------------------------------------------------- #
# Workers: task definitions only. There is deliberately no ECS service.        #
# --------------------------------------------------------------------------- #

resource "aws_ecs_cluster" "this" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "disabled" # Container Insights bills per task metric even for short tasks.
  }
  tags = { Name = local.name }
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "${local.name}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.worker_cpu
  memory                   = var.worker_memory_mb
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.worker_runtime.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "worker"
    image     = "${aws_ecr_repository.backend.repository_url}:${var.image_tag}"
    essential = true
    # One job per task, then exit: the task is billed only while it works.
    command = ["python", "-m", "aegis.worker.main", "--once", "--max-seconds", tostring(var.worker_max_seconds)]
    environment = [for key, value in merge(local.runtime_env, {
      AWS_REGION       = var.aws_region
      AEGIS_SSM_PREFIX = "${local.ssm_prefix}/api,${local.ssm_prefix}/worker"
    }) : { name = key, value = value }]
    stopTimeout = 120
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.worker.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "worker"
      }
    }
  }])

  tags = { Name = "${local.name}-worker" }
}

# Run once per release, as the Aurora master user, before the new image serves
# traffic. It also creates the runtime role the API and workers connect as.
resource "aws_ecs_task_definition" "migrate" {
  family                   = "${local.name}-migrate"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.migrate_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "migrate"
    image     = "${aws_ecr_repository.backend.repository_url}:${var.image_tag}"
    essential = true
    command   = ["python", "-m", "aegis.persistence.migrate_cli"]
    environment = [
      { name = "POSTGRES_HOST", value = aws_rds_cluster.this.endpoint },
      { name = "POSTGRES_PORT", value = "5432" },
      { name = "POSTGRES_DB", value = "aegis" },
      { name = "POSTGRES_USER", value = aws_rds_cluster.this.master_username },
      { name = "AEGIS_APP_DB_ROLE", value = local.app_db_role },
      { name = "LOG_FORMAT", value = "json" },
      { name = "OTEL_TRACES_ENABLED", value = "false" },
    ]
    secrets = [{
      name      = "POSTGRES_PASSWORD"
      valueFrom = "${aws_rds_cluster.this.master_user_secret[0].secret_arn}:password::"
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.worker.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "migrate"
      }
    }
  }])

  tags = { Name = "${local.name}-migrate" }
}
