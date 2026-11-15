# --------------------------------------------------------------------------- #
# Investigation orchestration: one Standard execution per dispatch             #
#                                                                              #
#   RunWorker (Fargate, exits when done) -> Settle (dispatch what it left)     #
#                  | failure                                                   #
#           Wait for the dead worker's lease -> Settle                         #
#                                                                              #
# Nothing here polls. A worker exists only inside RunWorker; Settle redispatches#
# retries, time-sliced continuations and reaped crashes, and waits out a retry #
# backoff instead of checking for it.                                          #
# --------------------------------------------------------------------------- #

#checkov:skip=CKV_AWS_158:The data key's default policy does not grant CloudWatch Logs; log content is covered by finite retention and IAM.
resource "aws_cloudwatch_log_group" "sfn" {
  #checkov:skip=CKV_AWS_158:The data key's default policy does not grant CloudWatch Logs; log content is covered by finite retention and IAM.
  name              = "/aws/states/${local.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_sfn_state_machine" "investigation" {
  name     = "${local.name}-investigation"
  role_arn = aws_iam_role.sfn.arn
  type     = "STANDARD"

  definition = jsonencode({
    Comment = "Run one bounded Aegis worker, then settle the dispatch it leaves behind."
    StartAt = "Init"
    States = {
      Init = {
        Type       = "Pass"
        Parameters = { "job_id.$" = "$.job_id", rounds = 0 }
        Next       = "RunWorker"
      }
      RunWorker = {
        Type           = "Task"
        Resource       = "arn:aws:states:::ecs:runTask.sync"
        TimeoutSeconds = 3600
        Parameters = {
          LaunchType     = "FARGATE"
          Cluster        = aws_ecs_cluster.this.arn
          TaskDefinition = aws_ecs_task_definition.worker.family
          NetworkConfiguration = {
            AwsvpcConfiguration = {
              Subnets        = values(aws_subnet.worker)[*].id
              SecurityGroups = [aws_security_group.worker.id]
              # Egress to ECR, Bedrock and the model APIs without a NAT gateway;
              # the address exists only while the task does and accepts no ingress.
              AssignPublicIp = "ENABLED"
            }
          }
        }
        ResultPath = "$.worker"
        Retry = [{
          ErrorEquals     = ["ECS.ServerException", "ECS.AmazonECSException", "ECS.LimitExceededException"]
          IntervalSeconds = 10
          MaxAttempts     = 2
          BackoffRate     = 2
        }]
        # A failed or killed worker still holds its job lease. Wait it out, then
        # settle: the sweep reaps the job and re-arms its dispatch.
        Catch = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.worker_error", Next = "WaitForLease" }]
        Next  = "Settle"
      }
      WaitForLease = {
        Type    = "Wait"
        Seconds = 130 # job lease is 120 s
        Next    = "Settle"
      }
      Settle = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.sweep.arn
          Payload      = { source = "state-machine", "job_id.$" = "$.job_id" }
        }
        ResultSelector = { "retry_in_s.$" = "$.Payload.retry_in_s" }
        ResultPath     = "$.settle"
        Retry = [{
          # Covers an Aurora resume that outlasts the sweep's own retry budget.
          ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException", "States.TaskFailed"]
          IntervalSeconds = 15
          MaxAttempts     = 4
          BackoffRate     = 2
        }]
        Next = "BackoffPending"
      }
      BackoffPending = {
        Type = "Choice"
        Choices = [{
          And = [
            { Variable = "$.settle.retry_in_s", IsPresent = true },
            { Variable = "$.settle.retry_in_s", IsNull = false },
            { Variable = "$.rounds", NumericLessThan = 5 },
          ]
          Next = "WaitForBackoff"
        }]
        Default = "Done"
      }
      WaitForBackoff = {
        Type        = "Wait"
        SecondsPath = "$.settle.retry_in_s"
        Next        = "NextRound"
      }
      NextRound = {
        Type       = "Pass"
        Parameters = { "job_id.$" = "$.job_id", "rounds.$" = "States.MathAdd($.rounds, 1)" }
        Next       = "Settle"
      }
      Done = { Type = "Succeed" }
    }
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = false
    level                  = "ERROR"
  }

  depends_on = [aws_iam_role_policy.sfn]
  tags       = { Name = "${local.name}-investigation" }
}

# --------------------------------------------------------------------------- #
# Recovery sweep: the only scheduled invocation. It exists for one failure:    #
# a request that died between committing a job and publishing it. It is NOT a #
# poller - at the default cadence Aurora resumes four times a day.             #
# --------------------------------------------------------------------------- #

resource "aws_cloudwatch_event_rule" "sweep" {
  name                = "${local.name}-sweep"
  description         = "Low-frequency recovery for committed-but-unpublished dispatches."
  schedule_expression = var.sweep_schedule_expression
}

resource "aws_cloudwatch_event_target" "sweep" {
  rule  = aws_cloudwatch_event_rule.sweep.name
  arn   = aws_lambda_function.sweep.arn
  input = jsonencode({ source = "schedule" })

  retry_policy {
    maximum_retry_attempts       = 2
    maximum_event_age_in_seconds = 3600
  }
}

resource "aws_lambda_permission" "sweep_schedule" {
  statement_id  = "AllowSweepSchedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sweep.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.sweep.arn
}

# --------------------------------------------------------------------------- #
# API: HTTP API in front of the Lambda. No ALB, no provisioned capacity.       #
#                                                                              #
# HTTP APIs buffer responses (no streaming) and cap integrations at 30 s, so  #
# live updates use authenticated, replayable polling instead of SSE.           #
# --------------------------------------------------------------------------- #

#checkov:skip=CKV_AWS_158:The data key's default policy does not grant CloudWatch Logs; log content is covered by finite retention and IAM.
resource "aws_cloudwatch_log_group" "api_access" {
  #checkov:skip=CKV_AWS_158:The data key's default policy does not grant CloudWatch Logs; log content is covered by finite retention and IAM.
  name              = "/aws/apigateway/${local.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_apigatewayv2_api" "this" {
  name          = "${local.name}-api"
  protocol_type = "HTTP"
  description   = "Aegis control-plane API"
  # CORS is answered by the application, which owns the allowed-origin policy.
  tags = { Name = "${local.name}-api" }
}

resource "aws_apigatewayv2_integration" "api" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 29000
}

# Authentication is enforced inside the application (Firebase ID tokens for
# people, a shared token for alert sources) so every contract is identical to
# the service deployment. A gateway authorizer would be a second, divergent
# policy.
#checkov:skip=CKV_AWS_309:Authorization is enforced by the application on every route (Firebase verification / ingest token); a gateway authorizer would duplicate and diverge from it.
resource "aws_apigatewayv2_route" "default" {
  #checkov:skip=CKV_AWS_309:Authorization is enforced by the application on every route (Firebase verification / ingest token); a gateway authorizer would duplicate and diverge from it.
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.api.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_rate_limit  = var.api_throttle_rate
    throttling_burst_limit = var.api_throttle_burst
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      method         = "$context.httpMethod"
      path           = "$context.path"
      status         = "$context.status"
      responseLength = "$context.responseLength"
      latency        = "$context.responseLatency"
      integration    = "$context.integrationErrorMessage"
    })
  }
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}
