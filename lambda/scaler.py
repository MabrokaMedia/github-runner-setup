"""
Lambda function: GitHub Actions Runner Auto-Scaler
Receives workflow_job webhooks from GitHub, scales the appropriate ASG up for queued jobs.

Routes by label:
  - label "stable" -> gh-runner-stable-asg (c7g.2xlarge on-demand — long deploys/builds)
  - else           -> gh-runner-asg        (c7g.2xlarge spot, default)

There is no "small" tier. The label used to route here to `gh-runner-small-asg`,
which was never created in any account, so every job carrying it failed to scale
and sat queued until it expired. Only add a route once the ASG actually exists.
"""

import json
import hashlib
import hmac
import os
import urllib.error
import urllib.request
import boto3

autoscaling = boto3.client("autoscaling")
ssm = boto3.client("ssm")

FAST_ASG = os.environ.get("FAST_ASG_NAME", os.environ.get("ASG_NAME", "gh-runner-asg"))
STABLE_ASG = os.environ.get("STABLE_ASG_NAME", "gh-runner-stable-asg")
MAX_RUNNERS = int(os.environ.get("MAX_RUNNERS", "10"))
WEBHOOK_SECRET_PARAM = os.environ["WEBHOOK_SECRET_PARAM"]
# Same PAT the runners boot with. Lets a queued-job webhook ask GitHub how
# many self-hosted jobs are ACTUALLY queued right now, so concurrent
# invocations all compute the same target instead of racing +1 writes.
GITHUB_PAT_PARAM = os.environ.get("GITHUB_PAT_PARAM", "/gh-runner/github-pat")
# Common discriminator labels our workflows set — if present, job is for our runners
BASE_LABELS = {"self-hosted", "arm64"}


class UnknownAsgError(RuntimeError):
    """A configured ASG name does not exist in this account/region."""


def verify_signature(body: str, signature: str, secret: str) -> bool:
    expected = "sha256=" + hmac.new(
        secret.encode(), body.encode(), hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(expected, signature)


def pick_asg(job_labels: set) -> str | None:
    """Decide which ASG handles this job, or None if it's not ours."""
    # Must at least claim the base labels
    if not BASE_LABELS.issubset(job_labels):
        return None
    # `stable` wins over `fast` if both are set, so a workflow can opt a single
    # job up to on-demand without rewriting the rest.
    if "stable" in job_labels:
        return STABLE_ASG
    if "fast" in job_labels:
        return FAST_ASG
    # Default anything else matching base labels to fast
    return FAST_ASG


def get_asg_state(asg_name: str):
    resp = autoscaling.describe_auto_scaling_groups(
        AutoScalingGroupNames=[asg_name]
    )
    groups = resp["AutoScalingGroups"]
    # A name that doesn't exist is not an API error — it comes back as an empty
    # list. Indexing it blind gave operators a bare `IndexError: list index out
    # of range` with no hint that the ASG name was the problem.
    if not groups:
        raise UnknownAsgError(
            f"ASG {asg_name!r} does not exist in {os.environ.get('AWS_REGION', '?')}. "
            "Check FAST_ASG_NAME/STABLE_ASG_NAME on this Lambda and the routing "
            "table in pick_asg()."
        )
    asg = groups[0]
    return {
        "desired": asg["DesiredCapacity"],
        "running": len([
            i for i in asg["Instances"]
            if i["LifecycleState"] in ("InService", "Pending", "Pending:Wait", "Pending:Proceed")
        ]),
    }


_pat_cache = {"v": None}


def _github_pat() -> str | None:
    if _pat_cache["v"] is None:
        try:
            _pat_cache["v"] = ssm.get_parameter(Name=GITHUB_PAT_PARAM, WithDecryption=True)["Parameter"]["Value"] or ""
        except Exception as e:  # noqa: BLE001 — degrade to the fallback path, never fail the webhook
            print(f"github pat unavailable ({e}); falling back to verify-loop scaling")
            _pat_cache["v"] = ""
    return _pat_cache["v"] or None


def count_queued_self_hosted(repo_full_name: str, wanted_labels: set) -> int | None:
    """How many jobs are queued RIGHT NOW in this repo whose labels match
    this ASG's tier. None when GitHub cannot be asked (no PAT, API error) —
    the caller then uses the fallback.

    Two API pages of queued runs is plenty: the fleet's MAX_RUNNERS is 10
    and a repo rarely has more than a handful of queued runs at once.
    """
    pat = _github_pat()
    if not pat:
        return None
    hdr = {"Authorization": f"Bearer {pat}", "Accept": "application/vnd.github+json",
           "User-Agent": "gh-runner-scaler"}
    try:
        n = 0
        # A run is `queued` only until its FIRST job starts; a run whose
        # Test/Fargate jobs already ran is `in_progress` while its Build
        # job sits queued (live 2026-08-18 17:51: Build Lambda queued 20
        # min, this function counted 0, nothing scaled). Look at both.
        runs = []
        for status in ("queued", "in_progress"):
            req = urllib.request.Request(
                f"https://api.github.com/repos/{repo_full_name}/actions/runs?status={status}&per_page=30", headers=hdr)
            with urllib.request.urlopen(req, timeout=8) as r:
                runs.extend(json.load(r).get("workflow_runs", []))
        for run in runs[:30]:
            jreq = urllib.request.Request(
                f"https://api.github.com/repos/{repo_full_name}/actions/runs/{run['id']}/jobs?per_page=50", headers=hdr)
            with urllib.request.urlopen(jreq, timeout=8) as r:
                for j in json.load(r).get("jobs", []):
                    if j.get("status") == "queued" and wanted_labels.issubset(set(j.get("labels", []))):
                        n += 1
        return n
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, ValueError, KeyError) as e:
        print(f"count_queued_self_hosted failed ({e}); falling back to verify-loop scaling")
        return None


