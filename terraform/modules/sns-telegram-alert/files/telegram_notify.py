"""SNS → Telegram notifier.

Second subscriber on the ops-alert topic (alongside Slack). Credentials come
from Secrets Manager: JSON {"bot_token": "...", "chat_id": "..."} at the id
given in env var telegram_secretpath. If the secret isn't populated yet the
handler logs and exits cleanly so alarms don't error while Telegram is unset.

Payload shapes mirror slack_notify.py: CloudWatch alarms (AlarmName /
NewStateValue), Splunk alerts ({"message", "source"}), anything else verbatim.
"""

import json
import logging
import os
import urllib.error
import urllib.request

logger = logging.getLogger()
logger.setLevel(logging.INFO)

import boto3

secrets = boto3.client("secretsmanager")

_creds = None

EMOJI = {"danger": "🔴", "good": "🟢", "warning": "🟠"}


def creds():
    global _creds
    if _creds is None:
        raw = secrets.get_secret_value(
            SecretId=os.environ["telegram_secretpath"]
        )["SecretString"]
        _creds = json.loads(raw)
    return _creds


def esc(s):
    return (
        str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    )


def format_record(sns):
    try:
        message = json.loads(sns["Message"])
    except (json.JSONDecodeError, TypeError):
        return esc(sns["Message"]), "warning"

    if not isinstance(message, dict):
        return esc(message), "warning"

    if "AlarmName" in message:
        state = message.get("NewStateValue", "")
        severity = {"ALARM": "danger", "OK": "good"}.get(state, "warning")
        body = "\n".join(
            f"<b>{label}:</b> {esc(value)}"
            for label, value in [
                ("Account", os.environ.get("account_name", "")),
                ("Alarm", message.get("AlarmName") or ""),
                ("Description", message.get("AlarmDescription") or ""),
                ("State", f"{message.get('OldStateValue') or ''} → {state}"),
                ("Reason", message.get("NewStateReason") or ""),
                ("At", message.get("StateChangeTime") or ""),
            ]
            if value
        )
        return body, severity

    if "message" in message:
        severity = {"high": "danger", "low": "good"}.get(
            message.get("source"), "warning"
        )
        return esc(message["message"]), severity

    return esc(json.dumps(message)), "warning"


def send(text):
    c = creds()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{c['bot_token']}/sendMessage",
        json.dumps(
            {
                "chat_id": c["chat_id"],
                "text": text,
                "parse_mode": "HTML",
                "disable_web_page_preview": True,
            }
        ).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            response.read()
        logger.info("Message sent to Telegram chat %s", c["chat_id"])
    except urllib.error.HTTPError as e:
        logger.error("Telegram API error: %d %s — %s", e.code, e.reason, e.read()[:200])
    except urllib.error.URLError as e:
        logger.error("Telegram connection failed: %s", e.reason)


def handler(event, _context):
    logger.info("Event: %s", json.dumps(event))
    try:
        creds()
    except Exception as e:  # secret unset/malformed: skip quietly
        logger.warning("Telegram credentials unavailable (%s); skipping", e)
        return

    for record in event["Records"]:
        sns = record["Sns"]
        body, severity = format_record(sns)
        subject = esc(sns.get("Subject") or "AWS notification")
        send(f"{EMOJI[severity]} <b>{subject}</b>\n{body}")
