#!/usr/bin/env python3
"""Registro estructurado de cada despliegue (observabilidad del proceso, no sólo de los datos).

Lo llaman igual infra/command/deploy.ps1 y destroy.ps1 (tu PC) y .github/workflows/deploy.yml (GitHub),
así todos los despliegues quedan en un mismo formato y en un mismo lugar:

  - CloudWatch Logs  /paylake/deployments   -> consultable con Logs Insights, alarma si falla
  - S3 (bucket del estado) deployments/AAAA/MM/DD/<id>.json  (+ <id>.plan.json y <id>.log)
  - copia local en logs/

El registro guarda QUÉ cambió (direcciones y acciones de Terraform), nunca los valores:
`terraform show -json` incluye los valores sensibles en claro y por eso no se guarda tal cual.

Es "mejor esfuerzo": si algo del registro falla, avisa pero nunca rompe el despliegue (sale con 0).
Sólo usa la librería estándar, el AWS CLI, git y terraform.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import socket
import subprocess
import tempfile
import time
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOG_GROUP = "/paylake/deployments"
SCHEMA_VERSION = 1
STATUSES = {"success", "failed", "cancelled", "no_changes", "planned"}


def run(cmd: list[str], cwd: Path | None = None, timeout: int = 300) -> str | None:
    """Ejecuta un comando y devuelve su salida, o None si falla (el registro nunca rompe el deploy)."""
    try:
        out = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, check=True,
                             encoding="utf-8", errors="replace")
        return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None


# --- Plan de Terraform -> resumen SIN valores ------------------------------------------------------

def summarize_plan(plan: dict) -> tuple[dict, list[dict]]:
    """Cuenta acciones como lo hace `terraform plan` y lista direcciones. No copia ningún valor."""
    counts = Counter()
    by_type: Counter = Counter()
    resources = []
    for rc in plan.get("resource_changes", []):
        actions = rc.get("change", {}).get("actions", [])
        if actions in (["no-op"], ["read"]):
            continue
        if "create" in actions and "delete" in actions:
            counts["replace"] += 1
            counts["add"] += 1
            counts["destroy"] += 1
        elif actions == ["create"]:
            counts["add"] += 1
        elif actions == ["update"]:
            counts["change"] += 1
        elif actions == ["delete"]:
            counts["destroy"] += 1
        by_type[rc.get("type", "?")] += 1
        resources.append({"address": rc.get("address"), "type": rc.get("type"), "actions": actions})
    summary = {
        "add": counts["add"], "change": counts["change"], "destroy": counts["destroy"], "replace": counts["replace"],
        "by_type": dict(sorted(by_type.items())),
    }
    return summary, resources


def read_plan(tf_dir: Path, plan_file: str) -> tuple[dict | None, list[dict]]:
    if not (tf_dir / plan_file).exists():
        return None, []
    raw = run(["terraform", f"-chdir={tf_dir}", "show", "-json", plan_file])
    if not raw:
        return None, []
    try:
        return summarize_plan(json.loads(raw))
    except json.JSONDecodeError:
        return None, []


# --- Contexto: quién, desde dónde, qué commit -----------------------------------------------------

def git_info() -> dict:
    def g(*args):
        return run(["git", *args], cwd=ROOT)
    sha = os.getenv("GITHUB_SHA") or g("rev-parse", "HEAD")
    return {
        "commit": sha,
        "commit_short": sha[:7] if sha else None,
        "branch": os.getenv("GITHUB_REF_NAME") or g("rev-parse", "--abbrev-ref", "HEAD"),
        "subject": g("log", "-1", "--format=%s"),
        "dirty": bool(g("status", "--porcelain")) if not os.getenv("GITHUB_ACTIONS") else False,
    }


def actor_info() -> tuple[str, dict, str | None]:
    if os.getenv("GITHUB_ACTIONS") == "true":
        run_url = f"{os.getenv('GITHUB_SERVER_URL')}/{os.getenv('GITHUB_REPOSITORY')}/actions/runs/{os.getenv('GITHUB_RUN_ID')}"
        return "github-actions", {"github_actor": os.getenv("GITHUB_ACTOR"), "workflow": os.getenv("GITHUB_WORKFLOW")}, run_url
    arn = run(["aws", "sts", "get-caller-identity", "--query", "Arn", "--output", "text"])
    return "local", {"aws_arn": arn, "git_user": run(["git", "config", "user.name"], cwd=ROOT), "host": socket.gethostname()}, None


def state_bucket(explicit: str | None) -> str | None:
    if explicit:
        return explicit
    if os.getenv("TF_STATE_BUCKET"):
        return os.getenv("TF_STATE_BUCKET")
    backend = ROOT / "infra" / "platform" / "backend.hcl"
    if backend.exists():
        m = re.search(r'bucket\s*=\s*"([^"]+)"', backend.read_text(encoding="utf-8"))
        return m.group(1) if m else None
    return None


# --- Registro --------------------------------------------------------------------------------------

def build_record(args, plan_summary: dict | None) -> dict:
    source, actor, run_url = actor_info()
    finished = datetime.now(timezone.utc)
    started = datetime.fromisoformat(args.started_at.replace("Z", "+00:00")) if args.started_at else finished
    return {
        "schema_version": SCHEMA_VERSION,
        "deployment_id": args.deployment_id,
        "kind": args.kind,
        "environment": args.environment,
        "result": args.status,
        "failed_step": args.failed_step or None,
        "error": (args.error or "")[:500] or None,
        "source": source,
        "actor": actor,
        "run_url": run_url,
        "git": git_info(),
        "started_at": started.isoformat(),
        "finished_at": finished.isoformat(),
        "duration_s": round((finished - started).total_seconds(), 1),
        "plan": plan_summary,
        "pipeline": {"execution_arn": args.pipeline_execution_arn or None, "status": args.pipeline_status or None},
        "iam_checks": args.iam_checks or None,
    }


def s3_prefix(record: dict) -> str:
    day = record["finished_at"][:10].replace("-", "/")
    return f"deployments/{day}/{record['deployment_id']}"


def publish(record: dict, resources: list[dict], bucket: str | None, log_file: Path | None, region: str) -> dict:
    """Escribe en S3 y CloudWatch Logs. Devuelve qué se pudo escribir."""
    written = {}
    tmp = Path(tempfile.mkdtemp())
    rec_path = tmp / "record.json"
    rec_path.write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding="utf-8")

    if bucket:
        prefix = f"s3://{bucket}/{s3_prefix(record)}"
        if run(["aws", "s3", "cp", str(rec_path), f"{prefix}.json", "--region", region, "--only-show-errors"]) is not None:
            written["s3_record"] = f"{prefix}.json"
        if resources:
            plan_path = tmp / "plan.json"
            plan_path.write_text(json.dumps(resources, indent=1), encoding="utf-8")
            if run(["aws", "s3", "cp", str(plan_path), f"{prefix}.plan.json", "--region", region, "--only-show-errors"]) is not None:
                written["s3_plan"] = f"{prefix}.plan.json"
        if log_file and log_file.exists():
            if run(["aws", "s3", "cp", str(log_file), f"{prefix}.log", "--region", region, "--only-show-errors"]) is not None:
                written["s3_log"] = f"{prefix}.log"

    # CloudWatch: un stream por origen; el evento es el registro en una línea (máx. 256 KB)
    stream = f"{record['source']}-{record['environment']}"
    run(["aws", "logs", "create-log-stream", "--log-group-name", LOG_GROUP, "--log-stream-name", stream, "--region", region])
    event = {
        "logGroupName": LOG_GROUP,
        "logStreamName": stream,
        "logEvents": [{"timestamp": int(time.time() * 1000), "message": json.dumps({**record, "artifacts": written}, ensure_ascii=False)}],
    }
    ev_path = tmp / "event.json"
    ev_path.write_text(json.dumps(event, ensure_ascii=False), encoding="utf-8")
    if run(["aws", "logs", "put-log-events", "--cli-input-json", f"file://{ev_path}", "--region", region]) is not None:
        written["cloudwatch"] = f"{LOG_GROUP}/{stream}"
    return written


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Registra un despliegue en CloudWatch Logs y S3")
    p.add_argument("--deployment-id", required=True)
    p.add_argument("--kind", choices=["deploy", "destroy", "pause"], default="deploy")
    p.add_argument("--status", choices=sorted(STATUSES), required=True)
    p.add_argument("--failed-step", default="")
    p.add_argument("--error", default="")
    p.add_argument("--started-at", default="")
    p.add_argument("--environment", default="dev")
    p.add_argument("--tf-dir", default=str(ROOT / "infra" / "platform"))
    p.add_argument("--plan-file", default="")
    p.add_argument("--pipeline-execution-arn", default="")
    p.add_argument("--pipeline-status", default="")
    p.add_argument("--iam-checks", default="")
    p.add_argument("--log-file", default="")
    p.add_argument("--state-bucket", default="")
    p.add_argument("--region", default=os.getenv("AWS_REGION", "sa-east-1"))
    p.add_argument("--out-dir", default=str(ROOT / "logs"))
    p.add_argument("--dry-run", action="store_true", help="sólo copia local, sin AWS")
    args = p.parse_args(argv)

    try:
        summary, resources = read_plan(Path(args.tf_dir), args.plan_file) if args.plan_file else (None, [])
        record = build_record(args, summary)
        out_dir = Path(args.out_dir)
        out_dir.mkdir(parents=True, exist_ok=True)
        (out_dir / f"{args.deployment_id}.json").write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding="utf-8")
        written = {} if args.dry_run else publish(
            record, resources, state_bucket(args.state_bucket or None), Path(args.log_file) if args.log_file else None, args.region
        )
        plan_txt = f"+{summary['add']} ~{summary['change']} -{summary['destroy']}" if summary else "sin plan"
        print(f"Registro del despliegue {args.deployment_id}: {record['result']} ({plan_txt}, {record['duration_s']} s) -> "
              f"{', '.join(written) or 'solo copia local'}")
    except Exception as exc:  # el registro jamás debe romper un despliegue
        print(f"AVISO: no se pudo registrar el despliegue: {exc}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
