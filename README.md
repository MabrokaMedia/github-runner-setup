# github-runner-setup

Scale-to-zero GitHub Actions self-hosted runners on AWS EC2 Spot (ARM64).

## What's here

- `setup.sh` — provisions the initial stack (IAM, SG, launch template, ASG, Lambda webhook, API Gateway, GitHub org webhook, S3 cache bucket).
- `add-stable-asg.sh` — adds the on-demand `stable` tier (idempotent; mirrors the fast LT minus spot, enables CapacityRebalance on the spot ASGs).
- `build-ami.sh` — bakes a pre-installed AMI (OS deps + runner binary). Run this monthly to keep the AMI fresh.
- `teardown.sh` — removes everything.
- `lambda/scaler.py` — Lambda that routes `workflow_job queued` events to the right ASG by label (`stable` → stable tier, else → fast tier). It also still routes `small` → `gh-runner-small-asg`, **an ASG that does not exist** — see the note below.
- `rust-s3-cache/` — composite actions (`restore/` + `save/`) that replace `Swatinem/rust-cache@v2` with a same-region S3 cache.
- `migrate-workflow.py` / `migrate-all.sh` — one-shot migration tooling used to roll out the S3 cache across existing workflows.

## Current production topology

```
  workflow_job=queued
          │
          ▼
  API Gateway → Lambda scaler.py
          │              │              │
                         (label: stable) (label: fast / default)
                                │              │
                                ▼              ▼
                      gh-runner-stable-asg  gh-runner-asg
                      c7g.2xlarge           c7g/c6g/m7g/m6g
                      8 vCPU                .2xlarge (8 vCPU)
                      80 GB gp3             80 GB gp3
                      ON-DEMAND             spot
```

> **There is no `small` tier. Do not use the `small` label.**
>
> This README used to diagram a third `gh-runner-small-asg` (c7g.large spot).
> It was designed but never built: no ASG, no launch template, and no line in
> `setup.sh` has ever created one. `lambda/scaler.py` still routes the label to
> that name, and `runner-userdata.sh.tpl` only ever registers
> `self-hosted,linux,arm64,<tier>` for `tier` in {`fast`, `stable`}.
>
> A job asking for `small` is therefore not slow — it is **unschedulable**, and
> sits `queued` until its run expires. `migrate-to-small-and-nextest.py` spread
> the label to ~20 repos' fmt jobs, all of which silently never ran; they were
> repointed to `ubuntu-latest` on 2026-08-08. `fleet-keeper.yml` in
> davoxi-backend now fails red when any queued job requests a label with no ASG
> behind it, so this cannot go unnoticed again.

The `fast` ASG uses a **MixedInstancesPolicy** with `price-capacity-optimized` spot allocation so the scheduler picks the cheapest ARM64 pool available. Instances are `--ephemeral` — one job per runner, then self-terminate and decrement desired capacity.

The `stable` ASG is **100% on-demand** — same instance shape as `fast`, no spot. It exists for jobs whose cancellation cost outweighs the ~5x price premium (long `cargo lambda build`, mid-deploy CFN change-sets — anything where a 30-min build getting reclaimed at minute 25 forces a full restart). Spot-eviction telemetry on 2026-04-30 motivated the split: three davoxi-backend deploys hit `BidEvictedEvent` mid-build/deploy in a single afternoon despite the 4-pool spot diversification, because `setup.sh` pins the ASG to a single AZ (intentional for ephemeral runners) and AZ-correlated capacity events still hit all four pools at once.

## Usage in workflows

```yaml
# big Rust compilation — clippy, test, cargo lambda build
runs-on: [self-hosted, linux, arm64, fast]

# long-running deploys / builds where mid-flight cancellation hurts
runs-on: [self-hosted, linux, arm64, stable]

# trivial jobs — fmt, lint, anything platform-independent needing no AWS.
# Use GitHub-hosted, NOT a self-hosted label: booting an 8-vCPU ARM box for a
# 10-second `cargo fmt --check` costs more than the job. (The `small` tier this
# line used to recommend was never built — such jobs queued forever.)
runs-on: ubuntu-latest

steps:
  - uses: actions/checkout@v4
  - uses: dtolnay/rust-toolchain@stable
  - id: rust-cache
    uses: MabrokaMedia/github-runner-setup/rust-s3-cache/restore@main
    with:
      workspace: .
  - run: cargo build --release
  - if: always()
    uses: MabrokaMedia/github-runner-setup/rust-s3-cache/save@main
    with:
      workspace: .
      key: ${{ steps.rust-cache.outputs.key }}
      cache-hit: ${{ steps.rust-cache.outputs.cache-hit }}
```

The EC2 instance role already has scoped access to `s3://mabroka-ci-cache`, so no AWS credentials step is needed.

## Why same-region S3 cache instead of `actions/cache`

GitHub's Actions cache is Azure Blob Storage. Every cache upload from a self-hosted EC2 runner is outbound internet egress at $0.09/GB. For a Rust-heavy org, that's ~$150/mo.

Same-region S3 → EC2 transfer is free. Storage is $0.023/GB/mo; the 7-day lifecycle keeps the bill under $2/mo.

## Cost optimizations applied

| Optimization | Savings |
|---|---|
| S3 cache instead of GitHub Actions cache | ~$150/mo (eliminated egress) |
| Ephemeral runners (one job per spawn, scale-to-zero idle) | Baseline — $0 when CI isn't running |
| Pre-baked AMI (OS deps + runner binary) | ~$11/mo + faster spawns (60-90s saved per run) |
| Mixed Instances Policy with 4 ARM64 pools + price-capacity-optimized | ~$15-30/mo + fewer spot interruptions |
| Trivial jobs (fmt/lint) on GitHub-hosted instead of the fleet | Keeps them off the 8-vCPU boxes entirely, and out of the scaler's credit arithmetic |
| 1-day CloudWatch log retention on all Lambda log groups | ~$10/mo |

## Runtime operations

- **Rebuild AMI periodically**: `bash build-ami.sh us-east-1`. Then update the launch template's `ImageId` with the new AMI. Runner binary auto-updates once registered, but baking a fresh one every month or two keeps spawn time fast and saves on the runner download.
- **Roll out rust-s3-cache to a new workflow**: copy the pattern from `workflow-templates/rust-ci.yml` in `davoxi-shared`, or run `python migrate-workflow.py <path>` on an existing workflow file.
- **Monitor cost drift**: `aws ce get-cost-and-usage` with SERVICE grouping. Expect DataTransfer-Out-Bytes near zero; a spike means a workflow is uploading artifacts or caches to GitHub directly.
