import json

from payments_lake import handlers, pipeline
from payments_lake.config import Settings


def test_api_requires_key_and_serves_gold(tmp_path, monkeypatch):
    root = str(tmp_path).replace("\\", "/")
    st = Settings(f"{root}/bronze", f"{root}/silver", f"{root}/gold", f"{root}/exchange", None, None, 3, "t")
    pipeline.ingest_core_snapshot(pipeline.SAMPLE_SNAPSHOT, st)
    pipeline.bronze_to_silver(None, st)
    pipeline.silver_to_gold(None, st)
    monkeypatch.setattr(handlers, "get_settings", lambda: st)
    monkeypatch.setattr(handlers, "_api_key", lambda: "secret")

    def call(path, key="secret", **qs):
        return handlers.api_handler({"rawPath": path, "headers": {"X-Api-Key": key}, "queryStringParameters": qs}, None)

    assert call("/health", key="wrong")["statusCode"] == 401
    kpis = json.loads(call("/gold/daily_merchant_kpis", date="2026-09-15")["body"])
    assert kpis["date"] == "2026-09-15" and kpis["count"] > 0
    perf = json.loads(call("/gold/fraud_rule_performance")["body"])
    assert {r["rule"] for r in perf["rows"]} >= {"velocity", "any_rule"}
    assert call("/gold/nope")["statusCode"] == 404
