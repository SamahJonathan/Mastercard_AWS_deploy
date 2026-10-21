"""Métricas de negocio y calidad hacia CloudWatch usando Embedded Metric Format (EMF).

En Lambda basta con imprimir el JSON: CloudWatch Logs lo convierte en métricas sin llamadas extra a la API.
Fuera de Lambda no hace nada.
"""
from __future__ import annotations

import json
import os
import time


def emit(dimensions: dict[str, str], metrics: dict[str, float]) -> dict | None:
    if not os.getenv("AWS_LAMBDA_FUNCTION_NAME"):
        return None
    values = {k: float(v) for k, v in metrics.items() if v is not None}
    payload = {
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [{
                "Namespace": os.getenv("METRICS_NAMESPACE", "PaymentsLakehouse"),
                "Dimensions": [list(dimensions)],
                "Metrics": [{"Name": k, "Unit": "None" if k.endswith("Usd") else "Count"} for k in values],
            }],
        },
        **dimensions,
        **values,
    }
    print(json.dumps(payload))
    return payload


def emit_stage(result: dict) -> None:
    """Traduce el resultado de cada etapa del pipeline a métricas."""
    stage = result.get("stage", "unknown")
    if stage == "ingest":
        emit({"Stage": stage, "Source": "simulator"}, {"IngestedRecords": result.get("records")})
    elif stage == "bronze_to_silver":
        for src in result.get("sources", []):
            recon = src.get("reconciliation", {})
            emit(
                {"Stage": stage, "Source": src["source_system"]},
                {
                    "BronzeRecords": src.get("bronze_records"),
                    "SilverRecords": src.get("silver_written"),
                    "RejectedRecords": src.get("rejected_records", 0),
                    "DuplicatesRemoved": src.get("duplicates_removed", 0),
                    "ReconciliationMismatches": sum(1 for v in recon.values() if v != "OK"),
                },
            )
    elif stage == "silver_to_gold":
        emit(
            {"Stage": stage, "Source": "all"},
            {
                "SilverRecords": result.get("silver_records"),
                "FraudAlerts": result.get("fraud_alerts_rows"),
                "ExchangeFiles": result.get("exchange_files"),
                "InterchangeUsd": result.get("total_interchange_usd"),
            },
        )
