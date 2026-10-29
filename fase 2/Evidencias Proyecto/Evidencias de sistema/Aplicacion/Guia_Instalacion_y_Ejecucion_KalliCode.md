# Guía de instalación y ejecución — KalliCode Backend

**Proyecto:** KalliCode · Capstone APT122 · Equipo 5/6
**Versión documentada:** repositorio `kallicode-backend`, rama `develop`, commit `f04519f`
**Fuentes:** `Makefile`, `README.md`, `docker-compose.yml`, `pyproject.toml` y `db/migrations/README.md` del repositorio.
**Responsable del documento:** Luis Ibáñez · Fecha: 28-10-2026

---

## 1. Qué se levanta

```
                    ┌────────────────────────────┐
  make api  ──────► │ API FastAPI  :8000         │ /api/v1 · /api/v1/webhooks · /internal/v1
  make workers ───► │ Workers asíncronos         │ normalizer, scheduler, billing_cycle,
                    └──────┬──────────────┬──────┘ notifier, housekeeping, audit_export
                           │              │
  make up ───────►  ┌──────▼─────┐  ┌─────▼────┐  ┌──────────┐  ┌─────────┐  ┌────────────┐
  (docker compose)  │ PostgreSQL │  │ Redis 7  │  │ Azurite  │  │ Mailpit │  │ Embeddings │
                    │ 16+pgvector│  │ Streams  │  │ (Blob)   │  │ (SMTP)  │  │ TEI BGE-M3 │
                    │ :5432      │  │ :6379    │  │ :10000   │  │ :1025   │  │ :8080      │
                    └────────────┘  └──────────┘  └──────────┘  │ UI :8025│  └────────────┘
                                                                └─────────┘
  make db ───────►  esquema db/00..05.sql → migraciones db/migrations/ → seeds
```

| Servicio | Imagen | Puerto(s) | Uso |
|---|---|---|---|
| postgres | `kallicode-postgres:16` | 5432 | Base de datos con pgvector y RLS |
| redis | `redis:7-alpine` | 6379 | Colas (Redis Streams), con contraseña |
| azurite | `mcr.microsoft.com/azure-storage/azurite` | 10000 | Emulación local de Azure Blob Storage |
| mailpit | `axllent/mailpit` | 1025 (SMTP), 8025 (UI) | Correo local de desarrollo |
| embeddings | `ghcr.io/huggingface/text-embeddings-inference:cpu-latest` | 8080 | Embeddings BGE-M3 en CPU |

## 2. Requisitos previos

- Windows con **WSL2 (Ubuntu)**, o Linux/macOS. El `Makefile` usa comandos de shell Unix.
- **Docker** con Docker Compose (en Windows, Docker Desktop con integración WSL activada).
- **Python ≥ 3.12** (`requires-python` en `pyproject.toml`).
- **uv** (gestor de paquetes y del monorepo), **make** y **git**.
- `pre-commit` (lo instala `make bootstrap`).
- `[PENDIENTE: versiones mínimas de Docker y uv; el repositorio no las fija]`

> **Nota para Windows:** si el repositorio se clona en el disco de Windows (p. ej. `C:\kallicode-backend`) y git convierte los saltos de línea a CRLF, los scripts de shell pueden fallar dentro de WSL. Las migraciones no se ven afectadas: el runner calcula el sha256 normalizando a LF (`db/migrations/README.md`, regla 5).

## 3. Instalación

```bash
git clone https://github.com/AAGONZALEZV96/kallicode-backend.git
cd kallicode-backend
git checkout develop
make bootstrap
```

`make bootstrap` hace tres cosas:
1. Si no existe `.env`, lo crea copiando `.env.example` (32 variables). Revisa las contraseñas antes de seguir.
2. `uv sync --all-packages`: instala las dependencias de todos los paquetes del monorepo.
3. `pre-commit install`: activa los hooks de calidad antes de cada commit.

## 4. Ejecución

```bash
make up          # levanta los 5 servicios de la sección 1
make db          # crea base, roles, extensiones, esquema, migraciones y seeds
make api         # API en http://localhost:8000 (documentación en /docs)
make workers     # en otra terminal
```

### Qué hace `make db`, paso a paso

| Paso | Rol de PostgreSQL | Archivos |
|---|---|---|
| 1. Crea la base `kallicode` si no existe | `postgres` | — |
| 2. Roles operativos con contraseña (variables psql `pw_app`, `pw_worker`, `pw_admin`) | `postgres` | `db/00_roles.sql` |
| 3. Extensiones | `postgres` | `db/00_extensiones.sql` |
| 4. Esquema base: tablas, índices, triggers, RLS, validaciones | `kallicode_admin` | `db/01_schema.sql` … `db/05_validacion.sql` |
| 5. Migraciones versionadas (registradas con sha256 en `core.schema_migrations`) | `kallicode_admin` | `db/migrations/NNN_*.sql` vía `packages/core/migrate.py` |
| 6. Datos de prueba | `kallicode_admin` | `db/seeds/dev.sql` |

Separar roles (`postgres` solo crea; `kallicode_admin` es dueño del esquema) evita que la aplicación opere con privilegios de superusuario, condición necesaria para que RLS no pueda saltarse.

Los usuarios de prueba del tenant `org_demo` están descritos en el `README.md` del repositorio.

## 5. Verificación

- La API responde y muestra la documentación OpenAPI en `http://localhost:8000/docs`.
- La UI de correo local está en `http://localhost:8025`.
- `make check-db`: verificación de la base. `[PENDIENTE: describir qué valida exactamente]`
- `docker compose ps`: los cinco servicios deben aparecer en ejecución.

## 6. Pruebas y calidad

| Comando | Qué hace |
|---|---|
| `make test` | `uv run pytest --cov -q`: suite completa con cobertura |
| `make test-env-up` / `make test-env-down` | Infraestructura efímera de pruebas (`docker-compose.test.yml`) con healthcheck |
| `make test-local` | `[PENDIENTE: describir]` |
| `make lint` / `make ci` | Controles de calidad (Ruff, Mypy) |
| `make mutation-codemapping` | Pruebas de mutación de CodeMapping con mutmut; umbral ≥ 90 % de mutantes muertos. Solo Linux/macOS/WSL |

En GitHub Actions corren cuatro workflows: `ci.yml`, `contrato.yml` (pruebas de contrato OpenAPI con schemathesis), `security_scan.yml` e `indices_nocturno.yml`.

## 7. Detener y limpiar

```bash
make down        # detiene los servicios y conserva los datos
make clean       # SOLO DESARROLLO: borra contenedores y volúmenes (pierdes la base local)
```

---

**Evidencia asociada:** capturas de `docker compose ps`, de `make db` terminando sin errores, de `/docs` en el navegador y de la salida de `make test`. `[PENDIENTE: capturas tomadas por Luis con el entorno levantado]`
