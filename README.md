# github-runner-setup

Scale-to-zero GitHub Actions self-hosted runners on AWS EC2 Spot (ARM64).

## What's here

- `setup.sh` — provisions the full stack (IAM, SG, launch template, ASG, Lambda webhook handler, API Gateway, GitHub org webhook, S3 cache bucket).
- `teardown.sh` — removes everything.
- `lambda/scaler.py` — Lambda that scales the ASG on `workflow_job` events.
- `rust-s3-cache/` — composite action for same-region S3-backed cargo cache (replaces `Swatinem/rust-cache@v2`).

## Usage in workflows

```yaml
runs-on: [self-hosted, linux, arm64, fast]
steps:
  - uses: actions/checkout@v4
  - uses: dtolnay/rust-toolchain@stable
  - uses: MabrokaMedia/github-runner-setup/rust-s3-cache@main
    with:
      workspace: .
  - run: cargo build --release
```

The runner IAM role already has scoped access to `s3://mabroka-ci-cache`, so no AWS credentials step is needed.

## Why S3 instead of GitHub Actions cache

GitHub's Actions cache lives in Azure Blob Storage. Every cache upload from a self-hosted EC2 runner is outbound internet egress at $0.09/GB. For a Rust-heavy org, that's easily $150/mo.

Same-region S3 → EC2 transfer is free. Storage is $0.023/GB/mo; the 7-day lifecycle keeps the bill under $2/mo.
