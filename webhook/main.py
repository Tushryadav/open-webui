"""
AI Self-Healing Webhook Service for Open WebUI
------------------------------------------------
Flow:
  1. Receives alert from Alertmanager (or ArgoCD notifications)
  2. Collects pod logs + helm diff from Kubernetes
  3. Fires ArgoCD rollback to last healthy revision  ← NO AI involved
  4. Calls Claude API to diagnose the crash          ← AI is read-only
  5. Sends email with rollback confirmation + AI fix suggestion
"""

import os
import json
import smtplib
import subprocess
from datetime import datetime
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText

import httpx
from fastapi import FastAPI, BackgroundTasks, Request
from fastapi.responses import JSONResponse

app = FastAPI(title="Open WebUI AI Self-Heal Webhook")

# ── Config from environment variables ──────────────────────────────────────
ANTHROPIC_API_KEY   = os.environ["ANTHROPIC_API_KEY"]
ARGOCD_SERVER       = os.environ.get("ARGOCD_SERVER", "argocd-server.argocd.svc.cluster.local")
ARGOCD_TOKEN        = os.environ["ARGOCD_TOKEN"]          # ArgoCD API token
ARGOCD_APP_NAME     = os.environ.get("ARGOCD_APP_NAME", "open-webui")
K8S_NAMESPACE       = os.environ.get("K8S_NAMESPACE", "open-webui")

SMTP_HOST           = os.environ.get("SMTP_HOST", "smtp.gmail.com")
SMTP_PORT           = int(os.environ.get("SMTP_PORT", "587"))
SMTP_USER           = os.environ["SMTP_USER"]
SMTP_PASSWORD       = os.environ["SMTP_PASSWORD"]
ALERT_EMAIL_TO      = os.environ["ALERT_EMAIL_TO"]
ALERT_EMAIL_FROM    = os.environ.get("ALERT_EMAIL_FROM", SMTP_USER)

# ── Health check ───────────────────────────────────────────────────────────
@app.get("/healthz")
def healthz():
    return {"status": "ok"}


# ── Main alert endpoint (called by Alertmanager) ───────────────────────────
@app.post("/alert")
async def handle_alert(request: Request, background_tasks: BackgroundTasks):
    payload = await request.json()

    # Only act on firing critical alerts — ignore resolved/info
    alerts = payload.get("alerts", [])
    critical = [
        a for a in alerts
        if a.get("status") == "firing"
        and a.get("labels", {}).get("severity") == "critical"
        and a.get("labels", {}).get("app") == "open-webui"
    ]

    if not critical:
        return JSONResponse({"skipped": "no critical open-webui alerts"})

    # Run the full self-heal flow in the background so Alertmanager
    # gets an immediate 200 OK and doesn't retry
    background_tasks.add_task(self_heal_flow, critical[0])
    return JSONResponse({"status": "self-heal triggered"})


# ── Core self-healing flow ─────────────────────────────────────────────────
async def self_heal_flow(alert: dict):
    alert_name  = alert["labels"].get("alertname", "Unknown")
    pod_name    = alert["labels"].get("pod", "")
    container   = alert["labels"].get("container", "open-webui")
    fired_at    = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")

    print(f"[{fired_at}] Self-heal triggered: {alert_name} | pod={pod_name}")

    # ── Step 1: Collect crash context ─────────────────────────────────────
    pod_logs  = get_pod_logs(pod_name, container)
    pod_desc  = kubectl("describe", "pod", pod_name, "-n", K8S_NAMESPACE)
    helm_diff = get_helm_diff()

    # ── Step 2: ArgoCD rollback to last healthy revision ──────────────────
    rollback_result = argocd_rollback()

    # ── Step 3: Claude API diagnosis (read-only — no cluster changes) ──────
    diagnosis = await call_claude(alert_name, pod_logs, pod_desc, helm_diff)

    # ── Step 4: Send email ─────────────────────────────────────────────────
    send_email(
        alert_name=alert_name,
        pod_name=pod_name,
        fired_at=fired_at,
        rollback_result=rollback_result,
        pod_logs=pod_logs,
        diagnosis=diagnosis,
    )

    print(f"[{fired_at}] Self-heal complete. Email sent.")


# ── Kubernetes helpers ─────────────────────────────────────────────────────
def kubectl(*args) -> str:
    try:
        result = subprocess.run(
            ["kubectl", *args],
            capture_output=True, text=True, timeout=30
        )
        return result.stdout or result.stderr
    except Exception as e:
        return f"kubectl error: {e}"


