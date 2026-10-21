-- Mezcla de segmentos de tarjetas por emisor (salida del job de Glue) con pivote por agregación condicional
SELECT month, issuer_id,
       count(*)                                                  AS cards,
       count_if(segment = 'high_value')                          AS high_value,
       count_if(segment = 'digital_first')                       AS digital_first,
       count_if(segment = 'regular')                             AS regular,
       count_if(segment = 'occasional')                          AS occasional,
       round(sum(spend_usd) FILTER (WHERE segment = 'high_value') / sum(spend_usd), 4) AS high_value_spend_share
FROM "${gold_db}"."card_monthly_segments"
GROUP BY month, issuer_id
ORDER BY month DESC, cards DESC;
