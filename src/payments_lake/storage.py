"""Capa de almacenamiento: disco local o S3 (vía AWS SDK for pandas / awswrangler).

En S3 las escrituras Parquet registran/actualizan la tabla en el Glue Data Catalog,
por lo que quedan consultables inmediatamente desde Athena.
"""
from __future__ import annotations

import glob
import os
import shutil

import pandas as pd


def _is_s3(path: str) -> bool:
    return path.startswith("s3://")


def _split_s3(path: str) -> tuple[str, str]:
    bucket, _, key = path[len("s3://"):].partition("/")
    return bucket, key


def write_text(path: str, text: str) -> None:
    if _is_s3(path):
        import boto3

        bucket, key = _split_s3(path)
        boto3.client("s3").put_object(Bucket=bucket, Key=key, Body=text.encode("utf-8"))
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


def read_text(path: str) -> str:
    if _is_s3(path):
        import boto3

        bucket, key = _split_s3(path)
        return boto3.client("s3").get_object(Bucket=bucket, Key=key)["Body"].read().decode("utf-8")
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def list_partitions(table_path: str, partition_key: str) -> list[str]:
    """Valores existentes de una partición estilo Hive (p.ej. ingest_date=2026-10-21)."""
    prefix = f"{table_path}/"
    if _is_s3(table_path):
        import awswrangler as wr

        dirs = wr.s3.list_directories(prefix)
    else:
        dirs = glob.glob(os.path.join(table_path, f"{partition_key}=*"))
    values = []
    for d in dirs:
        name = d.rstrip("/\\").replace("\\", "/").rsplit("/", 1)[-1]
        if name.startswith(f"{partition_key}="):
            values.append(name.split("=", 1)[1])
    return sorted(values)


def list_files(prefix: str, suffix: str) -> list[str]:
    if _is_s3(prefix):
        import awswrangler as wr

        return sorted(p for p in wr.s3.list_objects(prefix.rstrip("/") + "/") if p.endswith(suffix))
    return sorted(glob.glob(os.path.join(prefix, "**", f"*{suffix}"), recursive=True))


def read_parquet(table_path: str, partition_key: str | None = None, values: list[str] | None = None) -> pd.DataFrame:
    """Lee una tabla Parquet (particiones Hive en cualquier nivel); opcionalmente filtra por partition_key in values."""
    wanted = set(values) if partition_key and values is not None else None
    if _is_s3(table_path):
        import awswrangler as wr

        try:
            df = wr.s3.read_parquet(
                table_path.rstrip("/") + "/",
                dataset=True,
                partition_filter=(lambda p: p.get(partition_key) in wanted) if wanted is not None else None,
            )
        except wr.exceptions.NoFilesFound:
            return pd.DataFrame()
    else:
        if not os.path.exists(table_path):
            return pd.DataFrame()
        filters = [(partition_key, "in", sorted(wanted))] if wanted else None
        if wanted is not None and not wanted:
            return pd.DataFrame()
        df = pd.read_parquet(table_path, filters=filters)
    for col in df.columns:
        if isinstance(df[col].dtype, pd.CategoricalDtype):
            df[col] = df[col].astype(str)
    return df


def read_parquet_files(paths: list[str]) -> pd.DataFrame:
    """Lee una lista explícita de archivos Parquet (p.ej. los que escribe DMS: LOAD*.parquet + CDC)."""
    if not paths:
        return pd.DataFrame()
    if _is_s3(paths[0]):
        import awswrangler as wr

        return wr.s3.read_parquet(path=paths)
    return pd.concat([pd.read_parquet(p) for p in paths], ignore_index=True)


def write_parquet(
    df: pd.DataFrame,
    table_path: str,
    partition_cols: list[str] | None = None,
    database: str | None = None,
    table: str | None = None,
) -> None:
    """Escritura idempotente: reemplaza sólo las particiones presentes en df (o toda la tabla si no hay particiones)."""
    if df.empty:
        return
    if _is_s3(table_path):
        import awswrangler as wr

        wr.s3.to_parquet(
            df=df,
            path=table_path.rstrip("/") + "/",
            dataset=True,
            partition_cols=partition_cols,
            mode="overwrite_partitions" if partition_cols else "overwrite",
            database=database,
            table=table,
            compression="snappy",
        )
        return
    if partition_cols:
        for keys, _ in df.groupby(partition_cols):
            keys = keys if isinstance(keys, tuple) else (keys,)
            part_dir = os.path.join(table_path, *[f"{c}={k}" for c, k in zip(partition_cols, keys)])
            shutil.rmtree(part_dir, ignore_errors=True)
        df.to_parquet(table_path, partition_cols=partition_cols, index=False)
    else:
        shutil.rmtree(table_path, ignore_errors=True)
        os.makedirs(table_path, exist_ok=True)
        df.to_parquet(os.path.join(table_path, "part-0.parquet"), index=False)
