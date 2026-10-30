# Modelo Entidad-Relación — Esquema `core` · KalliCode

**Versión de la base de datos:** `kallicode-backend`, rama `develop`, commit `f04519f`
**Fecha:** 28-10-2026 · **Responsable:** Luis Ibáñez (QA2)

**Método.** Se aplicaron los scripts reales del repositorio (`db/00..05.sql` y las 31 migraciones versionadas de `db/migrations/`, con los mismos roles que usa `make db`) sobre un PostgreSQL 16 con pgvector y pg_partman. Los diagramas se generaron leyendo el catálogo de esa base (`pg_class`, `pg_attribute`, `pg_constraint`). **Ninguna tabla, columna ni relación se dibujó a mano.**

## 1. Visión general de la base de datos

```
ESQUEMA   TABLAS   CONTENIDO
core        39     organizaciones, usuarios, tickets, pipeline, calidad, comercial   ← este documento
cm          15     grafo de conocimiento del código (CodeMapping, decisión D18)
vec          4     embeddings vectoriales (pgvector)
audit        2     cadena de auditoría encadenada por hash
─────────────────
TOTAL       60     (sin contar particiones hijas)
```

Evolución del modelo:
```
41 tablas   diseño original (Modelo de Base de Datos, Alloxentric) — core, vec, audit
+15         esquema cm: el grafo de código pasa de Neo4j/Qdrant a PostgreSQL (D18)
 +4         tablas agregadas por migraciones versionadas
 60         estado actual del repositorio
```

## 2. Convenciones del modelo (leer antes de los diagramas)

- **Multi-tenencia.** Toda tabla de negocio tiene `tenant_id`, que referencia a `core.organizations`. Para que los diagramas sean legibles, esa relación **solo se dibuja en el diagrama A**. En los demás está implícita.
- **FK compuestas con tenant.** Las relaciones entre tablas usan claves foráneas compuestas `(tenant_id, x_id)`, no solo `x_id`. Así la base de datos *impide* que una fila de un cliente apunte a una fila de otro cliente (hallazgo DB-F01, cerrado con las migraciones 013–016).
- **Row Level Security.** 36 de las 39 tablas tienen RLS activado y **forzado** (`FORCE ROW LEVEL SECURITY`). Solo quedan fuera `plans`, que es un catálogo global de planes, y dos tablas técnicas.
- **Particionado.** `job_transitions`, `notifications`, `usage_tokens` y `webhook_inbox` están particionadas por fecha con pg_partman. Por eso la fecha forma parte de su clave primaria.
- **Identificadores.** Son ULID de texto con prefijo (`u_`, `org_`, `job_`…), lo que hace trazable cada id.
- **Cardinalidad.** `||--o{` = obligatoria (FK NOT NULL) · `|o--o{` = opcional (FK admite nulo).

## 3. Diagramas

### A. Organización, identidad y acceso

![A. Organización, identidad y acceso](img/MER_core_A.png)

| Tabla | Características | ¿Estaba en el MER anterior? |
|---|---|---|
| `core.organizations` | RLS forzado | Sí |
| `core.users` | RLS forzado | Sí |
| `core.invitations` | RLS forzado | **Nueva** |
| `core.refresh_tokens` | RLS forzado | Sí |
| `core.password_reset_tokens` | RLS forzado | **Nueva** |
| `core.onboarding_documents` | RLS forzado | **Nueva** |
| `core.connections` | RLS forzado | Sí |
| `core.branch_map` | RLS forzado | **Nueva** |
| `core.notifications` | particionada, RLS forzado | **Nueva** |
| `core.retention_policies` | RLS forzado | **Nueva** |

