# Dashboard en Power BI (sobre Athena)

Power BI Desktop es gratuito y se conecta a Athena con el conector nativo **Amazon Athena** (usa el
driver ODBC de Athena). Las consultas pasan por Lake Formation igual que en QuickSight.

## 1. Driver y DSN

1. Instalar el **Amazon Athena ODBC driver 2.x** (64 bits) desde la documentación de Athena.
2. *Administrador de orígenes de datos ODBC (64 bits) → DSN de sistema → Agregar → Amazon Athena ODBC (x64)*:

| Campo | Valor |
|---|---|
| Data Source Name | `PaylakeAthena` |
| Region | `sa-east-1` |
| Catalog | `AwsDataCatalog` |
| Database | `paylake_dev_gold` |
| Workgroup | `paylake-dev-analytics` |
| Authentication | *IAM Profile* → un perfil del AWS CLI que asuma `paylake-dev-analyst` (ver abajo) |

Perfil en `%USERPROFILE%\.aws\config` para entrar **como analista** (sólo verá Gold):

```ini
[profile paylake-analyst]
role_arn       = arn:aws:iam::<cuenta>:role/paylake-dev-analyst
source_profile = default
region         = sa-east-1
```

## 2. Conectar

*Obtener datos → Amazon Athena* → DSN `PaylakeAthena` → modo **DirectQuery** → seleccionar
`interchange_settlement`, `daily_merchant_kpis`, `fraud_alerts`, `cross_border_corridors`.

Alternativa sin el conector (Power Query M, en [`powerbi/queries.pq`](../powerbi/queries.pq)).

## 3. Modelo y medidas

Relación: `daily_merchant_kpis[txn_date]` ↔ `interchange_settlement[txn_date]` a través de una tabla
calendario (`Calendario = CALENDARAUTO()`). Las medidas DAX están en
[`powerbi/measures.dax`](../powerbi/measures.dax).

## 4. Páginas sugeridas

1. **Resumen**: tarjetas (Volumen USD, Transacciones, % Aprobación, Intercambio USD) + línea diaria.
2. **Intercambio**: matriz emisor × adquirente con `Tasa efectiva`, barras por emisor.
3. **Riesgo**: tabla de alertas con formato condicional por `risk_score`, segmentación por regla.
4. **Transfronterizo**: mapa coroplético por `merchant_country` con `Volumen transfronterizo USD`.
