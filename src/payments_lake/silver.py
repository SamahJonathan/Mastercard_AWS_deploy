"""Capa Silver: datos limpios, tipados, deduplicados, enriquecidos y sin PAN en claro.

Hay un adaptador por fuente que lleva su esquema al modelo canónico (SILVER_COLUMNS):
  - simulator      : autorizaciones en línea enviadas por adquirentes (JSON lines, con PAN)
  - core_snapshot  : extracto completo del sistema core (JSON anidado en español, ya tokenizado)
Los registros que no pasan las reglas no se pierden: van a la tabla de cuarentena con el motivo.
"""
from __future__ import annotations

import json

import numpy as np
import pandas as pd

from . import reference as ref
from .quality import join_flags, luhn_is_valid, mask_pans, parse_amount, tokenize_pan

REQUIRED = ["transaction_id", "event_ts", "pan", "merchant_id", "amount", "currency"]

SILVER_COLUMNS = [
    "transaction_id", "event_ts", "txn_date", "acquirer_id", "issuer_id", "issuer_name",
    "pan_token", "pan_bin", "pan_last4", "card_product", "card_country", "card_status",
    "merchant_id", "merchant_name", "mcc", "mcc_category", "merchant_country",
    "entry_mode", "is_card_present", "is_cross_border", "is_wallet", "is_3ds_authenticated", "ip_country",
    "amount", "currency", "fx_rate_usd", "amount_usd", "response_code", "is_approved",
    "fraud_confirmed", "chargeback",
    "source_system", "_batch_id", "_ingest_ts", "_source_file",
]
OPTIONAL_BOOL = ["is_wallet", "is_3ds_authenticated", "fraud_confirmed", "chargeback"]
QUARANTINE_COLUMNS = ["transaction_id", "reject_reasons", "raw_payload", "source_system", "_source_file", "_ingest_ts"]


def _dedupe(df: pd.DataFrame, metrics: dict) -> pd.DataFrame:
    """El mismo transaction_id reenviado se conserva una sola vez (el primero en llegar)."""
    df = df.sort_values("_ingest_ts", kind="stable")
    dup = df["transaction_id"].notna() & df.duplicated(subset=["transaction_id"], keep="first")
    metrics["duplicates_removed"] = int(dup.sum())
    return df[~dup].reset_index(drop=True)


def _split(df: pd.DataFrame, rules: dict[str, pd.Series], metrics: dict) -> tuple[pd.DataFrame, pd.DataFrame]:
    checks = pd.DataFrame({k: m.fillna(False).astype(bool) for k, m in rules.items()}, index=df.index)
    rejected = checks.any(axis=1)
    bad = df[rejected]
    quarantine = pd.DataFrame(
        {
            "transaction_id": bad["transaction_id"].astype("object"),
            "reject_reasons": join_flags(checks[rejected]),
            "raw_payload": bad["_raw"].map(mask_pans),  # nunca PAN en claro fuera de Bronze
            "source_system": bad["source_system"],
            "_source_file": bad["_source_file"],
            "_ingest_ts": bad["_ingest_ts"].astype("object"),
        }
    )
    metrics["rejected_records"] = int(rejected.sum())
    metrics["rejected_by_reason"] = {k: int(v) for k, v in checks.sum().items() if v}
    return df[~rejected].copy(), quarantine.reset_index(drop=True)


def _finalize(ok: pd.DataFrame, metrics: dict) -> pd.DataFrame:
    """Columnas derivadas comunes a todas las fuentes y orden/tipos canónicos."""
    ok["event_ts"] = ok["event_ts_parsed"].dt.tz_convert("UTC").dt.tz_localize(None)
    ok["txn_date"] = ok["event_ts"].dt.strftime("%Y-%m-%d")
    ok["amount"] = ok["amount_num"].astype(float)
    ok["amount_usd"] = (ok["amount"] * ok["fx_rate_usd"]).round(2)
    ok["is_card_present"] = ok["entry_mode"].isin(ref.CARD_PRESENT_MODES)
    ok["is_cross_border"] = ok["card_country"] != ok["merchant_country"]
    ok["is_approved"] = ok["response_code"] == "00"
    for col in SILVER_COLUMNS:
        if col not in ok.columns:
            ok[col] = None
    for col in OPTIONAL_BOOL:
        ok[col] = ok[col].astype("boolean")
    for col in ["card_status", "ip_country"]:
        ok[col] = ok[col].astype("object")
    silver = ok[SILVER_COLUMNS].reset_index(drop=True)
    metrics["silver_records"] = len(silver)
    metrics["approval_rate"] = round(float(np.mean(silver["is_approved"])) if len(silver) else 0.0, 4)
    return silver


