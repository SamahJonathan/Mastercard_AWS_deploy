#!/usr/bin/env python3
"""Lee el historial de una ejecución de Step Functions (stdin, JSON de get-execution-history --reverse-order)
e imprime en una línea la etapa, el tipo de error y la causa. Lo usa el registro de despliegues en GitHub.

    aws stepfunctions get-execution-history --execution-arn <arn> --reverse-order --output json \\
      | python3 scripts/sfn_failure_reason.py
"""
from __future__ import annotations

import json
import sys


def failure_reason(history: dict, limit: int = 400) -> str:
    events = history.get("events", [])
    details = next(
        (e.get("taskFailedEventDetails") or e.get("executionFailedEventDetails")
         for e in events if e.get("taskFailedEventDetails") or e.get("executionFailedEventDetails")),
        {},
    )
    stage = next((e["stateEnteredEventDetails"]["name"] for e in events if "stateEnteredEventDetails" in e), "?")
    cause = details.get("cause", "")
    try:
        message = json.loads(cause).get("errorMessage", cause)  # las Lambdas devuelven la causa como JSON
    except (json.JSONDecodeError, AttributeError):
        message = cause
    return f"etapa {stage}: {details.get('error', '')}: {message}"[:limit]


if __name__ == "__main__":
    print(failure_reason(json.load(sys.stdin)))
