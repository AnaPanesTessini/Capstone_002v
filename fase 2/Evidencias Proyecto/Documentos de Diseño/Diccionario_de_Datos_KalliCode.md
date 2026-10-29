# Diccionario de Datos — KalliCode

**Versión:** `kallicode-backend`, rama `develop`, commit `f04519f` · **Fecha:** 28-10-2026 · **Responsable:** Luis Ibáñez (QA2)
**Complementa:** `MER_core_KalliCode.md` y `MER_cm_vec_audit_KalliCode.md`

## Alcance y fuentes

Este diccionario detalla, columna por columna, las **36 tablas de negocio del esquema `core`**. Los esquemas `cm`, `vec` y `audit` (21 tablas) y las tablas técnicas se describen a nivel de tabla en las secciones finales; su detalle de columnas está en el MER.

Cada dato tiene una fuente verificable. **Nada se redactó por suposición:**

| Dato | Fuente |
|---|---|
| Columnas, tipos, nulos, valores por defecto, PK/UK/FK | Catálogo de PostgreSQL de una base construida con los scripts del repositorio |
| Valores permitidos | Restricciones `CHECK` de la base |
| Descripción de columna | 1) `COMMENT ON` de la base, 2) comentario en el SQL del repositorio, 3) convención documentada (`tenant_id`, `creado_en`…), 4) FK ("Referencia a…"), 5) traducción literal de nombres evidentes (`titulo` → Título) |
| Propósito de cada tabla | *Modelo de Base de Datos* de Alloxentric; si la tabla no figura ahí, comentario del SQL del repositorio |

Una descripción **"—"** significa que ninguna fuente documenta esa columna. Se dejó vacía a propósito para no inventar.

**Leyenda:** `PK` clave primaria · `UK` única · `FK→tabla` clave foránea (compuesta con `tenant_id`) · `FK→org` referencia a `core.organizations` · **NN** = NOT NULL.

## Organización, identidad y acceso

### `core.organizations`

Los tenants. Cada organización cliente es una fila; su id (org_...) es el tenant_id que replica toda tabla de negocio y sobre el que se aplican las políticas RLS. fabrica_activa marca el cierre del onboarding (habilita la publicación de tickets a Triage); eliminado_en implementa el borrado lógico, nunca físico.

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `id` | text | ✔ |  | PK | org_<slug/ulid> |
| `nombre` | text | ✔ |  |  | Nombre. |
| `idioma` | text | ✔ | `'es'` |  | Idioma. · Valores: es, en, pt |
| `timezone` | text | ✔ | `'Europe/Madrid'` |  | Zona horaria. |
| `despliegue` | text | ✔ | `'cloud'` |  | Valores: cloud, hibrido, onprem |
| `fabrica_activa` | boolean | ✔ | `false` |  | onboarding completado |
| `creado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de creación. |
| `actualizado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de la última modificación. |
| `eliminado_en` | timestamptz |  |  |  | soft-delete |

### `core.users`

Usuarios del portal con su rol (owner, admin, architect, approver, member, viewer), estado e idioma. password_hash usa Argon2id y es NULL mientras la invitación no se acepta. Los usuarios nunca se borran físicamente: se desactivan, porque sus firmas de gates y tickets forman parte del expediente de auditoría.

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `id` | text | ✔ |  | UK, PK | u_<ulid> |
| `tenant_id` | text | ✔ |  | UK, FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `email` | text | ✔ |  | UK | Correo electrónico. |
| `nombre` | text | ✔ |  |  | Nombre. |
| `rol` | text | ✔ | `'member'` |  | Valores: owner, admin, architect, approver, member, viewer |
| `estado` | text | ✔ | `'activo'` |  | Estado. · Valores: activo, invitado, desactivado |
| `idioma` | text | ✔ | `'es'` |  | Idioma. |
| `password_hash` | text |  |  |  | Argon2id (NULL si invitado) |
| `notificaciones` | jsonb | ✔ | `'{"email": true, "portal": true}'` |  | — |
| `ultimo_acceso` | timestamptz |  |  |  | Fecha y hora del último acceso. |
| `creado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de creación. |
| `actualizado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de la última modificación. |

### `core.invitations`

Invitaciones de alta con rol prefijado, token hasheado y expiración de 7 días. El índice parcial garantiza una sola invitación pendiente por email y tenant. Al aceptarse se crea el usuario y la fila pasa a aceptada (trazabilidad de quién invitó a quién).

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `id` | text | ✔ |  | PK | inv_<ulid> |
| `tenant_id` | text | ✔ |  | FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `email` | text | ✔ |  |  | Correo electrónico. |
| `rol` | text | ✔ |  |  | Valores: owner, admin, architect, approver, member, viewer |
| `token_hash` | text | ✔ |  | UK | SHA-256 del token enviado |
| `invitado_por` | text | ✔ |  | FK→core.users | Referencia a core.users. |
| `estado` | text | ✔ | `'enviada'` |  | Estado. · Valores: enviada, aceptada, expirada, revocada |
| `expira_en` | timestamptz | ✔ |  |  | Fecha y hora de expiración. |
| `usado_en` | timestamptz |  |  |  | Fecha y hora de uso. |
| `creado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de creación. |

### `core.refresh_tokens`

Sesiones de refresh rotativas: cada token es de un solo uso (usado_en) y revocable. La detección de replay (presentar un token ya usado) dispara la revocación de todas las sesiones del usuario. Se registran IP y user-agent para el análisis de seguridad. Purga programada por expira_en.

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `id` | text | ✔ |  | PK | rt_<ulid> |
| `tenant_id` | text | ✔ |  | FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `user_id` | text | ✔ |  | FK→core.users | Referencia a core.users. |
| `token_hash` | text | ✔ |  | UK | SHA-256; nunca el token |
| `emitido_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de emisión. |
| `expira_en` | timestamptz | ✔ |  |  | Fecha y hora de expiración. |
| `usado_en` | timestamptz |  |  |  | rotación: un solo uso |
| `revocado` | boolean | ✔ | `false` |  | Indica si fue revocado. |
| `ip` | inet |  |  |  | Dirección IP de origen. |
| `user_agent` | text |  |  |  | Cabecera User-Agent del cliente. |

