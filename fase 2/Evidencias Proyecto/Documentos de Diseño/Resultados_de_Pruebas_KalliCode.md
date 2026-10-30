# Resultados de Pruebas — KalliCode · Equipo 5 (Testing)

**Fecha del documento:** 30-10-2026 · **Responsable:** Luis Ibáñez (QA2)
**Regla aplicada:** solo se registra como *Aprobado* lo que tiene evidencia de ejecución.

---

## 1. Ejecuciones registradas

### Ejecución E-01: evidencia previa del equipo
| Campo | Detalle |
|---|---|
| Ejecutada por | Alejandro González (equipo `aagonzalezv@ale`, según las capturas) |
| Entorno | Linux · Python 3.12.14 · pytest 9.1.1 |
| Fecha y commit | No registrados en las capturas |
| Evidencia | 3 capturas en `Documentos de Diseño/3_Plan_y_Casos_de_Prueba_KalliCode.docx` (documento de Ana Panes) |

| Caso | Pruebas | Resultado |
|---|---|---|
| CP-02 Roles sin evasión de RLS | 3 | ✅ 3/3 aprobadas (0,18 s) |
| CP-08 Logs sin cruce de tenant | 1 | ✅ 1/1 aprobada (0,16 s) |
| CP-12 Fixtures globales | 3 | ✅ 3/3 aprobadas (0,25 s) |

### Ejecución E-02: suite completa del Equipo 5
| Campo | Detalle |
|---|---|
| Ejecutada por | Luis Ibáñez |
| Fecha | 30-10-2026, 00:11 |
| Commit | `3a0a9e6` (rama `develop`, repositorio `kallicode-backend`) |
| Entorno | WSL2 (Ubuntu) · Docker Desktop · Python 3.12.14 · pytest 9.1.1 · PostgreSQL 16 + pgvector + pg_partman · Redis 7 · Azurite |
| Comando | `uv run pytest packages/testing/tests -v --junitxml=resultados_pytest.xml` |
| Evidencia | `Evidencias de sistema/Pruebas/`: `resultados_pytest.xml` (reporte JUnit), `resultados_pytest.txt` (salida completa) y `Ejecucion_E02_62_passed.png` |

**Resultado: 62 de 62 ejecuciones aprobadas en 5,82 s.**
La suite tiene 47 funciones de prueba. La matriz RBAC se ejecuta una vez por cada rol (3 pruebas × 6 roles = 18 ejecuciones), y por eso el total es 62.

| Área | Casos | Ejecuciones | Aprobadas | Fallidas |
|---|---|---:|---:|---:|
| A. Aislamiento y datos | CP-01 a CP-03 | 7 | 7 | 0 |
| B. Autenticación y autorización | CP-04, CP-05 | 23 | 23 | 0 |
| C. Secretos y sandbox | CP-06, CP-07 | 6 | 6 | 0 |
| D. Observabilidad | CP-08, CP-09 | 2 | 2 | 0 |
| E. Base de datos | CP-10, CP-11 | 4 | 4 | 0 |
| F. Utilidades QA | CP-12 a CP-16 | 19 | 19 | 0 |
| Prueba marcador (`test_dummy`) | — | 1 | 1 | 0 |
| **Total** | **16 casos** | **62** | **62** | **0** |

### Cobertura de código (E-02)
Comando: `uv run pytest packages/testing/tests --cov=packages/testing/src`

| Módulo de `kallicode_testing` | Cobertura |
|---|---:|
| `gen_tests.py`, `run_suite.py`, `utils/path_utils.py` | 100 % |
| `stubs/llm_stub.py` | 92 % |
| `secrets_mock.py` | 90 % |
| `selector_repair.py` | 86 % |
| `storage_client.py` | 84 % |
| `logger.py` | 83 % |
| **Total del paquete** | **89,7 %** (129 sentencias, 36 ramas) |

Supera el umbral mínimo del 80 % configurado en el proyecto (*"Required test coverage of 80.0% reached"*) y el criterio de aceptación de KC-QA-B1-08 (> 85 % sobre el código del módulo de pruebas).
**Alcance:** esta cifra corresponde al paquete `packages/testing`. La meta del 95 % para los módulos de seguridad de `packages/core` (autenticación, RLS, guardas comerciales y auditoría) no se midió en esta ejecución.

