# Antes de desplegar en AWS

Pasos, en orden, desde una cuenta de AWS vacía hasta el primer `deploy.ps1`. Al final hay una
tabla con los problemas que ya aparecieron y cómo se resolvieron.

## Resumen

| # | Paso | Dónde | Una vez / siempre |
|---|---|---|---|
| 0 | Herramientas locales | tu PC | una vez |
| 1 | Cuenta, región y saldo | consola de AWS | una vez |
| 2 | Identidad de administrador (Terraform) | AWS CloudShell | una vez |
| 3 | Credenciales en tu PC | tu PC | una vez |
| 4 | Chequeo previo | tu PC | antes del primer despliegue |
| 5 | Bootstrap (CloudFormation) | tu PC | una vez |
| 6 | Despliegue (Terraform) | tu PC o GitHub Actions | en cada cambio |
| 7 | Apagar todo | tu PC + CloudShell | al terminar la demo |

## 0. Herramientas locales

```powershell
winget install -e --id Hashicorp.Terraform
winget install -e --id Amazon.AWSCLI
winget install -e --id GitHub.cli
gh auth login
```

Además Python 3.12. Abrir una terminal **nueva** después de instalar, para que tome el `PATH`.

## 1. Cuenta, región y saldo

- Entrar a https://console.aws.amazon.com y elegir arriba a la derecha **South America (São Paulo) sa-east-1**.
- **Billing → Free Tier / Credits**: revisar que haya saldo. Una semana con todo encendido ronda
  USD 15–20 (estimación, ver costos en el [README](../README.md#costos)).
- Si algún servicio responde *not available on the Free plan*, pasar la cuenta a plan pagado conserva los créditos.

## 2. Identidad de administrador, con Terraform, desde CloudShell

Para usar Terraform o el CLI desde tu PC hacen falta credenciales, y eso es justo lo que hay que crear.
**AWS CloudShell** (icono `>_` de la consola, o
https://console.aws.amazon.com/cloudshell/home?region=sa-east-1) ya está autenticado con tu sesión,
así que desde ahí se corre Terraform sin ninguna clave.

```bash
cd ~ && rm -rf ~/Mastercard_AWS_deploy
git clone https://github.com/SamahJonathan/Mastercard_AWS_deploy.git
cd Mastercard_AWS_deploy && bash infra/command/cloudshell_admin.sh
```

Lo que debe aparecer, en orden:

| Momento | Salida | Acción |
|---|---|---|
| Identidad | tabla con `Account` y `Arn` (`...:root` es normal: es la única vez que se usa) | — |
| Espacio | `==> Espacio disponible: ... en /tmp, ... en $HOME` | — |
| Init | `Installing hashicorp/aws v6.x...` sin error | — |
| Plan | `Plan: 4 to add` (grupo, permiso, usuario, membresía) | escribir **`yes`** |
| Claves | recuadro con **Access Key ID** y **Secret Access Key** | copiarlas y luego `clear` |

Qué crea y por qué así: ver [docs/iam.md → Etapa 0](iam.md#etapa-0-tu-identidad-de-administrador).

> El secreto se muestra **una sola vez**. No se pega en chats, tickets ni en el repositorio.

### Rotar la access key (si se expuso o al terminar)

Si el secreto se pegó en algún lado (chat, ticket, captura), se considera comprometido: borrarlo y crear otro.

```bash
aws iam list-access-keys --user-name admin-joony --query 'AccessKeyMetadata[].AccessKeyId' --output text   | xargs -n1 aws iam delete-access-key --user-name admin-joony --access-key-id
aws iam create-access-key --user-name admin-joony --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text
```

## 3. Credenciales en tu PC

```powershell
aws configure            # key y secret del paso 2, región sa-east-1, salida json
aws sts get-caller-identity
```

Debe mostrar `arn:aws:iam::<cuenta>:user/paylake/admin-joony`. Desde aquí el usuario root no se vuelve a usar.

## 4. Chequeo previo

```powershell
cd "<ruta>\payments-lakehouse"
./infra/command/preflight.ps1
```

No crea nada; revisa lo que suele bloquear. Cada fila dice `OK`, `AVISO` o `FALTA`:

| Chequeo | Si sale AVISO / FALTA |
|---|---|
| Herramientas | instalar la que falte (paso 0) |
| Credenciales | si dice `root`, repetir pasos 2–3 |
| Layer de pandas para Lambda | no existe esa versión en la región: poner la que indica en `infra/platform/local.auto.tfvars` (`aws_sdk_pandas_version = "x.y.z"`) |
| Roles de servicio de DMS | ya existen en la cuenta: `create_dms_service_roles = false` en `local.auto.tfvars` |
| Proveedor OIDC de GitHub | ya existe: no hacer nada, el bootstrap lo reutiliza |
| Administradores de Lake Formation | ya hay otros: agregarlos a `lakeformation_admin_arns`, porque Terraform reemplaza la lista |

## 5. Bootstrap (CloudFormation, una vez)

```powershell
./infra/command/bootstrap.ps1 -AlertEmail tu@correo.com
```

Crea el bucket del estado de Terraform, el log group del historial de despliegues (`/paylake/deployments`),
la confianza OIDC con GitHub, el rol de despliegue y el permissions boundary; escribe `backend.hcl` y `local.auto.tfvars` (no se suben al repo) y configura las
variables del repositorio en GitHub.

**Confirmar la suscripción** en el email *AWS Notification - Subscription Confirmation*, si no las
alarmas y el aviso de presupuesto no llegan.

### 5b. Accesos de personas

Después del bootstrap, el estado de `infra/account` (administradores y consultores) pasa a S3: ver
[infra/command/README.md → Migrar el estado de la etapa 0](../infra/command/README.md#migrar-el-estado-de-la-etapa-0-sólo-en-una-cuenta-nueva).
Desde ahí, dar o quitar acceso a una persona es editar la lista en `infra/account/main.tf` y ejecutar
`./infra/command/account.ps1` ([docs/iam.md](iam.md#dos-personas-dos-identidades)).

## 6. Despliegue (Terraform)

```powershell
./infra/command/deploy.ps1 -PlanOnly        # ver qué se va a crear
./infra/command/deploy.ps1 -RunPipeline     # aplicar, ejecutar el pipeline y comprobar IAM
```

La primera vez tarda ~20–25 minutos, casi todo por RDS y DMS. Al final corre solo
`check_iam.ps1` (25 comprobaciones). Desde aquí, cada `git push` a `main` despliega por GitHub Actions.

Opcionales para la demo: QuickSight ([docs/quicksight.md](quicksight.md)), Power BI
([docs/powerbi.md](powerbi.md)) y el dashboard en Lightsail (`dashboard/deploy_lightsail.sh`).

## 7. Al terminar la demo

```powershell
./infra/command/destroy.ps1                 # borra la plataforma (Terraform)
```

Y en CloudShell, si ya no se va a usar la cuenta para esto:

```bash
cd ~/Mastercard_AWS_deploy
aws iam list-access-keys --user-name admin-joony          # borrar la key con delete-access-key
TF_DATA_DIR=/tmp/paylake-tf-account terraform -chdir=infra/account init
TF_DATA_DIR=/tmp/paylake-tf-account terraform -chdir=infra/account destroy
```

El bucket del estado y el stack `paylake-bootstrap` quedan (el bucket tiene `DeletionPolicy: Retain`);
se borran desde la consola de CloudFormation si ya no se necesitan. Si se activó QuickSight, cancelar la
suscripción en *Manage QuickSight → Account settings*.

## Problemas que ya aparecieron

| Síntoma | Causa | Solución |
|---|---|---|
| `aws: command not found` en la PC | el CLI no estaba instalado, o la terminal es anterior a la instalación | `winget install -e --id Amazon.AWSCLI` y abrir una terminal nueva |
| `preflight.ps1` dice que falta `aws` recién instalado, en la terminal de VS Code | las terminales integradas heredan el `PATH` de VS Code, que se abrió antes de instalar | reiniciar VS Code, o recargar el PATH: `$env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")`. `preflight.ps1` ya lo hace solo |
| `cloudshell_admin.sh` se cortaba en silencio después de `Terraform v1.15.8` | `terraform version \| head -1` con `set -o pipefail`: `head` cierra la tubería y el script lo toma como error | corregido en el script (`ba262dc`); hacer `git pull` |
| `apply` no dejaba escribir `yes` | `-input=false` sin un plan guardado no permite confirmar | corregido en el script (`ba262dc`) |
| `no space left on device` al instalar el provider en CloudShell | CloudShell da 1 GB persistente en `$HOME` y el provider de AWS pesa ~800 MB | el script usa `TF_DATA_DIR=/tmp/...` (`44b7f77`); borrar clones repetidos con `rm -rf ~/Mastercard_AWS_deploy` |
| Secreto de la access key pegado en un chat | se copió la salida completa de `cloudshell_admin.sh` | rotar la key (sección *Rotar la access key*) antes de configurarla; compartir sólo la salida de `aws sts get-caller-identity` |
| `terraform init`: *Too many command line arguments. Did you mean to use -chdir?* | PowerShell parte los argumentos que empiezan con `-` y llevan un punto: `-backend-config=backend.hcl` llega como `-backend-config=backend` y `.hcl` | ir entre comillas: `"-backend-config=backend.hcl"` (corregido en `deploy.ps1` y `destroy.ps1`) |
| `apply` falla al crear `aws_cloudwatch_log_metric_filter.deployments`: *log group does not exist* | el bootstrap se ejecutó antes de que existiera el log group del historial | volver a ejecutar `./infra/command/bootstrap.ps1` (idempotente); `preflight.ps1` lo detecta |
| EC2: *The specified instance type is not eligible for Free Tier* | las cuentas con plan gratuito sólo lanzan tipos elegibles (`aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true`) | `loader_instance_type = "t4g.micro"` (por defecto desde `b327197`+) |
| DMS: *Invalid ReplicationInstance class* | `dms.t3.micro` no se ofrece en sa-east-1 (`aws dms describe-orderable-replication-instances`) | `dms_instance_class = "dms.t3.small"` con 50 GB incluidos |
| Step Functions: *The state machine IAM Role is not authorized to access the Log Destination* | la máquina de estados se creaba antes de que su rol tuviera la política de logs (y antes de que IAM la propagara) | `depends_on` a la política + `time_sleep` de 20 s |
| Pipeline `FAILED` en `BronzeToSilver`: *UndetectedType … card_status … completely empty* | el simulador no trae `card_status` ni `ip_country`: la columna queda 100 % vacía y awswrangler no puede inferir su tipo para el Glue Data Catalog (en local no pasa porque no se registra catálogo) | tipo explícito por columna en Silver (`SILVER_TYPES`) + red de seguridad en `storage.write_parquet` + test |
| La salida de Terraform muestra `ÔöÇÔöÇÔöÇ` en vez de líneas `───` | la consola de Windows usa CP850; al pasar la salida UTF-8 de Terraform por PowerShell (para el log) se decodifica mal | los scripts fijan `[Console]::OutputEncoding = UTF8` al empezar |
| Pipeline `FAILED` en `BronzeToSilver`: *TypeError: Need to pass bool-like values* | DMS escribe los `BOOLEAN` de PostgreSQL como texto (`'true'`/`'false'`) en Parquet; el test simulaba DMS con booleanos reales | `silver.dms_to_snapshot` convierte esas columnas; el test ahora usa el formato real, y se validó con los archivos reales de DMS del bucket |
| Pipeline `FAILED` en `SilverToGold`: *TypeError: boolean value of NA is ambiguous* | en la Lambda, awswrangler entrega Silver con tipos anulables y la capa trae pandas **3.0.2** (local era 3.0.5): una comparación con un valor vacío da `NA` y combinarla con `&` falla | `gold._flag` normaliza cada condición (NA = False); reproducido con las versiones exactas de la capa y los datos reales de S3; job `lambda-compat` en el CI con `requirements-lambda.txt`. Ver las versiones de la capa: `aws lambda get-layer-version-by-arn --arn <arn> --query Content.Location` y revisar los `*.dist-info` del zip |
| Job de Glue `FAILED`: *not authorized to perform glue:CreateDatabase* | con `saveAsTable`, Spark exige la base `default` del catálogo y trata de crearla | el job sólo escribe Parquet; las tablas las define Terraform con partition projection (`glue_job.tf`). El rol de Glue perdió los permisos de catálogo y de Lake Formation |
| Athena: *Invalid reference to output of SELECT clause from grouping() expression in ORDER BY* | Trino no admite `grouping()` en el `ORDER BY` sobre columnas transformadas | el `ROLLUP` se calcula en una CTE y se ordena afuera (`sql/advanced/10_settlement_rollup.sql`) |
| Power BI: *not authorized to perform athena:ListDataCatalogs* | el navegador de Power BI lista catálogos, bases y tablas con APIs de metadatos que una consulta directa no usa | el rol de analista recibe las acciones de metadatos de Athena (sólo lectura) |
| Sumar consultores dependía de una carpeta concreta de CloudShell | el estado de `infra/account` vivía en el `$HOME` de CloudShell | estado movido a S3 (`account/terraform.tfstate`) e importado lo existente; `account.ps1` desde la PC. Los scripts de CloudShell usan el mismo estado y apartan cualquier estado local viejo |
| Repositorio clonado dentro de sí mismo (`Mastercard_AWS_deploy/Mastercard_AWS_deploy`) | se ejecutó `git clone` estando ya dentro de la carpeta | partir siempre con `cd ~` (está en los comandos del paso 2) |
