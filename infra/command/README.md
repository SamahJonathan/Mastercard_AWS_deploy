# infra/command

Comandos para operar la infraestructura desde tu máquina. Ejecutan **lo mismo** que GitHub Actions
(`.github/workflows/deploy.yml`), para que lo que pruebes en local sea lo que se despliega.

| Script | Cuándo | Qué hace |
|---|---|---|
| `bootstrap.ps1` | **Una vez**, con credenciales de administrador | Crea el bucket del estado remoto, OIDC GitHub→AWS y el rol de despliegue; genera `infra/platform/backend.hcl` y configura las variables del repo en GitHub |
| `deploy.ps1` / `deploy.sh` | **Cada vez que cambias algo** | Credenciales → tests → `terraform fmt` → `init` + `validate` → `plan` → `apply` (con confirmación) → opcional: ejecuta el pipeline y verifica `SUCCEEDED` |
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
