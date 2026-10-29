# Metodología de Trabajo y Backlog — KalliCode · Equipo 5/6

**Fecha:** 28-10-2026 · **Responsable:** Luis Ibáñez (QA2)
**Fuentes:**
- *Plan de Programa v2.0* (Alloxentric)
- `backlog_plan_scrum_5-v4.md` (backlog del equipo)
- Tablero Trello del equipo
- Plataforma de tickets CoreStream (corestream.alloxentric.com)
- Historial de git del repositorio `kallicode-backend` (rama `develop`, commit `f04519f`, último commit 24-10-2026)

---

## 1. Marco metodológico

### 1.1 El marco de la empresa
Alloxentric organiza el programa KalliCode con **Scrum**:
- Sprints semanales: S1 (3-ago) → S12 (23-oct).
- 6 equipos verticales de 4 personas cada uno.
- Product Owner único, Architecture Board y gremios transversales.
- Una Definición de Terminado común a los seis equipos.

### 1.2 La adaptación del equipo (y por qué)
El equipo adaptó ese marco a sus condiciones reales:

| Condición del programa | Condición real del equipo | Decisión |
|---|---|---|
| 4 personas a tiempo completo por equipo | 3 estudiantes que trabajan y estudian, cubriendo **dos** equipos (E5 Plataforma y E6 Consola) | Roles QA1, QA2 y QA3 en vez de los 8 perfiles PLT/ADM |
| Sprints de 1 semana con ceremonias diarias | Disponibilidad irregular entre semana; calendario académico de 19 semanas | **Entregas incrementales por bloques** de ~2 semanas (B1–B6) |
| Cronograma ago–oct | Incorporación al proyecto en septiembre | Bloques del 29-sep al 18-dic |
| Flujo de trabajo controlado por sprint | Necesidad de limitar el trabajo simultáneo | **Tablero Kanban con límite WIP = 3** |

El resultado es un **modelo híbrido**: se conservan el backlog priorizado, las épicas, la estimación en Story Points y la Definición de Terminado de Scrum; la planificación se hace por bloques incrementales y el flujo se controla con Kanban.

**Lo que no cambia respecto al marco de la empresa:** la Definición de Terminado y las puertas de calidad del CI. Ningún ticket se considera terminado si su *pull request* no pasa el pipeline (ver sección 6).

### 1.3 Cambio de alcance (22–24 de septiembre)
Con la entrega de la documentación v2.0, Alloxentric reorganizó el programa:
- Pasó de 5 equipos por capa técnica a **6 equipos por flujo de valor**.
- Agregó la **Consola de Administración (E6)**.
- **Derogó la decisión D19**, con lo que dejó de existir un equipo de Testing separado.

El equipo, que había elegido el proyecto por su foco en calidad y CI/CD, quedó a cargo de E5 y E6. El backlog v4 conserva el enfoque de pruebas transversales de la plataforma, que según el Plan de Programa es responsabilidad de E5.

`[PENDIENTE: confirmar con el equipo si hubo reunión con acta para este cambio]`

---

## 2. Roles

| Rol (backlog v4) | Foco | Integrante | Tickets / SP asignados en v4 |
|---|---|---|---|
| QA1 · Lead Infra / SRE y CI-CD | Contenedores, workflows, carga, caos, release | `[PENDIENTE: confirmar]` Alejandro González | 20 / 104 SP |
| QA2 · Backend, Seguridad y Datos QA | Aislamiento RLS, contratos, BD, WORM | Luis Ibáñez | 20 / 92 SP |
| QA3 · Motor de pruebas IA y E2E | gen_tests, Playwright, selectores, accesibilidad | `[PENDIENTE: confirmar]` Ana Panes | 32 / 159 SP |

**Nota:** en CoreStream, Luis tiene asignados 9 tickets, entre ellos **KC-QA-B6-08**, que en el backlog v4 figuraba como de QA1. Las asignaciones se ajustaron después del backlog. `[PENDIENTE: registrar la reasignación vigente]`

---

## 3. Product Backlog

**72 tickets · 8 épicas · 355 Story Points** (suma real de los tickets. El encabezado del backlog v4 dice 350; hay una diferencia de 5 SP que conviene corregir en la fuente).

