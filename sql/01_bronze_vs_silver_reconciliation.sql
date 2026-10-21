-- Reconciliación por día: cuántos registros llegaron a Bronze vs. cuántos quedaron en Silver y en cuarentena
WITH bronze AS (
  SELECT substr(event_ts, 1, 10) AS txn_date, count(*) AS bronze_rows, count(DISTINCT transaction_id) AS bronze_unique
  FROM "${bronze_db}"."transactions"
  WHERE ingest_date >= date_format(current_date - interval '3' day, '%Y-%m-%d')
  GROUP BY 1
),
silver AS (
  SELECT txn_date, count(*) AS silver_rows
  FROM "${silver_db}"."transactions"
  GROUP BY 1
)
SELECT b.txn_date, b.bronze_rows, b.bronze_unique, s.silver_rows,
       b.bronze_unique - coalesce(s.silver_rows, 0) AS rejected_or_quarantined
FROM bronze b LEFT JOIN silver s ON b.txn_date = s.txn_date
ORDER BY b.txn_date DESC;
