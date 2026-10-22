# infra/command

Comandos para operar la infraestructura desde tu máquina. Ejecutan **lo mismo** que GitHub Actions
(`.github/workflows/deploy.yml`), para que lo que pruebes en local sea lo que se despliega.

> Primera vez en una cuenta nueva: [docs/antes-de-desplegar.md](../../docs/antes-de-desplegar.md).

| Script | Cuándo | Qué hace |
|---|---|---|
| `cloudshell_admin.sh` | **Etapa 0, una vez**, en AWS CloudShell | Terraform ([`infra/account`](../account/main.tf)) crea el grupo `paylake-admins` y el usuario `admin-joony`; el CLI crea su access key (fuera del estado de Terraform) |
| `cloudshell_consultor.sh` | Una vez, en la **misma carpeta** de CloudShell que `cloudshell_admin.sh` | Terraform crea el grupo `paylake-consultores` y el usuario `consultor-joony` (sólo puede asumir el rol de analista: Gold); el CLI crea su contraseña temporal de consola |
| `preflight.ps1` | **Antes del primer despliegue** | Revisa sin crear nada lo que suele bloquear: AWS CLI, credenciales (no root), versión del layer de pandas en la región, roles de DMS u OIDC ya existentes, administradores previos de Lake Formation, sesión de GitHub |
| `bootstrap.ps1` | **Una vez**, con credenciales de administrador | Despliega con **CloudFormation** el bucket del estado remoto, OIDC GitHub→AWS, el rol de despliegue y el permissions boundary; genera `backend.hcl` / `local.auto.tfvars` y configura las variables del repo en GitHub |
| `deploy.ps1` / `deploy.sh` | **Cada vez que cambias algo** | Credenciales → tests → `terraform fmt` → `init` + `validate` → `plan` → `apply` (con confirmación) → opcional: ejecuta el pipeline y verifica `SUCCEEDED` |
| `check_iam.ps1` | Al final de cada `deploy.ps1` (o cuando quieras) | Simula con `aws iam simulate-principal-policy` lo que cada identidad puede **y lo que no** (25 casos). Ver [docs/iam.md](../../docs/iam.md) |
| `destroy.ps1` | Al terminar una demo | Muestra el plan, pide confirmación; `-PauseOnly` apaga la ejecución horaria, sin flag destruye la plataforma |

`deploy.ps1` y `destroy.ps1` dejan registro de cada ejecución: `logs/<id>.log` + un JSON en CloudWatch Logs (`/paylake/deployments`) y en S3. Ver [docs/observabilidad-despliegues.md](../../docs/observabilidad-despliegues.md).

## Flujo típico al actualizar un cambio

```powershell
# 1. editar código en src/ o infra/platform/
# 2. probar y desplegar
./infra/command/deploy.ps1 -PlanOnly        # revisar el plan
./infra/command/deploy.ps1 -RunPipeline     # aplicar y validar en AWS
# 3. subir el cambio: GitHub Actions repite tests + plan + apply sobre main
git add -A; git commit -m "..."; git push
```

Si PowerShell bloquea los scripts: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.