def scale_up(asg_name: str, repo_full_name: str | None = None, job_labels: set | None = None):
    """Make sure every queued job for this ASG's tier has a runner coming.

    Two `workflow_job queued` webhooks for the same workflow arrive within
    the same second (Rustfmt+Test, Clippy+Test — the COMMON case) and run
    as two concurrent invocations. The old code was read-desired /
    write-desired+1 with no lock: both read 0, both wrote 1. Observed live
    2026-08-18 07:34:45 — two events, two "scaled 0 -> 1" lines, ONE
    runner. It took the first job and, being ephemeral, exited; the second
    job sat queued for hours with desired back at 0. Reserved concurrency
    of 1 would serialise this but the account's Lambda ceiling is 10 and
    reserving one drops unreserved below the minimum.

    Preferred path (idempotent): ask GitHub how many jobs are queued for
    this tier right now and set desired = max(current, that count). N
    concurrent invocations all compute the same number and write the same
    number; there is nothing to race. Fallback when GitHub is unreachable:
    +1 with a bounded write-then-verify, which narrows the window to
    milliseconds and errs towards one idle runner rather than one
    starved job.
    """
    state = get_asg_state(asg_name)
    if state["desired"] >= MAX_RUNNERS:
        print(f"{asg_name}: already at max capacity ({MAX_RUNNERS}). Scheduling retry in 90s.")
        _schedule_retry()
        return False

    queued = None
    if repo_full_name and job_labels:
        queued = count_queued_self_hosted(repo_full_name, job_labels)

    if queued is not None:
        # The webhook that invoked us IS one queued job for this tier;
        # the listing can lag it by a few seconds. Never trust a count
        # below one.
        queued = max(queued, 1)
        # Every queued job needs a runner that is not already busy. Runners
        # are ephemeral (one job each), so `running` runners are spoken for.
        target = min(max(state["desired"], state["running"] + queued), MAX_RUNNERS)
        if target <= state["desired"]:
            print(f"{asg_name}: desired={state['desired']} already covers running={state['running']}+queued={queued}")
            return True
        autoscaling.set_desired_capacity(AutoScalingGroupName=asg_name, DesiredCapacity=target)
        print(f"{asg_name}: scaled {state['desired']} -> {target} (running={state['running']}, queued={queued})")
        return True

    # Fallback: +1 with verify.
    intended = min(state["desired"] + 1, MAX_RUNNERS)
    autoscaling.set_desired_capacity(AutoScalingGroupName=asg_name, DesiredCapacity=intended)
    print(f"{asg_name}: scaled {state['desired']} -> {intended} (fallback +1)")
    for attempt in range(3):
        after = get_asg_state(asg_name)["desired"]
        if after >= intended:
            return True
        bumped = min(after + 1, MAX_RUNNERS)
        if bumped <= after:
            _schedule_retry()
            return False
        autoscaling.set_desired_capacity(AutoScalingGroupName=asg_name, DesiredCapacity=bumped)
        print(f"{asg_name}: verify attempt {attempt+1}: desired was {after} < {intended} — re-bumped to {bumped}")
        intended = bumped
    _schedule_retry()
    return True


