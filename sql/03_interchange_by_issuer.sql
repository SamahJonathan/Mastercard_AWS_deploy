-- Intercambio adeudado a cada emisor (lo que pagan los adquirentes), últimos 7 días
SELECT issuer_name,
       sum(txn_count)                                   AS approved_txns,
       round(sum(amount_usd), 2)                        AS volume_usd,
       round(sum(interchange_fee_usd), 2)               AS interchange_usd,
       round(sum(interchange_fee_usd) / sum(amount_usd) * 100, 3) AS effective_rate_pct
FROM "${gold_db}"."interchange_settlement"
WHERE txn_date >= date_format(current_date - interval '7' day, '%Y-%m-%d')
GROUP BY issuer_name
ORDER BY interchange_usd DESC;
