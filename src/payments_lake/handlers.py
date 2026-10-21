"""Entrypoints de AWS Lambda. Cada etapa es invocada por Step Functions; la API sirve la capa Gold."""
from __future__ import annotations

import json
import os
from datetime import date
from functools import lru_cache

from . import pipeline, storage
from .config import get_settings

GOLD_TABLES = {"daily_merchant_kpis", "interchange_settlement", "fraud_alerts", "cross_border_corridors"}
UNPARTITIONED_GOLD = {"fraud_rule_performance"}


def _ref_date(event: dict) -> date | None:
    value = (event or {}).get("ref_date")
    return date.fromisoformat(value) if value else None


def ingest_handler(event, context):
    size = int((event or {}).get("batch_size") or os.getenv("BATCH_SIZE", "2000"))
    return pipeline.ingest_batch(size)


def bronze_to_silver_handler(event, context):
    return pipeline.bronze_to_silver(_ref_date(event))


def silver_to_gold_handler(event, context):
    return pipeline.silver_to_gold(_ref_date(event))


# --- API de consumo (API Gateway HTTP API, payload v2) ---------------------------------------

@lru_cache(maxsize=1)
def _api_key() -> str:
    import boto3

    resp = boto3.client("ssm").get_parameter(Name=os.environ["API_KEY_PARAM"], WithDecryption=True)
    return resp["Parameter"]["Value"]


def _response(status: int, body) -> dict:
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body, default=str),
    }


def api_handler(event, context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    if headers.get("x-api-key") != _api_key():
        return _response(401, {"error": "unauthorized"})

    path = event.get("rawPath", "/").rstrip("/") or "/"
    params = event.get("queryStringParameters") or {}
    st = get_settings()

    if path == "/health":
        return _response(200, {"status": "ok"})
    if path == "/dates":
        return _response(200, storage.list_partitions(f"{st.gold_root}/interchange_settlement", "txn_date"))
    if path.startswith("/gold/"):
        table = path.split("/", 2)[2]
        table_path = f"{st.gold_root}/{table}"
        if table in UNPARTITIONED_GOLD:
            rows = json.loads(storage.read_parquet(table_path).to_json(orient="records"))
            return _response(200, {"table": table, "count": len(rows), "rows": rows})
        if table not in GOLD_TABLES:
            return _response(404, {"error": f"tabla desconocida: {table}", "available": sorted(GOLD_TABLES | UNPARTITIONED_GOLD)})
        day = params.get("date") or (storage.list_partitions(table_path, "txn_date") or [None])[-1]
        if day is None:
            return _response(200, {"table": table, "date": None, "rows": []})
        df = storage.read_parquet(table_path, "txn_date", [day])
        limit = min(int(params.get("limit", "500")), 5000)
        rows = json.loads(df.head(limit).to_json(orient="records", date_format="iso"))
        return _response(200, {"table": table, "date": day, "count": len(df), "rows": rows})
    return _response(404, {"error": "not found", "routes": ["/health", "/dates", "/gold/{table}?date=YYYY-MM-DD&limit=N"]})
