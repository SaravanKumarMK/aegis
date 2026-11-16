variable "image_tag" {
  description = "Tag of the backend images in ECR. Releases update the functions directly, so Terraform ignores later image drift."
  type        = string
  default     = "latest"
}

variable "api_throttle_rate" {
  description = "Steady requests per second admitted by API Gateway across every route. Also the practical Lambda concurrency bound: this account's Lambda quota is 10 and cannot be reserved from."
  type        = number
  default     = 5

  validation {
    condition     = var.api_throttle_rate >= 1 && var.api_throttle_rate <= 50
    error_message = "api_throttle_rate must be between 1 and 50 requests per second."
  }
}

variable "api_throttle_burst" {
  description = "Burst ceiling above the steady rate."
  type        = number
  default     = 10

  validation {
    condition     = var.api_throttle_burst >= 1 && var.api_throttle_burst <= 100
    error_message = "api_throttle_burst must be between 1 and 100."
  }
}

variable "api_memory_mb" {
  description = "API Lambda memory. CPU scales with it, which dominates cold-start time."
  type        = number
  default     = 1536
}

variable "worker_cpu" {
  description = "Fargate vCPU units for one bounded worker."
  type        = number
  default     = 1024
}

variable "worker_memory_mb" {
  description = "Fargate memory for one bounded worker."
  type        = number
  default     = 2048
}

variable "worker_max_seconds" {
  description = "Time slice after which a worker stops claiming, checkpoints and exits. The job resumes on a new worker."
  type        = number
  default     = 3000

  validation {
    condition     = var.worker_max_seconds >= 300 && var.worker_max_seconds <= 3300
    error_message = "worker_max_seconds must leave the state machine timeout (3600 s) headroom."
  }
}

variable "max_concurrent_workers" {
  description = "Global ceiling on simultaneously dispatched investigation workers."
  type        = number
  default     = 3

  validation {
    condition     = var.max_concurrent_workers >= 1 && var.max_concurrent_workers <= 20
    error_message = "max_concurrent_workers must be between 1 and 20."
  }
}

variable "max_queued_jobs" {
  description = "Jobs allowed to wait before new incidents are refused with 429."
  type        = number
  default     = 100
}

variable "sweep_schedule_expression" {
  description = "Recovery sweep cadence. Each run can resume Aurora, so this trades recovery delay for idle cost."
  type        = string
  default     = "rate(6 hours)"
}

variable "log_retention_days" {
  description = "Finite retention for every log group."
  type        = number
  default     = 14
}

variable "cors_allowed_origins" {
  description = "Comma-separated browser origins allowed by the API."
  type        = string
}

variable "firebase_project_id" {
  description = "Firebase project whose ID tokens the API verifies. Not a secret."
  type        = string
}

variable "bedrock_model_id" {
  description = "Bedrock model or inference-profile id used by investigations."
  type        = string
  default     = ""
}

variable "bedrock_fallback_model_id" {
  description = "Model used when the primary is refused; the investigation must not stop on one model's access."
  type        = string
  default     = ""
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget for notifications. AWS Budgets alerts; it does not stop spend."
  type        = number
  default     = 30
}

variable "alert_email" {
  description = "Address for alarm, budget and cost-anomaly notifications. Empty creates the topics without a subscription."
  type        = string
  default     = ""
}