def get_pod_logs(pod_name: str, container: str) -> str:
    """Get last 100 lines from the crashed container (previous run)."""
    if not pod_name:
        # No specific pod — get logs from any crashing pod in namespace
        pods_raw = kubectl("get", "pods", "-n", K8S_NAMESPACE,
                           "--field-selector=status.phase!=Running",
                           "-o", "jsonpath={.items[0].metadata.name}")
        pod_name = pods_raw.strip()

    if not pod_name:
        return "No crashed pod found"

    logs = kubectl("logs", pod_name, "-n", K8S_NAMESPACE,
                   "-c", container, "--previous", "--tail=100")
    if not logs:
        # Pod hasn't restarted yet — get current logs
        logs = kubectl("logs", pod_name, "-n", K8S_NAMESPACE,
                       "-c", container, "--tail=100")
    return logs or "No logs available"


def get_helm_diff() -> str:
    """Get diff between current deployed release and previous release."""
    try:
        result = subprocess.run(
            ["helm", "diff", "rollback", ARGOCD_APP_NAME, "0",
             "-n", K8S_NAMESPACE, "--no-color"],
            capture_output=True, text=True, timeout=30
        )
        diff = result.stdout[:3000]  # Cap at 3000 chars for Claude prompt
        return diff if diff else "No helm diff available"
    except Exception as e:
        return f"helm diff error: {e}"


# ── ArgoCD rollback ────────────────────────────────────────────────────────
def argocd_rollback() -> dict:
    """
    Rolls back the ArgoCD app to the last known Healthy revision.
    Uses ArgoCD REST API — no CLI dependency inside the container.
    """
    headers = {
        "Authorization": f"Bearer {ARGOCD_TOKEN}",
        "Content-Type": "application/json",
    }
    base = f"https://{ARGOCD_SERVER}"

    try:
        # 1. Get app history to find last healthy revision ID
        with httpx.Client(verify=False, timeout=30) as client:
            history_resp = client.get(
                f"{base}/api/v1/applications/{ARGOCD_APP_NAME}",
                headers=headers
            )
            history_resp.raise_for_status()
            app_data = history_resp.json()

        history = app_data.get("status", {}).get("history", [])
        if len(history) < 2:
            return {"status": "failed", "reason": "No previous revision in history"}

        # Last entry is current (broken), second-to-last is last good
        last_healthy = history[-2]
        revision_id  = last_healthy.get("id")
        revision_sha = last_healthy.get("revision", "unknown")[:8]

        # 2. Trigger rollback to that revision
        with httpx.Client(verify=False, timeout=60) as client:
            rollback_resp = client.post(
                f"{base}/api/v1/applications/{ARGOCD_APP_NAME}/rollback",
                headers=headers,
                json={"id": revision_id, "dryRun": False, "prune": True}
            )
            rollback_resp.raise_for_status()

        return {
            "status": "success",
            "rolled_back_to": f"Revision #{revision_id} ({revision_sha})",
        }

    except Exception as e:
        return {"status": "failed", "reason": str(e)}


# ── Claude API diagnosis ───────────────────────────────────────────────────
async def call_claude(
    alert_name: str,
    pod_logs: str,
    pod_desc: str,
    helm_diff: str,
) -> dict:
    """
    Calls Claude API to diagnose the crash.
    Returns root cause + suggested fix.
    Claude does NOT touch the cluster — diagnosis only.
    """
    prompt = f"""You are a Kubernetes DevOps expert.
A production pod in the open-webui namespace has crashed.
Your job is to diagnose the root cause and suggest a precise fix.
You have NO ability to make changes — your output goes to an email only.

ALERT: {alert_name}

POD LOGS (last 100 lines):
{pod_logs[:2000]}

POD DESCRIBE OUTPUT:
{pod_desc[:1500]}

HELM DIFF (current broken vs previous release):
{helm_diff[:2000]}

Respond in this exact JSON format (no markdown, no extra text):
{{
  "root_cause": "One sentence explaining exactly what caused the crash",
  "evidence": "The specific log line or helm diff line that proves this",
  "fix_type": "One of: memory_limit | image_tag | env_var | probe_config | resource_quota | dependency | other",
  "suggested_fix": "Exact YAML change to make in values.yaml or templates, with before/after",
  "confidence": "high | medium | low",
  "safe_to_auto_apply": false
}}"""

    try:
        async with httpx.AsyncClient(timeout=30) as client:
            resp = await client.post(
                "https://api.anthropic.com/v1/messages",
                headers={
                    "x-api-key": ANTHROPIC_API_KEY,
                    "anthropic-version": "2023-06-01",
                    "content-type": "application/json",
                },
                json={
                    "model": "claude-sonnet-4-20250514",
                    "max_tokens": 1000,
                    "messages": [{"role": "user", "content": prompt}],
                },
            )
            resp.raise_for_status()
            raw = resp.json()["content"][0]["text"].strip()
            return json.loads(raw)
    except json.JSONDecodeError:
        return {"root_cause": raw, "suggested_fix": "See raw output above", "confidence": "low"}
    except Exception as e:
        return {"root_cause": f"Diagnosis failed: {e}", "suggested_fix": "Check logs manually", "confidence": "low"}