```mermaid
erDiagram
    core_organizations {
        text id PK
        text nombre
        text idioma
        text timezone
        text despliegue
        boolean fabrica_activa
        timestamptz creado_en
        timestamptz actualizado_en
        timestamptz eliminado_en
    }
    core_users {
        text id PK, UK
        text tenant_id FK, UK
        text email UK
        text nombre
        text rol
        text estado
        text idioma
        text password_hash
        jsonb notificaciones
        timestamptz ultimo_acceso
        timestamptz creado_en
        timestamptz actualizado_en
    }
    core_invitations {
        text id PK
        text tenant_id FK
        text email
        text rol
        text token_hash UK
        text invitado_por FK
        text estado
        timestamptz expira_en
        timestamptz usado_en
        timestamptz creado_en
    }
    core_refresh_tokens {
        text id PK
        text tenant_id FK
        text user_id FK
        text token_hash UK
        timestamptz emitido_en
        timestamptz expira_en
        timestamptz usado_en
        boolean revocado
        inet ip
        text user_agent
    }
    core_password_reset_tokens {
        text id PK
        text tenant_id FK
        text user_id FK
        text token_hash UK
        timestamptz expira_en
        timestamptz usado_en
        timestamptz creado_en
    }
    core_onboarding_documents {
        text id PK, UK
        text tenant_id FK, UK
        text nombre_archivo
        text content_type
        bigint tamano_bytes
        text tipo_documento
        text blob_ref
        text hash_contenido
        text estado
        text subido_por FK
        timestamptz creado_en
    }
    core_connections {
        text id PK, UK
        text tenant_id FK, UK
        text categoria
        text proveedor
        text nombre
        jsonb config
        text secreto_ref
        text ruta_token UK
        text estado
        timestamptz ultimo_test
        jsonb ultimo_test_detalle
        timestamptz creado_en
        timestamptz actualizado_en
    }
    core_branch_map {
        text tenant_id PK, FK
        text feature_pattern
        text staging_branch
        text prod_branch
        timestamptz actualizado_en
    }
    core_notifications {
        text id PK
        text tenant_id FK
        text user_id FK
        text tipo
        text titulo
        text cuerpo
        text ticket_id FK
        boolean leida
        timestamptz creada_en PK
    }
    core_retention_policies {
        text id
        text tenant_id PK, FK
        text entity_name PK
        integer retention_days
        text action
        boolean is_active
        timestamptz created_at
        timestamptz updated_at
    }
    core_organizations ||--o{ core_branch_map : "tenant_id"
    core_organizations ||--o{ core_connections : "tenant_id"
    core_organizations ||--o{ core_invitations : "tenant_id"
    core_users ||--o{ core_invitations : "invitado_por"
    core_organizations ||--o{ core_notifications : "tenant_id"
    core_users ||--o{ core_notifications : "user_id"
    core_organizations ||--o{ core_onboarding_documents : "tenant_id"
    core_users ||--o{ core_onboarding_documents : "subido_por"
    core_organizations ||--o{ core_password_reset_tokens : "tenant_id"
    core_users ||--o{ core_password_reset_tokens : "user_id"
    core_organizations ||--o{ core_refresh_tokens : "tenant_id"
    core_users ||--o{ core_refresh_tokens : "user_id"
    core_organizations ||--o{ core_retention_policies : "tenant_id"
    core_organizations ||--o{ core_users : "tenant_id"
```

### B. Comercial y consumo

![B. Comercial y consumo](img/MER_core_B.png)

| Tabla | Características | ¿Estaba en el MER anterior? |
|---|---|---|
| `core.plans` | sin RLS (catálogo global) | Sí |
| `core.subscriptions` | RLS forzado | Sí |
| `core.upgrade_requests` | RLS forzado | **Nueva** |
| `core.usage_cycles` | RLS forzado | Sí |
| `core.usage_loc` | RLS forzado | Sí |
| `core.usage_tokens` | particionada, RLS forzado | **Nueva** |
| `core.model_providers` | RLS forzado | **Nueva** |
| `core.model_assignments` | RLS forzado | **Nueva** |

