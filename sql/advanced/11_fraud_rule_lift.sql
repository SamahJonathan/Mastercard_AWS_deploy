-- Calidad de las reglas de fraude: precision, recall, F1 y lift sobre la tasa base de fraude
SELECT rule,
       flagged,
       true_positives,
       precision,
       recall,
       round(2 * precision * recall / nullif(precision + recall, 0), 4)              AS f1,
       round(precision / nullif(confirmed_frauds * 1.0 / labeled_txns, 0), 1)      AS lift_vs_base_rate
FROM "${gold_db}"."fraud_rule_performance"
ORDER BY f1 DESC NULLS LAST;
