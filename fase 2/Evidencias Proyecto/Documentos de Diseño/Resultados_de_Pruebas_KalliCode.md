# Resultados de Pruebas — KalliCode · Equipo 5 (Testing)

**Fecha del documento:** 28-10-2026 · **Responsable:** Luis Ibáñez (QA2)
**Regla aplicada:** solo se registra como *Aprobado* lo que tiene evidencia de ejecución. Lo que no se ha ejecutado se marca *Pendiente*, no se supone.

---

## 1. Ejecuciones registradas

### Ejecución E-01: evidencia existente del equipo
| Campo | Detalle |
|---|---|
| Ejecutada por | Alejandro González (equipo `aagonzalezv@ale`, según las capturas) |
| Entorno | Linux · Python 3.12.14 · pytest 9.1.1 |
| Fecha | `[PENDIENTE: no registrada en las capturas; confirmar con Alejandro]` |
| Commit | `[PENDIENTE: no registrado]` |
| Evidencia | 3 capturas de terminal incluidas en `3_Plan_y_Casos_de_Prueba_KalliCode.docx` |

| Caso | Prueba | Resultado | Tiempo |
|---|---|---|---|
| CP-02.1 | `test_kallicode_roles_no_bypassrls` | ✅ Aprobado | — |
| CP-02.2 | `test_no_superuser_active_connections` | ✅ Aprobado | — |
| CP-02.3 | `test_current_session_is_operational_role` | ✅ Aprobado | 3 en 0,18 s |
| CP-08 | `test_log_tenant_isolation_concurrent_execution` | ✅ Aprobado | 1 en 0,16 s |
| CP-12 | `test_fixture_deterministic_uuid` | ✅ Aprobado | — |
| CP-12 | `test_fixture_http_client` | ✅ Aprobado | — |
| CP-12 | `test_fixture_db_session_structure` | ✅ Aprobado | 3 en 0,25 s |

**Subtotal E-01:** 7 de 7 aprobadas.

### Ejecución E-02: suite completa (por ejecutar)
| Campo | Detalle |
|---|---|
| Ejecutada por | Luis Ibáñez |
| Commit | `[PENDIENTE]` |
| Fecha | `[PENDIENTE]` |
| Comando | ver la sección 4 |
| Evidencia | `resultados_pytest.xml`, `resultados_pytest.txt` y captura de pantalla |

| Área | Funciones | Aprobadas | Fallidas | Bloqueadas |
|---|---|---|---|---|
| A. Aislamiento y datos | 7 | `[PENDIENTE]` | | |
| B. Autenticación y autorización | 8 (23 ejec.) | `[PENDIENTE]` | | |
| C. Secretos y sandbox | 6 | `[PENDIENTE]` | | |
| D. Observabilidad | 2 | `[PENDIENTE]` | | |
| E. Base de datos | 4 | `[PENDIENTE]` | | |
| F. Utilidades QA | 19 | `[PENDIENTE]` | | |
| **Total suite Equipo 5** | **46** | | | |

`[PENDIENTE: cobertura medida (%) global y de los módulos de seguridad, frente a la meta 80 % / 95 %]`

## 2. Estado consolidado por caso

```
Aprobado con evidencia   ██░░░░░░░░░░░░░░  CP-02, CP-08, CP-12           (3 de 16 casos)
Pendiente de ejecución   ░░██████████████  CP-01, 03-07, 09-11, 13-16   (13 de 16 casos)
```

## 3. Hallazgos y mejoras propuestas

Esta sección responde al indicador "Desarrolla mejoras al producto en base al resultado de las pruebas".

| ID | Hallazgo | Evidencia | Impacto | Mejora propuesta | Estado |
|---|---|---|---|---|---|
| H-01 | Existe una prueba *placeholder* que siempre pasa | `test_dummy.py::test_placeholder` (su docstring dice que es temporal, para evitar el *Exit Code 5* de pytest) | Infla el conteo de pruebas aprobadas | Eliminarla ahora que la suite tiene 46 pruebas reales | Abierto |
| H-02 | La evidencia existente no registra fecha ni commit | Capturas de E-01 | No se puede asociar el resultado a una versión | Ejecutar con `--junitxml` y anotar `git rev-parse HEAD` en cada reporte | Abierto (se corrige en E-02) |
| H-03 | La cobertura no está medida frente a la meta | Meta D17: 80 % global / 95 % seguridad (KC-QA-10-6) | Sin línea base no se sabe la brecha | Ejecutar `make test` (incluye `--cov`) y registrar el porcentaje | Abierto |
| H-04 | El script `db/apply_schema.py` es un *mock* | Imprime "Pendiente Miembro A" y sale con código 0 | Un paso del flujo reporta éxito sin hacer nada | Implementarlo o retirarlo. `[PENDIENTE: confirmar responsable]` | Abierto |
| H-06 | El inicializador del paquete del orquestador está mal nombrado (`__init_.py`) | `apps/workers/src/kallicode_workers/orquestador/__init_.py` (análisis estático, ver *Diagrama de Clases*) | Sus exportaciones (`__all__`) no se cargan | Renombrarlo a `__init__.py`; reportarlo al equipo dueño (E2) | Abierto |
| H-07 | Una escalación desde la etapa de seguridad se clasifica con severidad *media* en vez de *alta* | `politica.py:42` compara contra `"seguridad"`, pero el estado real es `"security"`; la prueba `test_orquestador_reintentos.py:40` usa el mismo texto erróneo y por eso pasa | Las escalaciones de seguridad pierden prioridad | Comparar contra `EstadoJob.SECURITY` en el código y en la prueba; reportar a E2 | Abierto |
| H-05 | La Consola de Administración (Equipo 6) no tiene pruebas | Sin código en el repositorio | Riesgo alto: es la única superficie cross-tenant del sistema | Diseñar la suite de aislamiento de la consola antes de su primer endpoint | Abierto |

## 4. Cómo registrar la ejecución E-02

En WSL, dentro del clon del backend, con el entorno levantado:

```bash
make up && make db
git rev-parse --short HEAD
uv run pytest packages/testing/tests -v --junitxml=resultados_pytest.xml 2>&1 | tee resultados_pytest.txt
uv run pytest --cov -q 2>&1 | tail -40 | tee cobertura.txt
```

Luego completar la sección 1 con el commit, la fecha y los totales. Las pruebas fallidas también se registran, con su mensaje de error, y se agregan como hallazgo en la sección 3.
