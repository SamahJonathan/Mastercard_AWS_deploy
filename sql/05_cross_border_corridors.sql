-- Corredores transfronterizos: de qué país son las tarjetas y dónde compran
SELECT card_country, merchant_country, sum(txn_count) AS txns, round(sum(amount_usd), 2) AS amount_usd
FROM "${gold_db}"."cross_border_corridors"
GROUP BY 1, 2
ORDER BY amount_usd DESC;
