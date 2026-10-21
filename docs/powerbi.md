# Dashboard en Power BI (sobre Athena)

Power BI Desktop (gratis) se conecta a Athena por ODBC **con el rol de analista**: Lake Formation sólo le
deja ver Gold. Verificado en la cuenta real (21-10-2026).

## 1. Una vez: driver y conexión

1. Instalar el **Amazon Athena ODBC driver 2.x** (64 bits) desde la
   [página oficial](https://docs.aws.amazon.com/athena/latest/ug/odbc-v2-driver.html). Requiere administrador.
2. Ejecutar:

   ```powershell
   ./powerbi/setup_odbc.ps1
   ```

   Crea el perfil de AWS `paylake-analyst` (asume `paylake-dev-analyst`), el DSN de usuario `PaylakeAthena` y
   prueba la conexión. Salida esperada:

   ```
   interchange_settlement        347 filas
   daily_merchant_kpis           933 filas
   fraud_alerts                 1004 filas
   cross_border_corridors        120 filas
   silver: negado por Lake Formation (correcto)
   ```

Requisitos de IAM que ya están en el proyecto: el rol de analista tiene `athena:GetQueryResultsStream` (el
driver trae los resultados por streaming, puerto 444 de salida), las acciones de metadatos de Athena que usa el
navegador de Power BI (`ListDataCatalogs`, `ListDatabases`, `ListTableMetadata`…) y `lakeformation:GetDataAccess`.
En el navegador sólo aparecen las tablas de Gold: Lake Formation oculta Silver y Bronze al analista.

No hace falta iniciar sesión en Power BI para trabajar en Desktop; sólo para publicar en el servicio web.

## 2. Cargar los datos

1. Power BI Desktop → **Obtener datos → Más… → ODBC → Conectar**.
2. **Nombre del origen de datos (DSN)**: `PaylakeAthena` → Aceptar.
3. Si pide credenciales: pestaña **Predeterminado o personalizado** → Conectar (las credenciales salen del perfil de AWS).
4. En el navegador: `AwsDataCatalog` → `paylake_dev_gold` → marcar
   `daily_merchant_kpis`, `interchange_settlement`, `fraud_alerts`, `cross_border_corridors`, `fraud_rule_performance`.
5. **Transformar datos** y, en cada tabla que tenga `txn_date`, cambiar su tipo a **Fecha**
   (clic en el ícono `ABC` del encabezado → Fecha) → **Cerrar y aplicar**.

## 3. Modelo y medidas

1. **Modelado → Nueva tabla**: `Calendario = CALENDARAUTO()`.
2. Vista de modelo: relacionar `Calendario[Date]` con el `txn_date` de las 4 tablas diarias (uno a varios).
3. Marcar `Calendario` como tabla de fechas (clic derecho → *Marcar como tabla de fechas* → columna `Date`).
4. Crear las medidas de [`powerbi/measures.dax`](../powerbi/measures.dax) (**Modelado → Nueva medida**, una por una).

## 4. Página "Resumen"

| Visual | Campos |
|---|---|
| 4 tarjetas | `Volumen USD`, `Transacciones`, `% Aprobación`, `Intercambio USD` |
| Gráfico de líneas | Eje: `Calendario[Date]` · Valores: `Volumen USD`, `Volumen 7d (promedio móvil)` |
| Barras horizontales | Eje: `interchange_settlement[issuer_name]` · Valores: `Intercambio USD` |
| Tabla | `fraud_alerts`: `txn_date`, `merchant_id`, `amount_usd`, `rules`, `risk_score` (orden por `risk_score`) |
| Tabla | `fraud_rule_performance`: `rule`, `flagged`, `true_positives`, `precision`, `recall` |
| Segmentación | `Calendario[Date]` (rango) |

Páginas opcionales: **Intercambio** (matriz `issuer_name` × `acquirer_id` con `Tasa efectiva`) y
**Transfronterizo** (mapa por `merchant_country` con `Volumen transfronterizo USD`).

## 5. Guardar como proyecto (versionable en git)

**Archivo → Guardar como → Tipo: Proyecto de Power BI (*.pbip)** → `powerbi/PaylakeDashboard.pbip`.
El formato `.pbip` guarda el modelo y el informe como archivos de texto, así el dashboard queda en el
repositorio igual que el resto del proyecto (el `.gitignore` que crea Power BI excluye la caché de datos).

## Alternativa sin DSN

Power Query M con el mismo DSN en [`powerbi/queries.pq`](../powerbi/queries.pq).
