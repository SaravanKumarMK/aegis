# Scale-to-zero deployment: decisions, evidence and runbook

This describes what is deployed by `infra/terraform/environments/scale-zero-foundation`
(environment name `zero`, region `us-west-2`), why it is shaped this way, what was
measured, and how to operate it. It supersedes the target sketch in
[scale-to-zero-plan.md](scale-to-zero-plan.md) where they differ. The code is the
authority; the specs in the repository root are unchanged.

## 1. Architecture

```text
Browser (Vercel) ─▶ API Gateway HTTP API ─▶ Lambda (container, in VPC) ─▶ Aurora Serverless v2
                                                │  (IAM auth, 0 ACU floor)
                         commit incident + job + outbox row (one transaction)
                                                │ inline, bounded, never fails the request
                                                ▼
                                   Step Functions (Standard)
                       RunWorker (Fargate, exits when done) ─▶ Settle (Lambda)
                              │ failure                          │ retry delay pending
                      wait out the dead worker's lease           └▶ Wait ─▶ Settle (≤5 rounds)
EventBridge, every 6 h ─▶ Settle Lambda   (the only recovery path for a request that died mid-publish)
```

There is no ECS service, no load balancer, no NAT gateway, no Redis/Neo4j task and no
provisioned concurrency. Application compute exists only while a request, a dispatch
settle, or one investigation is in flight.

### Decisions and the alternatives rejected

| Decision | Why | Rejected |
|---|---|---|
| API Gateway **HTTP API** + Lambda container | no hourly charge; $1/M requests; 30 s integration cap is acceptable for a request/response API | ALB (hourly), REST API (streaming is not needed because the client polls) |
| Lambda **in the VPC** with **IPv6 egress-only** gateway | Aurora is private. Egress-only IPv6 is free and reaches Google's token certificates and AWS dual-stack endpoints. Proven live: Firebase init, SSM, Step Functions all worked | NAT gateway (~$33/mo idle), interface endpoints (~$7/mo each per AZ), a public database |
| **Aurora Serverless v2**, min 0 ACU, 15 min pause, **IAM auth**, no proxy | the only PostgreSQL-compatible option that stops billing compute; IAM auth means no stored database password; RDS Proxy would prevent pausing | DynamoDB/Data API (would rewrite transactions, advisory locks, `SKIP LOCKED`), RDS Proxy |
| Performance Insights and Enhanced Monitoring **off** | AWS recommends 2 ACU minimum for Performance Insights and toggling it resumes the instance; the `ServerlessDatabaseCapacity` metric is the idle evidence | |
| **SSM SecureString** (standard tier) for secrets | free; no rotation is used; read once per cold start; split by path so the API role cannot read model keys | Secrets Manager ($0.40/secret/mo) except the RDS-managed master credential |
| **Step Functions Standard** + `ecs:runTask.sync` | idempotent by execution name, durable, waits out backoff and lease expiry without a poller | SQS + always-on poller, a Fargate service scaled to zero (not durable) |
| Fargate worker, one job per task (`--once`), 50 min time slice | task is billed only while working; long investigations span workers via checkpoints | Lambda (15 min cap), Spot (an interruption mid-slice only costs one lease wait, but the saving is ~$0.003/investigation) |
| Replay **polling** in the frontend | HTTP API buffers responses; polling backs off while nothing changes and stops while the tab is hidden | long-lived serverless connections |

### Correctness properties and where they are tested

