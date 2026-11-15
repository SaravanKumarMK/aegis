data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  # Runtime secrets live in SSM Parameter Store under this path. Terraform never
  # sees their values: they are written out-of-band and read at cold start.
  ssm_prefix = "/${local.name}"
  ssm_arn    = "arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter${local.ssm_prefix}/*"
  # The runtime database role created by `migrate_cli` (IAM-authenticated, DML only).
  app_db_role = "aegis_app"
  rds_connect = "arn:aws:rds-db:${var.aws_region}:${local.account_id}:dbuser:${aws_rds_cluster.this.cluster_resource_id}/${local.app_db_role}"
}

# --------------------------------------------------------------------------- #
# GitHub OIDC: read-only plan from main, and a narrow release role            #
# --------------------------------------------------------------------------- #

data "aws_iam_policy_document" "github_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_plan" {
  name                 = "${local.name}-github-plan"
  assume_role_policy   = data.aws_iam_policy_document.github_assume.json
  max_session_duration = 3600
  tags                 = { Name = "${local.name}-github-plan" }
}

#checkov:skip=CKV_AWS_356:AWS Describe APIs used by a read-only Terraform plan do not support resource scoping.
data "aws_iam_policy_document" "github_plan" {
  #checkov:skip=CKV_AWS_356:AWS Describe APIs used by a read-only Terraform plan do not support resource scoping.
  statement {
    sid       = "ReadState"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [var.terraform_state_bucket_arn, "${var.terraform_state_bucket_arn}/*"]
  }
  statement {
    sid       = "LockState"
    effect    = "Allow"
    actions   = ["dynamodb:DescribeTable", "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = [var.terraform_lock_table_arn]
  }
  statement {
    sid    = "ReadEnvironment"
    effect = "Allow"
    actions = [
      "apigateway:GET",
      "budgets:ViewBudget",
      "ce:GetAnomalyMonitors", "ce:GetAnomalySubscriptions",
      "cloudwatch:DescribeAlarms", "cloudwatch:ListTagsForResource",
      "ec2:DescribeAvailabilityZones", "ec2:DescribeEgressOnlyInternetGateways",
      "ec2:DescribeInternetGateways", "ec2:DescribeRouteTables", "ec2:DescribeSecurityGroupRules",
      "ec2:DescribeSecurityGroups", "ec2:DescribeSubnets", "ec2:DescribeVpcAttribute",
      "ec2:DescribeVpcEndpoints", "ec2:DescribeVpcs", "ec2:DescribeTags",
      "ecr:DescribeRepositories", "ecr:GetLifecyclePolicy", "ecr:ListTagsForResource",
      "ecs:DescribeClusters", "ecs:DescribeTaskDefinition", "ecs:ListTagsForResource",
      "events:DescribeRule", "events:ListTagsForResource", "events:ListTargetsByRule",
      "iam:GetRole", "iam:GetRolePolicy", "iam:ListAttachedRolePolicies", "iam:ListRolePolicies",
      "kms:DescribeKey", "kms:GetKeyPolicy", "kms:GetKeyRotationStatus", "kms:ListResourceTags",
      "lambda:GetFunction", "lambda:GetFunctionConfiguration", "lambda:GetPolicy",
      "lambda:ListVersionsByFunction",
      "logs:DescribeLogGroups", "logs:ListTagsForResource",
      "rds:DescribeDBClusterParameters", "rds:DescribeDBClusters", "rds:DescribeDBInstances",
      "rds:DescribeDBSubnetGroups", "rds:ListTagsForResource",
      "s3:GetBucketLifecycleConfiguration", "s3:GetBucketLocation", "s3:GetBucketPolicy",
      "s3:GetBucketPublicAccessBlock", "s3:GetBucketVersioning", "s3:GetEncryptionConfiguration",
      "sns:GetTopicAttributes", "sns:ListTagsForResource",
      "states:DescribeStateMachine", "states:ListTagsForResource",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_plan" {
  name   = "read-environment-plan"
  role   = aws_iam_role.github_plan.id
  policy = data.aws_iam_policy_document.github_plan.json
}

# Release: publish images, repoint the two functions, run the one-off migration.
# It cannot touch infrastructure, secrets, the database or IAM.
data "aws_iam_policy_document" "github_release_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:environment:scale-zero"]
    }
  }
}

resource "aws_iam_role" "github_release" {
  name                 = "${local.name}-github-release"
  assume_role_policy   = data.aws_iam_policy_document.github_release_assume.json
  max_session_duration = 3600
  tags                 = { Name = "${local.name}-github-release" }
}