### `core.password_reset_tokens`

Tokens de restablecimiento de contraseña: un solo uso, 30 minutos de validez, siempre hasheados.

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `id` | text | ✔ |  | PK | pr_<ulid> |
| `tenant_id` | text | ✔ |  | FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `user_id` | text | ✔ |  | FK→core.users | Referencia a core.users. |
| `token_hash` | text | ✔ |  | UK | Hash del token (nunca el token en claro). |
| `expira_en` | timestamptz | ✔ |  |  | Fecha y hora de expiración. |
| `usado_en` | timestamptz |  |  |  | Fecha y hora de uso. |
| `creado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de creación. |

### `core.onboarding_documents`

Documentación subida para el grafo de conocimiento (manuales, specs, ADRs, negocio) con hash de contenido para deduplicar y estado del pipeline de ingesta. Sus chunks embebidos viven en vec.doc_chunks.

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `id` | text | ✔ |  | UK, PK | doc_<ulid> |
| `tenant_id` | text | ✔ |  | UK, FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `nombre_archivo` | text | ✔ |  |  | Nombre del archivo. |
| `content_type` | text | ✔ |  |  | Tipo MIME del archivo. |
| `tamano_bytes` | bigint | ✔ |  |  | Tamaño en bytes. |
| `tipo_documento` | text | ✔ | `'otro'` |  | Valores: manual, spec, adr, negocio, otro |
| `blob_ref` | text | ✔ |  |  | Referencia al objeto en Blob Storage. |
| `hash_contenido` | text |  |  |  | dedup por contenido |
| `estado` | text | ✔ | `'pendiente'` |  | Estado. · Valores: pendiente, procesado, fallido |
| `subido_por` | text | ✔ |  | FK→core.users | Referencia a core.users. |
| `creado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de creación. |

### `core.connections`

Conexiones por categoría (repositorio, tickets, cicd, database) y proveedor. Las credenciales viven en Key Vault: aquí solo la referencia (secreto_ref) — nunca el valor. ruta_token es el token único de ruta de los webhooks entrantes (resuelve el tenant sin confiar en el cuerpo). Guarda el resultado del último test programado.

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `id` | text | ✔ |  | PK, UK | cn_<ulid> |
| `tenant_id` | text | ✔ |  | UK, FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `categoria` | text | ✔ |  |  | Valores: repositorio, tickets, cicd, database |
| `proveedor` | text | ✔ |  |  | Valores: github, gitlab, bitbucket, corestream_repo, jira, github_issues, kallicode_help, corestream, github_actions, gitlab_ci, jenkins, postgresql, mysql, sqlserver, oracle |
| `nombre` | text |  |  |  | Nombre. |
| `config` | jsonb | ✔ | `'{}'` |  | — |
| `secreto_ref` | text |  |  |  | referencia en Key Vault (nunca el valor) |
| `ruta_token` | text |  |  | UK | token de ruta del webhook (wh_...) |
| `estado` | text | ✔ | `'pendiente'` |  | Estado. · Valores: conectada, pendiente, pendiente_oauth, error, deshabilitada |
| `ultimo_test` | timestamptz |  |  |  | — |
| `ultimo_test_detalle` | jsonb |  |  |  | — |
| `creado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de creación. |
| `actualizado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de la última modificación. |

### `core.branch_map`

