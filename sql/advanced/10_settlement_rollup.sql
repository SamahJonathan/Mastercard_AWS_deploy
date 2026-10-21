-- Liquidación de intercambio con subtotales por emisor y total general (ROLLUP + grouping()).
-- El ROLLUP se calcula en una CTE y se ordena afuera: Athena (Trino) no admite grouping() en el ORDER BY
-- cuando se refiere a columnas transformadas en el SELECT.
WITH rollup_rows AS (
  SELECT issuer_name,
         acquirer_id,
         sum(txn_count)                     AS txns,
         round(sum(amount_usd), 2)          AS volume_usd,
         round(sum(interchange_fee_usd), 2) AS interchange_usd,
         round(sum(interchange_fee_usd) / sum(amount_usd) * 100, 3) AS effective_rate_pct,
         grouping(issuer_name, acquirer_id) AS grouping_level  -- 0 = detalle, 1 = subtotal emisor, 3 = total
  FROM "${gold_db}"."interchange_settlement"
  GROUP BY ROLLUP (issuer_name, acquirer_id)
)
SELECT coalesce(issuer_name, '== TOTAL ==')                                            AS issuer_name,
       coalesce(acquirer_id, CASE WHEN grouping_level = 1 THEN '-- subtotal --' END)   AS acquirer_id,
       txns, volume_usd, interchange_usd, effective_rate_pct, grouping_level
FROM rollup_rows
ORDER BY grouping_level = 3, issuer_name, grouping_level, interchange_usd DESC;
