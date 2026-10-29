# Casos de Prueba — KalliCode · Equipo 5 (Testing)

**Versión bajo prueba:** `kallicode-backend`, rama `develop`, commit `f04519f`
**Fecha:** 28-10-2026 · **Responsable:** Luis Ibáñez (QA2)
**Fuente:** suite `packages/testing/tests/`. Los objetivos y resultados esperados se tomaron de las *docstrings* de cada prueba, no se infirieron.

**Precondiciones comunes (aplican a todos los casos salvo indicación):**
1. Entorno levantado: `make up && make db`.
2. Dependencias instaladas: `uv sync --all-packages`.
3. Conexión con el rol `kallicode_app` (sin superusuario ni `BYPASSRLS`), inyectada por `conftest.py`.
4. Cada prueba corre dentro de una transacción con `SAVEPOINT` y se revierte al terminar.

**Formato de ejecución:** `uv run pytest <archivo> -v`

---

## A. Aislamiento y seguridad de datos

### CP-01 · Aislamiento multi-tenant por RLS · KC-QA-B2-01
| Campo | Detalle |
|---|---|
| Objetivo | Demostrar que ningún tenant puede leer ni modificar filas de otro en los esquemas `core`, `vec`, `audit` y `cm` |
| Precondición específica | Dos tenants de prueba creados por la fixture |
| Pasos | 1. Leer las políticas desde `pg_policies`. 2. Por cada tabla con política, ejecutar transacciones cruzadas entre los dos tenants |
| Resultado esperado | Ninguna fila del tenant B es visible ni modificable desde el contexto del tenant A |
| Archivo | `seguridad/test_aislamiento_rls.py::test_aislamiento_rls_generado_desde_politicas` |

### CP-02 · Roles sin privilegios de evasión · KC-QA-B2-02 (PR #91)
| Caso | Prueba | Resultado esperado |
|---|---|---|
| CP-02.1 | `test_kallicode_roles_no_bypassrls` | `kallicode_app` y `kallicode_worker` existen y no tienen superusuario ni `BYPASSRLS` |
| CP-02.2 | `test_no_superuser_active_connections` | No hay conexiones operativas activas con `postgres` ni con otro superusuario |
| CP-02.3 | `test_current_session_is_operational_role` | La sesión de prueba usa un rol estricto sometido a RLS |

Archivo: `seguridad/test_roles_db.py`

### CP-03 · Inyección SQL en búsqueda vectorial · KC-QA-B2-06
| Caso | Prueba | Resultado esperado |
|---|---|---|
| CP-03.1 | `test_vector_dimensions_sql_injection_blocked_by_pydantic` | La inyección en las dimensiones del vector se rechaza en la validación (Pydantic), antes de llegar a PostgreSQL |
| CP-03.2 | `test_vector_metadata_sql_injection_parameterization` | Los filtros de metadatos se parametrizan, sin concatenar SQL |
| CP-03.3 | `test_vector_distance_operator_injection` | No se pueden alterar los operadores de distancia de pgvector (`<->`, `<=>`, `<#>`) |

Archivo: `seguridad/test_sql_injection_vector.py`

## B. Autenticación y autorización

### CP-04 · Validación de JWT · KC-QA-B2-03
| Caso | Prueba | Entrada | Resultado esperado |
|---|---|---|---|
| CP-04.1 | `test_rechaza_ausencia_de_token` | Petición sin token | Rechazo (no autenticado) |
| CP-04.2 | `test_rechaza_token_expirado` | Token con `exp` vencido | Rechazo |
| CP-04.3 | `test_rechaza_firma_invalida_hmac` | Token firmado con otra clave | Rechazo |
| CP-04.4 | `test_rechaza_manipulacion_de_claims` | Payload alterado (rol elevado) con la firma original | Rechazo |
| CP-04.5 | `test_rechaza_ataque_algoritmo_none` | Token con `alg: none` | Rechazo |

Archivo: `seguridad/test_jwt_seguridad.py`

### CP-05 · Matriz RBAC sobre los Gates · KC-QA-B2-11
Prueba parametrizada por rol: 3 pruebas × 6 roles = **18 ejecuciones**.

| Acción | owner | admin | architect | approver | member | viewer |
|---|---|---|---|---|---|---|
| CP-05.1 Aprobar Gate 1 | ✔ | ✔ | ✔ | ✔ | 403 | 403 |
| CP-05.2 Firmar Gate 3 (paso a producción) | 403 | 403 | ✔ | 403 | 403 | 403 |
| CP-05.3 Ver `/api/v1/approvals/pending` | ✔ | ✔ | ✔ | ✔ | 403 | 403 |

CP-05.2 verifica la regla de negocio más sensible: **solo el arquitecto firma el paso a producción**, ni siquiera el `owner`.
Archivo: `seguridad/test_rbac_matrix.py`

## C. Secretos y sandbox