data "aws_iam_policy_document" "github_release" {
  statement {
    sid       = "EcrLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid    = "PushImages"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.backend.arn, aws_ecr_repository.lambda.arn]
  }
  statement {
    sid       = "RepointFunctions"
    effect    = "Allow"
    actions   = ["lambda:UpdateFunctionCode", "lambda:GetFunction", "lambda:PublishVersion"]
    resources = [aws_lambda_function.api.arn, aws_lambda_function.sweep.arn]
  }
  statement {
    sid       = "RunMigration"
    effect    = "Allow"
    actions   = ["ecs:RunTask"]
    resources = ["arn:aws:ecs:${var.aws_region}:${local.account_id}:task-definition/${local.name}-migrate:*"]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.this.arn]
    }
  }
  statement {
    sid       = "ObserveMigration"
    effect    = "Allow"
    actions   = ["ecs:DescribeTasks"]
    resources = ["arn:aws:ecs:${var.aws_region}:${local.account_id}:task/${aws_ecs_cluster.this.name}/*"]
  }
  statement {
    sid       = "HandOverTaskRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.ecs_execution.arn, aws_iam_role.migrate_task.arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
  statement {
    sid       = "ReadMigrationLogs"
    effect    = "Allow"
    actions   = ["logs:GetLogEvents"]
    resources = ["${aws_cloudwatch_log_group.worker.arn}:*"]
  }
}

resource "aws_iam_role_policy" "github_release" {
  name   = "release-minimum"
  role   = aws_iam_role.github_release.id
  policy = data.aws_iam_policy_document.github_release.json
}

# --------------------------------------------------------------------------- #
# Lambda runtime (API and recovery sweep share one least-privilege role)       #
# --------------------------------------------------------------------------- #

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_runtime" {
  name               = "${local.name}-lambda-runtime"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = { Name = "${local.name}-lambda-runtime" }
}

#checkov:skip=CKV_AWS_111:Lambda VPC ENI lifecycle requires EC2 write actions on wildcard resources.
#checkov:skip=CKV_AWS_356:Lambda VPC ENI APIs do not support resource-level permissions.
data "aws_iam_policy_document" "lambda_runtime" {
  #checkov:skip=CKV_AWS_111:Lambda VPC ENI lifecycle requires EC2 write actions on wildcard resources.
  #checkov:skip=CKV_AWS_356:Lambda VPC ENI APIs do not support resource-level permissions.
  statement {
    sid       = "ReadRuntimeSecrets"
    effect    = "Allow"
    actions   = ["ssm:GetParametersByPath", "ssm:GetParameters", "ssm:GetParameter"]
    resources = [local.ssm_arn, "arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter${local.ssm_prefix}"]
  }
  statement {
    sid       = "DecryptRuntimeSecrets"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.data.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }
  }
  statement {
    sid       = "ConnectToDatabaseAsRuntimeRole"
    effect    = "Allow"
    actions   = ["rds-db:connect"]
    resources = [local.rds_connect]
  }
  statement {
    sid     = "StartWorkerExecutions"
    effect  = "Allow"
    actions = ["states:StartExecution"]
    # By name: the state machine's definition depends on the sweep function,
    # which depends on this policy, so referencing its attribute would be a cycle.
    resources = ["arn:aws:states:${var.aws_region}:${local.account_id}:stateMachine:${local.name}-investigation"]
  }
  statement {
    sid       = "WriteFunctionLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/lambda/${local.name}-*:*"]
  }
  statement {
    sid       = "ManageVpcInterfaces"
    effect    = "Allow"
    actions   = ["ec2:CreateNetworkInterface", "ec2:DeleteNetworkInterface", "ec2:DescribeNetworkInterfaces"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "lambda_runtime" {
  name   = "runtime-minimum"
  role   = aws_iam_role.lambda_runtime.id
  policy = data.aws_iam_policy_document.lambda_runtime.json
}

# --------------------------------------------------------------------------- #
# ECS: execution role (pull image, write logs) and the two task roles         #
# --------------------------------------------------------------------------- #

data "aws_iam_policy_document" "worker_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "ecs_execution" {
  name               = "${local.name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.worker_assume.json
  tags               = { Name = "${local.name}-ecs-execution" }
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Only the migration task injects a secret (the RDS-managed master password).
data "aws_iam_policy_document" "ecs_execution_migrate_secret" {
  statement {
    sid       = "ReadMasterCredential"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_rds_cluster.this.master_user_secret[0].secret_arn]
  }
  statement {
    sid       = "DecryptMasterCredential"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.data.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "ecs_execution_migrate_secret" {
  name   = "migration-master-credential"
  role   = aws_iam_role.ecs_execution.id
  policy = data.aws_iam_policy_document.ecs_execution_migrate_secret.json
}

resource "aws_iam_role" "worker_runtime" {
  name               = "${local.name}-worker-runtime"
  assume_role_policy = data.aws_iam_policy_document.worker_assume.json
  tags               = { Name = "${local.name}-worker-runtime" }
}

data "aws_iam_policy_document" "worker_runtime" {
  statement {
    sid       = "ReadRuntimeSecrets"
    effect    = "Allow"
    actions   = ["ssm:GetParametersByPath", "ssm:GetParameters", "ssm:GetParameter"]
    resources = [local.ssm_arn, "arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter${local.ssm_prefix}"]
  }
  statement {
    sid       = "DecryptRuntimeSecrets"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.data.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }
  }
  statement {
    sid       = "ConnectToDatabaseAsRuntimeRole"
    effect    = "Allow"
    actions   = ["rds-db:connect"]
    resources = [local.rds_connect]
  }
  statement {
    sid     = "InvokeModels"
    effect  = "Allow"
    actions = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = [
      "arn:aws:bedrock:*::foundation-model/*",
      "arn:aws:bedrock:*:${local.account_id}:inference-profile/*",
    ]
  }
  statement {
    sid       = "ArtifactObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }
  statement {
    sid       = "ArtifactObjectKeys"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.data.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.aws_region}.amazonaws.com"]
    }
  }
  statement {
    sid       = "ListArtifactPrefixes"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["investigations/*", "evidence/*", "executions/*", "evaluations/*"]
    }
  }
}

