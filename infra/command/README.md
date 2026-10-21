# infra/command

Comandos para operar la infraestructura desde tu máquina. Ejecutan **lo mismo** que GitHub Actions
(`.github/workflows/deploy.yml`), para que lo que pruebes en local sea lo que se despliega.

| Script | Cuándo | Qué hace |
|---|---|---|
| `preflight.ps1` | **Antes del primer despliegue** | Revisa sin crear nada lo que suele bloquear: AWS CLI, credenciales (no root), versión del layer de pandas en la región, roles de DMS u OIDC ya existentes, administradores previos de Lake Formation, sesión de GitHub |
| `bootstrap.ps1` | **Una vez**, con credenciales de administrador | Despliega con **CloudFormation** el bucket del estado remoto, OIDC GitHub→AWS, el rol de despliegue y el permissions boundary; genera `backend.hcl` / `local.auto.tfvars` y configura las variables del repo en GitHub |
| `deploy.ps1` / `deploy.sh` | **Cada vez que cambias algo** | Credenciales → tests → `terraform fmt` → `init` + `validate` → `plan` → `apply` (con confirmación) → opcional: ejecuta el pipeline y verifica `SUCCEEDED` |
| `check_iam.ps1` | Al final de cada `deploy.ps1` (o cuando quieras) | Simula con `aws iam simulate-principal-policy` lo que cada identidad puede **y lo que no** (25 casos). Ver [docs/iam.md](../../docs/iam.md) |
| `destroy.ps1` | Al terminar una demo | `-PauseOnly` apaga la ejecución horaria; sin flag destruye la plataforma |

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
