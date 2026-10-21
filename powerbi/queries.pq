// Power Query M: consultas a Athena vía el DSN ODBC "PaylakeAthena" (ver docs/powerbi.md)
let
    Fuente = Odbc.DataSource("dsn=PaylakeAthena", [HierarchicalNavigation = true]),

    Intercambio = Odbc.Query(
        "dsn=PaylakeAthena",
        "SELECT txn_date, issuer_name, acquirer_id, txn_count, amount_usd, interchange_fee_usd, effective_rate
         FROM paylake_dev_gold.interchange_settlement
         WHERE txn_date >= date_format(current_date - interval '30' day, '%Y-%m-%d')"
    ),

    Tipado = Table.TransformColumnTypes(
        Intercambio,
        {
            {"txn_date", type date}, {"txn_count", Int64.Type}, {"amount_usd", type number},
            {"interchange_fee_usd", type number}, {"effective_rate", type number}
        }
    )
in
    Tipado