El mapa de ramas del flujo del cliente (una fila por tenant): patrón de feature, rama de staging y de producción (CHECK: distintas). Lo consumen Build (ramas/PRs) y Deploy (promociones).

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `tenant_id` | text | ✔ |  | PK, FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `feature_pattern` | text | ✔ | `'feature/*'` |  | — |
| `staging_branch` | text | ✔ | `'develop'` |  | — |
| `prod_branch` | text | ✔ | `'main'` |  | — |
| `actualizado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de la última modificación. |

### `core.notifications`

Notificaciones del portal por usuario (cambio de etapa, gate pendiente, cierre con evidencia, avisos de cuota, seguridad, sistema), con estado de lectura. El índice parcial de no leídas sirve el badge en O(filas no leídas).

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `id` | text | ✔ |  | PK | nt_<ulid> |
| `tenant_id` | text | ✔ |  | FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `user_id` | text | ✔ |  | FK→core.users | Referencia a core.users. |
| `tipo` | text | ✔ |  |  | Tipo. · Valores: cambio_etapa, gate_pendiente, ticket_cerrado, aviso_cuota, seguridad, sistema |
| `titulo` | text | ✔ |  |  | Título. |
| `cuerpo` | text |  |  |  | Cuerpo del mensaje. |
| `ticket_id` | text |  |  | FK→core.tickets | Referencia a core.tickets. |
| `leida` | boolean | ✔ | `false` |  | Indica si fue leída. |
| `creada_en` | timestamptz | ✔ | `now()` | PK | Fecha y hora de creación. |

### `core.retention_policies`

Política de retención de datos por organización y entidad (días de retención y acción). *Descripción derivada de sus columnas: la tabla no figura en el Modelo de Base de Datos.*

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `id` | text | ✔ | `('ret_' // substr(md5(((random()) // …` |  | Identificador de la fila. |
| `tenant_id` | text | ✔ |  | FK→org, PK | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `entity_name` | text | ✔ |  | PK | — |
| `retention_days` | integer | ✔ |  |  | — |
| `action` | text | ✔ | `'detach'` |  | Valores: detach, drop, archive |
| `is_active` | boolean | ✔ | `true` |  | — |
| `created_at` | timestamptz | ✔ | `now()` |  | Fecha y hora de creación. |
| `updated_at` | timestamptz | ✔ | `now()` |  | Fecha y hora de la última modificación. |

## Comercial y consumo

### `core.plans`

Catálogo comercial de planes (Starter, Growth, Enterprise). Define líneas concurrentes, cuota de LOC mensual, cupo de usuarios, almacenamiento y funciones habilitadas (p. ej. Kallicode Help). Los NULL significan «sin límite / a medida» (Enterprise). La aplicación solo la lee; los cambios de catálogo son operación administrativa.

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `codigo` | text | ✔ |  | PK | starter / growth / enterprise |
| `nombre` | text | ✔ |  |  | Nombre. |
| `lineas` | integer |  |  |  | NULL = ilimitadas |
| `loc_mes` | integer |  |  |  | NULL = a medida |
| `max_usuarios` | integer |  |  |  | NULL = ilimitados |
| `storage_mb` | integer |  |  |  | evidencia/adjuntos |
| `docs_mb` | integer |  |  |  | documentación del grafo |
| `permite_help` | boolean | ✔ | `false` |  | Kallicode Help como fuente |
| `despliegues` | text[] | ✔ | `'{cloud}'[]` |  | — |
| `creado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de creación. |

### `core.subscriptions`

Historial de suscripciones del tenant. La vigente es la que tiene finaliza_el IS NULL — garantizado único por índice parcial. renueva_el marca el inicio del próximo ciclo de consumo (las cuotas QU-1 se computan por ciclo 'YYYY-MM'). El estado (activa, periodo_gracia, suspendida) condiciona el login y el alcance del token.

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `id` | text | ✔ |  | PK | sub_<ulid> |
| `tenant_id` | text | ✔ |  | FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `plan_codigo` | text | ✔ |  | FK→core.plans | Referencia a core.plans. |
| `estado` | text | ✔ | `'activa'` |  | Estado. · Valores: activa, periodo_gracia, suspendida, finalizada |
| `inicia_el` | date | ✔ |  |  | — |
| `renueva_el` | date | ✔ |  |  | inicio del próximo ciclo |
| `finaliza_el` | date |  |  |  | NULL = vigente |
| `creado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de creación. |

### `core.upgrade_requests`

Solicitudes de mejora de plan con urgencia (automática si el tenant está en cuota agotada). Una abierta por tenant (índice único parcial).

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `id` | text | ✔ |  | PK | upg_<ulid> |
| `tenant_id` | text | ✔ |  | FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `plan_deseado` | text | ✔ |  | FK→core.plans | Referencia a core.plans. |
| `comentario` | text |  |  |  | — |
| `urgente` | boolean | ✔ | `false` |  | — |
| `estado` | text | ✔ | `'registrada'` |  | Estado. · Valores: registrada, en_gestion, aplicada, descartada |
| `solicitado_por` | text | ✔ |  | FK→core.users | Referencia a core.users. |
| `creado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de creación. |

### `core.usage_cycles`

Agregado por tenant y ciclo 'YYYY-MM' con el umbral precalculado. Lo mantiene el trigger T6 en la misma transacción que registra la LOC; la coherencia con el detalle se verifica con V10. Es la tabla que consulta CommercialGuard en cada creación de ticket y arranque de Build.

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `tenant_id` | text | ✔ |  | PK, FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `ciclo` | text | ✔ |  | PK | — |
| `loc_consumidas` | integer | ✔ | `0` |  | — |
| `umbral` | text | ✔ | `'normal'` |  | normal / aviso_80 / agotado · Valores: normal, aviso_80, agotado |
| `actualizado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de la última modificación. |
| `loc_netas` | integer | ✔ | `0` |  | KC-DB-05-3: suma real de usage_loc.netas del ciclo (un crédito mayor que lo consumido la deja negativa). loc_consumidas = greatest(loc_netas, 0). |

### `core.usage_loc`

El registro comercial: LOC del diff real de cada PR entregado (añadidas, eliminadas, netas, tests) — un registro por PR (índice único parcial sobre pr_url) — más los ajustes manuales (cortesías,

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `id` | bigint | ✔ |  | PK | Identificador de la fila. |
| `tenant_id` | text | ✔ |  | FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `ticket_id` | text |  |  | FK→core.tickets | Referencia a core.tickets. |
| `ciclo` | text | ✔ |  |  | 'YYYY-MM' |
| `tipo` | text | ✔ | `'pr'` |  | pr / ajuste · Valores: pr, ajuste |
| `pr_url` | text |  |  |  | — |
| `anadidas` | integer | ✔ | `0` |  | — |
| `eliminadas` | integer | ✔ | `0` |  | — |
| `netas` | integer | ✔ |  |  | — |
| `tests` | integer | ✔ | `0` |  | — |
| `motivo_ajuste` | text |  |  |  | — |
| `creado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de creación. |

### `core.usage_tokens`

Consumo de tokens por ticket, etapa y modelo (agregado desde llm_steps o escrito directamente por el orquestador). Alimenta la pestaña Consumo y el control interno de coste por tenant. No descuenta cuota: la métrica comercial es la LOC.

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `id` | bigint | ✔ |  | PK | Identificador de la fila. |
| `tenant_id` | text | ✔ |  | FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `ticket_id` | text | ✔ |  | FK→core.tickets | Referencia a core.tickets. |
| `etapa` | text | ✔ |  |  | Etapa del pipeline. |
| `modelo` | text | ✔ |  |  | — |
| `tier` | text | ✔ |  |  | Valores: flash, pro, fable |
| `invocaciones` | integer | ✔ | `1` |  | — |
| `tokens_in` | integer | ✔ |  |  | — |
| `tokens_out` | integer | ✔ |  |  | — |
| `duracion_ms` | integer | ✔ |  |  | — |
| `creado_en` | timestamptz | ✔ | `now()` | PK | Fecha y hora de creación. |

### `core.model_providers`

Llave por proveedor (anthropic, openai, google, deepseek_selfhosted) con la referencia a Key Vault, la máscara visible (••••4Jx2), la base_url para el despliegue soberano (obligatoria por CHECK) y el catálogo de modelos disponibles detectado en el test.

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `tenant_id` | text | ✔ |  | PK, FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `proveedor` | text | ✔ |  | PK | Valores: anthropic, openai, google, deepseek_selfhosted |
| `llave_ref` | text |  |  |  | Key Vault |
| `llave_mascara` | text |  |  |  | ••••4Jx2 |
| `base_url` | text |  |  |  | self-hosted |
| `estado` | text | ✔ | `'sin_configurar'` |  | Estado. · Valores: valida, invalida, sin_configurar |
| `modelos_disponibles` | jsonb | ✔ | `'[]'` |  | — |
| `ultimo_test` | timestamptz |  |  |  | — |
| `actualizado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de la última modificación. |

### `core.model_assignments`

Una fila por función del pipeline (triage, design, build, qa, security, deploy) con modelo principal y fallback. Las FKs compuestas garantizan que solo se asignen proveedores con llave registrada del propio tenant; el CHECK impide que principal y fallback sean idénticos.

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `tenant_id` | text | ✔ |  | FK→org, PK | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `funcion` | text | ✔ |  | PK | Valores: triage, design, build, qa, security, deploy |
| `principal_proveedor` | text | ✔ |  | FK→core.model_providers | Referencia a core.model_providers. |
| `principal_modelo` | text | ✔ |  |  | — |
| `fallback_proveedor` | text | ✔ |  | FK→core.model_providers | Referencia a core.model_providers. |
| `fallback_modelo` | text | ✔ |  |  | — |
| `actualizado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de la última modificación. |

## Tickets y pipeline

### `core.tickets`

Tabla central del portal: bugs, mejoras, funcionalidades y tickets de seguridad, con su origen (portal, jira, github, kallicode_help, corestream), prioridad declarada y prioridad de pipeline (P1–P4, la fija Triage), etapa visible, gate pendiente, radio de impacto (JSONB), duplicado_de y el vínculo con el usuario final de Kallicode Help para las notificaciones de vuelta. Los CHECK garantizan estados válidos, que un cancelado tenga motivo y que un ticket no sea duplicado de sí mismo.

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `id` | text | ✔ |  | UK, PK | tk_<ulid> (interno) |
| `tenant_id` | text | ✔ |  | UK, FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `numero` | text |  |  | UK | KC-#### (lo asigna trigger) |
| `tipo` | text | ✔ |  |  | Tipo. · Valores: bug, mejora, funcionalidad, seguridad |
| `titulo` | text | ✔ |  |  | Título. |
| `descripcion` | text | ✔ |  |  | Descripción. |
| `prioridad` | text | ✔ | `'media'` |  | declarada (alta/media/baja) · Valores: alta, media, baja |
| `prioridad_pipeline` | text |  |  |  | P1..P4 (la fija Triage) · Valores: P1, P2, P3, P4 |
| `etapa` | text | ✔ | `'triage'` |  | Etapa del pipeline. · Valores: triage, design, build, qa, security, deploy, produccion, en_cola_por_cuota, cancelado, cerrado_duplicado |
| `gate_pendiente` | smallint |  |  |  | 1/2/3 o NULL · Valores: 1, 2, 3 |
| `origen` | text | ✔ | `'portal'` |  | Valores: portal, jira, github, kallicode_help, corestream |
| `origen_ref` | jsonb |  |  |  | payload/clave del sistema origen |
| `reportado_por` | text |  |  | FK→core.users | NULL si origen externo |
| `usuario_final` | jsonb |  |  |  | {id_externo, canal} de Kallicode Help |
| `modulo_pista` | text |  |  |  | — |
| `duplicado_de` | text |  |  | FK→core.tickets | Referencia a core.tickets. |
| `impacto` | jsonb |  |  |  | {modulos[], tablas[], radio, riesgo_regresion} |
| `complejidad` | text |  |  |  | Valores: trivial, small, medium, large |
| `pr_url` | text |  |  |  | — |
| `fecha_objetivo` | date |  |  |  | — |
| `motivo_cancelacion` | text |  |  |  | — |
| `cancelado_por` | text |  |  | FK→core.users | Referencia a core.users. |
| `creado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de creación. |
| `actualizado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de la última modificación. |
| `cerrado_en` | timestamptz |  |  |  | Fecha y hora de cierre. |

### `core.ticket_attachments`

Adjuntos del usuario y evidencia: el binario vive en Blob Storage (blob_ref); aquí quedan metadatos, clase (usuario, evidencia, documento) y el resultado del escaneo antimalware. ticket_id admite NULL para el flujo de subida en dos pasos (URL firmada primero, asociación después); los huérfanos de más de 48 h se purgan (chequeo V19).

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `id` | text | ✔ |  | PK | att_<ulid> |
| `tenant_id` | text | ✔ |  | FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `ticket_id` | text |  |  | FK→core.tickets | NULL = pendiente de asociar |
| `nombre_archivo` | text | ✔ |  |  | Nombre del archivo. |
| `content_type` | text | ✔ |  |  | Tipo MIME del archivo. |
| `tamano_bytes` | bigint | ✔ |  |  | Tamaño en bytes. |
| `blob_ref` | text | ✔ |  |  | ruta en Blob Storage |
| `clase` | text | ✔ | `'usuario'` |  | usuario / evidencia / documento · Valores: usuario, evidencia, documento |
| `escaneo` | text | ✔ | `'pendiente'` |  | Valores: pendiente, limpio, infectado |
| `subido_por` | text |  |  | FK→core.users | Referencia a core.users. |
| `creado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de creación. |

### `core.ticket_counters`

Contador del correlativo KC-#### por tenant. El trigger T2 hace UPDATE ... RETURNING sobre esta fila (bloqueo de fila): dos inserciones concurrentes jamás obtienen el mismo número. Arranca en 1000 para que el primer ticket sea KC-1001.

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `tenant_id` | text | ✔ |  | FK→org, PK | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `ultimo` | integer | ✔ | `1000` |  | — |

### `core.ticket_watchers`

Visualizadores del ticket (N:M usuarios⇄tickets). El trigger T10 suscribe automáticamente al creador y prohíbe eliminarlo: siempre recibe el cierre con la evidencia.

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `tenant_id` | text | ✔ |  | FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `ticket_id` | text | ✔ |  | PK, FK→core.tickets | Referencia a core.tickets. |
| `user_id` | text | ✔ |  | PK, FK→core.users | Referencia a core.users. |
| `creado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de creación. |

### `core.webhook_inbox`

Bandeja de entrada de webhooks: payload crudo JSONB, delivery_id del proveedor (UNIQUE por conexión: los reintentos del origen son idempotentes) y estado de normalización (pendiente,

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `id` | bigint | ✔ |  | PK | Identificador de la fila. |
| `tenant_id` | text | ✔ |  | FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `connection_id` | text | ✔ |  | UK, FK→core.connections | Referencia a core.connections. |
| `delivery_id` | text | ✔ |  | UK | — |
| `evento` | text |  |  |  | — |
| `payload` | jsonb | ✔ |  |  | Contenido recibido (JSON). |
| `estado` | text | ✔ | `'pendiente'` |  | Estado. · Valores: pendiente, procesado, ignorado, fallido |
| `error_detalle` | text |  |  |  | — |
| `ticket_id` | text |  |  | FK→core.tickets | Referencia a core.tickets. |
| `recibido_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de recepción. |
| `procesado_en` | timestamptz |  |  |  | Fecha y hora de procesamiento. |
| `recibido_mes` | date | ✔ | `(date_trunc('month', (now() AT TIME Z…` | UK, PK | — |

### `core.specs`

Versiones de spec por ticket (UNIQUE ticket+version): narrativa en Blob (spec_md_ref), alcance autorizado scope_paths (el límite duro que Build no puede cruzar), plan de tests, migraciones con rollback, borrador de ADR y estimación de LOC para el aviso preventivo de cuota. El estado transita pendiente_gate1 → aprobada | reemplazada | rechazada; el resto de columnas queda congelado por el trigger T4.

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `id` | text | ✔ |  | UK, PK | sp_<ulid> |
| `tenant_id` | text | ✔ |  | UK, FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `ticket_id` | text | ✔ |  | UK, FK→core.tickets | Referencia a core.tickets. |
| `version` | integer | ✔ |  | UK | — |
| `estado` | text | ✔ | `'pendiente_gate1'` |  | Estado. · Valores: pendiente_gate1, aprobada, reemplazada, rechazada |
| `spec_md_ref` | text | ✔ |  |  | narrativa en Blob |
| `scope_paths` | text[] | ✔ |  |  | — |
| `plan_tests` | jsonb |  |  |  | — |
| `migraciones` | jsonb |  |  |  | — |
| `adr_borrador` | jsonb |  |  |  | — |
| `estimacion_loc` | integer |  |  |  | — |
| `creado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de creación. |

### `core.spec_alternatives`

Las 1–3 alternativas de diseño de cada spec con su riesgo. Dos índices únicos parciales garantizan exactamente una recomendada (la propone el agente) y como máximo una elegida (la marca la firma del Gate 1).

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `spec_id` | text | ✔ |  | PK, FK→core.specs | Referencia a core.specs. |
| `tenant_id` | text | ✔ |  | FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `alt_id` | text | ✔ |  | PK | 'A' / 'B' / 'C' |
| `titulo` | text | ✔ |  |  | Título. |
| `descripcion` | text | ✔ |  |  | Descripción. |
| `riesgo` | text | ✔ |  |  | Valores: bajo, medio, alto |
| `recomendada` | boolean | ✔ | `false` |  | — |
| `elegida` | boolean | ✔ | `false` |  | la marca el Gate 1 |

### `core.spec_criteria`

Criterios de aceptación Given/When/Then, con id normalizado AC-n (CHECK con expresión regular). Son el contrato que QA verifica de forma independiente: la matriz de evidencia referencia estos criterio_id (chequeos V07/V08).

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `spec_id` | text | ✔ |  | FK→core.specs, PK | Referencia a core.specs. |
| `tenant_id` | text | ✔ |  | FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `criterio_id` | text | ✔ |  | PK | AC-1, AC-2... |
| `given_txt` | text | ✔ |  |  | — |
| `when_txt` | text | ✔ |  |  | — |
| `then_txt` | text | ✔ |  |  | — |

### `core.jobs`

Un job por pasada de un ticket por el pipeline: estado (etapas + gates + pausas + terminales), línea asignada (FK compuesta a production_lines), prioridad P1–P4, contador de iteraciones por etapa (JSONB) y el contexto de la última transición (p. ej. el diagnóstico de QA que Build recibe). El estado del job es la fuente de verdad; la etapa del ticket es su proyección (T9).

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `id` | text | ✔ |  | UK, PK | job_<ulid> |
| `tenant_id` | text | ✔ |  | UK, FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `ticket_id` | text | ✔ |  | FK→core.tickets | Referencia a core.tickets. |
| `estado` | text | ✔ | `'pendiente_asignacion'` |  | Estado. · Valores: pendiente_asignacion, triage, design, gate1, build, qa, gate2, security, deploy_preflight, gate3, deploy, produccion, pausado_por_cuota, escalado_humano, cancelado, cerrado_duplicado |
| `linea` | integer |  |  | FK→core.production_lines | Referencia a core.production_lines. |
| `prioridad` | text | ✔ |  |  | Prioridad. · Valores: P1, P2, P3, P4 |
| `iteraciones` | jsonb | ✔ | `'{}'` |  | {"design":2,"build":1,...} |
| `contexto` | jsonb |  |  |  | payload de la última transición |
| `creado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de creación. |
| `actualizado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de la última modificación. |
| `terminado_en` | timestamptz |  |  |  | Fecha y hora de término. |

### `core.job_transitions`

Historial completo de transiciones del job. El trigger T8 inserta una fila en cada cambio de estado aunque la aplicación no lo haga (defensa en profundidad); la app añade motivo y contexto. Es la base de la cronología visible en la pestaña Actividad.

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `id` | bigint | ✔ |  | PK | Identificador de la fila. |
| `tenant_id` | text | ✔ |  | FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `job_id` | text | ✔ |  | FK→core.jobs | Referencia a core.jobs. |
| `de_estado` | text | ✔ |  |  | — |
| `a_estado` | text | ✔ |  |  | — |
| `motivo` | text |  |  |  | Motivo. |
| `contexto` | jsonb |  |  |  | — |
| `actor` | text | ✔ | `'sistema'` |  | sistema / svc:<agente> / user:<id> |
| `creado_en` | timestamptz | ✔ | `now()` | PK | Fecha y hora de creación. |

### `core.llm_steps`

Cada ejecución de un paso de cadena de prompts: plantilla y versión, modelo y tier efectivos (pro, flash, vision), confianza, resultado de la validación de esquema, reintentos, tokens y duración, con referencias a los payloads completos en Blob. Alimenta tres vistas a la vez: la pestaña Consumo, el expediente de auditoría paso a paso y las métricas de observabilidad.

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `id` | text | ✔ |  | PK | st_<ulid> |
| `tenant_id` | text | ✔ |  | FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `job_id` | text | ✔ |  | FK→core.jobs | Referencia a core.jobs. |
| `ticket_id` | text | ✔ |  | FK→core.tickets | Referencia a core.tickets. |
| `etapa` | text | ✔ |  |  | Etapa del pipeline. · Valores: triage, design, build, qa, security, deploy |
| `paso` | text | ✔ |  |  | p. ej. triage.classify |
| `version_plantilla` | text | ✔ |  |  | — |
| `modelo` | text | ✔ |  |  | — |
| `tier` | text | ✔ |  |  | Valores: flash, pro, fable |
| `confianza` | numeric(4,3) |  |  |  | — |
| `validacion` | text | ✔ |  |  | Valores: esquema_valido, reintento, escalado_tier, escalado_humano |
| `reintentos` | smallint | ✔ | `0` |  | — |
| `tokens_in` | integer | ✔ |  |  | — |
| `tokens_out` | integer | ✔ |  |  | — |
| `duracion_ms` | integer | ✔ |  |  | — |
| `entrada_ref` | text | ✔ |  |  | Blob |
| `salida_ref` | text | ✔ |  |  | Blob |
| `creado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de creación. |

### `core.escalations`

Cola de intervención humana del equipo Kallicode: dónde se detuvo la máquina (job, etapa, paso), por qué (validación persistente, baja confianza, máx. iteraciones, reparación de selector, anomalía de deploy) y con qué severidad. Un escalado abierto por job y paso (índice único parcial).

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `id` | text | ✔ |  | PK | esc_<ulid> |
| `tenant_id` | text | ✔ |  | FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `job_id` | text | ✔ |  | FK→core.jobs | Referencia a core.jobs. |
| `etapa` | text | ✔ |  |  | Etapa del pipeline. |
| `paso` | text |  |  |  | Paso dentro de la etapa. |
| `motivo` | text | ✔ |  |  | Motivo. · Valores: validacion_persistente, baja_confianza, max_iteraciones, selector_repair, anomalia_deploy, otro |
| `severidad` | text | ✔ |  |  | Severidad. · Valores: baja, media, alta, critica |
| `detalle` | jsonb | ✔ |  |  | — |
| `estado` | text | ✔ | `'abierta'` |  | Estado. · Valores: abierta, en_curso, resuelta |
| `resuelto_por` | text |  |  |  | — |
| `resuelto_en` | timestamptz |  |  |  | Fecha y hora de resolución. |
| `creado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de creación. |

### `core.production_lines`

Una fila por línea contratada del tenant (PK compuesta tenant_id+numero). El estado (disponible, ocupada, mantenimiento) y el job_id que la ocupa los sincroniza el trigger T7 desde core.jobs — la tabla es la vista operable de la capacidad, pero la fuente de verdad de la asignación es jobs.linea con su índice único parcial. El CHECK lines_coherencia_chk impide estados imposibles (ocupada sin job y viceversa).

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `tenant_id` | text | ✔ |  | PK, FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `numero` | integer | ✔ |  | PK | — |
| `estado` | text | ✔ | `'disponible'` |  | Estado. · Valores: disponible, ocupada, mantenimiento |
| `job_id` | text |  |  | FK→core.jobs | FK diferida: se añade tras crear jobs |
| `creado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de creación. |
| `actualizado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de la última modificación. |

## Calidad, gates y evidencia

### `core.qa_runs`

Corridas completas de QA por ticket (correlativo por ticket), ancladas a la versión de spec que verifican. Guardan el resumen de la regresión dirigida por el grafo y de la suite del cliente, y los casos flaky en cuarentena.

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `id` | text | ✔ |  | UK, PK | qr_<ulid> |
| `tenant_id` | text | ✔ |  | FK→org, UK | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `ticket_id` | text | ✔ |  | FK→core.tickets, UK | Referencia a core.tickets. |
| `spec_id` | text | ✔ |  | FK→core.specs | Referencia a core.specs. |
| `corrida` | integer | ✔ |  | UK | — |
| `regresion` | jsonb | ✔ |  |  | {dirigidos, dirigidos_ok, suite_cliente, cliente_ok} |
| `flaky` | jsonb | ✔ | `'[]'` |  | — |
| `ejecutada_en` | timestamptz | ✔ | `now()` |  | — |

### `core.qa_results`

La matriz criterio a criterio: resultado (pasa, falla, flaky — un fallo exige extracto literal), veredicto del checkpoint de visión y referencias a la evidencia inmutable en Blob (screenshots, video, traces con object-lock/WORM). Sobre esta matriz se firma el Gate 2.

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `qa_run_id` | text | ✔ |  | FK→core.qa_runs, PK | Referencia a core.qa_runs. |
| `tenant_id` | text | ✔ |  | FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `criterio_id` | text | ✔ |  | PK | AC-n de la spec |
| `resultado` | text | ✔ |  |  | Valores: pasa, falla, flaky |
| `extracto_fallo` | text |  |  |  | — |
| `veredicto_visual` | jsonb |  |  |  | {veredicto, observado, region} |
| `evidencias` | jsonb | ✔ | `'[]'` |  | [{tipo, blob_ref}] |

### `core.security_findings`

Hallazgos de los escáneres deterministas (SAST, SCA, secretos) con la evaluación contextual del agente: severidad en este sistema, veredicto (confirmado o falso positivo), fix propuesto y si bloquea el deploy. El CHECK sf_justif_chk obliga a justificar todo falso positivo o descarte — el registro de compliance también vive en el modelo.

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `id` | text | ✔ |  | PK | sf_<ulid> |
| `tenant_id` | text | ✔ |  | FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `ticket_id` | text | ✔ |  | FK→core.tickets | Referencia a core.tickets. |
| `origen` | text | ✔ |  |  | sast / sca / secrets · Valores: sast, sca, secrets |
| `regla` | text |  |  |  | — |
| `archivo` | text |  |  |  | — |
| `linea` | integer |  |  |  | — |
| `severidad` | text | ✔ |  |  | Severidad. · Valores: critica, alta, media, baja |
| `titulo` | text | ✔ |  |  | Título. |
| `veredicto` | text | ✔ |  |  | Valores: confirmado, falso_positivo |
| `justificacion` | text |  |  |  | — |
| `fix_diff_ref` | text |  |  |  | Blob |
| `bloquea` | boolean | ✔ | `false` |  | — |
| `estado` | text | ✔ | `'abierto'` |  | Estado. · Valores: abierto, corregido, descartado |
| `creado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de creación. |
| `actualizado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de la última modificación. |

### `core.gate_signatures`

Firmas y devoluciones de los tres gates: actor humano, comentario (que re-entra como contexto del agente), alternativa elegida (Gate 1), aceptación explícita de fallos (Gate 2), etapa de devolución (Gate 3) y el sello hash del evento de auditoría correspondiente — la firma y su registro inmutable quedan enlazados. gate_aprobado_uq impide la doble aprobación; las devoluciones (cambios_pedidos) pueden repetirse hasta el límite de iteraciones.

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `id` | text | ✔ |  | PK | gs_<ulid> |
| `tenant_id` | text | ✔ |  | FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `ticket_id` | text | ✔ |  | FK→core.tickets | Referencia a core.tickets. |
| `gate` | smallint | ✔ |  |  | Valores: 1, 2, 3 |
| `accion` | text | ✔ |  |  | aprobado / cambios_pedidos · Valores: aprobado, cambios_pedidos |
| `actor_id` | text | ✔ |  | FK→core.users | Referencia a core.users. |
| `comentario` | text |  |  |  | — |
| `alternativa_id` | text |  |  |  | Gate 1 |
| `acepta_fallos` | boolean | ✔ | `false` |  | Gate 2 |
| `devolver_a` | text |  |  |  | Gate 3: design/build/qa · Valores: design, build, qa |
| `spec_id` | text |  |  | FK→core.specs | versión firmada (Gate 1) |
| `sello` | text | ✔ |  |  | hash del evento de auditoría |
| `creado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de creación. |

### `core.audit_exports`

Exportaciones asíncronas de auditoría (CSV global con filtros o PDF de expediente — el CHECK exige ticket para PDF), con estado y referencia al archivo generado en Blob.

| Columna | Tipo | NN | Por defecto | Claves | Descripción |
|---|---|:-:|---|---|---|
| `id` | text | ✔ |  | PK | exp_<ulid> |
| `tenant_id` | text | ✔ |  | FK→org | Organización (tenant) dueña de la fila; base del aislamiento RLS. |
| `formato` | text | ✔ |  |  | Valores: csv, pdf |
| `ticket_id` | text |  |  | FK→core.tickets | Referencia a core.tickets. |
| `filtros` | jsonb |  |  |  | — |
| `estado` | text | ✔ | `'encolada'` |  | Estado. · Valores: encolada, procesando, lista, fallida |
| `blob_ref` | text |  |  |  | Referencia al objeto en Blob Storage. |
| `solicitado_por` | text | ✔ |  | FK→core.users | Referencia a core.users. |
| `creado_en` | timestamptz | ✔ | `now()` |  | Fecha y hora de creación. |
| `completado_en` | timestamptz |  |  |  | — |

## Esquemas `cm`, `vec` y `audit` (nivel de tabla)

| Tabla | Propósito |
|---|---|
| `audit.audit_events` | Cada decisión — humana, de agente o del sistema — con su resumen visible, payload estructurado, modelo si aplica y el sello hash encadenado: sello = SHA-256(sello_previo ‖ canónico del evento), calculado por el trigger T3 en el INSERT. Alterar un evento rompe todos los siguientes (verificable con audit.verify_chain y V16). Deliberadamente sin FKs a tickets/jobs: la auditoría sobrevive a cualquier borrado. |
| `audit.chain_heads` | La cabeza de cadena por tenant: último sello y contador de eventos. El trigger T3 la actualiza con bloqueo de fila, serializando el cálculo del hash — la cadena jamás se bifurca aunque haya escrituras concurrentes. Su coherencia con el último evento se verifica con V17. |
| `cm.concepts` | Capa semántica: conceptos de negocio, con curación humana. |
| `cm.curation_queue` | Cola de curación humana del conocimiento generado. |
| `cm.db_columns` | Columnas de las tablas de la base del cliente. |
| `cm.db_tables` | Tablas de la base de datos del cliente (capa determinista, fase 3). |
| `cm.definitions` | Capa semántica: definiciones técnicas generadas con LLM (fase 4). |
| `cm.edges` | Aristas del grafo en una sola tabla genérica; src_kind/dst_kind identifican el tipo de cada extremo (sin FK, el destino varía). |
| `cm.files` | Archivos del repositorio del cliente (capa determinista, fases 1-2 de CodeMapping). |
| `cm.incidents` | Historial de incidentes del cliente vinculado a tickets (épica ECM5). |
| `cm.nodes` | Un registro por nodo del grafo, con su tipo (kind). |
| `cm.nuggets` | Reglas o conocimiento puntual del dominio (épica ECM5). |
| `cm.repo_snapshots` | Snapshots de ingesta: una fila por corrida (completa o refresco). El grafo de un snapshot no se considera vigente hasta estado = 'completo'. |
| `cm.snapshot_vigente` | Puntero al snapshot vigente: una fila por tenant. |
| `cm.symbols` | Símbolos (funciones, clases) de cada archivo (capa determinista). |
| `vec.definition_embeddings` | La capa semántica de CodeMapping consultable por similitud: definiciones, conceptos de negocio y símbolos de código, cada uno con la referencia a su nodo del grafo (Neo4j). Respalda el impact- preview en vivo y la recuperación en dos fases (vector amplio → expansión exacta en el grafo). |
| `vec.doc_chunks` | Chunks de la documentación ingerida con su embedding y metadatos de localización (sección, página). Base de la recuperación amplia de la etapa Diseño y del contexto documental del grafo. |
| `vec.ticket_embeddings` | Un embedding por ticket (1:1) para la deduplicación vectorial de Triage y el panel de duplicados en vivo del formulario. texto_hash evita re-embeber si el texto no cambió. Consulta típica: ORDER BY embedding <=> :query LIMIT k con filtro por tenant. |

## Tablas técnicas y catálogos globales

| Tabla | Propósito |
|---|---|
| `core.schema_migrations` | Registro del runner de migraciones: archivo, sha256 y fecha de aplicación. |
| `core.retencion_particiones` | Control interno de la retención de particiones (pg_partman). |
| `core.idempotency_keys` | Claves de idempotencia: evitan procesar dos veces la misma petición. |
| `vec.acta_conversion_capa` | Registro de una conversión de datos ejecutada por una migración. |
| `cm.node_types` | Catálogo global de tipos de nodo del grafo. |
| `cm.edge_types` | Catálogo global de tipos de arista del grafo. |

---

**Cobertura:** 36 tablas y 355 columnas documentadas; 280 con descripción de fuente y 75 marcadas "—" (sin documentación en ninguna fuente).
