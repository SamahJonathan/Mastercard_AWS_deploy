-- Motivos de rechazo de calidad de datos
SELECT reason, count(*) AS records
FROM "${silver_db}"."quarantine"
CROSS JOIN UNNEST(split(reject_reasons, ',')) AS t(reason)
GROUP BY reason
ORDER BY records DESC;
