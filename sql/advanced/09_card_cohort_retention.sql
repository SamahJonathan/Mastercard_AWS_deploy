-- Cohortes: tarjetas agrupadas por su primer mes de uso y % que vuelve a transar en los meses siguientes
WITH activity AS (
  SELECT DISTINCT pan_token, date_trunc('month', event_ts) AS month
  FROM "${silver_db}"."transactions"
  WHERE is_approved
),
first_seen AS (
  SELECT pan_token, min(month) AS cohort_month FROM activity GROUP BY pan_token
),
cohort_activity AS (
  SELECT f.cohort_month, date_diff('month', f.cohort_month, a.month) AS month_offset, count(DISTINCT a.pan_token) AS cards
  FROM activity a JOIN first_seen f ON a.pan_token = f.pan_token
  GROUP BY 1, 2
)
SELECT cohort_month, month_offset, cards,
       round(cards * 1.0 / first_value(cards) OVER (PARTITION BY cohort_month ORDER BY month_offset), 4) AS retention
FROM cohort_activity
ORDER BY cohort_month, month_offset;