| Property | Mechanism | Test |
|---|---|---|
| Incident, job and dispatch row commit or roll back together | trigger on `workflow_jobs` (migration 011) | `test_dispatch_recovery.py` |
| Any transition into `queued` re-arms dispatch exactly once | trigger `workflow_jobs_rearm_dispatch` (013); execution name = job id, then `-g<generation>` | `test_scale_zero_recovery.py`, `test_scale_zero_dispatch.py` |
| A crash loop cannot launch unbounded paid workers | `reap_stale`/`reclaim_own` park a job at `max_attempts`; redispatch ceiling of 25 generations | `test_reaped_crash_is_redispatched_but_a_spent_job_is_parked`, `test_job_that_never_progresses_is_parked_at_the_redispatch_ceiling` |
| Global worker ceiling cannot be overshot by racing dispatchers | count and claim under one advisory lock, counting `dispatching` rows | `test_concurrent_claims_cannot_overshoot_the_in_flight_ceiling` |
| A flood of distinct alerts is refused, not billed | queue-depth ceiling → `429 RATE_LIMITED`; duplicates still attach | alert router |
| A worker claims the destination it was dispatched for | `claim(dispatch_destination=…)` | `test_bounded_worker.py` (regression for a live defect found during deployment) |
| A dispatch whose job never ran is recovered | `recover_orphaned` in the sweep | `test_orphaned_dispatch_is_rearmed_only_after_a_worker_could_have_booted` |
| Runtime DB role cannot alter schema, audit history or the migration ledger | `grant_app_role` | `test_app_role_gets_data_access_but_cannot_change_the_schema` |
| Stale worker cannot settle a reclaimed job | lease fencing (012) | `test_job_leases.py` |
| Approvals pause durably | the worker exits after parking; the approval request enqueues a new job (kicked inline) | `test_approval_atomicity.py` |

No write-path control was changed: `ValidatedAction`, `ActionGate`, policy, tiers,
leases, idempotency and verification are untouched, `AUTONOMY_ENABLED=false` and
`SANDBOX_ENABLED=false` in this environment, and the worker role has no write
permission against any customer system.

## 2. Continuous monitoring: the unavoidable trade-off

The previous design ran a metrics forwarder and a z-score heartbeat inside the worker
every 5 seconds. That is incompatible with zero idle compute: the detector needs a
continuous in-memory ring buffer of scrapes. It was **not** simply disabled; it was
replaced:

* **Option A, chosen as the default: external, authenticated alert ingestion.**
  Alertmanager, Grafana or a cloud alarm calls `POST /v1/alerts` with the ingest token.
  Aegis is idle until an alert arrives, deduplicates on `(source, external_id)`, opens
  one incident and starts one investigation. Detection latency is the alert source's
  evaluation interval plus roughly 1–20 s (cold API, database resume).
* **Option B, available but off:** a scheduled one-shot detection pass. It would need a
  stateless detector (the current one is stateful), and every run wakes Aurora. At a
  5-minute cadence the database never reaches its 15-minute pause, so it is simply
  always on: 0.5 ACU × 24 h × $0.12 ≈ $1.44/day ≈ $43/month before any compute. It is
  therefore not provisioned.
* **Option C, on demand:** the reference workloads, load generator and fault injection
  are demonstration tooling, not production. They are not deployed in this environment
  and `WORKLOAD_METRICS_TARGETS`, `PROMETHEUS_URL`, `TEMPO_URL`, `LOKI_URL`,
  `NEO4J_URI` and `REDIS_HOST` are empty. Empty means *not deployed*, which the
  product already reports as an explicit evidence gap, never as healthy and never as
  "found nothing".

What is lost: Aegis no longer notices an anomaly by itself between alerts. A
deployment that needs that guarantee must run its own alert source (it already has
one if it uses Prometheus) or accept the cost of a resident detector (~$30/month for
one 0.25 vCPU Fargate task ≈ $9 and its public IPv4 ≈ $3.6, plus the always-awake
database ≈ $44: about $57/month).

## 3. Cost model (us-west-2)

Measured baseline of the previous stack (Cost Explorer, 1–15 Nov 2026, 15 days):
**$56.4 total**, of which infrastructure $45.1 (ECS $17.8, VPC public IPv4 $12.0,
ALB $7.7, RDS $6.6, Secrets Manager $0.4, ECR $0.2, Route 53 $0.5) and Bedrock
$11.3. Daily infrastructure spend was a flat ≈ $3.1, so the run-rate is
**≈ $90/month infrastructure plus ≈ $11–13/month model inference**. The new fixed
cost below is infrastructure only and is compared against the $90.

