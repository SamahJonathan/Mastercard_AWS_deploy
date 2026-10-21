import importlib.util
import json
from datetime import datetime
from pathlib import Path

import pandas as pd

from payments_lake import observability, pipeline, silver, storage
from payments_lake.config import Settings

ROOT = Path(__file__).resolve().parents[1]
SNAPSHOT = json.loads((ROOT / "sample_data" / "mastercard_db_ficticia.json").read_text(encoding="utf-8"))

_spec = importlib.util.spec_from_file_location("load_core_db", ROOT / "scripts" / "core_db" / "load_core_db.py")
load_core_db = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(load_core_db)


def _settings(tmp_path):
    root = str(tmp_path).replace("\\", "/")
    return Settings(f"{root}/bronze", f"{root}/silver", f"{root}/gold", f"{root}/exchange", None, None, 2, "t")


def _write_dms(st, table, name, rows, op, ts):
    """Imita el layout de un endpoint S3 de DMS: bronze/dms/<schema>/<tabla>/<archivo>.parquet con Op y dms_ts."""
    df = pd.DataFrame(rows)
    df.insert(0, "Op", op)
    df.insert(1, "dms_ts", pd.Timestamp(ts).strftime("%Y-%m-%d %H:%M:%S.%f"))  # DMS lo escribe como texto
    if "fecha_hora" in df:
        df["fecha_hora"] = pd.to_datetime(df["fecha_hora"]).dt.tz_localize("UTC")
    # Formato real de DMS para PostgreSQL BOOLEAN: texto 'true' / 'false' (None se mantiene)
    for col in silver.DMS_BOOL_COLUMNS & set(df.columns):
        df[col] = df[col].map(lambda v: None if v is None else ("true" if v else "false"))
    path = Path(st.bronze_root) / "dms" / "core" / table
    path.mkdir(parents=True, exist_ok=True)
    df.to_parquet(path / name, index=False)


def test_dms_full_load_plus_cdc_wins_over_file_snapshot(tmp_path):
    st = _settings(tmp_path)
    pipeline.ingest_core_snapshot(pipeline.SAMPLE_SNAPSHOT, st)  # existe el extracto, pero DMS tiene prioridad
    for table in load_core_db.PRIMARY_KEYS:
        _write_dms(st, table, "LOAD00000001.parquet", SNAPSHOT[table], "I", "2026-10-21 10:00")

    txns = SNAPSHOT["transacciones"]
    updated = dict(txns[0], contracargo=True)
    deleted = dict(txns[1])
    new = dict(txns[2], transaccion_id="TXC-NEW-1", fecha_hora="2026-10-21T09:30:00")
    _write_dms(st, "transacciones", "20261021-110000.parquet", [updated, deleted, new], ["U", "D", "I"], "2026-10-21 11:00")

    result = pipeline.bronze_to_silver(datetime(2026, 10, 21).date(), st)
    core = next(s for s in result["sources"] if s["source_system"] == "core")
    assert core["channel"] == "dms_cdc"
    assert core["silver_written"] == len(txns)  # -1 borrada, +1 nueva

    silver = storage.read_parquet(f"{st.silver_root}/transactions")
    ids = set(silver["transaction_id"])
    assert "TXC-NEW-1" in ids and deleted["transaccion_id"] not in ids
    assert bool(silver.loc[silver["transaction_id"] == updated["transaccion_id"], "chargeback"].iloc[0])


def test_core_db_init_sql_escapes_and_covers_all_tables():
    sql = load_core_db.init_sql(SNAPSHOT)
    for table in load_core_db.PRIMARY_KEYS:
        assert f"INSERT INTO core.{table}" in sql
    assert "GRANT rds_replication" in sql
    assert load_core_db.literal("O'Higgins") == "'O''Higgins'"
    assert load_core_db.literal(None) == "NULL" and load_core_db.literal(True) == "TRUE"


def test_core_db_cdc_generates_inserts_and_late_updates():
    sql = load_core_db.cdc_sql(SNAPSHOT, new=5, now=datetime(2026, 10, 21, 12), seed=3)
    assert sql.count("'TXC") == 5
    assert "SET contracargo = TRUE" in sql and "SET fraude_confirmado = TRUE" in sql


def test_emf_metrics_only_inside_lambda(monkeypatch, capsys):
    assert observability.emit({"Stage": "x"}, {"Rows": 1}) is None
    monkeypatch.setenv("AWS_LAMBDA_FUNCTION_NAME", "fn")
    payload = observability.emit({"Stage": "x", "Source": "core"}, {"Rows": 3, "InterchangeUsd": 1.5})
    printed = json.loads(capsys.readouterr().out)
    assert printed == payload
    cw = payload["_aws"]["CloudWatchMetrics"][0]
    assert cw["Dimensions"] == [["Stage", "Source"]]
    assert {m["Name"]: m["Unit"] for m in cw["Metrics"]} == {"Rows": "Count", "InterchangeUsd": "None"}
