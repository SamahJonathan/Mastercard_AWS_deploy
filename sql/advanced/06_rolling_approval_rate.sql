-- Tasa de aprobación diaria y promedio móvil de 7 días (window frame) con variación vs. día anterior
WITH daily AS (
  SELECT txn_date,
         sum(txn_count)                                   AS txns,
         sum(approved_count)                              AS approved,
         sum(gross_amount_usd)                            AS gross_usd
  FROM "${gold_db}"."daily_merchant_kpis"
  GROUP BY txn_date
)
SELECT txn_date,
       txns,
       round(approved * 1.0 / txns, 4)                                                     AS approval_rate,
       round(avg(approved * 1.0 / txns) OVER (ORDER BY txn_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 4) AS approval_rate_7d,
       round(gross_usd, 2)                                                                 AS gross_usd,
       round(gross_usd - lag(gross_usd) OVER (ORDER BY txn_date), 2)                       AS gross_delta_vs_prev_day,
       round(sum(gross_usd) OVER (PARTITION BY substr(txn_date, 1, 7) ORDER BY txn_date), 2) AS gross_month_to_date
FROM daily
ORDER BY txn_date DESC;
