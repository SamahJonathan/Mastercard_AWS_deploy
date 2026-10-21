-- Distribución del ticket por producto de tarjeta y canal (percentiles aproximados). Requiere acceso a Silver (rol risk-analyst)
SELECT card_product,
       entry_mode,
       count(*)                                                AS approved_txns,
       round(approx_percentile(amount_usd, 0.50), 2)           AS p50_usd,
       round(approx_percentile(amount_usd, 0.90), 2)           AS p90_usd,
       round(approx_percentile(amount_usd, 0.99), 2)           AS p99_usd,
       round(max(amount_usd), 2)                               AS max_usd
FROM "${silver_db}"."transactions"
WHERE is_approved
GROUP BY card_product, entry_mode
ORDER BY card_product, p90_usd DESC;
