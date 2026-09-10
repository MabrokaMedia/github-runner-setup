# Oracle runner host

A second home for the same runner fleet, on an Oracle Cloud Always Free ARM
instance. It exists so CI does not depend on the AWS account, and so the EC2
fleet can be switched back on at any time.

## Why the switch is cheap

GitHub dispatches a job to any idle runner carrying all of the labels the job
asks for. It has no idea where that runner is. The runners here register with
the same labels the EC2 fleet uses:

    self-hosted, linux, arm64, fast, stable

so **no workflow file changes, in any repository, in either direction.** The
`runs-on:` lines that exist today already match these runners.

Both labels sit on every slot. On EC2 the split exists because `fast` is spot
and `stable` is on-demand; here there is no spot market, so the distinction has
nothing to express and either slot serves either job.

## Switching

Nothing to deploy. The only state is which runners are online.

**To Oracle** — on the instance:

    sudo SLOTS=3 ./provision.sh

Then stop AWS from launching more, either by disabling the org webhook that
feeds `gh-runner-scaler`, or by setting both ASGs to max 0:

    aws autoscaling update-auto-scaling-group --auto-scaling-group-name gh-runner-asg \
      --min-size 0 --max-size 0 --desired-capacity 0 --region us-east-2
    aws autoscaling update-auto-scaling-group --auto-scaling-group-name gh-runner-stable-asg \
      --min-size 0 --max-size 0 --desired-capacity 0 --region us-east-2

**Back to AWS** — restore the ASG maxima (10 each) and re-enable the webhook,
then on the Oracle box:

    sudo systemctl disable --now 'gh-runner@*'

**Both at once** is legal and is the safest way to migrate: bring Oracle up
before taking AWS down, watch a few builds land, then scale AWS to zero. A job
goes to whichever runner is free first.

## What is different from EC2

| | EC2 fleet | Oracle host |
|---|---|---|
| Isolation | fresh instance per job | fresh runner registration per job, shared disk |
| Concurrency | up to 10 | `SLOTS`, default 3 |
| Cost | ~$400/mo at 2026 rates | free |
| Spot eviction | yes, on `fast` | none |
| Capacity | on demand | fixed |

The isolation difference is the one that matters. On EC2 a job could not see
another job's leftovers because the whole machine was new. Here the disk
persists between jobs. `--ephemeral` still guarantees one job per
registration, and `_work` is cleaned by the runner, but a workflow that writes
outside its workspace can leave traces. Nothing in this org does today.

Fixed capacity is the other. Ten concurrent EC2 runners become three slots, so
a burst queues instead of scaling out. For a repository count in the dozens
with a handful of daily pushes this is not the bottleneck; if it becomes one,
raise `SLOTS` up to the core count.

## The S3 build cache

`rust-s3-cache/` reads and writes `mabroka-ci-cache` in us-east-2. From Oracle
that is a cross-cloud transfer, and when the AWS account goes it disappears.

It fails soft. `restore` treats an unreachable bucket as a cache miss, logs a
warning and continues as a cold build, so builds keep passing and only get
slower. Moving the cache to local disk or R2 is a follow-up, not a blocker.

## Operating notes

- Idle Always Free instances can be reclaimed after about a week of near-zero
  activity. A host running builds is not idle; one sitting through a quiet
  fortnight might be.
- ARM capacity is often unavailable at creation time. That is scarcity, not
  your account. Ask for a smaller shape and try each availability domain.
- Two firewalls: Oracle's security list and the one inside the OS. Runners
  only make outbound connections, so neither needs opening for CI — this bites
  when you later host something that listens.
- `journalctl -u 'gh-runner@*' -f` follows all slots.
