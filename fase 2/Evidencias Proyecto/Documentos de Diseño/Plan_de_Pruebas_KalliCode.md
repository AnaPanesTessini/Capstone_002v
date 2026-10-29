# Plan de Pruebas — KalliCode · Equipo 5 (Testing)

**Proyecto:** KalliCode · Capstone APT122 · Fase 2
**Versión del sistema bajo prueba:** `kallicode-backend`, rama `develop`, commit `f04519f`
**Fecha:** 28-10-2026 · **Responsable del documento:** Luis Ibáñez (QA2)
**Fuentes:** *Kallicode – Plan Scrum 5 – Testing* (Alloxentric), workflows de `.github/workflows/` y suite `packages/testing/tests/` del repositorio.

---

## 1. Objetivo

Verificar que la plataforma KalliCode cumpla sus requisitos de **aislamiento multi-tenant, seguridad de acceso, integridad de la base de datos y confiabilidad del entorno de pruebas**. Además, la verificación debe ser automática en cada *pull request*, de modo que ningún cambio llegue a `develop` o `main` sin pasar las puertas de calidad.

En el *Plan de Programa v2.0*, Alloxentric derogó la decisión D19, así que ya no existe un equipo de Testing separado. La calidad queda repartida así:

```
 E3 Calidad     → etapa QA del PRODUCTO (prueba el código que la fábrica genera para el cliente)
 E5 Plataforma  → CI/CD, entornos y suites TRANSVERSALES de aislamiento y contrato   ← este plan
 Cada equipo    → prueba su propio dominio (Definición de Terminado)
```

El equipo trabaja con su propia adaptación (`backlog_plan_scrum_5-v4`, roles QA1/QA2/QA3). Este plan cubre la parte de E5: las pruebas transversales sobre la plataforma.

## 2. Alcance

**Incluido en esta fase:**

| Área | Qué se verifica | Suite |
|---|---|---|
| Aislamiento multi-tenant (RLS) | Un tenant no puede leer ni escribir datos de otro | `seguridad/test_aislamiento_rls.py` |
| Roles de base de datos | Los roles operativos no tienen `BYPASSRLS` ni superusuario | `seguridad/test_roles_db.py` |
| Autenticación JWT | Rechazo de tokens ausentes, expirados, mal firmados, manipulados y `alg=none` | `seguridad/test_jwt_seguridad.py` |
| Autorización RBAC | Matriz de 6 roles contra los Gates 1 y 3 y la cola de aprobaciones | `seguridad/test_rbac_matrix.py` |
| Inyección SQL en búsqueda vectorial | Dimensiones, metadatos y operadores de pgvector | `seguridad/test_sql_injection_vector.py` |
| Secretos | Cifrado en Redis, archivos temporales y bóveda local | `seguridad/test_redis_secrets.py`, `test_secrets_vault.py` |
| Sandbox de ejecución | Sin red saliente, sin secretos y sin montajes al host | `seguridad/test_sandbox_isolation.py` |
| Observabilidad | Logs JSON trazables y sin cruce de tenant bajo concurrencia | `test_logger.py`, `seguridad/test_log_tenant_isolation.py` |
| Migraciones | Esquema completo, FK validadas, ciclo upgrade/rollback | `database/test_migraciones.py` |
| Higiene de datos | El *teardown* deja la base sin cambios (delta cero) | `database/test_teardown.py` |
| Utilidades de QA | Fixtures, stub LLM, rutas seguras, almacenamiento Azurite, módulo `testing/` | `test_conftest.py`, `test_llm_stub.py`, `test_path_utils.py`, `test_storage_client.py`, `test_testing_module.py` |

**Fuera de alcance en esta fase:**
- Corregir defectos de otros equipos. Según el Plan Scrum 5, *Testing detecta, escribe la prueba que lo demuestra y verifica el cierre; no lo arregla*.
- Pruebas extremo a extremo del Portal, de carga y de aceptación de usuario (planificadas para sprints posteriores).
- Consola de Administración (Equipo 6), sin desarrollo iniciado.

## 3. Niveles de prueba

La estrategia de Alloxentric define una pirámide de diez niveles. Este es el estado de cada uno en el repositorio a la fecha:

