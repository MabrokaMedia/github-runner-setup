"""
Lambda function: GitHub Actions Runner Auto-Scaler
Receives workflow_job webhooks from GitHub, scales the appropriate ASG up for queued jobs.

Routes by label:
  - label "small" -> gh-runner-small-asg (c7g.large tier)
  - else         -> gh-runner-asg       (c7g.2xlarge tier)
"""

import json
import hashlib
import hmac
import os
import boto3

autoscaling = boto3.client("autoscaling")
ssm = boto3.client("ssm")

FAST_ASG = os.environ.get("FAST_ASG_NAME", os.environ.get("ASG_NAME", "gh-runner-asg"))
SMALL_ASG = os.environ.get("SMALL_ASG_NAME", "gh-runner-small-asg")
MAX_RUNNERS = int(os.environ.get("MAX_RUNNERS", "10"))
WEBHOOK_SECRET_PARAM = os.environ["WEBHOOK_SECRET_PARAM"]
# Common discriminator labels our workflows set — if present, job is for our runners
BASE_LABELS = {"self-hosted", "arm64"}


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
    if "small" in job_labels:
        return SMALL_ASG
    if "fast" in job_labels:
        return FAST_ASG
    # Default anything else matching base labels to fast
    return FAST_ASG


def get_asg_state(asg_name: str):
    resp = autoscaling.describe_auto_scaling_groups(
        AutoScalingGroupNames=[asg_name]
    )
    asg = resp["AutoScalingGroups"][0]
    return {
        "desired": asg["DesiredCapacity"],
        "running": len([
            i for i in asg["Instances"]
            if i["LifecycleState"] in ("InService", "Pending", "Pending:Wait", "Pending:Proceed")
        ]),
    }


def scale_up(asg_name: str):
    state = get_asg_state(asg_name)
    new_desired = min(state["desired"] + 1, MAX_RUNNERS)
    if new_desired <= state["desired"]:
        print(f"{asg_name}: already at max capacity ({MAX_RUNNERS}). Scheduling retry in 90s.")
        _schedule_retry()
        return False
    autoscaling.set_desired_capacity(
        AutoScalingGroupName=asg_name,
        DesiredCapacity=new_desired,
    )
    print(f"{asg_name}: scaled {state['desired']} -> {new_desired}")
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
        for asg in (FAST_ASG, SMALL_ASG):
            try:
                state = get_asg_state(asg)
                if state["desired"] < MAX_RUNNERS:
                    new = min(state["desired"] + 1, MAX_RUNNERS)
                    autoscaling.set_desired_capacity(
                        AutoScalingGroupName=asg, DesiredCapacity=new
                    )
                    print(f"Periodic: {asg} {state['desired']} -> {new}")
            except Exception as e:
                print(f"Periodic: {asg}: {e}")
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

    scaled = scale_up(target)
    return {
        "statusCode": 200,
        "body": f"Scaled up {target}" if scaled else f"{target}: at max capacity",
    }
