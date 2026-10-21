-- Liquidación de intercambio con subtotales por emisor y total general (GROUPING SETS / ROLLUP)
SELECT coalesce(issuer_name, '== TOTAL ==')                    AS issuer_name,
       coalesce(acquirer_id, CASE WHEN issuer_name IS NOT NULL THEN '-- subtotal --' END) AS acquirer_id,
       sum(txn_count)                                          AS txns,
       round(sum(amount_usd), 2)                               AS volume_usd,
       round(sum(interchange_fee_usd), 2)                      AS interchange_usd,
       round(sum(interchange_fee_usd) / sum(amount_usd) * 100, 3) AS effective_rate_pct,
       grouping(issuer_name, acquirer_id)                      AS grouping_level
FROM "${gold_db}"."interchange_settlement"
GROUP BY ROLLUP (issuer_name, acquirer_id)
ORDER BY grouping(issuer_name), issuer_name, grouping(acquirer_id), interchange_usd DESC;