### CP-06 · Secretos en reposo · KC-QA-B2-07 y KC-QA-B2-04
| Caso | Prueba | Resultado esperado |
|---|---|---|
| CP-06.1 | `test_redis_keys_are_aes_encrypted` | Los payloads y tokens de sesión en Redis no se guardan en texto plano |
| CP-06.2 | `test_temporary_files_are_purged_or_encrypted` | Los archivos temporales no retienen credenciales en texto plano |
| CP-06.3 | `test_mock_vault_cifrado_y_recuperacion` | La bóveda local cifra (AES-GCM) y recupera el secreto original |

Archivos: `seguridad/test_redis_secrets.py`, `seguridad/test_secrets_vault.py`

### CP-07 · Aislamiento del sandbox de ejecución · KC-QA-B2-05
| Caso | Prueba | Resultado esperado |
|---|---|---|
| CP-07.1 | `test_sandbox_network_isolation_blocks_outbound` | Toda conexión saliente falla (*Network is unreachable* o *timeout*) |
| CP-07.2 | `test_sandbox_environment_secrets_isolation` | `PG_DSN` y `LLM_API_KEY` no existen dentro del contenedor |
| CP-07.3 | `test_sandbox_filesystem_isolation` | Sin montajes hacia la raíz del host y con permisos degradados |

Archivo: `seguridad/test_sandbox_isolation.py`

## D. Observabilidad

### CP-08 · Logs sin cruce de tenant · KC-QA-B2-10 (PR #137)
| Campo | Detalle |
|---|---|
| Objetivo | Bajo alta concurrencia asíncrona, cada línea de log debe pertenecer al `tenant_id` de su contexto |
| Pasos | Ejecutar peticiones concurrentes de varios tenants y capturar la salida de `structlog` |
| Resultado esperado | `expected_tenant == tenant_id` registrado en el 100 % de las líneas |
| Archivo | `seguridad/test_log_tenant_isolation.py::test_log_tenant_isolation_concurrent_execution` |

### CP-09 · Formato del logger · KC-QA-B1-10
`test_logger.py::test_logger_json_format_and_traceability_fields`: el logger emite JSON válido con los campos de trazabilidad obligatorios.

## E. Base de datos y migraciones

### CP-10 · Migraciones y rollback · KC-QA-B2-08
| Caso | Prueba | Resultado esperado |
|---|---|---|
| CP-10.1 | `test_esquema_base_y_ledger_migraciones_aplicados` | Los scripts `01..05.sql` y el runner dejan consolidados los 4 esquemas, sin tablas huérfanas |
| CP-10.2 | `test_integridad_contratos_claves_foraneas_y_validacion` | No quedan FK rotas ni restricciones `NOT VALID` pendientes |
| CP-10.3 | `test_ciclo_migracion_y_rollback_sin_tablas_huerfanas` | Un ciclo upgrade → rollback con FK compuestas no deja objetos huérfanos |

Archivo: `database/test_migraciones.py`

### CP-11 · Teardown idempotente · KC-QA-B2-09
`database/test_teardown.py::test_teardown_idempotencia_garantiza_delta_cero`: el conteo de filas antes y después de una ejecución es idéntico (delta cero).

## F. Utilidades del entorno de pruebas

| ID | Archivo | Pruebas | Resultado esperado |
|---|---|---|---|
| CP-12 · PR #67 | `test_conftest.py` | 3 | Las fixtures globales entregan UUID deterministas, un cliente HTTP aislado y una sesión de BD activa |
| CP-13 · KC-QA-B1-04 | `test_llm_stub.py` | 4 | El stub LLM responde en menos de 50 ms (tier flash), entrega pruebas e2e (tier pro) y simula JSON corrupto y errores de sintaxis |
| CP-14 · KC-QA-B1-06 | `test_path_utils.py` | 3 | Las rutas válidas se resuelven y se bloquean `../` y las rutas absolutas fuera de la base |
| CP-15 | `test_storage_client.py` | 2 | Creación idempotente de contenedores y subida/descarga contra Azurite |
| CP-16 | `test_testing_module.py` | 7 | Generador de pruebas (prefijo `test_`), parser de resultados (éxito y fallo) y reparación de selectores con fallback a `data-testid` |

---

## Resumen y trazabilidad

| Área | Casos | Pruebas (funciones) | Tickets |
|---|---|---|---|
| A. Aislamiento y datos | CP-01 a CP-03 | 7 | KC-QA-B2-01, 02, 06 |
| B. Autenticación y autorización | CP-04, CP-05 | 8 (23 ejecuciones) | KC-QA-B2-03, 11 |
| C. Secretos y sandbox | CP-06, CP-07 | 6 | KC-QA-B2-04, 05, 07 |
| D. Observabilidad | CP-08, CP-09 | 2 | KC-QA-B1-10, KC-QA-B2-10 |
| E. Base de datos | CP-10, CP-11 | 4 | KC-QA-B2-08, 09 |
| F. Utilidades QA | CP-12 a CP-16 | 19 | KC-QA-B1-04, 06 y PR #67 |
| **Total** | **16 casos** | **46 funciones** | |

Además existe `test_dummy.py::test_placeholder`, un marcador temporal que no verifica nada (ver hallazgo H-01 en *Resultados de Pruebas*).

`[PENDIENTE: vincular cada caso con su requerimiento del SRS (RF/RNF) una vez revisada la versión vigente del SRS]`