| Épica | Nombre | Responsable | Tickets | SP | Terminados | SP terminados |
|---|---|---|---:|---:|---:|---:|
| EQA1 | CI/CD y entornos de prueba | QA1 | 10 | 49 | 6 | 32 |
| EQA2 | Pruebas unitarias e integración | QA2 | 5 | 21 | 4 | 18 |
| EQA3 | Aislamiento multi-tenant y seguridad base | QA2 | 9 | 49 | **9** | **49** |
| EQA4 | Contrato de API, esquema y migraciones | QA2 | 7 | 28 | 2 | 8 |
| EQA5 | E2E del portal, visual diff y accesibilidad | QA3 | 8 | 39 | 0 | 0 |
| EQA6 | Motor de generación de pruebas con IA | QA3 | 13 | 66 | 2 | 8 |
| EQA7 | Sandbox, evidencia WORM y auto-reparación | QA3/QA1 | 12 | 62 | 0 | 0 |
| EQA8 | Carga, resiliencia, caos y release | QA1 | 8 | 41 | 0 | 0 |
| | **Total** | | **72** | **355** | **23** | **115** |

El detalle de cada ticket (descripción, criterios de aceptación y archivos afectados) está en `backlog_plan_scrum_5-v4.md`. Su carga oficial está en CoreStream (proyecto DK_Kallicode).

---

## 4. Planificación por bloques (equivalente al Sprint Backlog)

```
            sep          oct                     nov                     dic
            29 │ 6 │ 13 │ 20 │ 27 │ 3 │ 10 │ 17 │ 24 │ 1 │ 8 │ 15 │
B1 Fundaciones  ████████                                              12 t · 58 SP  ✅
B2 Aislamiento       ████████                                         11 t · 57 SP  ✅
B3 Motor IA                    ████████  ← hoy                        13 t · 66 SP  ⏳
B4 Sandbox/WORM                         ████████                      13 t · 65 SP
B5 E2E Portal                                    ████████             12 t · 54 SP
B6 Carga/Release                                          ████████    11 t · 55 SP
```

| Bloque | Ventana | Objetivo | Tickets | SP | Estado (verificado en git) |
|---|---|---|---:|---:|---|
| B1 | 29-sep → 09-oct | Entorno de pruebas cero-nube, CI unificado, utilidades base | 12 | 58 | ✅ 12/12 cerrados |
| B2 | 12-oct → 23-oct | Aislamiento multi-tenant (RLS), JWT, RBAC, secretos, migraciones | 11 | 57 | ✅ 11/11 cerrados |
| B3 | 26-oct → 06-nov | Motor de generación de pruebas con IA, fixtures sintéticos | 13 | 66 | ⏳ En curso (0/13 al 28-oct) |
| B4 | 09-nov → 20-nov | Sandbox, sellado de evidencias, cuarentena, métricas | 13 | 65 | Pendiente |
| B5 | 23-nov → 04-dic | E2E del portal, contrato API, i18n, accesibilidad | 12 | 54 | Pendiente |
| B6 | 07-dic → 18-dic | Carga (k6), caos, UAT, firma de release | 11 | 55 | Pendiente |

### Avance medido
- **Tickets:** 23 de 72 cerrados (**32 %**).
- **Story Points:** 115 de 355 (**32 %**).
- **Velocidad:** B1 = 58 SP y B2 = 57 SP, unos 57 SP por bloque. Con esa velocidad, los 240 SP restantes requieren ~4,2 bloques y quedan 4 (B3–B6). **El plan es ajustado:** cualquier retraso en B3 compromete B6.

> Esta cifra reemplaza el "40 % de madurez" de borradores anteriores, que no tenía cálculo de respaldo. El 32 % se obtiene directamente del backlog y del historial de git.

---

## 5. Evidencia de cierre: tickets terminados

Fuente: `git log` de `kallicode-backend`. Cada ticket se cerró con un *pull request* aprobado por el CI.