def _empty() -> tuple[pd.DataFrame, pd.DataFrame]:
    return pd.DataFrame(columns=SILVER_COLUMNS), pd.DataFrame(columns=QUARANTINE_COLUMNS)


# --- Fuente 1: simulador de adquirentes ------------------------------------------------------

def transform(raw: list[dict], pan_secret: str) -> tuple[pd.DataFrame, pd.DataFrame, dict]:
    metrics = {"source_system": "simulator", "bronze_records": len(raw)}
    if not raw:
        return (*_empty(), metrics)

    df = pd.DataFrame(raw)
    for col in REQUIRED + ["acquirer_id", "card_product", "card_country", "mcc", "merchant_country", "entry_mode",
                           "response_code", "_batch_id", "_ingest_ts", "_parse_error", "_raw", "_source_file"]:
        if col not in df.columns:
            df[col] = None
    df["source_system"] = "simulator"
    df = _dedupe(df, metrics)

    # Tipado
    df["amount_num"] = pd.to_numeric(df["amount"].map(parse_amount), errors="coerce")
    df["event_ts_parsed"] = pd.to_datetime(df["event_ts"], utc=True, errors="coerce", format="ISO8601")
    df["pan"] = df["pan"].astype("object").where(df["pan"].notna(), None)
    df["pan_bin"] = df["pan"].map(lambda p: p[:6] if isinstance(p, str) else None)

    # Enriquecimiento con datos de referencia
    df = df.merge(ref.build_merchants()[["merchant_id", "merchant_name"]], on="merchant_id", how="left")
    df = df.merge(ref.issuers_frame()[["pan_bin", "issuer_id", "issuer_name"]], on="pan_bin", how="left")
    df = df.merge(ref.mcc_frame()[["mcc", "mcc_category"]], on="mcc", how="left")
    df["fx_rate_usd"] = df["currency"].map(ref.FX_TO_USD)

    ok, quarantine = _split(df, {
        "malformed_json": df["_parse_error"].fillna(False).astype(bool),
        "missing_required_field": df[REQUIRED].isna().any(axis=1),
        "invalid_pan_luhn": df["pan"].notna() & ~df["pan"].map(lambda p: isinstance(p, str) and luhn_is_valid(p)),
        "unparseable_amount": df["amount"].notna() & df["amount_num"].isna(),
        "non_positive_amount": df["amount_num"].notna() & (df["amount_num"] <= 0),
        "unknown_currency": df["currency"].notna() & df["fx_rate_usd"].isna(),
        "invalid_timestamp": df["event_ts"].notna() & df["event_ts_parsed"].isna(),
        "unknown_merchant": df["merchant_id"].notna() & df["merchant_name"].isna(),
        "unknown_issuer_bin": df["pan_bin"].notna() & df["issuer_id"].isna(),
    }, metrics)

    ok["pan_token"] = ok["pan"].map(lambda p: tokenize_pan(p, pan_secret))
    ok["pan_last4"] = ok["pan"].str[-4:]  # el PAN en claro NO pasa a Silver
    return _finalize(ok, metrics), quarantine, metrics


# --- Fuente 2: extracto del sistema core (sample_data/mastercard_db_ficticia.json) -----------

ENTRY_MODE_MAP = {"contactless": "CONTACTLESS", "online": "ECOMMERCE", "chip": "CHIP", "banda": "MAGSTRIPE"}