# ── Email ──────────────────────────────────────────────────────────────────
def send_email(
    alert_name: str,
    pod_name: str,
    fired_at: str,
    rollback_result: dict,
    pod_logs: str,
    diagnosis: dict,
):
    rollback_status = rollback_result.get("status", "unknown")
    rollback_detail = rollback_result.get("rolled_back_to", rollback_result.get("reason", ""))

    html = f"""
<html><body style="font-family: monospace; background:#0f0f0f; color:#d4d4d4; padding:20px;">
<h2 style="color:#e24b4a;">🚨 Open WebUI — Crash Detected & Auto-Rollback Triggered</h2>
<table style="border-collapse:collapse; width:100%">
  <tr><td style="padding:6px; color:#888; width:180px;">Time</td>
      <td style="padding:6px;">{fired_at}</td></tr>
  <tr style="background:#1a1a1a;"><td style="padding:6px; color:#888;">Alert</td>
      <td style="padding:6px; color:#e24b4a;">{alert_name}</td></tr>
  <tr><td style="padding:6px; color:#888;">Pod</td>
      <td style="padding:6px;">{pod_name or "N/A"}</td></tr>
  <tr style="background:#1a1a1a;"><td style="padding:6px; color:#888;">Namespace</td>
      <td style="padding:6px;">{K8S_NAMESPACE}</td></tr>
  <tr><td style="padding:6px; color:#888;">Rollback status</td>
      <td style="padding:6px; color:{'#639922' if rollback_status == 'success' else '#e24b4a'};">
        {'✅' if rollback_status == 'success' else '❌'} {rollback_status.upper()} — {rollback_detail}
      </td></tr>
</table>

<h3 style="color:#EF9F27; margin-top:24px;">🤖 AI Root Cause Analysis</h3>
<p style="background:#1a1a1a; padding:12px; border-left:3px solid #EF9F27;">
  <strong>Root cause:</strong> {diagnosis.get('root_cause', 'Unknown')}<br><br>
  <strong>Evidence:</strong> {diagnosis.get('evidence', 'N/A')}<br><br>
  <strong>Confidence:</strong> {diagnosis.get('confidence', 'N/A')}
</p>

<h3 style="color:#1D9E75; margin-top:24px;">🔧 Suggested Fix (NOT applied — manual action required)</h3>
<pre style="background:#1a1a1a; padding:12px; border-left:3px solid #1D9E75; overflow-x:auto; white-space:pre-wrap;">{diagnosis.get('suggested_fix', 'N/A')}</pre>

<h3 style="color:#888; margin-top:24px;">📋 Pod Logs (last 100 lines)</h3>
<pre style="background:#111; padding:12px; font-size:12px; overflow-x:auto; max-height:300px; overflow-y:auto; white-space:pre-wrap;">{pod_logs[:3000]}</pre>

<hr style="border-color:#333; margin-top:24px;">
<p style="color:#555; font-size:12px;">
  ⚠️ The suggested fix has NOT been applied. Review it, make the change in values.yaml, push to Git — ArgoCD will deploy it.<br>
  ArgoCD app: <a href="https://{ARGOCD_SERVER}/applications/{ARGOCD_APP_NAME}" style="color:#378ADD;">open-webui</a>
</p>
</body></html>"""

    msg = MIMEMultipart("alternative")
    msg["Subject"] = f"[CRASH] Open WebUI — {alert_name} | Rolled back | Fix inside"
    msg["From"]    = ALERT_EMAIL_FROM
    msg["To"]      = ALERT_EMAIL_TO
    msg.attach(MIMEText(html, "html"))

    try:
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT) as server:
            server.ehlo()
            server.starttls()
            server.login(SMTP_USER, SMTP_PASSWORD)
            server.sendmail(ALERT_EMAIL_FROM, ALERT_EMAIL_TO, msg.as_string())
        print("Email sent successfully")
    except Exception as e:
        print(f"Email failed: {e}")