```mermaid
erDiagram
    core_plans {
        text codigo PK
        text nombre
        integer lineas
        integer loc_mes
        integer max_usuarios
        integer storage_mb
        integer docs_mb
        boolean permite_help
        text_arr despliegues
        timestamptz creado_en
    }
    core_subscriptions {
        text id PK
        text tenant_id FK
        text plan_codigo FK
        text estado
        date inicia_el
        date renueva_el
        date finaliza_el
        timestamptz creado_en
    }
    core_upgrade_requests {
        text id PK
        text tenant_id FK
        text plan_deseado FK
        text comentario
        boolean urgente
        text estado
        text solicitado_por FK
        timestamptz creado_en
    }
    core_usage_cycles {
        text tenant_id PK, FK
        text ciclo PK
        integer loc_consumidas
        text umbral
        timestamptz actualizado_en
        integer loc_netas
    }
    core_usage_loc {
        bigint id PK
        text tenant_id FK
        text ticket_id FK
        text ciclo
        text tipo
        text pr_url
        integer anadidas
        integer eliminadas
        integer netas
        integer tests
        text motivo_ajuste
        timestamptz creado_en
    }
    core_usage_tokens {
        bigint id PK
        text tenant_id FK
        text ticket_id FK
        text etapa
        text modelo
        text tier
        integer invocaciones
        integer tokens_in
        integer tokens_out
        integer duracion_ms
        timestamptz creado_en PK
    }
    core_model_providers {
        text tenant_id PK, FK
        text proveedor PK
        text llave_ref
        text llave_mascara
        text base_url
        text estado
        jsonb modelos_disponibles
        timestamptz ultimo_test
        timestamptz actualizado_en
    }
    core_model_assignments {
        text tenant_id PK, FK
        text funcion PK
        text principal_proveedor FK
        text principal_modelo
        text fallback_proveedor FK
        text fallback_modelo
        timestamptz actualizado_en
    }
    core_model_providers ||--o{ core_model_assignments : "fallback_proveedor"
    core_model_providers ||--o{ core_model_assignments : "principal_proveedor"
    core_plans ||--o{ core_subscriptions : "plan_codigo"
    core_plans ||--o{ core_upgrade_requests : "plan_deseado"
```

### C. Tickets y pipeline de producción

![C. Tickets y pipeline de producción](img/MER_core_C.png)

| Tabla | Características | ¿Estaba en el MER anterior? |
|---|---|---|
| `core.tickets` | RLS forzado | Sí |
| `core.ticket_attachments` | RLS forzado | **Nueva** |
| `core.ticket_counters` | RLS forzado | **Nueva** |
| `core.ticket_watchers` | RLS forzado | Sí |
| `core.webhook_inbox` | particionada, RLS forzado | Sí |
| `core.specs` | RLS forzado | Sí |
| `core.spec_alternatives` | RLS forzado | Sí |
| `core.spec_criteria` | RLS forzado | Sí |
| `core.jobs` | RLS forzado | Sí |
| `core.job_transitions` | particionada, RLS forzado | Sí |
| `core.llm_steps` | RLS forzado | Sí |
| `core.escalations` | RLS forzado | **Nueva** |
| `core.production_lines` | RLS forzado | Sí |

