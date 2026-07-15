"""SNS → Slack webhook notifier.

Formats CloudWatch alarm state changes and Splunk alert payloads into Slack
attachments and posts them to the configured channel. Payload shapes handled:

- CloudWatch alarm JSON (has "AlarmName"): red on ALARM, green on OK.
- Splunk alert JSON (has "message"): severity from its "source" field
  (high → red, low → green, else yellow); optional "entity" overrides the
  destination channel.
- Anything else (including non-JSON): posted verbatim as yellow.
"""

import json
import logging
import os
import urllib.error
import urllib.request

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

secrets = boto3.client("secretsmanager")

_hook_url = None


def hook_url():
    # Resolved on first use, not at import — an init-time Secrets Manager
    # blip would otherwise fail the whole cold start.
    global _hook_url
    if _hook_url is None:
        token = secrets.get_secret_value(
            SecretId=os.environ["token_secretpath"]
        )["SecretString"]
        _hook_url = f"https://hooks.slack.com/services/{token.lstrip('/')}"
    return _hook_url


def format_alarm(message):
    state = message.get("NewStateValue", "")
    severity = {"ALARM": "danger", "OK": "good"}.get(state, "warning")
    body = "\n".join(
        f"*{label}:* {value}"
        for label, value in [
            ("AWSAccount", os.environ["account_name"]),
            ("AlarmName", message.get("AlarmName") or ""),
            ("Description", message.get("AlarmDescription") or ""),
            ("State", f"{message.get('OldStateValue') or ''} -> {state}"),
            ("Reason", message.get("NewStateReason") or ""),
            ("Detected at", message.get("StateChangeTime") or ""),
        ]
    )
    return body, severity


def format_record(sns):
    """Returns (body, severity, channel_override) for one SNS record."""
    try:
        message = json.loads(sns["Message"])
    except (json.JSONDecodeError, TypeError):
        return sns["Message"], "warning", None

    if not isinstance(message, dict):
        return str(message), "warning", None

    channel = message.get("entity") or None

    if "AlarmName" in message:
        body, severity = format_alarm(message)
        return body, severity, channel

    if "message" in message:
        severity = {"high": "danger", "low": "good"}.get(
            message.get("source"), "warning"
        )
        return message["message"], severity, channel

    return json.dumps(message), "warning", channel


def post(slack_message):
    req = urllib.request.Request(
        hook_url(),
        json.dumps(slack_message).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            response.read()
        logger.info("Message posted to %s", slack_message["channel"])
    except urllib.error.HTTPError as e:
        logger.error("Request failed: %d %s", e.code, e.reason)
    except urllib.error.URLError as e:
        logger.error("Server connection failed: %s", e.reason)


def handler(event, _context):
    logger.info("Event: %s", json.dumps(event))

    for record in event["Records"]:
        sns = record["Sns"]
        body, severity, channel = format_record(sns)
        post(
            {
                "channel": channel or os.environ["slack_channel"],
                "text": f"*{sns.get('Subject') or 'AWS notification'}*",
                "attachments": [{"color": severity, "text": body}],
            }
        )