Unit prices are the published ones as of this work and are assumptions to re-verify:
Aurora Serverless v2 $0.12/ACU-h, storage $0.10/GB-month; Fargate $0.04048/vCPU-h and
$0.004445/GB-h; public IPv4 $0.005/h; Lambda $0.20/M requests and $0.0000166667/GB-s;
API Gateway HTTP $1.00/M; Step Functions Standard $25/M transitions (4,000 free).

| Fixed (idle) | $/month | Basis |
|---|---|---|
| Aurora compute while paused | 0 | measured: see §4 |
| Aurora storage (≈1–2 GB) | 0.10–0.20 | |
| KMS customer key | 1.00 | |
| Secrets Manager (RDS master credential) | 0.40 | |
| ECR (two repos, 10 builds kept) | 0.30–1.00 | |
| CloudWatch alarms (9) | 0.90 | |
| Recovery sweep wakes (4/day × ~$0.015) | ~1.80 | 0.5 ACU for the 15 min before pausing |
| Everything else (API Gateway, Lambda, Step Functions, SSM, S3, DynamoDB lock) | ≈0 | pay per use |
| **Total fixed** | **≈ $4–5** | vs ≈ $94 |

| Variable | Cost |
|---|---|
| 0 requests, 0 investigations | the fixed total above |
| API requests | ≈ $0.0026 per 100 at the ≈ 1 s warm latency measured (1.5 GB × 1 s Lambda ≈ $0.000025 + gateway $0.000001 each), plus one database wake of ≈ $0.015 per burst separated by more than 15 minutes |
| 10 / 100 / 1,000 / 10,000 requests | ≈ $0.015 / $0.018 / $0.04 / $0.28 when they arrive in one burst; if every request lands in its own 15-minute window the wake dominates: ≈ $0.15 / $1.50 / capped at $1.44 per day (96 wakes) |
| One investigation (compute) | ≈ $0.03–0.10: Fargate 1 vCPU/2 GB ≈ $0.054/h incl. IPv4 for 10–25 min (≈ $0.01–0.02), the database awake for the run plus the 15-minute pause delay (≈ $0.02–0.08), ≈ $0.0002 Step Functions |
| 1 / 10 / 100 investigations (compute) | ≈ $0.06 / $0.60 / $6 (investigations that overlap share one database wake, so 100 is an upper bound) |
| Model inference | not changed by this migration; previous spend was $11–13/month. Budget ≈ $0.3 per investigation at 50k input / 8k output tokens on Sonnet 4.6 (assumption — re-measure from Bedrock usage) |

Hard bounds that cap spend even under abuse: API Gateway 5 req/s steady, 10 burst
(also the practical Lambda concurrency bound, because this account's Lambda quota is
10 and reserved concurrency cannot be carved from it); ≤3 concurrent workers; ≤100
queued jobs, after which new incidents get `429`; one-hour execution timeout; ≤3
attempts per job; redispatch ceiling 25; Aurora ≤2 ACU; 14-day log retention;
`monthly_budget_usd` notification (AWS Budgets notifies, it does not stop spend).

## 4. Evidence from the live deployment

See §6 for the verification log (filled in from the live environment).

## 5. Operating it

**Release** (after `terraform apply` of reviewed changes): run the `deploy-scale-zero`
workflow from `main` (environment `scale-zero`, deployment branches restricted to
`main`). It builds both images, runs the migration task on the new image, repoints both
functions, then smoke-tests. Locally the same steps are in the workflow file.

**First-time bootstrap order** (images must exist before the functions can be created):
`terraform apply -target=aws_kms_key.data -target=aws_kms_alias.data
-target=aws_ecr_repository.backend -target=aws_ecr_repository.lambda`, push both images
built with `--provenance=false --sbom=false` (Lambda rejects the manifest list buildx
adds by default), write the secrets (below), full `terraform apply`, run the migration
task, then smoke-test.

**Secrets** (never in Terraform or CI): SecureString parameters under the data key,
`/aegis-zero/api/ALERT_INGEST_TOKEN`, `/aegis-zero/api/FIREBASE_SERVICE_ACCOUNT_JSON_BASE64`,
and model keys under `/aegis-zero/worker/` (`GOOGLE_API_KEY`…). Optional integrations
(GitHub, Slack, LangSmith, RawTree, Nimble, BFL) are intentionally unset and appear as
capability gaps.