def transform_core_snapshot(snapshot: dict, source_file: str, ingest_ts: str) -> tuple[pd.DataFrame, pd.DataFrame, dict]:
    txns = snapshot.get("transacciones") or []
    metrics = {"source_system": "core_snapshot", "bronze_records": len(txns)}
    if not txns:
        return (*_empty(), metrics)

    fx = {**ref.FX_TO_USD, **snapshot.get("metadata", {}).get("tipos_cambio_ficticios_a_usd", {})}
    issuers = pd.DataFrame(snapshot.get("emisores", [])).rename(columns={"emisor_id": "issuer_id", "nombre": "issuer_name"})
    merchants = pd.DataFrame(snapshot.get("comercios", [])).rename(columns={"comercio_id": "merchant_id", "nombre": "merchant_name"})
    cards = pd.DataFrame(snapshot.get("tarjetas", [])).rename(columns={"token_tarjeta": "pan_token", "estado": "card_status"})
    cards["pan_bin"] = cards["bin"]
    cards["pan_last4"] = cards["pan_enmascarado"].str[-4:]
    cards["card_product"] = cards["producto"].str.upper()

    df = pd.DataFrame(txns).rename(columns={
        "transaccion_id": "transaction_id", "fecha_hora": "event_ts", "token_tarjeta": "pan_token",
        "comercio_id": "merchant_id", "emisor_id": "issuer_id", "adquirente_id": "acquirer_id",
        "monto": "amount", "moneda": "currency", "pais_emisor": "card_country", "pais_comercio": "merchant_country",
        "pais_ip": "ip_country", "wallet": "is_wallet", "autenticacion_3ds": "is_3ds_authenticated",
        "codigo_respuesta": "response_code", "fraude_confirmado": "fraud_confirmed", "contracargo": "chargeback",
    })
    df["_raw"] = [json.dumps(t, ensure_ascii=False) for t in txns]
    df["_source_file"], df["_ingest_ts"], df["_batch_id"] = source_file, ingest_ts, "core_snapshot"
    df["source_system"] = "core_snapshot"
    df = _dedupe(df, metrics)

    df["amount_num"] = pd.to_numeric(df["amount"].map(parse_amount), errors="coerce")
    # El core entrega hora local sin zona; se asume America/Santiago y se normaliza a UTC
    local = pd.to_datetime(df["event_ts"], errors="coerce", format="ISO8601")
    df["event_ts_parsed"] = local.dt.tz_localize("America/Santiago", ambiguous="NaT", nonexistent="shift_forward")
    df["entry_mode"] = df["modo_entrada"].map(ENTRY_MODE_MAP)
    df["fx_rate_usd"] = df["currency"].map(fx)
    df = df.merge(issuers[["issuer_id", "issuer_name"]], on="issuer_id", how="left")
    df = df.merge(merchants[["merchant_id", "merchant_name"]], on="merchant_id", how="left")
    df = df.merge(cards[["pan_token", "pan_bin", "pan_last4", "card_product", "card_status"]], on="pan_token", how="left")
    df = df.merge(ref.mcc_frame()[["mcc", "mcc_category"]], on="mcc", how="left")

    ok, quarantine = _split(df, {
        "missing_required_field": df[["transaction_id", "event_ts", "pan_token", "merchant_id", "amount", "currency"]].isna().any(axis=1),
        "unparseable_amount": df["amount"].notna() & df["amount_num"].isna(),
        "non_positive_amount": df["amount_num"].notna() & (df["amount_num"] <= 0),
        "unknown_currency": df["currency"].notna() & df["fx_rate_usd"].isna(),
        "invalid_timestamp": df["event_ts"].notna() & df["event_ts_parsed"].isna(),
        "unknown_merchant": df["merchant_id"].notna() & df["merchant_name"].isna(),
        "unknown_card_token": df["pan_token"].notna() & df["card_product"].isna(),
        "unknown_entry_mode": df["entry_mode"].isna(),
        "usd_amount_mismatch": (df["amount_num"] * df["fx_rate_usd"]).round(2).sub(df["monto_usd"]).abs() > 0.011,
    }, metrics)
    return _finalize(ok, metrics), quarantine, metrics


def reconcile_core_snapshot(snapshot: dict, silver_core: pd.DataFrame) -> pd.DataFrame:
    """Compara los totales que declara la fuente (metricas_resumen) con lo que quedó en Silver."""
    reported = snapshot.get("metricas_resumen", {})
    s = silver_core
    approved = s[s["is_approved"]]
    computed = {
        "transacciones_procesadas": len(s),
        "transacciones_aprobadas": len(approved),
        "gdv_usd": round(float(approved["amount_usd"].sum()), 2),
        "volumen_cross_border_usd": round(float(approved.loc[approved["is_cross_border"], "amount_usd"].sum()), 2),
        "fraudes_confirmados": int(s["fraud_confirmed"].fillna(False).sum()),
        "contracargos": int(s["chargeback"].fillna(False).sum()),
    }
    rows = []
    for metric, value in computed.items():
        rep = reported.get(metric)
        diff = None if rep is None else round(value - rep, 2)
        ok = rep is not None and abs(diff) <= max(0.01, abs(rep) * 0.0005)
        rows.append({"metric": metric, "reported": rep, "computed": value, "diff": diff,
                     "status": "OK" if ok else ("MISSING" if rep is None else "MISMATCH")})
    return pd.DataFrame(rows)