resource "aws_iam_role_policy" "worker_runtime" {
  name   = "runtime-minimum"
  role   = aws_iam_role.worker_runtime.id
  policy = data.aws_iam_policy_document.worker_runtime.json
}

# The migration task runs as the Aurora master user (password injected by ECS)
# and needs no AWS permissions of its own.
resource "aws_iam_role" "migrate_task" {
  name               = "${local.name}-migrate-task"
  assume_role_policy = data.aws_iam_policy_document.worker_assume.json
  tags               = { Name = "${local.name}-migrate-task" }
}

# --------------------------------------------------------------------------- #
# Step Functions                                                               #
# --------------------------------------------------------------------------- #

data "aws_iam_policy_document" "sfn_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "sfn" {
  name               = "${local.name}-sfn"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
  tags               = { Name = "${local.name}-sfn" }
}

#checkov:skip=CKV_AWS_356:ecs:StopTask/DescribeTasks and the managed-rule events actions used by .sync integrations do not support task-level resources.
data "aws_iam_policy_document" "sfn" {
  #checkov:skip=CKV_AWS_356:ecs:StopTask/DescribeTasks and the managed-rule events actions used by .sync integrations do not support task-level resources.
  statement {
    sid       = "RunBoundedWorker"
    effect    = "Allow"
    actions   = ["ecs:RunTask"]
    resources = ["arn:aws:ecs:${var.aws_region}:${local.account_id}:task-definition/${local.name}-worker:*"]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.this.arn]
    }
  }
  statement {
    sid       = "ObserveAndStopTasks"
    effect    = "Allow"
    actions   = ["ecs:StopTask", "ecs:DescribeTasks"]
    resources = ["*"]
  }
  statement {
    sid       = "HandOverTaskRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.ecs_execution.arn, aws_iam_role.worker_runtime.arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
  statement {
    sid       = "SyncIntegrationRule"
    effect    = "Allow"
    actions   = ["events:PutTargets", "events:PutRule", "events:DescribeRule"]
    resources = ["arn:aws:events:${var.aws_region}:${local.account_id}:rule/StepFunctionsGetEventsForECSTaskRule"]
  }
  statement {
    sid       = "SettleDispatch"
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.sweep.arn]
  }
  statement {
    sid    = "DeliverExecutionLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogDelivery", "logs:GetLogDelivery", "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery", "logs:ListLogDeliveries", "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies", "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "sfn" {
  name   = "orchestrate-bounded-worker"
  role   = aws_iam_role.sfn.id
  policy = data.aws_iam_policy_document.sfn.json
}