def _schedule_retry():
    try:
        lambda_client = boto3.client("lambda")
        lambda_client.invoke(
            FunctionName=os.environ.get("AWS_LAMBDA_FUNCTION_NAME", "gh-runner-scaler"),
            InvocationType="Event",
            Payload=json.dumps({"_retry": True}).encode(),
        )
        print("Scheduled async retry")
    except Exception as e:
        print(f"Failed to schedule retry: {e}")


def handler(event, context):
    if event.get("_periodic_check") or event.get("_retry"):
        failed = []
        for asg in (FAST_ASG, STABLE_ASG):
            # Per-ASG catch so one broken tier doesn't stop the others from
            # scaling. Deliberately no re-raise: this path runs as an async
            # (Event) invoke, so raising would make Lambda replay the whole
            # loop twice and double-bump the healthy ASGs. Failures are tagged
            # ERROR instead — alarm on a metric filter, not on Errors.
            try:
                state = get_asg_state(asg)
                if state["desired"] < MAX_RUNNERS:
                    new = min(state["desired"] + 1, MAX_RUNNERS)
                    autoscaling.set_desired_capacity(
                        AutoScalingGroupName=asg, DesiredCapacity=new
                    )
                    print(f"Periodic: {asg} {state['desired']} -> {new}")
            except Exception as e:
                failed.append(asg)
                print(f"ERROR Periodic: {asg}: {type(e).__name__}: {e}")
        if failed:
            return {
                "statusCode": 500,
                "body": f"Periodic check failed for: {', '.join(failed)}",
            }
        return {"statusCode": 200, "body": "Periodic check done"}

    body = event.get("body", "")
    headers = {k.lower(): v for k, v in event.get("headers", {}).items()}

    signature = headers.get("x-hub-signature-256", "")
    secret_resp = ssm.get_parameter(Name=WEBHOOK_SECRET_PARAM, WithDecryption=True)
    secret = secret_resp["Parameter"]["Value"]
    if not verify_signature(body, signature, secret):
        return {"statusCode": 401, "body": "Invalid signature"}

    gh_event = headers.get("x-github-event", "")
    if gh_event != "workflow_job":
        return {"statusCode": 200, "body": "Ignored event: " + gh_event}

    payload = json.loads(body)
    action = payload.get("action")
    job = payload.get("workflow_job", {})
    job_labels = set(job.get("labels", []))
    print(f"workflow_job action={action} labels={job_labels}")

    if action != "queued":
        return {"statusCode": 200, "body": f"Ignored action: {action}"}

    target = pick_asg(job_labels)
    if not target:
        return {"statusCode": 200, "body": "Labels don't match, skipping"}

    # UnknownAsgError propagates on purpose: this path is synchronous, so a
    # misrouted label surfaces as a failed webhook delivery in GitHub *and* on
    # the Lambda Errors metric, rather than a 200 that pretends it scaled.
    repo_full_name = (payload.get("repository") or {}).get("full_name")
    scaled = scale_up(target, repo_full_name, job_labels)
    return {
        "statusCode": 200,
        "body": f"Scaled up {target}" if scaled else f"{target}: at max capacity",
    }