| # | Nivel | Estado en el repo | Evidencia |
|---|---|---|---|
| 1 | Unitarias del núcleo | ✅ Implementado | 51 archivos de prueba en `packages/core` |
| 2 | Integración contra PostgreSQL real | ✅ Implementado | `packages/core/tests/integracion/`, paso *Pruebas de base de datos* del CI |
| 3 | Aislamiento multi-tenant | ✅ Implementado | `test_aislamiento_rls.py` (KC-QA-B2-01) |
| 4 | Contrato de APIs (OpenAPI) | ✅ Implementado | Workflow `contrato.yml`, schemathesis |
| 5 | Esquema y migraciones | ✅ Implementado | `test_migraciones.py` (KC-QA-B2-08), validación de idempotencia y ledger SHA-256 en el CI |
| 6 | Extremo a extremo del Portal | ⏳ Parcial | Paso *Pruebas – Portal* del CI. `[PENDIENTE: confirmar alcance]` |
| 7 | Carga | ❌ No iniciado | — |
| 8 | Seguridad | ✅ Implementado | Gitleaks, Semgrep y Trivy en el CI, y `security_scan.yml` diario |
| 9 | CI/CD | ✅ Implementado | `ci.yml` en cada PR a `main`, `develop` y `testdev` |
| 10 | Entornos y datos de prueba | ✅ Implementado | `docker-compose.test.yml`, fixtures con *savepoints*, Azurite |

Además existen **pruebas de mutación** sobre CodeMapping (mutmut, umbral ≥ 90 % de mutantes muertos).

## 4. Entorno de pruebas

| Componente | Versión / detalle |
|---|---|
| Python | 3.12 (según la evidencia de ejecución: 3.12.14) |
| Framework | pytest 9.1.1 con pytest-asyncio, hypothesis, schemathesis, respx y pytest-cov |
| Base de datos | PostgreSQL 16 con pgvector. **Nunca SQLite**: RLS, triggers y la cadena de hash solo existen en el motor real |
| Cola | Redis 7 |
| Almacenamiento | Azurite (emulador de Azure Blob) |
| Aislamiento de datos | Transacciones anidadas con `SAVEPOINT` y *rollback* automático por prueba (PR #67) |
| Rol de conexión | `kallicode_app`, sin superusuario ni `BYPASSRLS`. Las pruebas corren con las mismas restricciones que producción |

## 5. Ejecución automatizada (CI/CD)

```
 PR hacia main / develop / testdev
        │
        ▼
 ┌─ Seguridad ──────────┐  Gitleaks · Semgrep · Trivy
 ├─ Base de datos ──────┤  roles → esquema 01..05 → migraciones → re-ejecución (idempotencia)
 │                      │  → ledger SHA-256 → pruebas de BD
 ├─ Calidad estática ───┤  Ruff + Mypy (Python) · TSC (Portal)
 ├─ Pruebas ────────────┤  pytest + cobertura · mutación codemapping · integridad BD · Portal
 └─ Reporte ────────────┘  publicación de resultados y cobertura
        │
   ¿todo verde? ── no ──► merge bloqueado
        │ sí
        ▼
      merge
```

Workflows complementarios:
- `contrato.yml`: pruebas de contrato OpenAPI.
- `indices_nocturno.yml`: informe nocturno de índices (KC-DB-06-1).
- `security_scan.yml`: escaneo completo del historial con Gitleaks, todos los días a las 02:00.

## 6. Criterios de entrada y salida

**Entrada:** entorno levantado (`make up && make db`), dependencias sincronizadas (`uv sync --all-packages`) y una rama con un PR abierto.

**Salida (aprobación de un cambio):**
- El 100 % de las pruebas del CI aprobadas.
- Ruff y Mypy sin errores.
- Sin secretos detectados.
- **Meta de cobertura** (D17 y especificación de entorno): 80 % global y 95 % en los módulos de seguridad (autenticación, middleware RLS, guardas comerciales y sellado de auditoría). Es el ticket KC-QA-10-6, asignado al rol QA2. `[PENDIENTE: medir la cobertura actual con make test]`

## 7. Gestión de defectos

Cada defecto detectado se registra como *issue* o tarjeta en el tablero, con el ID del caso de prueba que lo demuestra, y se asigna al equipo dueño del código. El Equipo 5 verifica el cierre volviendo a ejecutar el caso. Un antecedente documentado: el conflicto CR-KC-001 (las pruebas del Equipo de Fábrica fallaban contra RLS), resuelto con el PR #67 (ver *Actas de reunión*, Acta 01).

## 8. Roles

| Rol (Plan Scrum 5) | Responsabilidad en este plan | Integrante |
|---|---|---|
| QA2 · Pruebas de backend y datos | Núcleo, RLS, migraciones, contrato y cobertura | Luis Ibáñez |
| `[PENDIENTE: rol]` | `[PENDIENTE]` | Alejandro González |
| `[PENDIENTE: rol]` | `[PENDIENTE]` | Ana Panes |

## 9. Documentos relacionados

- `Casos_de_Prueba_KalliCode.md`: detalle de cada caso.
- `Resultados_de_Pruebas_KalliCode.md`: ejecuciones registradas.
- `Guia_Instalacion_y_Ejecucion_KalliCode.md`: cómo levantar el entorno.