**Rollback:** the previous stack is untouched. Repoint the frontend's
`NEXT_PUBLIC_API_BASE_URL` back to it. To roll back a function:
`aws lambda update-function-code --function-name aegis-zero-api --image-uri <previous digest>`.
Migrations are forward-only and idempotent; there is no schema rollback.

**Cutover (not yet performed):** set `NEXT_PUBLIC_API_BASE_URL` to the `api_url` output
and `NEXT_PUBLIC_EVENT_TRANSPORT=poll` in Vercel, add the new origin's alert sources,
rotate alert senders to the new ingest token, and keep the old stack through a
rollback window.

**Aurora pause check:** CloudWatch `ServerlessDatabaseCapacity` for
`aegis-zero-postgres` must reach 0 after ~15 minutes without connections. The
`aegis-zero-database-never-pauses` alarm fires if the minimum stays above 0 for three
days. A paused cluster resumes on the first connection in about 15 s; the API answers
`503 DATABASE_RESUMING` with `Retry-After` meanwhile and clients retry.

## 6. Residual risks recorded by independent review (not fixed in this change)

| Risk | Why it remains | What to do |
|---|---|---|
| One database role (`aegis_app`) serves the API and the worker; both can write every table except `audit_log` and `schema_migrations` | splitting needs a per-table review of what each component legitimately writes | create `aegis_api` and `aegis_worker` roles; the API should not write approvals, policy or lease tables |
| TLS to Aurora is encrypted but the certificate is not verified (`ssl="require"`) | the RDS CA bundle must be shipped in both images | add the bundle and use `verify-full` |
| Task definitions and functions run the mutable `:latest` tag; a principal that can push to ECR can change what the migration task and workers run | the release workflow tags every build and moves `latest`; role trust is pinned to the reviewed workflow on `main` | immutable tags plus digest-pinned task definitions |
| A compromised API Lambda can call `StartExecution` directly, bypassing the in-flight ceiling (application code) | the ceiling is in the claim, not in IAM | alarm on execution count; request an ECS Fargate task quota |
| Alarm topic has no subscriber unless `alert_email` is set; the e-mail must also be confirmed | cannot be chosen on the operator's behalf | set `alert_email` and confirm the subscription |
| The first alert after a long quiet period needs a ≈ 19 s cold start plus up to ≈ 15 s database resume, close to the 29 s gateway limit; the sender must retry 5xx | cannot be removed without provisioned concurrency | confirm each alert source retries on 502/503/504 before cutover |
| The 10-concurrency Lambda quota is shared with other workloads; 5 req/s with a 19 s cold start can in theory need more | quota increase is an AWS support request | request an increase, then reserve 2 for the sweep |
| In-flight count scans the outbox (small today); a terminal outbox state would let it use an index | not needed at current volume | migration 015 when the table grows |
| `/health` may touch the database, so an unauthenticated probe can wake Aurora | not yet changed | have monitors call `/health/live` only |

## 7. Known limitations

* Cold start of the API Lambda is long (first request ≈ 19 s: image load, imports, SSM
  read, IAM token, Firebase init); warm requests are ≈ 1 s. Provisioned concurrency
  would remove it and is excluded by the idle-cost requirement. The frontend must
  tolerate a slow first request.
* `GET /v1/incidents/{id}/stream` (SSE) does not stream through an HTTP API; the
  client polls `…/events`. The war-room health and workload frames depend on the
  reference workload and show as unavailable when it is not deployed.
* The account's Lambda quota (10) is shared with other projects; this environment
  cannot reserve concurrency. Request an increase before raising the throttle.
* Optional backends (graph/Neo4j, Redis, Prometheus, Tempo, Loki) are not deployed
  here. Graph pages report "not deployed". Moving the topology projection into
  PostgreSQL, or a hosted graph, is future work and was not done silently.
* Cost anomaly detection: the account already holds its one allowed monitor.