| Ticket | Descripción breve | PR | Fecha |
|---|---|---|---|
| KC-QA-B1-01 | Docker Compose de pruebas | #49 | 30-09 |
| KC-QA-B1-02 | Workflow CI unificado | #54 | 30-09 |
| KC-QA-B1-03 | Empaquetado de `packages/testing` | #42 (`pyproject.toml`) | 28-09 |
| KC-QA-B1-04 | Stub LLM cero-nube | #64 | 01-10 |
| KC-QA-B1-05 | Escaneo de secretos en pre-commit | #55 | 30-09 |
| KC-QA-B1-06 | Sanitización path-traversal | #65 | 01-10 |
| KC-QA-B1-07 | Doble de Azure Blob con Azurite | #56 | 30-09 |
| KC-QA-B1-08 | Suite de autoevaluación del módulo de pruebas | #66 | 01-10 |
| KC-QA-B1-09 | Fixtures globales con SAVEPOINT | #67 | 02-10 |
| KC-QA-B1-10 | Logger JSON estructurado | #68 | 02-10 |
| KC-QA-B1-11 | Imagen Docker del test runner | #58 | 30-09 |
| KC-QA-B1-12 | Guía de pruebas cero-nube | #59 | 30-09 |
| KC-QA-B2-01 | Suite de aislamiento RLS | #92 | 05-10 |
| KC-QA-B2-02 | Eliminación de BYPASSRLS | #91 | 05-10 |
| KC-QA-B2-03 | Pruebas negativas JWT | (sin n.º de PR en el mensaje) | 05-10 |
| KC-QA-B2-04 | Bóveda local AES-GCM | #105 | 07-10 |
| KC-QA-B2-05 | Harness del sandbox aislado | #128 | 14-10 |
| KC-QA-B2-06 | Inyección SQL en pgvector | (sin n.º de PR en el mensaje) | 14-10 |
| KC-QA-B2-07 | Secretos en Redis y temporales | #134 | 14-10 |
| KC-QA-B2-08 | Migraciones y rollback | #135 | 14-10 |
| KC-QA-B2-09 | Teardown con delta cero | #136 | 14-10 |
| KC-QA-B2-10 | Aislamiento de logs entre tenants | #137 | 14-10 |
| KC-QA-B2-11 | Matriz RBAC | #138 | 15-10 |

**Observación sobre equidad (indicador 7):** los 23 tickets tienen como autor del commit al mismo integrante (Alejandro González), aunque el backlog asigna 11 de ellos a QA2 y 4 a QA3. `[PENDIENTE: el equipo debe documentar cómo se distribuyó el trabajo real (pair programming, integración centralizada u otra modalidad) para que la evidencia en git refleje la participación de cada integrante.]`

---

## 6. Flujo de trabajo y Definición de Terminado

### 6.1 Tablero Kanban (Trello: "KalliCode – Gestión de Proyecto Equipo 5")

```
BACKLOG → BLOQUE ACTIVO → EN DESARROLLO → REVISIÓN Y CODEOWNERS → ENTREGADO/TERMINADO
                          (WIP máx. 3)     (PR + CI)
                                                         DEUDA TÉCNICA EXTERNA
                                                         (hallazgos en código de otros equipos)
```

- La columna **"Deuda técnica externa"** materializa una regla del programa: el equipo detecta y documenta defectos en el código de otros equipos, pero no los corrige (*"Testing entrega la prueba; el arreglo es del equipo dueño"*).
- **Inconsistencia a resolver:** las tarjetas del Trello usan códigos `KC-PLT-xx` (nomenclatura del Plan de Programa para E5), mientras CoreStream y los commits usan `KC-QA-Bx-xx` (backlog v4). Se recomienda unificar en `KC-QA` o agregar a cada tarjeta su código CoreStream.

### 6.2 Definición de Terminado (aplicada por el CI en cada PR)
Un ticket pasa a "Terminado" solo si su *pull request*:
1. Pasa el escaneo de secretos (Gitleaks), el análisis estático (Semgrep) y el escaneo de vulnerabilidades (Trivy).
2. Pasa Ruff y Mypy en Python, y TSC en el portal.
3. Aplica el esquema y las migraciones de forma idempotente, con el ledger SHA-256 verificado.
4. Pasa todas las pruebas contra PostgreSQL real, incluida la suite de aislamiento multi-tenant.
5. Es revisado por al menos otra persona antes del merge (exigencia del Plan de Programa, §10.1). `[PENDIENTE: verificar que la protección de rama de GitHub lo obligue]`

### 6.3 Reuniones
| Fecha | Tema | Registro |
|---|---|---|
| 12-09-2026 | Conflicto CR-KC-001: pruebas vs RLS | Acta 01 (`4_Actas_de_Reunion_KalliCode.docx`) |
| 25-09-2026 | Riesgo de mezcla de logs entre tenants | Acta 02 |
| 27-10-2026 | Revisión de avance con el stakeholder (Max, Alloxentric) | `[PENDIENTE: redactar acta]` |

---

## 7. Lecciones y ajustes de la metodología

- **El bloque de dos semanas funcionó para el trabajo de infraestructura.** B1 y B2 se cerraron completos, dentro de su ventana o antes.
- **La concentración de commits en un integrante es un riesgo:** depende de una sola persona (*bus factor* 1) y debilita la evidencia de participación. Ajuste: cada integrante abre sus propios PR desde B3.
- **Dos sistemas de códigos de ticket** (Trello y CoreStream) generan confusión. Ajuste: unificar en CoreStream como fuente oficial.
