"""Configuración por variables de entorno.

El mismo código corre en local (rutas de disco) y en AWS Lambda (rutas s3://).
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from functools import lru_cache


@dataclass(frozen=True)
class Settings:
    bronze_root: str
    silver_root: str
    gold_root: str
    exchange_root: str
    glue_db_silver: str | None
    glue_db_gold: str | None
    lookback_days: int
    pan_token_secret: str

    @property
    def is_s3(self) -> bool:
        return self.bronze_root.startswith("s3://")


def _pan_secret() -> str:
    # En AWS el secreto vive en SSM Parameter Store (SecureString); en local se usa una variable de entorno.
    param = os.getenv("PAN_TOKEN_SECRET_PARAM")
    if param:
        import boto3

        resp = boto3.client("ssm").get_parameter(Name=param, WithDecryption=True)
        return resp["Parameter"]["Value"]
    return os.getenv("PAN_TOKEN_SECRET", "local-dev-secret-not-for-prod")


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    data_root = os.getenv("DATA_ROOT", "data")
    return Settings(
        bronze_root=os.getenv("BRONZE_ROOT", f"{data_root}/bronze").rstrip("/"),
        silver_root=os.getenv("SILVER_ROOT", f"{data_root}/silver").rstrip("/"),
        gold_root=os.getenv("GOLD_ROOT", f"{data_root}/gold").rstrip("/"),
        exchange_root=os.getenv("EXCHANGE_ROOT", f"{data_root}/exchange").rstrip("/"),
        glue_db_silver=os.getenv("GLUE_DB_SILVER"),
        glue_db_gold=os.getenv("GLUE_DB_GOLD"),
        lookback_days=int(os.getenv("LOOKBACK_DAYS", "7")),
        pan_token_secret=_pan_secret(),
    )
