-- Top comercios por volumen junto a sus alertas de fraude
WITH kpis AS (
  SELECT merchant_id, merchant_name, mcc_category, merchant_country,
         sum(gross_amount_usd) AS volume_usd, sum(txn_count) AS txns,
         round(sum(approved_count) * 1.0 / sum(txn_count), 4) AS approval_rate
  FROM "${gold_db}"."daily_merchant_kpis"
  GROUP BY 1, 2, 3, 4
),
alerts AS (
  SELECT merchant_id, count(*) AS fraud_alerts, max(risk_score) AS max_risk
  FROM "${gold_db}"."fraud_alerts"
  GROUP BY 1
)
SELECT k.*, coalesce(a.fraud_alerts, 0) AS fraud_alerts, a.max_risk
FROM kpis k LEFT JOIN alerts a ON k.merchant_id = a.merchant_id
ORDER BY volume_usd DESC
LIMIT 25;