```mermaid
erDiagram
    core_tickets {
        text id PK, UK
        text tenant_id FK, UK
        text numero UK
        text tipo
        text titulo
        text descripcion
        text prioridad
        text prioridad_pipeline
        text etapa
        smallint gate_pendiente
        text origen
        jsonb origen_ref
        text reportado_por FK
        jsonb usuario_final
        text modulo_pista
        text duplicado_de FK
        jsonb impacto
        text complejidad
        text pr_url
        date fecha_objetivo
        text motivo_cancelacion
        text cancelado_por FK
        timestamptz creado_en
        timestamptz actualizado_en
        timestamptz cerrado_en
    }
    core_ticket_attachments {
        text id PK
        text tenant_id FK
        text ticket_id FK
        text nombre_archivo
        text content_type
        bigint tamano_bytes
        text blob_ref
        text clase
        text escaneo
        text subido_por FK
        timestamptz creado_en
    }
    core_ticket_counters {
        text tenant_id PK, FK
        integer ultimo
    }
    core_ticket_watchers {
        text tenant_id FK
        text ticket_id PK, FK
        text user_id PK, FK
        timestamptz creado_en
    }
    core_webhook_inbox {
        bigint id PK
        text tenant_id FK
        text connection_id FK, UK
        text delivery_id UK
        text evento
        jsonb payload
        text estado
        text error_detalle
        text ticket_id FK
        timestamptz recibido_en
        timestamptz procesado_en
        date recibido_mes PK, UK
    }
    core_specs {
        text id PK, UK
        text tenant_id FK, UK
        text ticket_id FK, UK
        integer version UK
        text estado
        text spec_md_ref
        text_arr scope_paths
        jsonb plan_tests
        jsonb migraciones
        jsonb adr_borrador
        integer estimacion_loc
        timestamptz creado_en
    }
    core_spec_alternatives {
        text spec_id PK, FK
        text tenant_id FK
        text alt_id PK
        text titulo
        text descripcion
        text riesgo
        boolean recomendada
        boolean elegida
    }
    core_spec_criteria {
        text spec_id PK, FK
        text tenant_id FK
        text criterio_id PK
        text given_txt
        text when_txt
        text then_txt
    }
    core_jobs {
        text id PK, UK
        text tenant_id FK, UK
        text ticket_id FK
        text estado
        integer linea FK
        text prioridad
        jsonb iteraciones
        jsonb contexto
        timestamptz creado_en
        timestamptz actualizado_en
        timestamptz terminado_en
    }
    core_job_transitions {
        bigint id PK
        text tenant_id FK
        text job_id FK
        text de_estado
        text a_estado
        text motivo
        jsonb contexto
        text actor
        timestamptz creado_en PK
    }
    core_llm_steps {
        text id PK
        text tenant_id FK
        text job_id FK
        text ticket_id FK
        text etapa
        text paso
        text version_plantilla
        text modelo
        text tier
        numeric confianza
        text validacion
        smallint reintentos
        integer tokens_in
        integer tokens_out
        integer duracion_ms
        text entrada_ref
        text salida_ref
        timestamptz creado_en
    }
    core_escalations {
        text id PK
        text tenant_id FK
        text job_id FK
        text etapa
        text paso
        text motivo
        text severidad
        jsonb detalle
        text estado
        text resuelto_por
        timestamptz resuelto_en
        timestamptz creado_en
    }
    core_production_lines {
        text tenant_id PK, FK
        integer numero PK
        text estado
        text job_id FK
        timestamptz creado_en
        timestamptz actualizado_en
    }
    core_jobs ||--o{ core_escalations : "job_id"
    core_jobs ||--o{ core_job_transitions : "job_id"
    core_production_lines |o--o{ core_jobs : "linea"
    core_tickets ||--o{ core_jobs : "ticket_id"
    core_jobs ||--o{ core_llm_steps : "job_id"
    core_tickets ||--o{ core_llm_steps : "ticket_id"
    core_jobs |o--o{ core_production_lines : "job_id"
    core_specs ||--o{ core_spec_alternatives : "spec_id"
    core_specs ||--o{ core_spec_criteria : "spec_id"
    core_tickets ||--o{ core_specs : "ticket_id"
    core_tickets |o--o{ core_ticket_attachments : "ticket_id"
    core_tickets ||--o{ core_ticket_watchers : "ticket_id"
    core_tickets |o--o{ core_tickets : "duplicado_de"
    core_tickets |o--o{ core_webhook_inbox : "ticket_id"
```

### D. Calidad, gates y evidencia

![D. Calidad, gates y evidencia](img/MER_core_D.png)

