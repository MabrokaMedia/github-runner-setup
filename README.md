# github-runner-setup

Scale-to-zero GitHub Actions self-hosted runners on AWS EC2 Spot (ARM64).

## What's here

- `setup.sh` — provisions the initial stack (IAM, SG, launch template, ASG, Lambda webhook, API Gateway, GitHub org webhook, S3 cache bucket).
- `add-stable-asg.sh` — adds the on-demand `stable` tier (idempotent; mirrors the fast LT minus spot, enables CapacityRebalance on the spot ASGs).
- `build-ami.sh` — bakes a pre-installed AMI (OS deps + runner binary). Run this monthly to keep the AMI fresh.
- `teardown.sh` — removes everything.
- `lambda/scaler.py` — Lambda that routes `workflow_job queued` events to the right ASG by label (`stable` → stable tier, `small` → small tier, else → fast tier).
- `rust-s3-cache/` — composite actions (`restore/` + `save/`) that replace `Swatinem/rust-cache@v2` with a same-region S3 cache.
- `migrate-workflow.py` / `migrate-all.sh` — one-shot migration tooling used to roll out the S3 cache across existing workflows.

## Current production topology

```
  workflow_job=queued
          │
          ▼
  API Gateway → Lambda scaler.py
          │              │              │
   (label: small) (label: stable) (label: fast / default)
          │              │              │
          ▼              ▼              ▼
  gh-runner-small-asg  gh-runner-stable-asg  gh-runner-asg
  c7g/c6g/m6g/t4g      c7g.2xlarge           c7g/c6g/m7g/m6g
  .large (2 vCPU)      8 vCPU                .2xlarge (8 vCPU)
  40 GB gp3            80 GB gp3             80 GB gp3
  spot                 ON-DEMAND             spot
```

The `fast` and `small` ASGs use **MixedInstancesPolicy** with `price-capacity-optimized` spot allocation so the scheduler picks the cheapest ARM64 pool available. Instances are `--ephemeral` — one job per runner, then self-terminate and decrement desired capacity.

The `stable` ASG is **100% on-demand** — same instance shape as `fast`, no spot. It exists for jobs whose cancellation cost outweighs the ~5x price premium (long `cargo lambda build`, mid-deploy CFN change-sets — anything where a 30-min build getting reclaimed at minute 25 forces a full restart). Spot-eviction telemetry on 2026-04-30 motivated the split: three davoxi-backend deploys hit `BidEvictedEvent` mid-build/deploy in a single afternoon despite the 4-pool spot diversification, because `setup.sh` pins the ASG to a single AZ (intentional for ephemeral runners) and AZ-correlated capacity events still hit all four pools at once.

## Usage in workflows

```yaml
# big Rust compilation — clippy, test, cargo lambda build
runs-on: [self-hosted, linux, arm64, fast]

# long-running deploys / builds where mid-flight cancellation hurts
runs-on: [self-hosted, linux, arm64, stable]

# trivial jobs — fmt, small-proxy test
runs-on: [self-hosted, linux, arm64, small]

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
| Small runner tier for fmt/light jobs (c7g.large) | ~$30-60/mo (when workflows adopt the `small` label) |
| 1-day CloudWatch log retention on all Lambda log groups | ~$10/mo |

## Runtime operations

- **Rebuild AMI periodically**: `bash build-ami.sh us-east-1`. Then update the launch template's `ImageId` with the new AMI. Runner binary auto-updates once registered, but baking a fresh one every month or two keeps spawn time fast and saves on the runner download.
- **Roll out rust-s3-cache to a new workflow**: copy the pattern from `workflow-templates/rust-ci.yml` in `davoxi-shared`, or run `python migrate-workflow.py <path>` on an existing workflow file.
- **Monitor cost drift**: `aws ce get-cost-and-usage` with SERVICE grouping. Expect DataTransfer-Out-Bytes near zero; a spike means a workflow is uploading artifacts or caches to GitHub directly.
