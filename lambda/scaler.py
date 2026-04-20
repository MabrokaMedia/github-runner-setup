"""
Lambda function: GitHub Actions Runner Auto-Scaler
Receives workflow_job webhooks from GitHub, scales ASG up for queued jobs.
"""

import json
import hashlib
import hmac
import os
import boto3

autoscaling = boto3.client("autoscaling")
ssm = boto3.client("ssm")

ASG_NAME = os.environ["ASG_NAME"]
MAX_RUNNERS = int(os.environ.get("MAX_RUNNERS", "3"))
WEBHOOK_SECRET_PARAM = os.environ["WEBHOOK_SECRET_PARAM"]
RUNNER_LABELS = set(os.environ.get("RUNNER_LABELS", "self-hosted").split(","))


def verify_signature(body: str, signature: str, secret: str) -> bool:
    """Verify GitHub webhook HMAC-SHA256 signature."""
    expected = "sha256=" + hmac.new(
        secret.encode(), body.encode(), hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(expected, signature)


def get_asg_state():
    """Get current ASG desired capacity and running instance count."""
    resp = autoscaling.describe_auto_scaling_groups(
        AutoScalingGroupNames=[ASG_NAME]
    )
    asg = resp["AutoScalingGroups"][0]
    return {
        "desired": asg["DesiredCapacity"],
        "running": len([
            i for i in asg["Instances"]
            if i["LifecycleState"] in ("InService", "Pending", "Pending:Wait", "Pending:Proceed")
        ]),
    }


def scale_up():
    """Increment ASG desired capacity by 1, up to MAX_RUNNERS.

    If already at max, schedule a retry via EventBridge so queued jobs
    get picked up once running runners finish and self-terminate.
    """
    state = get_asg_state()
    new_desired = min(state["desired"] + 1, MAX_RUNNERS)

    if new_desired <= state["desired"]:
        print(f"Already at max capacity ({MAX_RUNNERS}). Scheduling retry in 90s.")
        _schedule_retry()
        return False

    autoscaling.set_desired_capacity(
        AutoScalingGroupName=ASG_NAME,
        DesiredCapacity=new_desired,
    )
    print(f"Scaled ASG from {state['desired']} to {new_desired}")
    return True


def _schedule_retry():
    """Schedule this Lambda to re-check and scale in 90 seconds."""
    try:
        lambda_client = boto3.client("lambda")
        lambda_client.invoke(
            FunctionName=os.environ.get("AWS_LAMBDA_FUNCTION_NAME", "gh-runner-scaler"),
            InvocationType="Event",  # async
            Payload=json.dumps({"_retry": True}).encode(),
        )
        print("Scheduled async retry")
    except Exception as e:
        print(f"Failed to schedule retry: {e}")


def _count_queued_jobs():
    """Query GitHub API for queued self-hosted jobs across the org."""
    try:
        import urllib.request
        pat_resp = ssm.get_parameter(Name="/gh-runner/github-pat", WithDecryption=True)
        pat = pat_resp["Parameter"]["Value"]
        org_resp = ssm.get_parameter(Name="/gh-runner/org-name")
        org = org_resp["Parameter"]["Value"]

        # List org runners to find idle ones
        req = urllib.request.Request(
            f"https://api.github.com/orgs/{org}/actions/runners",
            headers={"Authorization": f"token {pat}", "Accept": "application/vnd.github+json"},
        )
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read())
        idle = sum(1 for r in data.get("runners", []) if r["status"] == "online" and not r["busy"])
        busy = sum(1 for r in data.get("runners", []) if r["status"] == "online" and r["busy"])
        print(f"Runners: {busy} busy, {idle} idle, {data.get('total_count', 0)} total")
        return idle, busy
    except Exception as e:
        print(f"Failed to query runners: {e}")
        return 0, 0


def handler(event, context):
    # Periodic check from EventBridge: scale ASG to match demand
    if event.get("_periodic_check") or event.get("_retry"):
        state = get_asg_state()
        idle, busy = _count_queued_jobs()

        # If there are idle runners, no need to scale (jobs will be picked up)
        if idle > 0:
            print(f"Periodic: {idle} idle runners available, no scale needed")
            return {"statusCode": 200, "body": f"{idle} idle runners"}

        # If no idle runners and ASG has room, scale up
        if state["desired"] < MAX_RUNNERS:
            new = min(state["desired"] + 2, MAX_RUNNERS)  # scale by 2 for faster catch-up
            autoscaling.set_desired_capacity(
                AutoScalingGroupName=ASG_NAME,
                DesiredCapacity=new,
            )
            print(f"Periodic: scaled ASG from {state['desired']} to {new}")
        else:
            print(f"Periodic: at max ({MAX_RUNNERS}), waiting for runners to free up")
        return {"statusCode": 200, "body": "Periodic check done"}

    # Parse API Gateway v2 payload
    body = event.get("body", "")
    headers = {k.lower(): v for k, v in event.get("headers", {}).items()}

    # Verify webhook signature
    signature = headers.get("x-hub-signature-256", "")
    secret_resp = ssm.get_parameter(Name=WEBHOOK_SECRET_PARAM, WithDecryption=True)
    secret = secret_resp["Parameter"]["Value"]

    if not verify_signature(body, signature, secret):
        return {"statusCode": 401, "body": "Invalid signature"}

    # Parse event
    gh_event = headers.get("x-github-event", "")
    if gh_event != "workflow_job":
        return {"statusCode": 200, "body": "Ignored event: " + gh_event}

    payload = json.loads(body)
    action = payload.get("action")
    job = payload.get("workflow_job", {})
    job_labels = set(job.get("labels", []))

    print(f"workflow_job action={action} labels={job_labels}")

    # Only scale on queued jobs that request our runner labels
    if action != "queued":
        return {"statusCode": 200, "body": f"Ignored action: {action}"}

    if not RUNNER_LABELS.intersection(job_labels):
        return {"statusCode": 200, "body": "Labels don't match, skipping"}

    scaled = scale_up()
    return {
        "statusCode": 200,
        "body": "Scaled up" if scaled else "Already at max capacity",
    }
