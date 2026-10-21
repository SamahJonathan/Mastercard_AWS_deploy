"""AWS Glue 5.0 (PySpark): calidad de datos sobre Silver + analítica Gold con Spark SQL.

Corre una vez al día (aws_glue_trigger). Las Lambdas cubren el pipeline horario de bajo volumen;
este job muestra el camino de escala: misma capa Silver, motor distribuido.

Salidas (Parquet en S3; las tablas las define Terraform en infra/platform/glue_job.tf):
  - card_monthly_segments  : comportamiento mensual por tarjeta + segmentación con NTILE / PERCENT_RANK
  - merchant_daily_trends  : promedio móvil 7 días, ranking y participación dentro de su categoría
  - Resultados de Glue Data Quality publicados en CloudWatch y en S3

El job NO toca el catálogo: con saveAsTable, Spark intenta crear la base `default` (glue:CreateDatabase)
y el rol necesitaría permisos de catálogo. Escribir sólo archivos deja el esquema versionado en Terraform
y el rol con menos privilegios. Los tipos se fijan con CAST para que coincidan con esas tablas.
"""
import sys

from awsglue.context import GlueContext
from awsglue.dynamicframe import DynamicFrame
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from awsgluedq.transforms import EvaluateDataQuality
from pyspark.context import SparkContext

args = getResolvedOptions(sys.argv, ["JOB_NAME", "SILVER_PATH", "GOLD_PATH", "DQ_RESULTS_PATH"])
sc = SparkContext()
glue = GlueContext(sc)
spark = glue.spark_session
job = Job(glue)
job.init(args["JOB_NAME"], args)

# Lectura directa de Silver (descubre las particiones source_system / txn_date)
silver = spark.read.parquet(args["SILVER_PATH"])
silver.createOrReplaceTempView("silver_tx")

# --- 1) Glue Data Quality (DQDL) ------------------------------------------------------------
RULESET = """
Rules = [
    RowCount > 0,
    IsComplete "transaction_id",
    IsUnique "transaction_id",
    IsComplete "pan_token",
    IsComplete "event_ts",
    ColumnValues "amount_usd" > 0,
    ColumnValues "currency" in ["CLP", "ARS", "BRL", "PEN", "COP", "MXN", "USD", "EUR"],
    ColumnValues "entry_mode" in ["CHIP", "CONTACTLESS", "ECOMMERCE", "MAGSTRIPE"],
    ColumnLength "pan_last4" = 4,
    Completeness "issuer_id" > 0.99,
    ColumnValues "response_code" matches "[0-9]{2}"
]
"""
dq_outcomes = EvaluateDataQuality.apply(
    frame=DynamicFrame.fromDF(silver, glue, "silver_tx"),
    ruleset=RULESET,
    publishing_options={
        "dataQualityEvaluationContext": "silver_transactions",
        "enableDataQualityCloudWatchMetrics": True,
        "enableDataQualityResultsPublishing": True,
    },
)
dq_outcomes.toDF().write.mode("append").json(args["DQ_RESULTS_PATH"])

# --- 2) Analítica Gold con Spark SQL --------------------------------------------------------
spark.sql("""
    SELECT date_format(event_ts, 'yyyy-MM')                                    AS month,
           pan_token,
           issuer_id,
           CAST(COUNT(*) AS BIGINT)                                                     AS txn_count,
           CAST(SUM(CASE WHEN is_approved THEN 1 ELSE 0 END) AS BIGINT)                 AS approved_count,
           CAST(ROUND(SUM(CASE WHEN is_approved THEN amount_usd ELSE 0 END), 2) AS DOUBLE) AS spend_usd,
           CAST(COUNT(DISTINCT merchant_id) AS BIGINT)                                  AS distinct_merchants,
           CAST(COUNT(DISTINCT txn_date) AS BIGINT)                                     AS active_days,
           CAST(ROUND(AVG(CASE WHEN is_cross_border THEN 1.0 ELSE 0.0 END), 4) AS DOUBLE)  AS cross_border_share,
           CAST(ROUND(AVG(CASE WHEN entry_mode = 'ECOMMERCE' THEN 1.0 ELSE 0.0 END), 4) AS DOUBLE) AS ecommerce_share
    FROM silver_tx
    GROUP BY date_format(event_ts, 'yyyy-MM'), pan_token, issuer_id
""").createOrReplaceTempView("card_monthly")

card_segments = spark.sql("""
    WITH ranked AS (
        SELECT *,
               CAST(NTILE(4) OVER (PARTITION BY month ORDER BY spend_usd) AS INT)       AS spend_quartile,
               CAST(ROUND(PERCENT_RANK() OVER (PARTITION BY month, issuer_id ORDER BY spend_usd), 4) AS DOUBLE) AS spend_pct_rank_in_issuer
        FROM card_monthly
    )
    SELECT *,
           CASE WHEN spend_quartile = 4 AND active_days >= 3 THEN 'high_value'
                WHEN ecommerce_share >= 0.8                 THEN 'digital_first'
                WHEN active_days = 1                        THEN 'occasional'
                ELSE 'regular' END AS segment
    FROM ranked
""")

merchant_trends = spark.sql("""
    WITH daily AS (
        SELECT CAST(txn_date AS STRING) AS txn_date, merchant_id, merchant_name, mcc_category,
               CAST(COUNT(*) AS BIGINT)                                                        AS txn_count,
               CAST(ROUND(SUM(CASE WHEN is_approved THEN amount_usd ELSE 0 END), 2) AS DOUBLE) AS gross_usd
        FROM silver_tx
        GROUP BY txn_date, merchant_id, merchant_name, mcc_category
    )
    SELECT *,
           CAST(ROUND(AVG(gross_usd) OVER (PARTITION BY merchant_id ORDER BY txn_date
                                           ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 2) AS DOUBLE) AS gross_usd_7d_avg,
           CAST(RANK() OVER (PARTITION BY txn_date, mcc_category ORDER BY gross_usd DESC) AS INT)  AS rank_in_category,
           CAST(ROUND(gross_usd / NULLIF(SUM(gross_usd) OVER (PARTITION BY txn_date, mcc_category), 0), 4) AS DOUBLE) AS share_of_category,
           CAST(ROUND(gross_usd - LAG(gross_usd) OVER (PARTITION BY merchant_id ORDER BY txn_date), 2) AS DOUBLE)   AS delta_vs_prev_day
    FROM daily
""")

# Recalculo completo diario: se reemplaza la carpeta entera de cada tabla (idempotente)
for name, df, partition in [
    ("card_monthly_segments", card_segments, "month"),
    ("merchant_daily_trends", merchant_trends, "txn_date"),
]:
    df.write.mode("overwrite").partitionBy(partition).parquet(f"{args['GOLD_PATH']}/{name}/")

job.commit()