## 2. Diagnóstico de la primera corrida (proceso de QA)

La primera ejecución de E-02 dio **45 aprobadas, 8 fallidas y 9 con error**. Antes de reportar defectos se analizaron los mensajes de error:

| Síntoma | Pruebas afectadas | Causa identificada | Tipo |
|---|---|---|---|
| `database "kallicode_test" does not exist` | 9 (errores de preparación) | Las pruebas usan una base separada que no se crea con `make db` | Entorno |
| `HTTP 500` en `/approvals/pending` | 4 (RBAC, roles autorizados) | La API bajo prueba apuntaba a la misma base inexistente. Los roles que debían recibir 403 sí pasaron, porque se rechazan antes de consultar la base | Entorno |
| `AuthenticationError` de Redis | 1 | `uv run pytest` no carga el `.env`, y la prueba usó la URL de Redis por defecto, sin contraseña | Entorno |
| `Unable to find image 'kallicode-test-runner'` | 3 (sandbox) | La imagen del sandbox no estaba construida en local (el CI la construye) | Entorno |

Una vez corregidas las tres condiciones del entorno, la suite pasó completa (62/62). **Ninguna de las 17 pruebas que no pasaban correspondía a un defecto del sistema.** Las condiciones se registran como hallazgo H-08 y se agregaron a la *Guía de Instalación*.

## 3. Hallazgos y mejoras propuestas

| ID | Hallazgo | Evidencia | Impacto | Mejora propuesta | Estado |
|---|---|---|---|---|---|
| H-01 | Existe una prueba *placeholder* que siempre pasa | `test_dummy.py::test_placeholder` (su docstring dice que es temporal) | Infla el conteo de aprobadas | Eliminarla; la suite ya tiene 46 pruebas reales | Abierto |
| H-02 | La evidencia previa no registraba fecha ni commit | Capturas de E-01 | No se podía asociar el resultado a una versión | E-02 se registró con commit, fecha y reporte JUnit | **Cerrado** |
| H-03 | Cobertura no medida frente a la meta | Meta 80 % global y 95 % en seguridad (KC-QA-10-6) | Sin línea base no se conoce la brecha | Medida en `packages/testing`: 89,7 %. Falta medir los módulos de seguridad de `core` | Parcial |
| H-04 | El script `db/apply_schema.py` es un *mock* | Imprime "Pendiente Miembro A" y sale con código 0 | Un paso reporta éxito sin hacer nada | Implementarlo o retirarlo | Abierto |
| H-05 | La Consola de Administración (E6) no tiene pruebas | Desarrollo en etapa inicial | Es la única superficie cross-tenant del sistema | Diseñar su suite de aislamiento antes del primer endpoint | Abierto |
| H-06 | El inicializador del paquete del orquestador está mal nombrado (`__init_.py`) | `apps/workers/src/kallicode_workers/orquestador/__init_.py` | Sus exportaciones (`__all__`) no se cargan | Renombrarlo a `__init__.py`; reportarlo a E2 | Abierto |
| H-07 | Una escalación desde la etapa de seguridad se clasifica como *media* en vez de *alta* | `politica.py:42` compara contra `"seguridad"`, pero el estado real es `"security"`; la prueba `test_orquestador_reintentos.py:40` usa el mismo texto erróneo y por eso pasa | Las escalaciones de seguridad pierden prioridad | Comparar contra `EstadoJob.SECURITY` en el código y en la prueba; reportar a E2 | Abierto |
| H-08 | Ejecutar la suite en local exige tres condiciones no documentadas | Primera corrida de E-02: 17 pruebas no pasaron por entorno | Cualquier integrante nuevo obtiene falsos fallos | Documentado en la *Guía de Instalación*, sección 6. Se sugiere además agregar un objetivo `make test-db` | **Mitigado** |

## 4. Cómo repetir la ejecución

```bash
set -a; source .env; set +a                                   # cargar variables del .env
make db KC_DB_NAME=kallicode_test                             # base de pruebas separada
docker build -t kallicode-test-runner -f packages/testing/Dockerfile.runner .   # imagen del sandbox
uv run pytest packages/testing/tests -v --junitxml=resultados_pytest.xml
```