| Tabla | Características | ¿Estaba en el MER anterior? |
|---|---|---|
| `core.qa_runs` | RLS forzado | Sí |
| `core.qa_results` | RLS forzado | Sí |
| `core.security_findings` | RLS forzado | Sí |
| `core.gate_signatures` | RLS forzado | Sí |
| `core.audit_exports` | RLS forzado | **Nueva** |

En este diagrama, `tickets`, `specs`, `users` aparecen solo como referencia (claves y columnas principales). Su detalle está en los diagramas A y C.

```mermaid
erDiagram
    core_tickets {
        text id PK, UK
        text titulo
    }
    core_specs {
        text id PK, UK
        text estado
    }
    core_users {
        text id PK, UK
        text email UK
        text nombre
        text estado
    }
    core_qa_runs {
        text id PK, UK
        text tenant_id FK, UK
        text ticket_id FK, UK
        text spec_id FK
        integer corrida UK
        jsonb regresion
        jsonb flaky
        timestamptz ejecutada_en
    }
    core_qa_results {
        text qa_run_id PK, FK
        text tenant_id FK
        text criterio_id PK
        text resultado
        text extracto_fallo
        jsonb veredicto_visual
        jsonb evidencias
    }
    core_security_findings {
        text id PK
        text tenant_id FK
        text ticket_id FK
        text origen
        text regla
        text archivo
        integer linea
        text severidad
        text titulo
        text veredicto
        text justificacion
        text fix_diff_ref
        boolean bloquea
        text estado
        timestamptz creado_en
        timestamptz actualizado_en
    }
    core_gate_signatures {
        text id PK
        text tenant_id FK
        text ticket_id FK
        smallint gate
        text accion
        text actor_id FK
        text comentario
        text alternativa_id
        boolean acepta_fallos
        text devolver_a
        text spec_id FK
        text sello
        timestamptz creado_en
    }
    core_audit_exports {
        text id PK
        text tenant_id FK
        text formato
        text ticket_id FK
        jsonb filtros
        text estado
        text blob_ref
        text solicitado_por FK
        timestamptz creado_en
        timestamptz completado_en
    }
    core_tickets |o--o{ core_audit_exports : "ticket_id"
    core_users ||--o{ core_audit_exports : "solicitado_por"
    core_specs |o--o{ core_gate_signatures : "spec_id"
    core_tickets ||--o{ core_gate_signatures : "ticket_id"
    core_users ||--o{ core_gate_signatures : "actor_id"
    core_qa_runs ||--o{ core_qa_results : "qa_run_id"
    core_specs ||--o{ core_qa_runs : "spec_id"
    core_tickets ||--o{ core_qa_runs : "ticket_id"
    core_tickets ||--o{ core_security_findings : "ticket_id"
```

### Tablas técnicas (no se dibujan)

| Tabla | Propósito |
|---|---|
| `core.schema_migrations` | Registro del runner de migraciones (archivo, sha256, fecha de aplicación). |
| `core.retencion_particiones` | Control interno de la retención de particiones (pg_partman). |
| `core.idempotency_keys` | Claves de idempotencia de peticiones; evita procesar dos veces la misma operación. |

## 4. Diferencias con el MER anterior (`MER.md`)

- El MER anterior modelaba **22** de las 39 tablas de `core`. Todas existen en la base real: **no tenía entidades inventadas**.
- Faltaban **17** tablas, que este documento incorpora: `audit_exports`, `branch_map`, `escalations`, `idempotency_keys`, `invitations`, `model_assignments`, `model_providers`, `notifications`, `onboarding_documents`, `password_reset_tokens`, `retencion_particiones`, `retention_policies`, `schema_migrations`, `ticket_attachments`, `ticket_counters`, `upgrade_requests`, `usage_tokens`.
- El MER anterior no mostraba las FK compuestas con `tenant_id` ni las tablas particionadas.

## 5. Pendiente

- MER de los esquemas `cm`, `vec` y `audit`.
- Diccionario de datos (descripción de cada columna).
