# Dashboard en Amazon QuickSight

Terraform crea el **data source** (Athena, workgroup `paylake-dev-analytics`) y cuatro **datasets** de
Gold en modo `DIRECT_QUERY` ([`quicksight.tf`](../infra/platform/quicksight.tf)). El tablero se arma en
la consola en ~15 minutos con los pasos de abajo.

## 1. Una vez: suscripción y permisos

1. Consola → **QuickSight** → *Sign up* (Enterprise; la prueba gratuita es de 30 días). Región `sa-east-1`.
2. *Manage QuickSight → Security & permissions → AWS resources*:
   - marcar **Amazon Athena**;
   - en **Amazon S3**, marcar los buckets `paylake-dev-gold-*` y `paylake-dev-athena-results-*`
     (con *Write permission for Athena Workgroup* en este último);
   - en **AWS KMS**, agregar la llave `alias/paylake-dev-lake`.
3. Copiar el ARN de tu usuario: *Manage QuickSight → Manage users*, o
   `aws quicksight list-users --aws-account-id <cuenta> --namespace default --region sa-east-1`.

## 2. Activarlo en Terraform

En `infra/platform/local.auto.tfvars` (y en las variables del repo de GitHub `ENABLE_QUICKSIGHT` /
`QUICKSIGHT_USER_ARN`):

```hcl
enable_quicksight   = true
quicksight_user_arn = "arn:aws:quicksight:sa-east-1:<cuenta>:user/default/<usuario>"
```

`./infra/command/deploy.ps1` crea el data source, los datasets y además le concede a tu usuario
`SELECT` sobre las tablas `layer=gold` en **Lake Formation** (sin eso Athena devolvería *access denied*).

## 3. El análisis

*Analyses → New analysis* → elegir los datasets:

| Hoja | Visual | Dataset | Campos |
|---|---|---|---|
| Resumen | KPI | KPIs diarios por comercio | `sum(gross_amount_usd)`, `sum(txn_count)`, tasa de aprobación = `sum(approved_count)/sum(txn_count)` |
| Resumen | Línea | KPIs diarios por comercio | X `txn_date`, valor `gross_amount_usd`, color `mcc_category` |
| Intercambio | Barras horizontales | Liquidación de intercambio | Y `issuer_name`, valor `interchange_fee_usd`, color `acquirer_id` |
| Intercambio | Tabla dinámica | Liquidación de intercambio | filas `issuer_name`, columnas `acquirer_id`, valor `effective_rate` (promedio) |
| Riesgo | Tabla | Alertas de fraude | ordenada por `risk_score`, filtro `rules` |
| Riesgo | Donut | Alertas de fraude | grupo `rules`, valor `count(transaction_id)` |
| Transfronterizo | Sankey | Corredores transfronterizos | origen `card_country`, destino `merchant_country`, peso `amount_usd` |

Agregar un control de filtro sobre `txn_date` aplicado a todas las hojas y publicar como **dashboard**.

## Apagarlo

QuickSight cobra por usuario mientras la suscripción existe: al terminar la semana, *Manage
QuickSight → Account settings → Unsubscribe* (Terraform no gestiona la suscripción).
