-- Detección de anomalías: días en que un comercio se aleja más de 3 desviaciones estándar de su promedio
WITH stats AS (
  SELECT merchant_id, merchant_name, txn_date, gross_amount_usd,
         avg(gross_amount_usd)         OVER (PARTITION BY merchant_id) AS mean_usd,
         stddev_samp(gross_amount_usd) OVER (PARTITION BY merchant_id) AS std_usd,
         count(*)                      OVER (PARTITION BY merchant_id) AS days_observed
  FROM "${gold_db}"."daily_merchant_kpis"
)
SELECT merchant_id, merchant_name, txn_date,
       round(gross_amount_usd, 2)                              AS gross_usd,
       round(mean_usd, 2)                                      AS mean_usd,
       round((gross_amount_usd - mean_usd) / nullif(std_usd, 0), 2) AS z_score
FROM stats
WHERE days_observed >= 5
  AND abs((gross_amount_usd - mean_usd) / nullif(std_usd, 0)) >= 3
ORDER BY abs((gross_amount_usd - mean_usd) / nullif(std_usd, 0)) DESC;
