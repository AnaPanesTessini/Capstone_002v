-- KalliCode · Esquema consolidado (DDL)
-- Generado concatenando los scripts del repo kallicode-backend, sin modificarlos.
-- Rama: develop · Commit: f04519f · Fecha: 2026-10-28
-- Orden de aplicación: db/00..05 (esquema basal) y luego db/migrations/NNN en orden alfabético (runner packages/core/migrate.py).

-- ================================================================
-- ARCHIVO: db/00_extensiones.sql
-- ================================================================
-- ============================================================================
-- KALLICODE · 00_extensiones.sql — Extensiones de PostgreSQL (KC-DB-01-5)
-- Junto con 00_roles.sql, es lo ÚNICO que requiere superusuario. Todo lo
-- demás (01..05.sql y db/migrations/) lo aplica kallicode_admin.
--
-- Nota Azure: habilitar las extensiones en el servidor antes de ejecutar:
--   az postgres flexible-server parameter set --name azure.extensions \
--      --value vector,pg_trgm ...
-- Los hashes usan la función nativa sha256() (PostgreSQL >= 11): sin extensión.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;   -- búsqueda de texto en títulos
CREATE EXTENSION IF NOT EXISTS vector  WITH SCHEMA public;   -- pgvector: embeddings

-- pg_stat_statements (KC-DB-06-1): mide qué consultas cuestan más y qué índices se usan; la lee
-- db/tools/informe_indices.sql. Para que recoja datos Postgres debe arrancar con
-- shared_preload_libraries = pg_stat_statements (ver docker-compose.yml); sin eso la extensión
-- existe pero no registra nada. La creación es opcional: si el servidor no la ofrece (en Azure
-- debe estar permitida en azure.extensions) el arranque NO falla y el informe omite esas secciones.
DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA public;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_stat_statements no disponible (%): el informe de indices omitira las consultas costosas', SQLERRM;
END $$;

-- pg_partman (KC-DB-07-1): crea y mantiene las particiones mensuales de audit.audit_events
-- (db/migrations/033_particion_auditoria.sql). Requiere una imagen/servidor que la incluya
-- (db/postgres/Dockerfile; en Azure, permitirla en azure.extensions y, para el mantenimiento
-- automático, pg_partman_bgw en shared_preload_libraries). Si no está disponible el arranque
-- NO falla, pero la migración 033 se negará a aplicarse con un mensaje explícito.
-- kallicode_admin (dueño del esquema, no superusuario) la opera sin privilegios especiales.
DO $$
BEGIN
    CREATE SCHEMA IF NOT EXISTS partman;
    CREATE EXTENSION IF NOT EXISTS pg_partman WITH SCHEMA partman;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_partman no disponible (%): la migracion 033 (particionado de audit_events) no podra aplicarse', SQLERRM;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_partman')
       AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kallicode_admin') THEN
        GRANT USAGE, CREATE ON SCHEMA partman TO kallicode_admin;
        GRANT ALL ON ALL TABLES IN SCHEMA partman TO kallicode_admin;
        GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA partman TO kallicode_admin;
        GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA partman TO kallicode_admin;
    END IF;
END $$;

-- Particiones sin acceso para la aplicación (KC-DB-07-2, reforzado en KC-DB-07-3).
-- 04_rls.sql concede por defecto SELECT/INSERT/UPDATE/DELETE a kallicode_app sobre TODA tabla nueva
-- de core y vec, y una partición es una tabla nueva. Pero la política RLS vive en la tabla padre:
-- una partición no la hereda, y quien tenga permiso sobre ella la leería ENTERA, de todos los
-- tenants. La aplicación solo debe llegar a las particiones a través del padre. Este event trigger
-- (necesita superusuario, por eso está aquí) quita todo acceso a kallicode_app y kallicode_worker
-- a las particiones de core y vec, también las que cree pg_partman_bgw cada mes.
-- pg_partman crea las particiones de dos maneras: CREATE TABLE ... PARTITION OF (la tabla ya es
-- partición al terminar el comando) o CREATE TABLE suelta + ALTER TABLE padre ATTACH PARTITION
-- (en el CREATE todavía no lo es, y el comando del ATTACH reporta al PADRE). Por eso el trigger
-- mira el objeto del comando y, si es una tabla particionada, sus particiones.
CREATE OR REPLACE FUNCTION public.kc_revocar_acceso_particiones() RETURNS event_trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT DISTINCT c.oid::regclass::text AS tabla
          FROM pg_event_trigger_ddl_commands() d
          JOIN pg_class k ON k.oid = d.objid
          JOIN pg_class c ON c.oid = k.oid
                          OR c.oid IN (SELECT i.inhrelid FROM pg_inherits i WHERE i.inhparent = k.oid)
         WHERE d.object_type = 'table' AND d.schema_name IN ('core', 'vec') AND c.relispartition
           AND (has_table_privilege('kallicode_app', c.oid, 'SELECT, INSERT, UPDATE, DELETE')
                OR has_table_privilege('kallicode_worker', c.oid, 'SELECT, INSERT, UPDATE, DELETE'))
    LOOP
        EXECUTE format('REVOKE ALL ON TABLE %s FROM kallicode_app, kallicode_worker', r.tabla);
    END LOOP;
END $$;

DROP EVENT TRIGGER IF EXISTS kc_particiones_sin_acceso;
CREATE EVENT TRIGGER kc_particiones_sin_acceso ON ddl_command_end
    WHEN TAG IN ('CREATE TABLE', 'ALTER TABLE')
    EXECUTE FUNCTION public.kc_revocar_acceso_particiones();


-- ================================================================
-- ARCHIVO: db/00_roles.sql
-- ================================================================
-- ============================================================================
-- KALLICODE · 00_roles.sql — Roles de base de datos y su modelo de privilegios
-- KC-DB-01-5 (EDB2). Única fuente de los roles: CI, Makefile y entornos lo
-- ejecutan igual. Reejecutable: crea lo que falta y reajusta los atributos.
--
-- Rol               Lo usa                   RLS        Atributos
-- ----------------  -----------------------  ---------  -------------------------
-- kallicode_app     API (apps/api)           sujeto     LOGIN
-- kallicode_worker  workers (apps/workers)   sujeto     LOGIN (+ política de colas)
-- kallicode_admin   migraciones y soporte    BYPASSRLS  LOGIN, dueño del esquema
--
-- Cada rol es su propio usuario de login. Ninguno es superusuario ni puede
-- crear bases o roles. El ÚNICO rol con BYPASSRLS es kallicode_admin.
--
-- kallicode_worker NO tiene BYPASSRLS: ve todos los tenants solo en las 5
-- tablas de cola (webhook_inbox, jobs, refresh_tokens, ticket_attachments,
-- idempotency_keys) gracias a la política worker_colas, y no tiene GRANT
-- sobre ninguna otra tabla. Ver db/migrations/010_rol_worker.sql (KC-DB-02-2).
--
-- Ejecutar como superusuario, con las contraseñas como variables de psql
-- (nunca se escriben en este archivo):
--   psql -v ON_ERROR_STOP=1 -v pw_app=... -v pw_worker=... -v pw_admin=... \
--        -d <base> -f db/00_roles.sql
-- ============================================================================


\if :{?pw_app}
\else
  \echo 'ERROR: falta -v pw_app=<contraseña de kallicode_app>'
  SELECT 1/0 AS falta_pw_app;
\endif
\if :{?pw_worker}
\else
  \echo 'ERROR: falta -v pw_worker=<contraseña de kallicode_worker>'
  SELECT 1/0 AS falta_pw_worker;
\endif
\if :{?pw_admin}
\else
  \echo 'ERROR: falta -v pw_admin=<contraseña de kallicode_admin>'
  SELECT 1/0 AS falta_pw_admin;
\endif

BEGIN;

-- 1. Crear los roles que no existan (los roles son de todo el clúster).
SELECT format('CREATE ROLE %I', r)
  FROM unnest(ARRAY['kallicode_app', 'kallicode_worker', 'kallicode_admin']) AS r
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r)
\gexec

-- Rol de login no privilegiado para las pruebas de aislamiento RLS.
SELECT format('CREATE ROLE %I LOGIN IN ROLE kallicode_app', 'kallicode_dev')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kallicode_dev')
\gexec

-- 2. Fijar SIEMPRE los atributos: converge aunque el rol existiera con otros
--    (01_schema.sql antiguo los creaba NOLOGIN; el Makefile, con LOGIN).
ALTER ROLE kallicode_app    LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE
                            PASSWORD :'pw_app';
ALTER ROLE kallicode_worker LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE
                            PASSWORD :'pw_worker';
ALTER ROLE kallicode_admin  LOGIN NOSUPERUSER BYPASSRLS   NOCREATEDB NOCREATEROLE
                            PASSWORD :'pw_admin';
ALTER ROLE kallicode_dev    LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE
                            INHERIT PASSWORD :'pw_app';
GRANT kallicode_app TO kallicode_dev;

-- 3. Privilegios sobre la base actual: todos conectan; solo el admin crea
--    esquemas (core, vec, audit, cm).
SELECT format('GRANT CONNECT ON DATABASE %I TO kallicode_app, kallicode_worker, kallicode_admin',
              current_database())
\gexec
SELECT format('GRANT CREATE ON DATABASE %I TO kallicode_admin', current_database())
\gexec

COMMIT;

-- ================================================================
-- ARCHIVO: db/01_schema.sql
-- ================================================================
-- ============================================================================
-- KALLICODE · Modelo de datos operacional
-- 01_schema.sql — Esquemas, tipos y tablas con constraints
-- PostgreSQL 16 (Azure Database for PostgreSQL Flexible Server) + pgvector
--
-- Requisitos (KC-DB-01-5): aplicar antes, como superusuario, db/00_roles.sql
-- (kallicode_app, kallicode_worker, kallicode_admin) y db/00_extensiones.sql
-- (pg_trgm, vector). Este script y los siguientes los aplica kallicode_admin,
-- que queda como dueño del esquema; ninguna sentencia requiere superusuario.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- Esquemas
-- ----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS core;    -- estado operacional
CREATE SCHEMA IF NOT EXISTS vec;     -- colecciones vectoriales (pgvector)
CREATE SCHEMA IF NOT EXISTS audit;   -- auditoría inmutable (append-only)

-- ----------------------------------------------------------------------------
-- Función de contexto de tenant (usada por RLS y por defecto de columnas)
-- La API ejecuta al abrir cada transacción:
--   SET LOCAL app.tenant_id = '<org del JWT>';
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.current_tenant() RETURNS text
LANGUAGE sql STABLE AS
$$ SELECT current_setting('app.tenant_id', true) $$;

-- ============================================================================
-- CATÁLOGOS GLOBALES (sin tenant_id, sin RLS)
-- ============================================================================

-- Planes comerciales: catálogo global que parametriza la validación comercial.
CREATE TABLE core.plans (
    codigo            text PRIMARY KEY,                  -- starter | growth | enterprise
    nombre            text NOT NULL,
    lineas            integer,                           -- NULL = ilimitadas
    loc_mes           integer,                           -- NULL = a medida
    max_usuarios      integer,                           -- NULL = ilimitados
    storage_mb        integer,                           -- evidencia/adjuntos
    docs_mb           integer,                           -- documentación del grafo
    permite_help      boolean NOT NULL DEFAULT false,    -- Kallicode Help como fuente
    despliegues       text[]  NOT NULL DEFAULT '{cloud}',
    creado_en         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT plans_lineas_chk  CHECK (lineas  IS NULL OR lineas  > 0),
    CONSTRAINT plans_loc_chk     CHECK (loc_mes IS NULL OR loc_mes > 0)
);

INSERT INTO core.plans (codigo, nombre, lineas, loc_mes, max_usuarios, storage_mb, docs_mb, permite_help, despliegues) VALUES
  ('starter',    'Starter',    1,    3000, 5,    5120,   200,  false, '{cloud}'),
  ('growth',     'Growth',     3,    8000, 25,   25600,  1024, true,  '{cloud,hibrido}'),
  ('enterprise', 'Enterprise', NULL, NULL, NULL, NULL,   NULL, true,  '{cloud,hibrido,onprem}');

-- Ledger de migraciones (D06, §8 del entorno): una fila por archivo de
-- db/migrations/ aplicado. Lo escribe exclusivamente packages/core/migrate.py,
-- que aborta si el sha256 de un archivo ya aplicado cambió (edición retroactiva).
CREATE TABLE core.schema_migrations (
    archivo           text PRIMARY KEY,                  -- NNN_descripcion.sql
    sha256            text NOT NULL,                     -- contenido con fin de línea LF
    aplicado_en       timestamptz NOT NULL DEFAULT now(),
    duracion_ms       integer NOT NULL,
    CONSTRAINT sm_archivo_chk  CHECK (archivo ~ '^[0-9]{3}[a-z]?_[a-z0-9_]+\.sql$'),
    CONSTRAINT sm_sha256_chk   CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT sm_duracion_chk CHECK (duracion_ms >= 0)
);

-- ============================================================================
-- TENANTS Y SUSCRIPCIONES
-- ============================================================================

-- Organizaciones (tenants). Tabla raíz de la multi-tenencia.
CREATE TABLE core.organizations (
    id                text PRIMARY KEY,                  -- org_<slug|ulid>
    nombre            text NOT NULL,
    idioma            text NOT NULL DEFAULT 'es',
    timezone          text NOT NULL DEFAULT 'Europe/Madrid',
    despliegue        text NOT NULL DEFAULT 'cloud',
    fabrica_activa    boolean NOT NULL DEFAULT false,    -- onboarding completado
    creado_en         timestamptz NOT NULL DEFAULT now(),
    actualizado_en    timestamptz NOT NULL DEFAULT now(),
    eliminado_en      timestamptz,                       -- soft-delete
    CONSTRAINT org_idioma_chk     CHECK (idioma IN ('es','en','pt')),
    CONSTRAINT org_despliegue_chk CHECK (despliegue IN ('cloud','hibrido','onprem'))
);

-- Suscripción vigente e histórica de cada tenant.
CREATE TABLE core.subscriptions (
    id                text PRIMARY KEY,                  -- sub_<ulid>
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    plan_codigo       text NOT NULL REFERENCES core.plans(codigo),
    estado            text NOT NULL DEFAULT 'activa',
    inicia_el         date NOT NULL,
    renueva_el        date NOT NULL,                     -- inicio del próximo ciclo
    finaliza_el       date,                              -- NULL = vigente
    creado_en         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT sub_estado_chk CHECK (estado IN ('activa','periodo_gracia','suspendida','finalizada')),
    CONSTRAINT sub_fechas_chk CHECK (renueva_el > inicia_el)
);
-- Una sola suscripción vigente por tenant:
CREATE UNIQUE INDEX subscriptions_vigente_uq
    ON core.subscriptions (tenant_id) WHERE finaliza_el IS NULL;

-- ============================================================================
-- USUARIOS, INVITACIONES Y SESIONES
-- ============================================================================

CREATE TABLE core.users (
    id                text PRIMARY KEY,                  -- u_<ulid>
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    email             text NOT NULL,
    nombre            text NOT NULL,
    rol               text NOT NULL DEFAULT 'member',
    estado            text NOT NULL DEFAULT 'activo',
    idioma            text NOT NULL DEFAULT 'es',
    password_hash     text,                              -- Argon2id (NULL si invitado)
    notificaciones    jsonb NOT NULL DEFAULT '{"email":true,"portal":true}',
    ultimo_acceso     timestamptz,
    creado_en         timestamptz NOT NULL DEFAULT now(),
    actualizado_en    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT users_rol_chk    CHECK (rol IN ('owner','admin','architect','approver','member','viewer')),
    CONSTRAINT users_estado_chk CHECK (estado IN ('activo','invitado','desactivado')),
    CONSTRAINT users_email_uq   UNIQUE (tenant_id, email)
);

CREATE TABLE core.invitations (
    id                text PRIMARY KEY,                  -- inv_<ulid>
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    email             text NOT NULL,
    rol               text NOT NULL,
    token_hash        text NOT NULL UNIQUE,              -- SHA-256 del token enviado
    invitado_por      text NOT NULL REFERENCES core.users(id),
    estado            text NOT NULL DEFAULT 'enviada',
    expira_en         timestamptz NOT NULL,
    usado_en          timestamptz,
    creado_en         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT inv_rol_chk    CHECK (rol IN ('owner','admin','architect','approver','member','viewer')),
    CONSTRAINT inv_estado_chk CHECK (estado IN ('enviada','aceptada','expirada','revocada'))
);
-- Una invitación pendiente por email y tenant:
CREATE UNIQUE INDEX invitations_pendiente_uq
    ON core.invitations (tenant_id, email) WHERE estado = 'enviada';

CREATE TABLE core.refresh_tokens (
    id                text PRIMARY KEY,                  -- rt_<ulid>
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    user_id           text NOT NULL REFERENCES core.users(id) ON DELETE CASCADE,
    token_hash        text NOT NULL UNIQUE,              -- SHA-256; nunca el token
    emitido_en        timestamptz NOT NULL DEFAULT now(),
    expira_en         timestamptz NOT NULL,
    usado_en          timestamptz,                       -- rotación: un solo uso
    revocado          boolean NOT NULL DEFAULT false,
    ip                inet,
    user_agent        text
);

CREATE TABLE core.password_reset_tokens (
    id                text PRIMARY KEY,                  -- pr_<ulid>
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    user_id           text NOT NULL REFERENCES core.users(id) ON DELETE CASCADE,
    token_hash        text NOT NULL UNIQUE,
    expira_en         timestamptz NOT NULL,
    usado_en          timestamptz,
    creado_en         timestamptz NOT NULL DEFAULT now()
);

-- ============================================================================
-- LÍNEAS DE PRODUCCIÓN
-- ============================================================================

CREATE TABLE core.production_lines (
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    numero            integer NOT NULL,
    estado            text NOT NULL DEFAULT 'disponible',
    job_id            text,                              -- FK diferida: se añade tras crear jobs
    creado_en         timestamptz NOT NULL DEFAULT now(),
    actualizado_en    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, numero),
    CONSTRAINT lines_estado_chk CHECK (estado IN ('disponible','ocupada','mantenimiento')),
    CONSTRAINT lines_coherencia_chk CHECK (
        (estado = 'ocupada' AND job_id IS NOT NULL) OR
        (estado <> 'ocupada' AND job_id IS NULL))
);

-- ============================================================================
-- TICKETS
-- ============================================================================

-- Contador del correlativo visible KC-#### por tenant (lo usa el trigger).
CREATE TABLE core.ticket_counters (
    tenant_id         text PRIMARY KEY REFERENCES core.organizations(id),
    ultimo            integer NOT NULL DEFAULT 1000
);

CREATE TABLE core.tickets (
    id                text PRIMARY KEY,                  -- tk_<ulid> (interno)
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    numero            text,                              -- KC-#### (lo asigna trigger)
    tipo              text NOT NULL,
    titulo            text NOT NULL,
    descripcion       text NOT NULL,
    prioridad         text NOT NULL DEFAULT 'media',     -- declarada (alta|media|baja)
    prioridad_pipeline text,                             -- P1..P4 (la fija Triage)
    etapa             text NOT NULL DEFAULT 'triage',
    gate_pendiente    smallint,                          -- 1|2|3 o NULL
    origen            text NOT NULL DEFAULT 'portal',
    origen_ref        jsonb,                             -- payload/clave del sistema origen
    reportado_por     text REFERENCES core.users(id),    -- NULL si origen externo
    usuario_final     jsonb,                             -- {id_externo, canal} de Kallicode Help
    modulo_pista      text,
    duplicado_de      text REFERENCES core.tickets(id),
    impacto           jsonb,                             -- {modulos[], tablas[], radio, riesgo_regresion}
    complejidad       text,
    pr_url            text,
    fecha_objetivo    date,
    motivo_cancelacion text,
    cancelado_por     text REFERENCES core.users(id),
    creado_en         timestamptz NOT NULL DEFAULT now(),
    actualizado_en    timestamptz NOT NULL DEFAULT now(),
    cerrado_en        timestamptz,
    CONSTRAINT tk_tipo_chk   CHECK (tipo IN ('bug','mejora','funcionalidad','seguridad')),
    CONSTRAINT tk_prio_chk   CHECK (prioridad IN ('alta','media','baja')),
    CONSTRAINT tk_priop_chk  CHECK (prioridad_pipeline IS NULL OR prioridad_pipeline IN ('P1','P2','P3','P4')),
    CONSTRAINT tk_etapa_chk  CHECK (etapa IN ('triage','design','build','qa','security','deploy',
                                              'produccion','en_cola_por_cuota','cancelado','cerrado_duplicado')),
    CONSTRAINT tk_gate_chk   CHECK (gate_pendiente IS NULL OR gate_pendiente IN (1,2,3)),
    CONSTRAINT tk_origen_chk CHECK (origen IN ('portal','jira','github','kallicode_help','corestream')),
    CONSTRAINT tk_complej_chk CHECK (complejidad IS NULL OR complejidad IN ('trivial','small','medium','large')),
    CONSTRAINT tk_numero_uq  UNIQUE (tenant_id, numero),
    CONSTRAINT tk_cancel_chk CHECK (etapa <> 'cancelado' OR motivo_cancelacion IS NOT NULL),
    CONSTRAINT tk_dup_no_self_chk CHECK (duplicado_de IS NULL OR duplicado_de <> id)
);

CREATE TABLE core.ticket_attachments (
    id                text PRIMARY KEY,                  -- att_<ulid>
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    ticket_id         text REFERENCES core.tickets(id) ON DELETE CASCADE,  -- NULL = pendiente de asociar
    nombre_archivo    text NOT NULL,
    content_type      text NOT NULL,
    tamano_bytes      bigint NOT NULL,
    blob_ref          text NOT NULL,                     -- ruta en Blob Storage
    clase             text NOT NULL DEFAULT 'usuario',   -- usuario | evidencia | documento
    escaneo           text NOT NULL DEFAULT 'pendiente',
    subido_por        text REFERENCES core.users(id),
    creado_en         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT att_tamano_chk  CHECK (tamano_bytes BETWEEN 1 AND 52428800),
    CONSTRAINT att_clase_chk   CHECK (clase IN ('usuario','evidencia','documento')),
    CONSTRAINT att_escaneo_chk CHECK (escaneo IN ('pendiente','limpio','infectado'))
);

CREATE TABLE core.ticket_watchers (
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    ticket_id         text NOT NULL REFERENCES core.tickets(id) ON DELETE CASCADE,
    user_id           text NOT NULL REFERENCES core.users(id) ON DELETE CASCADE,
    creado_en         timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (ticket_id, user_id)
);

-- ============================================================================
-- SPECS (Diseño) — versiones inmutables
-- ============================================================================

CREATE TABLE core.specs (
    id                text PRIMARY KEY,                  -- sp_<ulid>
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    ticket_id         text NOT NULL REFERENCES core.tickets(id) ON DELETE CASCADE,
    version           integer NOT NULL,
    estado            text NOT NULL DEFAULT 'pendiente_gate1',
    spec_md_ref       text NOT NULL,                     -- narrativa en Blob
    scope_paths       text[] NOT NULL,
    plan_tests        jsonb,
    migraciones       jsonb,
    adr_borrador      jsonb,
    estimacion_loc    integer,
    creado_en         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT spec_estado_chk CHECK (estado IN ('pendiente_gate1','aprobada','reemplazada','rechazada')),
    CONSTRAINT spec_version_uq UNIQUE (ticket_id, version),
    CONSTRAINT spec_scope_chk  CHECK (array_length(scope_paths, 1) >= 1)
);

CREATE TABLE core.spec_alternatives (
    spec_id           text NOT NULL REFERENCES core.specs(id) ON DELETE CASCADE,
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    alt_id            text NOT NULL,                     -- 'A' | 'B' | 'C'
    titulo            text NOT NULL,
    descripcion       text NOT NULL,
    riesgo            text NOT NULL,
    recomendada       boolean NOT NULL DEFAULT false,
    elegida           boolean NOT NULL DEFAULT false,    -- la marca el Gate 1
    PRIMARY KEY (spec_id, alt_id),
    CONSTRAINT alt_riesgo_chk CHECK (riesgo IN ('bajo','medio','alto'))
);
-- Exactamente una recomendada por spec (parcial):
CREATE UNIQUE INDEX spec_alt_recomendada_uq
    ON core.spec_alternatives (spec_id) WHERE recomendada;
CREATE UNIQUE INDEX spec_alt_elegida_uq
    ON core.spec_alternatives (spec_id) WHERE elegida;

CREATE TABLE core.spec_criteria (
    spec_id           text NOT NULL REFERENCES core.specs(id) ON DELETE CASCADE,
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    criterio_id       text NOT NULL,                     -- AC-1, AC-2...
    given_txt         text NOT NULL,
    when_txt          text NOT NULL,
    then_txt          text NOT NULL,
    PRIMARY KEY (spec_id, criterio_id),
    CONSTRAINT crit_id_chk CHECK (criterio_id ~ '^AC-[0-9]+$')
);

-- ============================================================================
-- JOBS (máquina de estados del pipeline)
-- ============================================================================

CREATE TABLE core.jobs (
    id                text PRIMARY KEY,                  -- job_<ulid>
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    ticket_id         text NOT NULL REFERENCES core.tickets(id) ON DELETE CASCADE,
    estado            text NOT NULL DEFAULT 'pendiente_asignacion',
    linea             integer,
    prioridad         text NOT NULL,
    iteraciones       jsonb NOT NULL DEFAULT '{}',       -- {"design":2,"build":1,...}
    contexto          jsonb,                             -- payload de la última transición
    creado_en         timestamptz NOT NULL DEFAULT now(),
    actualizado_en    timestamptz NOT NULL DEFAULT now(),
    terminado_en      timestamptz,
    CONSTRAINT job_estado_chk CHECK (estado IN (
        'pendiente_asignacion','triage','design','gate1','build','qa','gate2','security',
        'deploy_preflight','gate3','deploy','produccion',
        'pausado_por_cuota','escalado_humano','cancelado','cerrado_duplicado')),
    CONSTRAINT job_prio_chk CHECK (prioridad IN ('P1','P2','P3','P4')),
    CONSTRAINT job_linea_fk FOREIGN KEY (tenant_id, linea)
        REFERENCES core.production_lines(tenant_id, numero)
);
-- Un job activo por ticket:
CREATE UNIQUE INDEX jobs_activo_por_ticket_uq
    ON core.jobs (ticket_id)
    WHERE estado NOT IN ('produccion','cancelado','cerrado_duplicado');
-- Una línea no puede tener dos jobs activos:
CREATE UNIQUE INDEX jobs_linea_ocupada_uq
    ON core.jobs (tenant_id, linea)
    WHERE linea IS NOT NULL
      AND estado NOT IN ('produccion','cancelado','cerrado_duplicado');

-- FK diferida de production_lines.job_id → jobs.id
ALTER TABLE core.production_lines
    ADD CONSTRAINT lines_job_fk FOREIGN KEY (job_id) REFERENCES core.jobs(id)
    DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE core.job_transitions (
    id                bigint GENERATED ALWAYS AS IDENTITY,
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    job_id            text NOT NULL REFERENCES core.jobs(id) ON DELETE CASCADE,
    de_estado         text NOT NULL,
    a_estado          text NOT NULL,
    motivo            text,
    contexto          jsonb,
    actor             text NOT NULL DEFAULT 'sistema',   -- sistema | svc:<agente> | user:<id>
    creado_en         timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (creado_en, id)
);

-- Pasos LLM de las cadenas de prompts.
CREATE TABLE core.llm_steps (
    id                text PRIMARY KEY,                  -- st_<ulid>
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    job_id            text NOT NULL REFERENCES core.jobs(id) ON DELETE CASCADE,
    ticket_id         text NOT NULL REFERENCES core.tickets(id) ON DELETE CASCADE,
    etapa             text NOT NULL,
    paso              text NOT NULL,                     -- p. ej. triage.classify
    version_plantilla text NOT NULL,
    modelo            text NOT NULL,
    tier              text NOT NULL,
    confianza         numeric(4,3),
    validacion        text NOT NULL,
    reintentos        smallint NOT NULL DEFAULT 0,
    tokens_in         integer NOT NULL,
    tokens_out        integer NOT NULL,
    duracion_ms       integer NOT NULL,
    entrada_ref       text NOT NULL,                     -- Blob
    salida_ref        text NOT NULL,                     -- Blob
    creado_en         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT step_etapa_chk  CHECK (etapa IN ('triage','design','build','qa','security','deploy')),
    CONSTRAINT step_tier_chk   CHECK (tier IN ('pro','flash','vision')),
    CONSTRAINT step_valid_chk  CHECK (validacion IN ('esquema_valido','reintento','escalado_tier','escalado_humano')),
    CONSTRAINT step_conf_chk   CHECK (confianza IS NULL OR (confianza >= 0 AND confianza <= 1)),
    CONSTRAINT step_tokens_chk CHECK (tokens_in >= 0 AND tokens_out >= 0 AND duracion_ms >= 0)
);

-- ============================================================================
-- GATES (firmas humanas)
-- ============================================================================

CREATE TABLE core.gate_signatures (
    id                text PRIMARY KEY,                  -- gs_<ulid>
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    ticket_id         text NOT NULL REFERENCES core.tickets(id) ON DELETE CASCADE,
    gate              smallint NOT NULL,
    accion            text NOT NULL,                     -- aprobado | cambios_pedidos
    actor_id          text NOT NULL REFERENCES core.users(id),
    comentario        text,
    alternativa_id    text,                              -- Gate 1
    acepta_fallos     boolean NOT NULL DEFAULT false,    -- Gate 2
    devolver_a        text,                              -- Gate 3: design|build|qa
    spec_id           text REFERENCES core.specs(id),    -- versión firmada (Gate 1)
    sello             text NOT NULL,                     -- hash del evento de auditoría
    creado_en         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT gate_num_chk    CHECK (gate IN (1,2,3)),
    CONSTRAINT gate_accion_chk CHECK (accion IN ('aprobado','cambios_pedidos')),
    CONSTRAINT gate_dev_chk    CHECK (devolver_a IS NULL OR devolver_a IN ('design','build','qa'))
);
-- Una única APROBACIÓN por gate y ticket (las devoluciones pueden repetirse):
CREATE UNIQUE INDEX gate_aprobado_uq
    ON core.gate_signatures (ticket_id, gate) WHERE accion = 'aprobado';

-- ============================================================================
-- QA (corridas y matriz de evidencia)
-- ============================================================================

CREATE TABLE core.qa_runs (
    id                text PRIMARY KEY,                  -- qr_<ulid>
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    ticket_id         text NOT NULL REFERENCES core.tickets(id) ON DELETE CASCADE,
    spec_id           text NOT NULL REFERENCES core.specs(id),
    corrida           integer NOT NULL,
    regresion         jsonb NOT NULL,                    -- {dirigidos, dirigidos_ok, suite_cliente, cliente_ok}
    flaky             jsonb NOT NULL DEFAULT '[]',
    ejecutada_en      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT qa_corrida_uq UNIQUE (ticket_id, corrida)
);

CREATE TABLE core.qa_results (
    qa_run_id         text NOT NULL REFERENCES core.qa_runs(id) ON DELETE CASCADE,
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    criterio_id       text NOT NULL,                     -- AC-n de la spec
    resultado         text NOT NULL,
    extracto_fallo    text,
    veredicto_visual  jsonb,                             -- {veredicto, observado, region}
    evidencias        jsonb NOT NULL DEFAULT '[]',       -- [{tipo, blob_ref}]
    PRIMARY KEY (qa_run_id, criterio_id),
    CONSTRAINT qares_resultado_chk CHECK (resultado IN ('pasa','falla','flaky')),
    CONSTRAINT qares_fallo_chk CHECK (resultado <> 'falla' OR extracto_fallo IS NOT NULL)
);

-- ============================================================================
-- SECURITY (hallazgos)
-- ============================================================================

CREATE TABLE core.security_findings (
    id                text PRIMARY KEY,                  -- sf_<ulid>
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    ticket_id         text NOT NULL REFERENCES core.tickets(id) ON DELETE CASCADE,
    origen            text NOT NULL,                     -- sast | sca | secrets
    regla             text,
    archivo           text,
    linea             integer,
    severidad         text NOT NULL,
    titulo            text NOT NULL,
    veredicto         text NOT NULL,
    justificacion     text,
    fix_diff_ref      text,                              -- Blob
    bloquea           boolean NOT NULL DEFAULT false,
    estado            text NOT NULL DEFAULT 'abierto',
    creado_en         timestamptz NOT NULL DEFAULT now(),
    actualizado_en    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT sf_origen_chk    CHECK (origen IN ('sast','sca','secrets')),
    CONSTRAINT sf_severidad_chk CHECK (severidad IN ('critica','alta','media','baja')),
    CONSTRAINT sf_veredicto_chk CHECK (veredicto IN ('confirmado','falso_positivo')),
    CONSTRAINT sf_estado_chk    CHECK (estado IN ('abierto','corregido','descartado')),
    -- Todo falso positivo o descarte exige justificación (compliance):
    CONSTRAINT sf_justif_chk CHECK (
        (veredicto = 'falso_positivo' OR estado = 'descartado') = (justificacion IS NOT NULL)
        OR (veredicto = 'confirmado' AND estado <> 'descartado'))
);

-- ============================================================================
-- CONSUMO (tokens y LOC) — validación comercial
-- ============================================================================

CREATE TABLE core.usage_tokens (
    id                bigint GENERATED ALWAYS AS IDENTITY,
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    ticket_id         text NOT NULL REFERENCES core.tickets(id) ON DELETE CASCADE,
    etapa             text NOT NULL,
    modelo            text NOT NULL,
    tier              text NOT NULL,
    invocaciones      integer NOT NULL DEFAULT 1,
    tokens_in         integer NOT NULL,
    tokens_out        integer NOT NULL,
    duracion_ms       integer NOT NULL,
    creado_en         timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (creado_en, id),
    CONSTRAINT ut_pos_chk CHECK (tokens_in >= 0 AND tokens_out >= 0)
);

-- Único punto que descuenta cuota LOC (QU-1). Un registro por PR.
CREATE TABLE core.usage_loc (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    ticket_id         text REFERENCES core.tickets(id) ON DELETE SET NULL,
    ciclo             text NOT NULL,                     -- 'YYYY-MM'
    tipo              text NOT NULL DEFAULT 'pr',        -- pr | ajuste
    pr_url            text,
    anadidas          integer NOT NULL DEFAULT 0,
    eliminadas        integer NOT NULL DEFAULT 0,
    netas             integer NOT NULL,
    tests             integer NOT NULL DEFAULT 0,
    motivo_ajuste     text,
    creado_en         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT loc_ciclo_chk  CHECK (ciclo ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
    CONSTRAINT loc_tipo_chk   CHECK (tipo IN ('pr','ajuste')),
    CONSTRAINT loc_netas_chk  CHECK (tipo <> 'pr' OR netas = anadidas - eliminadas),
    CONSTRAINT loc_pr_chk     CHECK (tipo <> 'pr' OR pr_url IS NOT NULL),
    CONSTRAINT loc_ajuste_chk CHECK (tipo <> 'ajuste' OR motivo_ajuste IS NOT NULL)
);
CREATE UNIQUE INDEX usage_loc_pr_uq ON core.usage_loc (pr_url) WHERE tipo = 'pr';

-- Agregado por ciclo (lo mantiene un trigger; el middleware comercial lo lee).
CREATE TABLE core.usage_cycles (
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    ciclo             text NOT NULL,
    loc_consumidas    integer NOT NULL DEFAULT 0,
    umbral            text NOT NULL DEFAULT 'normal',    -- normal | aviso_80 | agotado
    actualizado_en    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, ciclo),
    CONSTRAINT uc_umbral_chk CHECK (umbral IN ('normal','aviso_80','agotado'))
);

-- ============================================================================
-- INTEGRACIONES
-- ============================================================================

CREATE TABLE core.connections (
    id                text PRIMARY KEY,                  -- cn_<ulid>
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    categoria         text NOT NULL,
    proveedor         text NOT NULL,
    nombre            text,
    config            jsonb NOT NULL DEFAULT '{}',
    secreto_ref       text,                              -- referencia en Key Vault (nunca el valor)
    ruta_token        text UNIQUE,                       -- token de ruta del webhook (wh_...)
    estado            text NOT NULL DEFAULT 'pendiente',
    ultimo_test       timestamptz,
    ultimo_test_detalle jsonb,
    creado_en         timestamptz NOT NULL DEFAULT now(),
    actualizado_en    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT cn_categoria_chk CHECK (categoria IN ('repositorio','tickets','cicd','database')),
    CONSTRAINT cn_estado_chk    CHECK (estado IN ('conectada','pendiente','pendiente_oauth','error','deshabilitada')),
    CONSTRAINT cn_proveedor_chk CHECK (proveedor IN (
        'github','gitlab','bitbucket','corestream_repo',
        'jira','github_issues','kallicode_help','corestream',
        'github_actions','gitlab_ci','jenkins',
        'postgresql','mysql','sqlserver','oracle'))
);

-- Mapa de ramas: una fila por tenant.
CREATE TABLE core.branch_map (
    tenant_id         text PRIMARY KEY REFERENCES core.organizations(id),
    feature_pattern   text NOT NULL DEFAULT 'feature/*',
    staging_branch    text NOT NULL DEFAULT 'develop',
    prod_branch       text NOT NULL DEFAULT 'main',
    actualizado_en    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT bm_distintas_chk CHECK (staging_branch <> prod_branch)
);

CREATE TABLE core.webhook_inbox (
    id                bigint GENERATED ALWAYS AS IDENTITY,
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    connection_id     text NOT NULL REFERENCES core.connections(id) ON DELETE CASCADE,
    delivery_id       text NOT NULL,
    evento            text,
    payload           jsonb NOT NULL,
    estado            text NOT NULL DEFAULT 'pendiente',
    error_detalle     text,
    ticket_id         text REFERENCES core.tickets(id),
    recibido_en       timestamptz NOT NULL DEFAULT now(),
    procesado_en      timestamptz,
    PRIMARY KEY (recibido_en, id),
    CONSTRAINT wi_estado_chk CHECK (estado IN ('pendiente','procesado','ignorado','fallido')),
    CONSTRAINT wi_delivery_uq UNIQUE (connection_id, delivery_id)
);

-- ============================================================================
-- MODELOS IA
-- ============================================================================

CREATE TABLE core.model_providers (
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    proveedor         text NOT NULL,
    llave_ref         text,                              -- Key Vault
    llave_mascara     text,                              -- ••••4Jx2
    base_url          text,                              -- self-hosted
    estado            text NOT NULL DEFAULT 'sin_configurar',
    modelos_disponibles jsonb NOT NULL DEFAULT '[]',
    ultimo_test       timestamptz,
    actualizado_en    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, proveedor),
    CONSTRAINT mp_proveedor_chk CHECK (proveedor IN ('anthropic','openai','google','deepseek_selfhosted')),
    CONSTRAINT mp_estado_chk    CHECK (estado IN ('valida','invalida','sin_configurar')),
    CONSTRAINT mp_selfhost_chk  CHECK (proveedor <> 'deepseek_selfhosted' OR base_url IS NOT NULL)
);

CREATE TABLE core.model_assignments (
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    funcion           text NOT NULL,
    principal_proveedor text NOT NULL,
    principal_modelo  text NOT NULL,
    fallback_proveedor text NOT NULL,
    fallback_modelo   text NOT NULL,
    actualizado_en    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, funcion),
    CONSTRAINT ma_funcion_chk CHECK (funcion IN ('triage','design','build','qa','security','deploy')),
    CONSTRAINT ma_distintos_chk CHECK (principal_proveedor <> fallback_proveedor
                                       OR principal_modelo <> fallback_modelo),
    CONSTRAINT ma_prov_ppal_fk FOREIGN KEY (tenant_id, principal_proveedor)
        REFERENCES core.model_providers(tenant_id, proveedor),
    CONSTRAINT ma_prov_fb_fk FOREIGN KEY (tenant_id, fallback_proveedor)
        REFERENCES core.model_providers(tenant_id, proveedor)
);

-- ============================================================================
-- SOPORTE OPERATIVO
-- ============================================================================

CREATE TABLE core.notifications (
    id                text NOT NULL,                  -- nt_<ulid>
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    user_id           text NOT NULL REFERENCES core.users(id) ON DELETE CASCADE,
    tipo              text NOT NULL,
    titulo            text NOT NULL,
    cuerpo            text,
    ticket_id         text REFERENCES core.tickets(id) ON DELETE CASCADE,
    leida             boolean NOT NULL DEFAULT false,
    creada_en         timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (creada_en, id),
    CONSTRAINT nt_tipo_chk CHECK (tipo IN ('cambio_etapa','gate_pendiente','ticket_cerrado',
                                           'aviso_cuota','seguridad','sistema'))
);

CREATE TABLE core.idempotency_keys (
    clave             text NOT NULL,
    tenant_id         text NOT NULL,
    endpoint          text NOT NULL,
    respuesta         jsonb NOT NULL,
    status_code       smallint NOT NULL,
    creado_en         timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, endpoint, clave)
);

CREATE TABLE core.escalations (
    id                text PRIMARY KEY,                  -- esc_<ulid>
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    job_id            text NOT NULL REFERENCES core.jobs(id) ON DELETE CASCADE,
    etapa             text NOT NULL,
    paso              text,
    motivo            text NOT NULL,
    severidad         text NOT NULL,
    detalle           jsonb NOT NULL,
    estado            text NOT NULL DEFAULT 'abierta',
    resuelto_por      text,
    resuelto_en       timestamptz,
    creado_en         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT esc_motivo_chk CHECK (motivo IN ('validacion_persistente','baja_confianza',
        'max_iteraciones','selector_repair','anomalia_deploy','otro')),
    CONSTRAINT esc_sev_chk    CHECK (severidad IN ('baja','media','alta','critica')),
    CONSTRAINT esc_estado_chk CHECK (estado IN ('abierta','en_curso','resuelta'))
);
-- Un escalado abierto por job y paso:
CREATE UNIQUE INDEX escalations_abierta_uq
    ON core.escalations (job_id, coalesce(paso, '-')) WHERE estado = 'abierta';

CREATE TABLE core.audit_exports (
    id                text PRIMARY KEY,                  -- exp_<ulid>
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    formato           text NOT NULL,
    ticket_id         text REFERENCES core.tickets(id),
    filtros           jsonb,
    estado            text NOT NULL DEFAULT 'encolada',
    blob_ref          text,
    solicitado_por    text NOT NULL REFERENCES core.users(id),
    creado_en         timestamptz NOT NULL DEFAULT now(),
    completado_en     timestamptz,
    CONSTRAINT exp_formato_chk CHECK (formato IN ('csv','pdf')),
    CONSTRAINT exp_estado_chk  CHECK (estado IN ('encolada','procesando','lista','fallida')),
    CONSTRAINT exp_pdf_chk     CHECK (formato <> 'pdf' OR ticket_id IS NOT NULL)
);

CREATE TABLE core.onboarding_documents (
    id                text PRIMARY KEY,                  -- doc_<ulid>
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    nombre_archivo    text NOT NULL,
    content_type      text NOT NULL,
    tamano_bytes      bigint NOT NULL,
    tipo_documento    text NOT NULL DEFAULT 'otro',
    blob_ref          text NOT NULL,
    hash_contenido    text,                              -- dedup por contenido
    estado            text NOT NULL DEFAULT 'pendiente',
    subido_por        text NOT NULL REFERENCES core.users(id),
    creado_en         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT od_tipo_chk   CHECK (tipo_documento IN ('manual','spec','adr','negocio','otro')),
    CONSTRAINT od_estado_chk CHECK (estado IN ('pendiente','procesado','fallido')),
    CONSTRAINT od_tamano_chk CHECK (tamano_bytes BETWEEN 1 AND 52428800)
);
CREATE UNIQUE INDEX onboarding_docs_hash_uq
    ON core.onboarding_documents (tenant_id, hash_contenido) WHERE hash_contenido IS NOT NULL;

CREATE TABLE core.upgrade_requests (
    id                text PRIMARY KEY,                  -- upg_<ulid>
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    plan_deseado      text NOT NULL REFERENCES core.plans(codigo),
    comentario        text,
    urgente           boolean NOT NULL DEFAULT false,
    estado            text NOT NULL DEFAULT 'registrada',
    solicitado_por    text NOT NULL REFERENCES core.users(id),
    creado_en         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT upg_estado_chk CHECK (estado IN ('registrada','en_gestion','aplicada','descartada'))
);
CREATE UNIQUE INDEX upgrade_abierta_uq
    ON core.upgrade_requests (tenant_id) WHERE estado IN ('registrada','en_gestion');

-- ============================================================================
-- AUDITORÍA INMUTABLE (esquema audit)
-- ============================================================================

-- Cabeza de cadena por tenant: serializa el cálculo del hash encadenado.
CREATE TABLE audit.chain_heads (
    tenant_id         text PRIMARY KEY REFERENCES core.organizations(id),
    ultimo_sello      text NOT NULL DEFAULT repeat('0', 64),  -- génesis
    eventos           bigint NOT NULL DEFAULT 0
);

-- Registro append-only. Sin UPDATE/DELETE (trigger + permisos).
CREATE TABLE audit.audit_events (
    id                bigint GENERATED ALWAYS AS IDENTITY,
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    ticket_id         text,                              -- sin FK: la auditoría sobrevive a todo
    job_id            text,
    etapa             text,
    actor_tipo        text NOT NULL,                     -- humano | agente | sistema
    actor_id          text,                              -- user_id o nombre del agente
    evento            text NOT NULL,                     -- código estable (gate_firmado, spec_generada...)
    resumen           text NOT NULL,                     -- texto visible en el portal
    datos             jsonb,                             -- payload estructurado del evento
    modelo            text,                              -- si actor agente
    step_id           text,                              -- ref a core.llm_steps
    sello_previo      text NOT NULL,
    sello             text NOT NULL,                     -- SHA-256(sello_previo || canónico)
    creado_en         timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (creado_en, id),
    CONSTRAINT ae_actor_chk CHECK (actor_tipo IN ('humano','agente','sistema')),
    CONSTRAINT ae_sello_chk CHECK (sello ~ '^[0-9a-f]{64}$')
);

-- ============================================================================
-- VECTORIAL (esquema vec, pgvector) — BGE-M3, 1024 dimensiones
-- ============================================================================

-- Embeddings de tickets: deduplicación vectorial de Triage y dedup-preview.
CREATE TABLE vec.ticket_embeddings (
    ticket_id         text PRIMARY KEY REFERENCES core.tickets(id) ON DELETE CASCADE,
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    embedding         vector(1024) NOT NULL,
    modelo_embedding  text NOT NULL DEFAULT 'bge-m3',
    texto_hash        text NOT NULL,                     -- re-embeber solo si cambió
    creado_en         timestamptz NOT NULL DEFAULT now()
);

-- Chunks de documentación ingerida (onboarding y refresh diario del grafo).
CREATE TABLE vec.doc_chunks (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    documento_id      text NOT NULL REFERENCES core.onboarding_documents(id) ON DELETE CASCADE,
    chunk_idx         integer NOT NULL,
    contenido         text NOT NULL,
    embedding         vector(1024) NOT NULL,
    metadatos         jsonb NOT NULL DEFAULT '{}',       -- {seccion, pagina, tipo_documento}
    creado_en         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT dc_chunk_uq UNIQUE (documento_id, chunk_idx)
);

-- Definiciones semánticas de CodeMapping (capa de definiciones del grafo):
-- respaldan impact-preview y la recuperación en dos fases de Diseño.
CREATE TABLE vec.definition_embeddings (
    id                text PRIMARY KEY,                  -- de_<ulid>
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    nodo_ref          text NOT NULL,                     -- id del nodo en cm.nodes (FK desde 022_vec_fk_cm.sql)
    capa              text NOT NULL,                     -- kind del nodo (022_vec_fk_cm.sql; antes definicion | negocio | codigo)
    nombre            text NOT NULL,
    descripcion       text NOT NULL,
    modulo            text,
    embedding         vector(1024) NOT NULL,
    actualizado_en    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT de_capa_chk CHECK (capa IN ('definicion','negocio','codigo')),
    CONSTRAINT de_nodo_uq  UNIQUE (tenant_id, nodo_ref)
);

COMMIT;

-- ================================================================
-- ARCHIVO: db/02_indexes.sql
-- ================================================================
-- ============================================================================
-- KALLICODE · 02_indexes.sql — Índices de rendimiento
-- (Los índices UNIQUE que implementan reglas de negocio viven en 01_schema.sql
--  junto a su tabla; aquí van los índices de acceso.)
-- Convención (KC-DB-06-2): todo índice multi-tenant comienza por tenant_id, para que el filtro
-- implícito de RLS se resuelva dentro del índice y no después de la búsqueda. Excepciones, todas
-- documentadas con su plan de ejecución en docs/plan-indices.md (test_convencion_indices.py las
-- verifica): los índices únicos de regla de negocio (devuelven a lo sumo una fila), los barridos de
-- los workers entre tenants (no filtran por tenant), el GIN de trigramas y los HNSW vectoriales.
-- Los índices que respaldan una PRIMARY KEY o UNIQUE se justifican por su restricción.
-- ============================================================================

BEGIN;

-- --- Usuarios y sesiones ----------------------------------------------------
CREATE INDEX users_tenant_rol_ix        ON core.users (tenant_id, rol) WHERE estado = 'activo';
CREATE INDEX users_tenant_estado_ix     ON core.users (tenant_id, estado);
CREATE INDEX refresh_tokens_tenant_user_activos_ix ON core.refresh_tokens (tenant_id, user_id)
    WHERE usado_en IS NULL AND NOT revocado;
CREATE INDEX refresh_tokens_expira_ix   ON core.refresh_tokens (expira_en);   -- purga programada (excepción tenant-first: barrido entre tenants)
CREATE INDEX invitations_tenant_ix      ON core.invitations (tenant_id, estado);

-- --- Tickets: listados, filtros y búsqueda ----------------------------------
-- Listado por defecto (actualizado_en desc) con filtros:
CREATE INDEX tickets_tenant_upd_ix      ON core.tickets (tenant_id, actualizado_en DESC);
CREATE INDEX tickets_tenant_etapa_ix    ON core.tickets (tenant_id, etapa, actualizado_en DESC);
CREATE INDEX tickets_tenant_gate_ix     ON core.tickets (tenant_id, gate_pendiente)
    WHERE gate_pendiente IS NOT NULL;                    -- pantalla Aprobaciones
CREATE INDEX tickets_tenant_tipo_ix     ON core.tickets (tenant_id, tipo);
-- reportado_por y duplicado_de los cubren idx_tickets_tenant_reportado_por / _duplicado_de (migración 018).
-- Búsqueda de texto en título (ILIKE '%...%'). Excepción tenant-first: un GIN de trigramas no admite
-- tenant_id como primera columna sin btree_gin; el filtro de tenant lo aporta el btree del tablero.
CREATE INDEX tickets_titulo_trgm_ix     ON core.tickets USING gin (titulo gin_trgm_ops);
-- Kanban / dashboard (solo activos):
CREATE INDEX tickets_kanban_ix          ON core.tickets (tenant_id, etapa, creado_en DESC)
    WHERE etapa NOT IN ('produccion','cancelado','cerrado_duplicado');

-- --- Adjuntos ----------------------------------------------------------------
-- ticket_id y user_id los cubren idx_ticket_attachments_tenant_ticket_id / idx_ticket_watchers_tenant_user_id (018).
CREATE INDEX attachments_huerfanos_ix   ON core.ticket_attachments (creado_en)
    WHERE ticket_id IS NULL;                             -- purga de huérfanos >48 h (excepción tenant-first: barrido entre tenants)

-- --- Specs -------------------------------------------------------------------
CREATE INDEX specs_tenant_ticket_ix     ON core.specs (tenant_id, ticket_id, version DESC);
CREATE INDEX spec_criteria_tenant_ix    ON core.spec_criteria (tenant_id);

-- --- Jobs y pipeline ----------------------------------------------------------
CREATE INDEX jobs_tenant_estado_ix      ON core.jobs (tenant_id, estado);
CREATE INDEX jobs_pendientes_ix         ON core.jobs (tenant_id, prioridad, creado_en)
    WHERE estado = 'pendiente_asignacion';               -- cola del planificador
CREATE INDEX job_transitions_tenant_job_ix ON core.job_transitions (tenant_id, job_id, creado_en);
CREATE INDEX llm_steps_tenant_job_ix    ON core.llm_steps (tenant_id, job_id, creado_en);
CREATE INDEX llm_steps_tenant_ticket_etapa_ix ON core.llm_steps (tenant_id, ticket_id, etapa);

-- --- Gates / QA / Security -----------------------------------------------------
CREATE INDEX gates_tenant_ticket_ix     ON core.gate_signatures (tenant_id, ticket_id, gate, creado_en);
CREATE INDEX gates_tenant_actor_ix      ON core.gate_signatures (tenant_id, actor_id, creado_en DESC);
CREATE INDEX qa_runs_tenant_ticket_ix   ON core.qa_runs (tenant_id, ticket_id, corrida DESC);
-- security_findings por ticket: lo cubre idx_security_findings_tenant_ticket_id (018).
CREATE INDEX findings_bloqueantes_ix    ON core.security_findings (tenant_id, ticket_id)
    WHERE bloquea AND estado = 'abierto';                -- precondición de deploy

-- --- Consumo -------------------------------------------------------------------
CREATE INDEX usage_tokens_tenant_ticket_etapa_ix ON core.usage_tokens (tenant_id, ticket_id, etapa);
CREATE INDEX usage_tokens_tenant_ix     ON core.usage_tokens (tenant_id, creado_en);
-- KC-DB-07-2: usage_tokens y job_transitions se particionan por mes (migración 035_particion_consumo.sql);
-- sus índices pasan a ser por partición (declarados en el padre; PostgreSQL crea uno por partición).
CREATE INDEX usage_loc_tenant_ciclo_ix  ON core.usage_loc (tenant_id, ciclo);
-- usage_loc por ticket: lo cubre idx_usage_loc_tenant_ticket_id (018).

-- --- Integraciones ----------------------------------------------------------------
CREATE INDEX connections_tenant_ix      ON core.connections (tenant_id, categoria);
CREATE INDEX webhook_inbox_pend_ix      ON core.webhook_inbox (estado, recibido_en)
    WHERE estado IN ('pendiente','fallido');             -- cola del normalizador (excepción tenant-first: barrido entre tenants)
CREATE INDEX webhook_inbox_tenant_ix    ON core.webhook_inbox (tenant_id, recibido_en DESC);

-- --- Notificaciones / soporte -------------------------------------------------------
CREATE INDEX notifications_tenant_user_ix ON core.notifications (tenant_id, user_id, creada_en DESC);
-- KC-DB-07-3: webhook_inbox y notifications se particionan por mes (migración 036_particion_colas.sql); sus
-- índices pasan a ser por partición (declarados en el padre; PostgreSQL crea uno por partición).
CREATE INDEX notifications_tenant_noleidas_ix ON core.notifications (tenant_id, user_id) WHERE NOT leida;
CREATE INDEX idempotency_purga_ix       ON core.idempotency_keys (creado_en);  -- TTL 48 h (excepción tenant-first: barrido entre tenants)
CREATE INDEX escalations_abiertas_ix    ON core.escalations (tenant_id, severidad, creado_en)
    WHERE estado = 'abierta';
CREATE INDEX audit_exports_tenant_ix    ON core.audit_exports (tenant_id, creado_en DESC);

-- --- Auditoría -----------------------------------------------------------------------
CREATE INDEX audit_tenant_fecha_ix      ON audit.audit_events (tenant_id, creado_en DESC);
CREATE INDEX audit_ticket_ix            ON audit.audit_events (tenant_id, ticket_id, creado_en);
CREATE INDEX audit_actor_ix             ON audit.audit_events (tenant_id, actor_tipo, creado_en DESC);
CREATE INDEX audit_evento_ix            ON audit.audit_events (tenant_id, evento);
-- KC-DB-07-1: audit_events se particiona por rango mensual de creado_en (migración
-- 033_particion_auditoria.sql, pg_partman). Estos seis índices (los cuatro de aquí más
-- audit_events_sello_ix y audit_events_request_id_ix, de las migraciones 024 y 030) pasan a
-- ser índices POR PARTICIÓN: se declaran en la tabla padre y PostgreSQL los crea en cada
-- partición. Este script basal sigue creando la tabla simple; la migración 033 la convierte.

-- --- Vectorial (pgvector) ---------------------------------------------------------------
-- HNSW con distancia coseno (BGE-M3 produce vectores normalizados).
-- m y ef_construction: valores por defecto razonables para 10^4–10^6 filas.
-- Excepción tenant-first: un índice HNSW indexa una sola columna vectorial; el tenant se filtra con RLS
-- (ver la migración 023, hnsw.iterative_scan).
CREATE INDEX ticket_embeddings_hnsw_ix
    ON vec.ticket_embeddings USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

CREATE INDEX doc_chunks_hnsw_ix
    ON vec.doc_chunks USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

CREATE INDEX definition_embeddings_hnsw_ix
    ON vec.definition_embeddings USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

-- Filtros por payload que acompañan a la búsqueda vectorial:
CREATE INDEX ticket_embeddings_tenant_ix  ON vec.ticket_embeddings (tenant_id);
CREATE INDEX doc_chunks_tenant_ix         ON vec.doc_chunks (tenant_id);
CREATE INDEX definition_emb_tenant_ix     ON vec.definition_embeddings (tenant_id, capa, modulo);

COMMIT;

-- ================================================================
-- ARCHIVO: db/03_triggers.sql
-- ================================================================
-- ============================================================================
-- KALLICODE · 03_triggers.sql — Funciones y triggers
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- T1 · actualizado_en automático
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.actualizado_en := now();
    RETURN NEW;
END $$;

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'organizations','users','production_lines','tickets','jobs',
        'security_findings','connections','model_providers','branch_map'
    ] LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_%s_updated BEFORE UPDATE ON core.%I
             FOR EACH ROW EXECUTE FUNCTION core.set_updated_at()', t, t);
    END LOOP;
END $$;

-- ----------------------------------------------------------------------------
-- T2 · Correlativo visible KC-#### por tenant
--      Serializado con UPDATE ... RETURNING sobre ticket_counters (bloqueo de fila):
--      dos inserciones concurrentes del mismo tenant jamás repiten número.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.assign_ticket_numero() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
    IF NEW.numero IS NOT NULL THEN
        RETURN NEW;  -- permitir carga histórica con número explícito
    END IF;
    INSERT INTO core.ticket_counters (tenant_id) VALUES (NEW.tenant_id)
        ON CONFLICT (tenant_id) DO NOTHING;
    UPDATE core.ticket_counters
       SET ultimo = ultimo + 1
     WHERE tenant_id = NEW.tenant_id
     RETURNING ultimo INTO n;
    NEW.numero := 'KC-' || n::text;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_tickets_numero
    BEFORE INSERT ON core.tickets
    FOR EACH ROW EXECUTE FUNCTION core.assign_ticket_numero();

-- ----------------------------------------------------------------------------
-- T3 · Cadena de hashes de auditoría
--      sello = SHA-256(sello_previo || tenant || evento || resumen || datos || fecha)
--      chain_heads serializa por tenant (UPDATE bloquea la fila): la cadena
--      nunca se bifurca. La API NO calcula sellos: solo inserta el evento.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.seal_event() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE prev text;
BEGIN
    INSERT INTO audit.chain_heads (tenant_id) VALUES (NEW.tenant_id)
        ON CONFLICT (tenant_id) DO NOTHING;
    -- Bloquea la cabeza de cadena del tenant hasta el COMMIT:
    UPDATE audit.chain_heads
       SET eventos = eventos + 1
     WHERE tenant_id = NEW.tenant_id
     RETURNING ultimo_sello INTO prev;

    NEW.sello_previo := prev;
    NEW.creado_en    := now();
    NEW.sello := encode(sha256(convert_to(
        prev
        || NEW.tenant_id
        || NEW.evento
        || NEW.resumen
        || coalesce(NEW.datos::text, '')
        || coalesce(NEW.ticket_id, '')
        || coalesce(NEW.actor_id, '')
        || to_char(NEW.creado_en, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        'UTF8')), 'hex');

    UPDATE audit.chain_heads
       SET ultimo_sello = NEW.sello
     WHERE tenant_id = NEW.tenant_id;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_audit_seal
    BEFORE INSERT ON audit.audit_events
    FOR EACH ROW EXECUTE FUNCTION audit.seal_event();

-- Inmutabilidad: la tabla es append-only también a nivel de motor.
CREATE OR REPLACE FUNCTION audit.forbid_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'audit.audit_events es append-only: % prohibido', TG_OP
        USING ERRCODE = 'raise_exception';
END $$;

CREATE TRIGGER trg_audit_immutable
    BEFORE UPDATE OR DELETE ON audit.audit_events
    FOR EACH ROW EXECUTE FUNCTION audit.forbid_mutation();

-- Función de verificación de integridad de la cadena (usada por §validación
-- y por el endpoint GET /audit/integrity).
CREATE OR REPLACE FUNCTION audit.verify_chain(p_tenant text,
                                              p_desde timestamptz DEFAULT NULL,
                                              p_hasta timestamptz DEFAULT NULL)
RETURNS TABLE (integra boolean, eventos_verificados bigint, primer_evento_roto bigint)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    r record;
    esperado text;
    n bigint := 0;
BEGIN
    integra := true; primer_evento_roto := NULL;
    FOR r IN
        SELECT * FROM audit.audit_events
         WHERE tenant_id = p_tenant
           AND (p_desde IS NULL OR creado_en >= p_desde)
           AND (p_hasta IS NULL OR creado_en <= p_hasta)
         ORDER BY id
    LOOP
        n := n + 1;
        esperado := encode(sha256(convert_to(
            r.sello_previo || r.tenant_id || r.evento || r.resumen
            || coalesce(r.datos::text,'') || coalesce(r.ticket_id,'')
            || coalesce(r.actor_id,'')
            || to_char(r.creado_en, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
            'UTF8')), 'hex');
        IF esperado <> r.sello THEN
            integra := false;
            primer_evento_roto := r.id;
            EXIT;
        END IF;
    END LOOP;
    eventos_verificados := n;
    RETURN NEXT;
END $$;

-- ----------------------------------------------------------------------------
-- T4 · Inmutabilidad de specs: una versión emitida solo puede cambiar de estado
--      (pendiente_gate1 → aprobada | reemplazada | rechazada); el contenido no.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.spec_freeze() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.spec_md_ref    IS DISTINCT FROM OLD.spec_md_ref
    OR NEW.scope_paths    IS DISTINCT FROM OLD.scope_paths
    OR NEW.version        IS DISTINCT FROM OLD.version
    OR NEW.ticket_id      IS DISTINCT FROM OLD.ticket_id
    OR NEW.plan_tests     IS DISTINCT FROM OLD.plan_tests
    OR NEW.migraciones    IS DISTINCT FROM OLD.migraciones THEN
        RAISE EXCEPTION 'Las versiones de spec son inmutables: solo puede cambiar el estado';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_specs_freeze
    BEFORE UPDATE ON core.specs
    FOR EACH ROW EXECUTE FUNCTION core.spec_freeze();

-- ----------------------------------------------------------------------------
-- T5 · Precondición del Gate 3 (constraint trigger, DEFERRABLE):
--      no puede firmarse sin la aprobación previa de los gates 1 y 2.
--      (La app también lo valida; esto es el cinturón del motor.)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.gate3_requires_gates12() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.gate = 3 AND NEW.accion = 'aprobado' THEN
        IF (SELECT count(DISTINCT gate) FROM core.gate_signatures
             WHERE ticket_id = NEW.ticket_id
               AND gate IN (1,2) AND accion = 'aprobado') < 2 THEN
            RAISE EXCEPTION 'Gate 3 requiere los gates 1 y 2 aprobados (ticket %)', NEW.ticket_id;
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE CONSTRAINT TRIGGER trg_gate3_precondicion
    AFTER INSERT ON core.gate_signatures
    DEFERRABLE INITIALLY IMMEDIATE
    FOR EACH ROW EXECUTE FUNCTION core.gate3_requires_gates12();

-- ----------------------------------------------------------------------------
-- T6 · Agregado de consumo LOC por ciclo (QU-1)
--      Mantiene usage_cycles y calcula el umbral con el límite del plan vigente.
--      La app lee usage_cycles.umbral; el trigger nunca notifica (eso es de la app).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.accumulate_loc() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    lim integer;
    consumidas integer;
    nuevo_umbral text;
BEGIN
    SELECT p.loc_mes INTO lim
      FROM core.subscriptions s JOIN core.plans p ON p.codigo = s.plan_codigo
     WHERE s.tenant_id = NEW.tenant_id AND s.finaliza_el IS NULL;

    INSERT INTO core.usage_cycles (tenant_id, ciclo, loc_consumidas)
    VALUES (NEW.tenant_id, NEW.ciclo, greatest(NEW.netas, 0))
    ON CONFLICT (tenant_id, ciclo) DO UPDATE
       SET loc_consumidas = core.usage_cycles.loc_consumidas + greatest(NEW.netas, 0),
           actualizado_en = now()
    RETURNING loc_consumidas INTO consumidas;

    IF lim IS NULL THEN
        nuevo_umbral := 'normal';                        -- Enterprise: sin límite
    ELSIF consumidas >= lim THEN
        nuevo_umbral := 'agotado';
    ELSIF consumidas >= lim * 0.8 THEN
        nuevo_umbral := 'aviso_80';
    ELSE
        nuevo_umbral := 'normal';
    END IF;

    UPDATE core.usage_cycles
       SET umbral = nuevo_umbral
     WHERE tenant_id = NEW.tenant_id AND ciclo = NEW.ciclo
       AND umbral IS DISTINCT FROM nuevo_umbral;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_usage_loc_acumula
    AFTER INSERT ON core.usage_loc
    FOR EACH ROW EXECUTE FUNCTION core.accumulate_loc();

-- ----------------------------------------------------------------------------
-- T7 · Sincronía jobs ⇄ production_lines
--      Al asignar/liberar línea en jobs, la fila de production_lines se
--      actualiza en la misma transacción (una sola fuente de verdad visible).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.sync_line_state() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    -- Liberación (job terminó, se pausó sin línea o cambió de línea):
    IF TG_OP = 'UPDATE'
       AND OLD.linea IS NOT NULL
       AND (NEW.linea IS DISTINCT FROM OLD.linea
            OR NEW.estado IN ('produccion','cancelado','cerrado_duplicado')) THEN
        UPDATE core.production_lines
           SET estado = 'disponible', job_id = NULL
         WHERE tenant_id = OLD.tenant_id AND numero = OLD.linea AND job_id = OLD.id;
    END IF;
    -- Ocupación:
    IF NEW.linea IS NOT NULL
       AND NEW.estado NOT IN ('produccion','cancelado','cerrado_duplicado') THEN
        UPDATE core.production_lines
           SET estado = 'ocupada', job_id = NEW.id
         WHERE tenant_id = NEW.tenant_id AND numero = NEW.linea;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_jobs_sync_linea
    AFTER INSERT OR UPDATE OF linea, estado ON core.jobs
    FOR EACH ROW EXECUTE FUNCTION core.sync_line_state();

-- ----------------------------------------------------------------------------
-- T8 · Historial de transiciones de job automático
--      Cada cambio de estado del job queda en job_transitions aunque la app
--      olvide registrarlo (la app añade motivo/contexto en su propio insert).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.log_job_transition() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.estado IS DISTINCT FROM OLD.estado THEN
        INSERT INTO core.job_transitions (tenant_id, job_id, de_estado, a_estado, actor)
        VALUES (NEW.tenant_id, NEW.id, OLD.estado, NEW.estado,
                coalesce(current_setting('app.actor', true), 'sistema'));
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_jobs_transicion
    AFTER UPDATE OF estado ON core.jobs
    FOR EACH ROW EXECUTE FUNCTION core.log_job_transition();

-- ----------------------------------------------------------------------------
-- T9 · Espejo ticket ⇄ job: la etapa visible del ticket sigue al estado del job.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.mirror_ticket_stage() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_etapa text;
    v_gate smallint;
BEGIN
    v_gate := NULL;
    CASE NEW.estado
        WHEN 'gate1' THEN v_etapa := 'design';   v_gate := 1;
        WHEN 'gate2' THEN v_etapa := 'qa';       v_gate := 2;
        WHEN 'gate3' THEN v_etapa := 'deploy';   v_gate := 3;
        WHEN 'deploy_preflight' THEN v_etapa := 'deploy';
        WHEN 'pendiente_asignacion' THEN v_etapa := 'triage';
        WHEN 'pausado_por_cuota' THEN v_etapa := 'en_cola_por_cuota';
        WHEN 'escalado_humano' THEN v_etapa := NULL;  -- conserva la etapa visible
        ELSE v_etapa := NEW.estado;
    END CASE;

    IF v_etapa IS NOT NULL THEN
        UPDATE core.tickets
           SET etapa = v_etapa,
               gate_pendiente = v_gate,
               cerrado_en = CASE WHEN v_etapa IN ('produccion','cancelado','cerrado_duplicado')
                                 THEN coalesce(cerrado_en, now()) ELSE cerrado_en END
         WHERE id = NEW.ticket_id;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_jobs_espejo_ticket
    AFTER INSERT OR UPDATE OF estado ON core.jobs
    FOR EACH ROW EXECUTE FUNCTION core.mirror_ticket_stage();

-- ----------------------------------------------------------------------------
-- T10 · El creador del ticket siempre es visualizador (y no puede eliminarse).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.creator_is_watcher() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.reportado_por IS NOT NULL THEN
        INSERT INTO core.ticket_watchers (tenant_id, ticket_id, user_id)
        VALUES (NEW.tenant_id, NEW.id, NEW.reportado_por)
        ON CONFLICT DO NOTHING;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_tickets_watcher_creador
    AFTER INSERT ON core.tickets
    FOR EACH ROW EXECUTE FUNCTION core.creator_is_watcher();

CREATE OR REPLACE FUNCTION core.protect_creator_watcher() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE creador text;
BEGIN
    SELECT reportado_por INTO creador FROM core.tickets WHERE id = OLD.ticket_id;
    IF creador = OLD.user_id THEN
        RAISE EXCEPTION 'El creador del ticket no puede eliminarse como visualizador';
    END IF;
    RETURN OLD;
END $$;

CREATE TRIGGER trg_watchers_protege_creador
    BEFORE DELETE ON core.ticket_watchers
    FOR EACH ROW EXECUTE FUNCTION core.protect_creator_watcher();

COMMIT;

-- ================================================================
-- ARCHIVO: db/04_rls.sql
-- ================================================================
-- ============================================================================
-- KALLICODE · 04_rls.sql — Row-Level Security y permisos
-- La API ejecuta al abrir cada transacción:
--     SET LOCAL app.tenant_id = '<org del JWT>';
-- kallicode_app queda confinado al tenant de la sesión; un recurso ajeno
-- es indistinguible de uno inexistente.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- Permisos base
-- ----------------------------------------------------------------------------
GRANT USAGE ON SCHEMA core, vec, audit TO kallicode_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA core TO kallicode_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA vec  TO kallicode_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA core TO kallicode_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA audit TO kallicode_app;

-- Auditoría: SOLO INSERT y SELECT (append-only también por permisos).
GRANT SELECT, INSERT ON audit.audit_events TO kallicode_app;
GRANT SELECT, INSERT, UPDATE ON audit.chain_heads TO kallicode_app; -- la actualiza el trigger
REVOKE UPDATE, DELETE, TRUNCATE ON audit.audit_events FROM kallicode_app;

-- Catálogos globales: solo lectura para la app.
REVOKE INSERT, UPDATE, DELETE ON core.plans FROM kallicode_app;

-- Ledger de migraciones: solo lo toca el runner (kallicode_admin).
REVOKE ALL ON core.schema_migrations FROM kallicode_app;

-- ----------------------------------------------------------------------------
-- RLS: política uniforme por tenant_id
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT schemaname, tablename
          FROM pg_tables
         WHERE schemaname IN ('core','vec','audit')
           AND tablename NOT IN ('plans', 'schema_migrations') -- globales sin RLS
    LOOP
        EXECUTE format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', r.schemaname, r.tablename);
        EXECUTE format('ALTER TABLE %I.%I FORCE ROW LEVEL SECURITY',  r.schemaname, r.tablename);
        IF r.tablename = 'organizations' THEN
            -- La tabla raíz filtra por su propio id:
            EXECUTE format($sql$
                CREATE POLICY tenant_isolation ON %I.%I
                USING (id = core.current_tenant())
                WITH CHECK (id = core.current_tenant())
            $sql$, r.schemaname, r.tablename);
        ELSE
            EXECUTE format($sql$
                CREATE POLICY tenant_isolation ON %I.%I
                USING (tenant_id = core.current_tenant())
                WITH CHECK (tenant_id = core.current_tenant())
            $sql$, r.schemaname, r.tablename);
        END IF;
    END LOOP;
END $$;

-- idempotency_keys no tiene FK a organizations pero sí tenant_id: cubierta arriba.
-- ticket_counters: cubierta (PK = tenant_id → columna tenant_id existe).

-- ----------------------------------------------------------------------------
-- Rol administrador (migraciones, soporte): sin RLS.
-- Su BYPASSRLS y sus atributos se fijan en db/00_roles.sql (KC-DB-01-5).
-- ----------------------------------------------------------------------------
GRANT USAGE ON SCHEMA core, vec, audit TO kallicode_admin;
GRANT ALL ON ALL TABLES IN SCHEMA core, vec TO kallicode_admin;
GRANT SELECT, INSERT ON audit.audit_events TO kallicode_admin;
GRANT ALL ON audit.chain_heads TO kallicode_admin;

-- Defaults para objetos futuros:
ALTER DEFAULT PRIVILEGES IN SCHEMA core
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO kallicode_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA vec
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO kallicode_app;

COMMIT;

-- ================================================================
-- ARCHIVO: db/05_validacion.sql
-- ================================================================
-- ============================================================================
-- KALLICODE · 05_validacion.sql — Validación de integridad
-- Ejecutar con un rol sin RLS (kallicode_admin) para validar todos los tenants,
-- o con app.tenant_id fijado para validar uno solo.
-- Uso:  SELECT * FROM core.validar_integridad();          -- todos los chequeos
--       SELECT * FROM core.validar_integridad() WHERE problemas > 0;
--
-- OJO: esta es la versión BASE (V01-V20). La función vigente la reemplazan las
-- migraciones de db/migrations/ (011_v21_coherencia_tenant.sql añade V21);
-- un chequeo nuevo va en una migración nueva, no editando este archivo.
-- ============================================================================

BEGIN;

DROP FUNCTION IF EXISTS core.validar_integridad();
CREATE OR REPLACE FUNCTION core.validar_integridad()
RETURNS TABLE (chequeo text, descripcion text, problemas bigint)
LANGUAGE plpgsql STABLE AS $$
BEGIN

-- V01 · Suscripción vigente: todo tenant activo debe tener exactamente una.
chequeo := 'V01_suscripcion_vigente';
descripcion := 'Tenants sin suscripción vigente (o con más de una)';
SELECT count(*) INTO problemas FROM (
    SELECT o.id
      FROM core.organizations o
      LEFT JOIN core.subscriptions s
             ON s.tenant_id = o.id AND s.finaliza_el IS NULL
     WHERE o.eliminado_en IS NULL
     GROUP BY o.id
    HAVING count(s.id) <> 1
) q;
RETURN NEXT;

-- V02 · Ticket ⇄ job: la etapa visible del ticket debe corresponder al job activo.
chequeo := 'V02_espejo_ticket_job';
descripcion := 'Tickets activos cuya etapa no corresponde al estado de su job';
SELECT count(*) INTO problemas
  FROM core.tickets t
  JOIN core.jobs j ON j.ticket_id = t.id
             AND j.estado NOT IN ('produccion','cancelado','cerrado_duplicado')
 WHERE t.etapa <> CASE j.estado
        WHEN 'gate1' THEN 'design'
        WHEN 'gate2' THEN 'qa'
        WHEN 'gate3' THEN 'deploy'
        WHEN 'deploy_preflight' THEN 'deploy'
        WHEN 'pendiente_asignacion' THEN 'triage'
        WHEN 'pausado_por_cuota' THEN 'en_cola_por_cuota'
        WHEN 'escalado_humano' THEN t.etapa
        ELSE j.estado END;
RETURN NEXT;

-- V03 · Gate 3 sin gates 1 y 2 (el trigger lo impide; verificación de defensa).
chequeo := 'V03_gate3_sin_previos';
descripcion := 'Aprobaciones de Gate 3 sin aprobación previa de gates 1 y 2';
SELECT count(*) INTO problemas
  FROM core.gate_signatures g3
 WHERE g3.gate = 3 AND g3.accion = 'aprobado'
   AND 2 > (SELECT count(DISTINCT g.gate) FROM core.gate_signatures g
             WHERE g.ticket_id = g3.ticket_id
               AND g.gate IN (1,2) AND g.accion = 'aprobado'
               AND g.creado_en <= g3.creado_en);
RETURN NEXT;

-- V04 · Tickets en producción con las tres firmas.
chequeo := 'V04_produccion_sin_firmas';
descripcion := 'Tickets en producción sin las tres firmas de gates';
SELECT count(*) INTO problemas
  FROM core.tickets t
 WHERE t.etapa = 'produccion'
   AND 3 > (SELECT count(DISTINCT gate) FROM core.gate_signatures
             WHERE ticket_id = t.id AND accion = 'aprobado');
RETURN NEXT;

-- V05 · Specs: exactamente una alternativa recomendada por versión.
chequeo := 'V05_spec_recomendada';
descripcion := 'Specs sin exactamente una alternativa recomendada';
SELECT count(*) INTO problemas FROM (
    SELECT s.id FROM core.specs s
      LEFT JOIN core.spec_alternatives a ON a.spec_id = s.id AND a.recomendada
     GROUP BY s.id HAVING count(a.alt_id) <> 1
) q;
RETURN NEXT;

-- V06 · Specs aprobadas con alternativa elegida.
chequeo := 'V06_spec_aprobada_sin_eleccion';
descripcion := 'Specs aprobadas (Gate 1) sin alternativa elegida';
SELECT count(*) INTO problemas FROM (
    SELECT s.id FROM core.specs s
     WHERE s.estado = 'aprobada'
       AND NOT EXISTS (SELECT 1 FROM core.spec_alternatives a
                        WHERE a.spec_id = s.id AND a.elegida)
       AND EXISTS (SELECT 1 FROM core.spec_alternatives a WHERE a.spec_id = s.id)
) q;
RETURN NEXT;

-- V07 · Matriz de QA completa: cada corrida cubre todos los criterios de su spec.
chequeo := 'V07_matriz_qa_completa';
descripcion := 'Corridas de QA que no cubren todos los criterios de la spec';
SELECT count(*) INTO problemas FROM (
    SELECT r.id
      FROM core.qa_runs r
      JOIN core.spec_criteria c ON c.spec_id = r.spec_id
      LEFT JOIN core.qa_results q ON q.qa_run_id = r.id AND q.criterio_id = c.criterio_id
     GROUP BY r.id
    HAVING count(c.criterio_id) <> count(q.criterio_id)
) q;
RETURN NEXT;

-- V08 · Resultados de QA que referencian criterios inexistentes en la spec.
chequeo := 'V08_qa_criterio_fantasma';
descripcion := 'Resultados de QA con criterio_id que no existe en la spec de la corrida';
SELECT count(*) INTO problemas
  FROM core.qa_results q
  JOIN core.qa_runs r ON r.id = q.qa_run_id
 WHERE NOT EXISTS (SELECT 1 FROM core.spec_criteria c
                    WHERE c.spec_id = r.spec_id AND c.criterio_id = q.criterio_id);
RETURN NEXT;

-- V09 · Deploy bloqueado: tickets en produccion con hallazgos bloqueantes abiertos.
chequeo := 'V09_produccion_con_bloqueantes';
descripcion := 'Tickets en producción con hallazgos de seguridad bloqueantes abiertos';
SELECT count(*) INTO problemas
  FROM core.tickets t
 WHERE t.etapa = 'produccion'
   AND EXISTS (SELECT 1 FROM core.security_findings f
                WHERE f.ticket_id = t.id AND f.bloquea AND f.estado = 'abierto');
RETURN NEXT;

-- V10 · Agregado de cuota: usage_cycles debe cuadrar con la suma de usage_loc.
chequeo := 'V10_cuota_cuadra';
descripcion := 'Ciclos cuyo agregado no cuadra con la suma de usage_loc';
SELECT count(*) INTO problemas FROM (
    SELECT c.tenant_id, c.ciclo
      FROM core.usage_cycles c
      LEFT JOIN core.usage_loc l ON l.tenant_id = c.tenant_id AND l.ciclo = c.ciclo
     GROUP BY c.tenant_id, c.ciclo, c.loc_consumidas
    HAVING c.loc_consumidas <> coalesce(sum(greatest(l.netas,0)), 0)
) q;
RETURN NEXT;

-- V11 · Líneas: coherencia production_lines ⇄ jobs.
chequeo := 'V11_lineas_coherentes';
descripcion := 'Líneas ocupadas sin job activo o jobs con línea no reflejada';
SELECT count(*) INTO problemas FROM (
    SELECT pl.tenant_id, pl.numero
      FROM core.production_lines pl
      LEFT JOIN core.jobs j ON j.id = pl.job_id
             AND j.estado NOT IN ('produccion','cancelado','cerrado_duplicado')
     WHERE (pl.estado = 'ocupada') <> (j.id IS NOT NULL)
    UNION ALL
    SELECT j.tenant_id, j.linea
      FROM core.jobs j
      LEFT JOIN core.production_lines pl
             ON pl.tenant_id = j.tenant_id AND pl.numero = j.linea AND pl.job_id = j.id
     WHERE j.linea IS NOT NULL
       AND j.estado NOT IN ('produccion','cancelado','cerrado_duplicado')
       AND pl.job_id IS NULL
) q;
RETURN NEXT;

-- V12 · Líneas concurrentes dentro del plan (QU-2).
chequeo := 'V12_lineas_dentro_del_plan';
descripcion := 'Tenants con más jobs en línea que líneas de su plan';
SELECT count(*) INTO problemas FROM (
    SELECT j.tenant_id
      FROM core.jobs j
      JOIN core.subscriptions s ON s.tenant_id = j.tenant_id AND s.finaliza_el IS NULL
      JOIN core.plans p ON p.codigo = s.plan_codigo
     WHERE j.linea IS NOT NULL
       AND j.estado NOT IN ('produccion','cancelado','cerrado_duplicado')
     GROUP BY j.tenant_id, p.lineas
    HAVING p.lineas IS NOT NULL AND count(*) > p.lineas
) q;
RETURN NEXT;

-- V13 · Duplicados: cadena sin ciclos de un nivel y sin duplicado_de colgante.
chequeo := 'V13_duplicados_validos';
descripcion := 'Tickets duplicados que apuntan a otro duplicado (cadenas)';
SELECT count(*) INTO problemas
  FROM core.tickets t
  JOIN core.tickets d ON d.id = t.duplicado_de
 WHERE d.duplicado_de IS NOT NULL;
RETURN NEXT;

-- V14 · Embeddings huérfanos o faltantes (vec ⇄ core).
chequeo := 'V14_embeddings_tickets';
descripcion := 'Tickets activos (>1 h) sin embedding de deduplicación';
SELECT count(*) INTO problemas
  FROM core.tickets t
 WHERE t.etapa NOT IN ('cancelado','cerrado_duplicado')
   AND t.creado_en < now() - interval '1 hour'
   AND NOT EXISTS (SELECT 1 FROM vec.ticket_embeddings e WHERE e.ticket_id = t.id);
RETURN NEXT;

-- V15 · Dimensión de embeddings homogénea (1024).
chequeo := 'V15_dimension_embeddings';
descripcion := 'Embeddings con dimensión distinta de 1024';
SELECT (SELECT count(*) FROM vec.ticket_embeddings     WHERE vector_dims(embedding) <> 1024)
     + (SELECT count(*) FROM vec.doc_chunks            WHERE vector_dims(embedding) <> 1024)
     + (SELECT count(*) FROM vec.definition_embeddings WHERE vector_dims(embedding) <> 1024)
  INTO problemas;
RETURN NEXT;

-- V16 · Cadena de auditoría íntegra (recorre todos los tenants visibles).
chequeo := 'V16_cadena_auditoria';
descripcion := 'Tenants con cadena de hashes rota (ver audit.verify_chain)';
SELECT count(*) INTO problemas FROM (
    SELECT h.tenant_id
      FROM audit.chain_heads h,
           LATERAL audit.verify_chain(h.tenant_id) v
     WHERE NOT v.integra
) q;
RETURN NEXT;

-- V17 · Cabeza de cadena consistente con el último evento.
chequeo := 'V17_cabeza_cadena';
descripcion := 'chain_heads cuyo último sello no coincide con el último evento';
SELECT count(*) INTO problemas FROM (
    SELECT h.tenant_id
      FROM audit.chain_heads h
      LEFT JOIN LATERAL (
          SELECT sello FROM audit.audit_events e
           WHERE e.tenant_id = h.tenant_id
           ORDER BY e.id DESC LIMIT 1) ult ON true
     WHERE h.eventos > 0 AND ult.sello IS DISTINCT FROM h.ultimo_sello
) q;
RETURN NEXT;

-- V18 · Webhooks: fallidos estancados (>24 h sin reproceso).
chequeo := 'V18_webhooks_estancados';
descripcion := 'Entradas de webhook_inbox fallidas hace más de 24 h';
SELECT count(*) INTO problemas
  FROM core.webhook_inbox
 WHERE estado = 'fallido' AND recibido_en < now() - interval '24 hours';
RETURN NEXT;

-- V19 · Adjuntos huérfanos vencidos (>48 h sin asociar): candidatos a purga.
chequeo := 'V19_adjuntos_huerfanos';
descripcion := 'Adjuntos sin ticket asociado hace más de 48 h';
SELECT count(*) INTO problemas
  FROM core.ticket_attachments
 WHERE ticket_id IS NULL AND creado_en < now() - interval '48 hours';
RETURN NEXT;

-- V20 · Gates aprobados apuntando a specs de otro ticket.
chequeo := 'V20_gate_spec_coherente';
descripcion := 'Firmas de Gate 1 cuya spec no pertenece al mismo ticket';
SELECT count(*) INTO problemas
  FROM core.gate_signatures g
  JOIN core.specs s ON s.id = g.spec_id
 WHERE g.spec_id IS NOT NULL AND s.ticket_id <> g.ticket_id;
RETURN NEXT;

END $$;

COMMENT ON FUNCTION core.validar_integridad() IS
'Batería de chequeos de integridad de negocio. Programar ejecución nocturna y
alertar si cualquier fila devuelve problemas > 0. Los chequeos V16/V17 verifican
la cadena de hashes de auditoría; V10/V12 la validación comercial.';

COMMIT;

-- ----------------------------------------------------------------------------
-- Consultas sueltas de apoyo (no forman parte de la función):
-- ----------------------------------------------------------------------------
-- Verificar la cadena de un tenant concreto:
--   SELECT * FROM audit.verify_chain('org_acme');
-- Consumo de un ciclo vs límite del plan:
--   SELECT c.*, p.loc_mes
--     FROM core.usage_cycles c
--     JOIN core.subscriptions s ON s.tenant_id = c.tenant_id AND s.finaliza_el IS NULL
--     JOIN core.plans p ON p.codigo = s.plan_codigo
--    WHERE c.ciclo = to_char(now(), 'YYYY-MM');
-- Duplicados vectoriales candidatos (ejemplo de uso de pgvector):
--   SELECT t.numero, 1 - (e.embedding <=> q.embedding) AS similitud
--     FROM vec.ticket_embeddings q
--     JOIN vec.ticket_embeddings e ON e.ticket_id <> q.ticket_id
--     JOIN core.tickets t ON t.id = e.ticket_id
--    WHERE q.ticket_id = :ticket
--    ORDER BY e.embedding <=> q.embedding LIMIT 5;

-- ================================================================
-- ARCHIVO: db/migrations/001_vec_modelo_embedding_hash.sql
-- ================================================================
-- ============================================================================
-- KALLICODE · 001_vec_modelo_embedding_hash.sql
-- KC-ONB-02-1 (DB-F18) — Migración DDL en vec.*: estandariza modelo de
-- embedding y hash de contenido en las tres tablas vectoriales.
--
-- vec.ticket_embeddings ya tenía modelo_embedding + texto_hash (01_schema.sql).
-- Esta migración agrega las mismas columnas a vec.doc_chunks y
-- vec.definition_embeddings, con el mismo propósito: permitir a los workers
-- saltarse el re-embeber cuando el contenido no cambió, y saber con qué
-- modelo se generó cada vector si en el futuro se migra a otro.
--
-- Convención de hash (ver apps/workers/.../normalizer.py):
--   sha256(texto_embebido).hexdigest()[:32]
--
-- Ambas tablas están vacías en todos los entornos existentes (no hay INSERT
-- en db/seeds/dev.sql), por lo que agregar texto_hash NOT NULL sin DEFAULT
-- es seguro: no hay filas que violen el constraint.
--
-- Índices HNSW: ya existen para las tres tablas desde 02_indexes.sql
-- (ticket_embeddings_hnsw_ix, doc_chunks_hnsw_ix, definition_embeddings_hnsw_ix,
-- todos m=16/ef_construction=64/coseno) — no requieren cambios en este ticket.
-- ============================================================================


ALTER TABLE vec.doc_chunks
    ADD COLUMN modelo_embedding text NOT NULL DEFAULT 'bge-m3',
    ADD COLUMN texto_hash       text NOT NULL;              -- re-embeber solo si cambió

ALTER TABLE vec.definition_embeddings
    ADD COLUMN modelo_embedding text NOT NULL DEFAULT 'bge-m3',
    ADD COLUMN texto_hash       text NOT NULL;              -- re-embeber solo si cambió


-- ================================================================
-- ARCHIVO: db/migrations/002_esquema_cm.sql
-- ================================================================
-- ============================================================================
-- KALLICODE · 002_esquema_cm.sql
-- KC-ONB-03-1 — Despliegue del esquema cm (CodeMapping) acordado en
-- KC-ONB-02-4: grafo de conocimiento del código en PostgreSQL 16, reemplaza
-- el diseño anterior sobre Neo4j (decisión D18). Ver docs/esquema_cm.md.
--
-- Aislamiento multi-tenant: tenant_id + RLS, igual que core/vec/audit. El
-- RLS de cm queda autocontenido al final de este archivo (no en
-- db/04_rls.sql, que corre antes que las migraciones en `make db`).
-- ============================================================================


CREATE SCHEMA IF NOT EXISTS cm;   -- grafo de conocimiento de CodeMapping

-- ----------------------------------------------------------------------------
-- Snapshots de ingesta: una fila por corrida (completa o refresco). El grafo
-- de un snapshot no se considera vigente hasta estado = 'completo'.
-- ----------------------------------------------------------------------------
CREATE TABLE cm.repo_snapshots (
    id             text NOT NULL,                 -- snap_<ulid>
    tenant_id      text NOT NULL REFERENCES core.organizations(id),
    commit_sha     text NOT NULL,
    rama           text NOT NULL,
    estado         text NOT NULL DEFAULT 'en_progreso',
    fase_actual    text,                           -- último punto de control confirmado
    stats          jsonb NOT NULL DEFAULT '{}',    -- recuentos por capa, duración por fase
    iniciado_en    timestamptz NOT NULL DEFAULT now(),
    finalizado_en  timestamptz,
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT snapshots_estado_chk CHECK (estado IN ('en_progreso','completo','fallido','pendiente_intervencion'))
);

-- ----------------------------------------------------------------------------
-- Archivos, símbolos: capa determinista (fases 1-2 de CodeMapping)
-- ----------------------------------------------------------------------------
CREATE TABLE cm.files (
    id            text NOT NULL,                   -- file_<ulid determinista>
    tenant_id     text NOT NULL REFERENCES core.organizations(id),
    path          text NOT NULL,
    language      text NOT NULL,
    sha256        text NOT NULL,
    snapshot_id   text NOT NULL,
    PRIMARY KEY (tenant_id, id),
    UNIQUE (tenant_id, path),
    FOREIGN KEY (tenant_id, snapshot_id) REFERENCES cm.repo_snapshots(tenant_id, id)
);

CREATE TABLE cm.symbols (
    id           text NOT NULL,                    -- sha1(path:name:línea:col)
    tenant_id    text NOT NULL REFERENCES core.organizations(id),
    file_id      text NOT NULL,
    kind         text NOT NULL,
    name         text NOT NULL,
    start_line   integer NOT NULL,
    end_line     integer NOT NULL,
    signature    text NOT NULL,
    descripcion  text,                              -- la llena la fase semántica (LLM)
    role         text,                              -- domain | infra | glue
    PRIMARY KEY (tenant_id, id),
    FOREIGN KEY (tenant_id, file_id) REFERENCES cm.files(tenant_id, id) ON DELETE CASCADE,
    CONSTRAINT symbols_kind_chk CHECK (kind IN ('function','method','class','interface','enum','type')),
    CONSTRAINT symbols_role_chk CHECK (role IS NULL OR role IN ('domain','infra','glue'))
);

-- ----------------------------------------------------------------------------
-- Esquema de la base del cliente: capa determinista (fase 3)
-- ----------------------------------------------------------------------------
CREATE TABLE cm.db_tables (
    id        text NOT NULL,                        -- dbt_<ulid determinista>
    tenant_id text NOT NULL REFERENCES core.organizations(id),
    esquema   text NOT NULL,
    nombre    text NOT NULL,
    PRIMARY KEY (tenant_id, id),
    UNIQUE (tenant_id, esquema, nombre)
);

CREATE TABLE cm.db_columns (
    id        text NOT NULL,                        -- dbc_<ulid determinista>
    tenant_id text NOT NULL REFERENCES core.organizations(id),
    table_id  text NOT NULL,
    nombre    text NOT NULL,
    tipo      text NOT NULL,
    nullable  boolean NOT NULL,
    PRIMARY KEY (tenant_id, id),
    UNIQUE (tenant_id, table_id, nombre),
    FOREIGN KEY (tenant_id, table_id) REFERENCES cm.db_tables(tenant_id, id) ON DELETE CASCADE
);

-- ----------------------------------------------------------------------------
-- Capa semántica: definiciones técnicas y conceptos de negocio (fase 4, LLM)
-- ----------------------------------------------------------------------------
CREATE TABLE cm.definitions (
    id          text NOT NULL,                      -- def_<ulid determinista>
    tenant_id   text NOT NULL REFERENCES core.organizations(id),
    modulo      text NOT NULL,
    nombre      text NOT NULL,
    kind        text NOT NULL,
    descripcion text NOT NULL,
    PRIMARY KEY (tenant_id, id)
);

CREATE TABLE cm.concepts (
    id          text NOT NULL,                      -- con_<ulid determinista>
    tenant_id   text NOT NULL REFERENCES core.organizations(id),
    name_en     text NOT NULL,
    name_local  text NOT NULL,
    descripcion text NOT NULL,
    confianza   numeric(4,3),
    curado_por  text REFERENCES core.users(id),
    curado_en   timestamptz,
    PRIMARY KEY (tenant_id, id),
    UNIQUE (tenant_id, name_en),
    CONSTRAINT concepts_conf_chk CHECK (confianza IS NULL OR (confianza >= 0 AND confianza <= 1))
);

-- ----------------------------------------------------------------------------
-- Aristas: toda relación del grafo en una sola tabla genérica. src_kind y
-- dst_kind identifican a qué tabla pertenece el nodo (file | symbol |
-- db_table | db_column | definition | concept); sin FK cruzada porque el
-- destino varía según el tipo.
-- ----------------------------------------------------------------------------
CREATE TABLE cm.edges (
    tenant_id text NOT NULL REFERENCES core.organizations(id),
    tipo      text NOT NULL,
    src_kind  text NOT NULL,
    src_id    text NOT NULL,
    dst_kind  text NOT NULL,
    dst_id    text NOT NULL,
    props     jsonb NOT NULL DEFAULT '{}',          -- ej. {"confidence": 0.9} en EXPRESSES
    PRIMARY KEY (tenant_id, tipo, src_id, dst_id),
    CONSTRAINT edges_tipo_chk CHECK (tipo IN
        ('DEFINES','CALLS','HAS_COLUMN','REFERENCES','USES_TABLE','REALIZED_BY','RELATES','EXPRESSES')),
    CONSTRAINT edges_kind_chk CHECK (
        src_kind IN ('file','symbol','db_table','db_column','definition','concept') AND
        dst_kind IN ('file','symbol','db_table','db_column','definition','concept'))
);

-- ----------------------------------------------------------------------------
-- Curación humana, nuggets e incidentes (épica ECM5 — sin consumidores en
-- este ticket, pero se crean ya para no repartir la migración del esquema)
-- ----------------------------------------------------------------------------
CREATE TABLE cm.curation_queue (
    id           text NOT NULL,                      -- cq_<ulid>
    tenant_id    text NOT NULL REFERENCES core.organizations(id),
    tipo         text NOT NULL,                       -- concepto | enlace | nugget
    payload      jsonb NOT NULL,
    estado       text NOT NULL DEFAULT 'pendiente',
    revisado_por text REFERENCES core.users(id),
    revisado_en  timestamptz,
    creado_en    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT curation_estado_chk CHECK (estado IN ('pendiente','aprobado','rechazado'))
);

CREATE TABLE cm.nuggets (
    id            text NOT NULL,                     -- ng_<ulid>
    tenant_id     text NOT NULL REFERENCES core.organizations(id),
    regla         text NOT NULL,
    scope_refs    jsonb NOT NULL DEFAULT '[]',
    evidencia_ref text NOT NULL,
    estado        text NOT NULL DEFAULT 'propuesto',
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT nuggets_estado_chk CHECK (estado IN ('propuesto','aprobado','rechazado'))
);

CREATE TABLE cm.incidents (
    id                text NOT NULL,                 -- inc_<ulid>
    tenant_id         text NOT NULL REFERENCES core.organizations(id),
    ticket_id         text REFERENCES core.tickets(id),
    resumen           text NOT NULL,
    causa             text,
    correccion        text,
    nodos_afectados   jsonb NOT NULL DEFAULT '[]',
    creado_en         timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, id)
);

-- ----------------------------------------------------------------------------
-- Permisos y RLS de cm (mismo patrón que db/04_rls.sql). Autocontenido en
-- esta migración: 04_rls.sql corre antes que db/migrations/ en `make db`
-- (ver Makefile), así que un GRANT sobre 'cm' ahí fallaría en una
-- instalación nueva por no existir todavía el esquema.
-- ----------------------------------------------------------------------------
GRANT USAGE ON SCHEMA cm TO kallicode_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA cm TO kallicode_app;

DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT schemaname, tablename
          FROM pg_tables
         WHERE schemaname = 'cm'
    LOOP
        EXECUTE format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', r.schemaname, r.tablename);
        EXECUTE format('ALTER TABLE %I.%I FORCE ROW LEVEL SECURITY',  r.schemaname, r.tablename);
        EXECUTE format($sql$
            CREATE POLICY tenant_isolation ON %I.%I
            USING (tenant_id = core.current_tenant())
            WITH CHECK (tenant_id = core.current_tenant())
        $sql$, r.schemaname, r.tablename);
    END LOOP;
END $$;


-- ================================================================
-- ARCHIVO: db/migrations/009_admitir_tier_fable.sql
-- ================================================================
-- Migración DDL: KC-FAB-03-1 (Cierres BE-F10, BE-F41)
-- Amplía la restricción CHECK de tier en core.llm_steps y core.usage_tokens para admitir 'fable'
--
-- Nota (fusión kallicode-backend -> kallicode-backend-1): los nombres de
-- restricción originales (llm_steps_tier_check, usage_tokens_tier_check) no
-- existen en el esquema real -- core.llm_steps la nombra step_tier_chk, y
-- core.usage_tokens no tenía restricción de tier en absoluto. Corregido para
-- que la migración aplique contra el esquema real.

-- 1. Actualizar core.llm_steps
ALTER TABLE core.llm_steps
    DROP CONSTRAINT step_tier_chk;

ALTER TABLE core.llm_steps
    ADD CONSTRAINT step_tier_chk
    CHECK (tier IN ('flash', 'pro', 'fable'));

-- 2. Actualizar core.usage_tokens (no tenía restricción de tier previa)
ALTER TABLE core.usage_tokens
    ADD CONSTRAINT ut_tier_chk
    CHECK (tier IN ('flash', 'pro', 'fable'));
-- ================================================================
-- ARCHIVO: db/migrations/010_rol_worker.sql
-- ================================================================
-- ============================================================================
-- KALLICODE · 010_rol_worker.sql
-- KC-DB-02-2 (DB-F11) — Rol kallicode_worker y políticas para las colas
-- cross-tenant.
--
-- Los workers barren colas de TODOS los tenants (normalizador, planificador,
-- purgas), pero RLS solo deja ver un tenant por sesión. Hasta ahora usaban
-- kallicode_admin (BYPASSRLS): un defecto en un worker exponía todo el esquema.
--
-- kallicode_worker ve TODOS los tenants solo en estas 5 tablas, por política
-- (no por BYPASSRLS), y nada en el resto: sin GRANT, cualquier otra tabla
-- responde "permission denied".
--
--   Tabla                   Índice que sirve el barrido   Operaciones
--   core.webhook_inbox      webhook_inbox_pend_ix         SELECT, UPDATE, DELETE
--   core.jobs               jobs_pendientes_ix            SELECT
--   core.refresh_tokens     refresh_tokens_expira_ix      SELECT, DELETE
--   core.ticket_attachments attachments_ticket_ix (*)     SELECT, DELETE
--   core.idempotency_keys   idempotency_purga_ix          SELECT, DELETE
--
--   (*) El planificador prefiere attachments_ticket_ix (ticket_id IS NULL)
--       a attachments_huerfanos_ix, que queda redundante (KC-DB-06-3).
--
-- Sin BEGIN/COMMIT: el runner abre la transacción (db/migrations/README.md).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Privilegios mínimos: solo las operaciones que usan los workers.
--    (UPDATE en webhook_inbox también lo exige el SELECT ... FOR UPDATE
--    SKIP LOCKED del normalizador.)
-- ----------------------------------------------------------------------------
GRANT USAGE ON SCHEMA core TO kallicode_worker;

GRANT SELECT, UPDATE, DELETE ON core.webhook_inbox      TO kallicode_worker;
GRANT SELECT                 ON core.jobs               TO kallicode_worker;
GRANT SELECT, DELETE         ON core.refresh_tokens     TO kallicode_worker;
GRANT SELECT, DELETE         ON core.ticket_attachments TO kallicode_worker;
GRANT SELECT, DELETE         ON core.idempotency_keys   TO kallicode_worker;

-- ----------------------------------------------------------------------------
-- 2. Políticas: las políticas permisivas de una tabla se combinan con OR. A
--    tenant_isolation ("solo tu tenant") se suma esta, que deja ver todos los
--    tenants SOLO a kallicode_worker y SOLO en estas tablas. Las operaciones
--    concretas las limita el GRANT de arriba, no la política.
-- ----------------------------------------------------------------------------
CREATE POLICY worker_colas ON core.webhook_inbox
    FOR ALL TO kallicode_worker USING (true);
CREATE POLICY worker_colas ON core.jobs
    FOR ALL TO kallicode_worker USING (true);
CREATE POLICY worker_colas ON core.refresh_tokens
    FOR ALL TO kallicode_worker USING (true);
CREATE POLICY worker_colas ON core.ticket_attachments
    FOR ALL TO kallicode_worker USING (true);
CREATE POLICY worker_colas ON core.idempotency_keys
    FOR ALL TO kallicode_worker USING (true);

-- ================================================================
-- ARCHIVO: db/migrations/011_v21_coherencia_tenant.sql
-- ================================================================
-- ============================================================================
-- KALLICODE · 011_v21_coherencia_tenant.sql
-- KC-DB-03-3 (DB-F01) — Chequeo V21: coherencia de tenant entre padre e hijo.
--
-- Las claves ajenas escalares (specs.ticket_id -> tickets.id) solo exigen que
-- el padre EXISTA, no que sea del mismo tenant: la base admite una spec de
-- org_A colgada de un ticket de org_B. V21 cuenta esas filas.
--
-- Las relaciones se generan desde pg_constraint (no hay lista a mano): toda
-- FK nueva entre dos tablas con tenant_id queda cubierta sola. Se excluyen:
--   - las FK que ya incluyen tenant_id (la base ya garantiza la coherencia);
--   - las FK hacia tablas sin tenant_id (core.organizations, catálogos).
--
-- Va ANTES de KC-DB-03-2 (FKs compuestas): si V21 encuentra filas, el
-- VALIDATE CONSTRAINT de esa migración fallaría. Repararlas primero con:
--   SELECT * FROM core.incoherencias_tenant();
--
-- El ticket proponía 004b; se usa 011 para respetar el orden cronológico
-- (009 y 010 ya existen). Sin BEGIN/COMMIT: la transacción la abre el runner.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Consulta de reparación: una fila por cada registro incoherente.
--    Ejecutar como kallicode_admin (BYPASSRLS) para ver todos los tenants.
--      SELECT * FROM core.incoherencias_tenant();
--    `fila` identifica la fila hija por su clave primaria, p. ej. {"id": "sp_9"}.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.incoherencias_tenant()
RETURNS TABLE (relacion text, tabla_hija text, tabla_padre text,
               fila jsonb, tenant_hija text, tenant_padre text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT c.conname,
               c.conrelid::regclass  AS hija,
               c.confrelid::regclass AS padre,
               -- Condición de unión hija/padre, columna a columna de la FK:
               (SELECT string_agg(format('p.%I = h.%I', pa.attname, ha.attname), ' AND ')
                  FROM unnest(c.conkey, c.confkey) AS k(hijo_n, padre_n)
                  JOIN pg_attribute ha ON ha.attrelid = c.conrelid  AND ha.attnum = k.hijo_n
                  JOIN pg_attribute pa ON pa.attrelid = c.confrelid AND pa.attnum = k.padre_n
               ) AS union_sql,
               -- Clave primaria de la hija como jsonb, para identificar la fila:
               (SELECT string_agg(format('%L, h.%I', a.attname, a.attname), ', ')
                  FROM pg_index i
                  JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
                 WHERE i.indrelid = c.conrelid AND i.indisprimary
               ) AS pk_sql
          FROM pg_constraint c
         WHERE c.contype = 'f'
           -- la hija y el padre tienen tenant_id ...
           AND EXISTS (SELECT 1 FROM pg_attribute
                        WHERE attrelid = c.conrelid AND attname = 'tenant_id' AND NOT attisdropped)
           AND EXISTS (SELECT 1 FROM pg_attribute
                        WHERE attrelid = c.confrelid AND attname = 'tenant_id' AND NOT attisdropped)
           -- ... y la FK no incluye ya tenant_id (si lo incluye, la base lo garantiza).
           AND NOT EXISTS (SELECT 1 FROM unnest(c.conkey) AS k(n)
                             JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.n
                            WHERE a.attname = 'tenant_id')
         ORDER BY c.conrelid::regclass::text, c.conname
    LOOP
        RETURN QUERY EXECUTE format(
            'SELECT %L::text, %L::text, %L::text, %s, h.tenant_id::text, p.tenant_id::text
               FROM %s h JOIN %s p ON %s
              WHERE h.tenant_id <> p.tenant_id',
            r.conname, r.hija::text, r.padre::text,
            CASE WHEN r.pk_sql IS NULL THEN 'jsonb_build_object(''ctid'', h.ctid::text)'
                 ELSE 'jsonb_build_object(' || r.pk_sql || ')' END,
            r.hija, r.padre, r.union_sql);
    END LOOP;
END $$;

COMMENT ON FUNCTION core.incoherencias_tenant() IS
'KC-DB-03-3: filas hijas cuyo tenant_id no coincide con el de su padre, en toda FK
escalar entre dos tablas con tenant_id (generadas desde pg_constraint). Base de V21
y consulta de reparación previa a KC-DB-03-2.';

-- ----------------------------------------------------------------------------
-- 2. validar_integridad(): V01-V20 copiados sin cambios de db/05_validacion.sql
--    + V21. PostgreSQL no permite añadir un chequeo: se reemplaza la función.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.validar_integridad()
RETURNS TABLE (chequeo text, descripcion text, problemas bigint)
LANGUAGE plpgsql STABLE AS $$
BEGIN

-- V01 · Suscripción vigente: todo tenant activo debe tener exactamente una.
chequeo := 'V01_suscripcion_vigente';
descripcion := 'Tenants sin suscripción vigente (o con más de una)';
SELECT count(*) INTO problemas FROM (
    SELECT o.id
      FROM core.organizations o
      LEFT JOIN core.subscriptions s
             ON s.tenant_id = o.id AND s.finaliza_el IS NULL
     WHERE o.eliminado_en IS NULL
     GROUP BY o.id
    HAVING count(s.id) <> 1
) q;
RETURN NEXT;

-- V02 · Ticket ⇄ job: la etapa visible del ticket debe corresponder al job activo.
chequeo := 'V02_espejo_ticket_job';
descripcion := 'Tickets activos cuya etapa no corresponde al estado de su job';
SELECT count(*) INTO problemas
  FROM core.tickets t
  JOIN core.jobs j ON j.ticket_id = t.id
             AND j.estado NOT IN ('produccion','cancelado','cerrado_duplicado')
 WHERE t.etapa <> CASE j.estado
        WHEN 'gate1' THEN 'design'
        WHEN 'gate2' THEN 'qa'
        WHEN 'gate3' THEN 'deploy'
        WHEN 'deploy_preflight' THEN 'deploy'
        WHEN 'pendiente_asignacion' THEN 'triage'
        WHEN 'pausado_por_cuota' THEN 'en_cola_por_cuota'
        WHEN 'escalado_humano' THEN t.etapa
        ELSE j.estado END;
RETURN NEXT;

-- V03 · Gate 3 sin gates 1 y 2 (el trigger lo impide; verificación de defensa).
chequeo := 'V03_gate3_sin_previos';
descripcion := 'Aprobaciones de Gate 3 sin aprobación previa de gates 1 y 2';
SELECT count(*) INTO problemas
  FROM core.gate_signatures g3
 WHERE g3.gate = 3 AND g3.accion = 'aprobado'
   AND 2 > (SELECT count(DISTINCT g.gate) FROM core.gate_signatures g
             WHERE g.ticket_id = g3.ticket_id
               AND g.gate IN (1,2) AND g.accion = 'aprobado'
               AND g.creado_en <= g3.creado_en);
RETURN NEXT;

-- V04 · Tickets en producción con las tres firmas.
chequeo := 'V04_produccion_sin_firmas';
descripcion := 'Tickets en producción sin las tres firmas de gates';
SELECT count(*) INTO problemas
  FROM core.tickets t
 WHERE t.etapa = 'produccion'
   AND 3 > (SELECT count(DISTINCT gate) FROM core.gate_signatures
             WHERE ticket_id = t.id AND accion = 'aprobado');
RETURN NEXT;

-- V05 · Specs: exactamente una alternativa recomendada por versión.
chequeo := 'V05_spec_recomendada';
descripcion := 'Specs sin exactamente una alternativa recomendada';
SELECT count(*) INTO problemas FROM (
    SELECT s.id FROM core.specs s
      LEFT JOIN core.spec_alternatives a ON a.spec_id = s.id AND a.recomendada
     GROUP BY s.id HAVING count(a.alt_id) <> 1
) q;
RETURN NEXT;

-- V06 · Specs aprobadas con alternativa elegida.
chequeo := 'V06_spec_aprobada_sin_eleccion';
descripcion := 'Specs aprobadas (Gate 1) sin alternativa elegida';
SELECT count(*) INTO problemas FROM (
    SELECT s.id FROM core.specs s
     WHERE s.estado = 'aprobada'
       AND NOT EXISTS (SELECT 1 FROM core.spec_alternatives a
                        WHERE a.spec_id = s.id AND a.elegida)
       AND EXISTS (SELECT 1 FROM core.spec_alternatives a WHERE a.spec_id = s.id)
) q;
RETURN NEXT;

-- V07 · Matriz de QA completa: cada corrida cubre todos los criterios de su spec.
chequeo := 'V07_matriz_qa_completa';
descripcion := 'Corridas de QA que no cubren todos los criterios de la spec';
SELECT count(*) INTO problemas FROM (
    SELECT r.id
      FROM core.qa_runs r
      JOIN core.spec_criteria c ON c.spec_id = r.spec_id
      LEFT JOIN core.qa_results q ON q.qa_run_id = r.id AND q.criterio_id = c.criterio_id
     GROUP BY r.id
    HAVING count(c.criterio_id) <> count(q.criterio_id)
) q;
RETURN NEXT;

-- V08 · Resultados de QA que referencian criterios inexistentes en la spec.
chequeo := 'V08_qa_criterio_fantasma';
descripcion := 'Resultados de QA con criterio_id que no existe en la spec de la corrida';
SELECT count(*) INTO problemas
  FROM core.qa_results q
  JOIN core.qa_runs r ON r.id = q.qa_run_id
 WHERE NOT EXISTS (SELECT 1 FROM core.spec_criteria c
                    WHERE c.spec_id = r.spec_id AND c.criterio_id = q.criterio_id);
RETURN NEXT;

-- V09 · Deploy bloqueado: tickets en produccion con hallazgos bloqueantes abiertos.
chequeo := 'V09_produccion_con_bloqueantes';
descripcion := 'Tickets en producción con hallazgos de seguridad bloqueantes abiertos';
SELECT count(*) INTO problemas
  FROM core.tickets t
 WHERE t.etapa = 'produccion'
   AND EXISTS (SELECT 1 FROM core.security_findings f
                WHERE f.ticket_id = t.id AND f.bloquea AND f.estado = 'abierto');
RETURN NEXT;

-- V10 · Agregado de cuota: usage_cycles debe cuadrar con la suma de usage_loc.
chequeo := 'V10_cuota_cuadra';
descripcion := 'Ciclos cuyo agregado no cuadra con la suma de usage_loc';
SELECT count(*) INTO problemas FROM (
    SELECT c.tenant_id, c.ciclo
      FROM core.usage_cycles c
      LEFT JOIN core.usage_loc l ON l.tenant_id = c.tenant_id AND l.ciclo = c.ciclo
     GROUP BY c.tenant_id, c.ciclo, c.loc_consumidas
    HAVING c.loc_consumidas <> coalesce(sum(greatest(l.netas,0)), 0)
) q;
RETURN NEXT;

-- V11 · Líneas: coherencia production_lines ⇄ jobs.
chequeo := 'V11_lineas_coherentes';
descripcion := 'Líneas ocupadas sin job activo o jobs con línea no reflejada';
SELECT count(*) INTO problemas FROM (
    SELECT pl.tenant_id, pl.numero
      FROM core.production_lines pl
      LEFT JOIN core.jobs j ON j.id = pl.job_id
             AND j.estado NOT IN ('produccion','cancelado','cerrado_duplicado')
     WHERE (pl.estado = 'ocupada') <> (j.id IS NOT NULL)
    UNION ALL
    SELECT j.tenant_id, j.linea
      FROM core.jobs j
      LEFT JOIN core.production_lines pl
             ON pl.tenant_id = j.tenant_id AND pl.numero = j.linea AND pl.job_id = j.id
     WHERE j.linea IS NOT NULL
       AND j.estado NOT IN ('produccion','cancelado','cerrado_duplicado')
       AND pl.job_id IS NULL
) q;
RETURN NEXT;

-- V12 · Líneas concurrentes dentro del plan (QU-2).
chequeo := 'V12_lineas_dentro_del_plan';
descripcion := 'Tenants con más jobs en línea que líneas de su plan';
SELECT count(*) INTO problemas FROM (
    SELECT j.tenant_id
      FROM core.jobs j
      JOIN core.subscriptions s ON s.tenant_id = j.tenant_id AND s.finaliza_el IS NULL
      JOIN core.plans p ON p.codigo = s.plan_codigo
     WHERE j.linea IS NOT NULL
       AND j.estado NOT IN ('produccion','cancelado','cerrado_duplicado')
     GROUP BY j.tenant_id, p.lineas
    HAVING p.lineas IS NOT NULL AND count(*) > p.lineas
) q;
RETURN NEXT;

-- V13 · Duplicados: cadena sin ciclos de un nivel y sin duplicado_de colgante.
chequeo := 'V13_duplicados_validos';
descripcion := 'Tickets duplicados que apuntan a otro duplicado (cadenas)';
SELECT count(*) INTO problemas
  FROM core.tickets t
  JOIN core.tickets d ON d.id = t.duplicado_de
 WHERE d.duplicado_de IS NOT NULL;
RETURN NEXT;

-- V14 · Embeddings huérfanos o faltantes (vec ⇄ core).
chequeo := 'V14_embeddings_tickets';
descripcion := 'Tickets activos (>1 h) sin embedding de deduplicación';
SELECT count(*) INTO problemas
  FROM core.tickets t
 WHERE t.etapa NOT IN ('cancelado','cerrado_duplicado')
   AND t.creado_en < now() - interval '1 hour'
   AND NOT EXISTS (SELECT 1 FROM vec.ticket_embeddings e WHERE e.ticket_id = t.id);
RETURN NEXT;

-- V15 · Dimensión de embeddings homogénea (1024).
chequeo := 'V15_dimension_embeddings';
descripcion := 'Embeddings con dimensión distinta de 1024';
SELECT (SELECT count(*) FROM vec.ticket_embeddings     WHERE vector_dims(embedding) <> 1024)
     + (SELECT count(*) FROM vec.doc_chunks            WHERE vector_dims(embedding) <> 1024)
     + (SELECT count(*) FROM vec.definition_embeddings WHERE vector_dims(embedding) <> 1024)
  INTO problemas;
RETURN NEXT;

-- V16 · Cadena de auditoría íntegra (recorre todos los tenants visibles).
chequeo := 'V16_cadena_auditoria';
descripcion := 'Tenants con cadena de hashes rota (ver audit.verify_chain)';
SELECT count(*) INTO problemas FROM (
    SELECT h.tenant_id
      FROM audit.chain_heads h,
           LATERAL audit.verify_chain(h.tenant_id) v
     WHERE NOT v.integra
) q;
RETURN NEXT;

-- V17 · Cabeza de cadena consistente con el último evento.
chequeo := 'V17_cabeza_cadena';
descripcion := 'chain_heads cuyo último sello no coincide con el último evento';
SELECT count(*) INTO problemas FROM (
    SELECT h.tenant_id
      FROM audit.chain_heads h
      LEFT JOIN LATERAL (
          SELECT sello FROM audit.audit_events e
           WHERE e.tenant_id = h.tenant_id
           ORDER BY e.id DESC LIMIT 1) ult ON true
     WHERE h.eventos > 0 AND ult.sello IS DISTINCT FROM h.ultimo_sello
) q;
RETURN NEXT;

-- V18 · Webhooks: fallidos estancados (>24 h sin reproceso).
chequeo := 'V18_webhooks_estancados';
descripcion := 'Entradas de webhook_inbox fallidas hace más de 24 h';
SELECT count(*) INTO problemas
  FROM core.webhook_inbox
 WHERE estado = 'fallido' AND recibido_en < now() - interval '24 hours';
RETURN NEXT;

-- V19 · Adjuntos huérfanos vencidos (>48 h sin asociar): candidatos a purga.
chequeo := 'V19_adjuntos_huerfanos';
descripcion := 'Adjuntos sin ticket asociado hace más de 48 h';
SELECT count(*) INTO problemas
  FROM core.ticket_attachments
 WHERE ticket_id IS NULL AND creado_en < now() - interval '48 hours';
RETURN NEXT;

-- V20 · Gates aprobados apuntando a specs de otro ticket.
chequeo := 'V20_gate_spec_coherente';
descripcion := 'Firmas de Gate 1 cuya spec no pertenece al mismo ticket';
SELECT count(*) INTO problemas
  FROM core.gate_signatures g
  JOIN core.specs s ON s.id = g.spec_id
 WHERE g.spec_id IS NOT NULL AND s.ticket_id <> g.ticket_id;
RETURN NEXT;


-- V21 · Coherencia de tenant padre/hijo (KC-DB-03-3, DB-F01). Las relaciones se
--       generan desde pg_constraint: ver core.incoherencias_tenant().
chequeo := 'V21_coherencia_tenant';
SELECT count(*),
       'Filas cuyo tenant no coincide con el de su padre'
       || coalesce(' en: ' || string_agg(DISTINCT relacion || ' (' || tabla_hija || ')', ', '), '')
  INTO problemas, descripcion
  FROM core.incoherencias_tenant();
RETURN NEXT;

END $$;

COMMENT ON FUNCTION core.validar_integridad() IS
'Batería de chequeos de integridad de negocio. Programar ejecución nocturna y
alertar si cualquier fila devuelve problemas > 0. Los chequeos V16/V17 verifican
la cadena de hashes de auditoría; V10/V12 la validación comercial; V21 la
coherencia de tenant entre padre e hijo (KC-DB-03-2 depende de que esté en 0).';

-- ================================================================
-- ARCHIVO: db/migrations/012_unicidad_tenant_id.sql
-- ================================================================
-- ============================================================================
-- KALLICODE · 012_unicidad_tenant_id.sql
-- KC-DB-03-1 (DB-F01) — UNIQUE (tenant_id, id) en las tablas padre.
--
-- Paso previo de KC-DB-03-2: una FK compuesta (tenant_id, ticket_id) ->
-- tickets(tenant_id, id) exige que esa pareja sea única en el padre. Como id
-- ya es PK, (tenant_id, id) es único siempre: esta migración no puede fallar
-- por datos duplicados.
--
-- Tablas: las 7 que reciben las 41 FK escalares que vigila V21 (011):
--   tickets (16) · users (14) · jobs (4) · specs (4) · qa_runs (1) ·
--   connections (1) · onboarding_documents (1)
-- core.organizations NO entra (el plan la listaba): no tiene tenant_id porque
-- ES el tenant; sus FK (tenant_id -> organizations.id) ya son coherentes.
--
-- Sin bloquear escrituras: CREATE UNIQUE INDEX CONCURRENTLY (no admite
-- transacción) y después ADD CONSTRAINT ... USING INDEX (instantáneo, solo
-- catálogo). Reejecutable: si falla a mitad, se vuelve a lanzar el runner.
-- Si un CONCURRENTLY se interrumpe deja un índice INVÁLIDO y el ADD CONSTRAINT
-- fallará con un error explícito: borrarlo con
--   DROP INDEX CONCURRENTLY core.<tabla>_tenant_id_uq;
-- y volver a ejecutar el runner.
-- ============================================================================
-- kc:sin-transaccion

-- Si una tabla está ocupada, abortar en 5 s en lugar de encolar a los demás.
SET lock_timeout = '5s';
-- Tope por sentencia: un índice CONCURRENTLY sobre una tabla grande puede
-- tardar minutos; 30 min es una red de seguridad, no el tiempo esperado.
SET statement_timeout = '30min';

CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS tickets_tenant_id_uq
    ON core.tickets (tenant_id, id);
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS users_tenant_id_uq
    ON core.users (tenant_id, id);
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS jobs_tenant_id_uq
    ON core.jobs (tenant_id, id);
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS specs_tenant_id_uq
    ON core.specs (tenant_id, id);
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS qa_runs_tenant_id_uq
    ON core.qa_runs (tenant_id, id);
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS connections_tenant_id_uq
    ON core.connections (tenant_id, id);
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS onboarding_documents_tenant_id_uq
    ON core.onboarding_documents (tenant_id, id);

-- Convertir cada índice en restricción (solo si aún no lo es).
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['tickets', 'users', 'jobs', 'specs', 'qa_runs',
                             'connections', 'onboarding_documents']
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_constraint
                        WHERE conrelid = format('core.%I', t)::regclass
                          AND conname = t || '_tenant_id_uq') THEN
            EXECUTE format('ALTER TABLE core.%I ADD CONSTRAINT %I UNIQUE USING INDEX %I',
                           t, t || '_tenant_id_uq', t || '_tenant_id_uq');
        END IF;
    END LOOP;
END $$;

RESET lock_timeout;
RESET statement_timeout;

-- ================================================================
-- ARCHIVO: db/migrations/013_v21_fks_compuestas.sql
-- ================================================================
-- ============================================================================
-- KALLICODE · 013_v21_fks_compuestas.sql
-- KC-DB-03-2 (DB-F01) — V21 revisa también las claves ajenas compuestas.
--
-- La versión de 011 solo revisaba las FK escalares. KC-DB-03-2 las convierte
-- TODAS en compuestas (tenant_id, x) -> padre(tenant_id, id): sin este cambio
-- V21 se quedaría revisando 0 relaciones. Ahora revisa toda FK entre dos
-- tablas con tenant_id, uniendo hija y padre por las columnas de la FK salvo
-- la pareja tenant_id = tenant_id, que es justo lo que se compara.
--
-- Una FK compuesta VALIDADA garantiza 0 filas; V21 sigue siendo útil en la
-- ventana NOT VALID -> VALIDATE (las filas viejas aún no se revisaron) y si
-- alguien desactiva o recrea una FK. validar_integridad() no cambia: V21 ya
-- delega en esta función.
-- ============================================================================

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

CREATE OR REPLACE FUNCTION core.incoherencias_tenant()
RETURNS TABLE (relacion text, tabla_hija text, tabla_padre text,
               fila jsonb, tenant_hija text, tenant_padre text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT c.conname,
               c.conrelid::regclass  AS hija,
               c.confrelid::regclass AS padre,
               -- Unión hija/padre por las columnas de la FK, sin la pareja de tenant:
               (SELECT string_agg(format('p.%I = h.%I', pa.attname, ha.attname), ' AND ')
                  FROM unnest(c.conkey, c.confkey) AS k(hijo_n, padre_n)
                  JOIN pg_attribute ha ON ha.attrelid = c.conrelid  AND ha.attnum = k.hijo_n
                  JOIN pg_attribute pa ON pa.attrelid = c.confrelid AND pa.attnum = k.padre_n
                 WHERE NOT (ha.attname = 'tenant_id' AND pa.attname = 'tenant_id')
               ) AS union_sql,
               -- Clave primaria de la hija como jsonb, para identificar la fila:
               (SELECT string_agg(format('%L, h.%I', a.attname, a.attname), ', ')
                  FROM pg_index i
                  JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
                 WHERE i.indrelid = c.conrelid AND i.indisprimary
               ) AS pk_sql
          FROM pg_constraint c
         WHERE c.contype = 'f'
           -- la hija y el padre tienen tenant_id (escalar o compuesta, da igual)
           AND EXISTS (SELECT 1 FROM pg_attribute
                        WHERE attrelid = c.conrelid AND attname = 'tenant_id' AND NOT attisdropped)
           AND EXISTS (SELECT 1 FROM pg_attribute
                        WHERE attrelid = c.confrelid AND attname = 'tenant_id' AND NOT attisdropped)
         ORDER BY c.conrelid::regclass::text, c.conname
    LOOP
        CONTINUE WHEN r.union_sql IS NULL;  -- FK solo por tenant_id: nada que comparar
        RETURN QUERY EXECUTE format(
            'SELECT %L::text, %L::text, %L::text, %s, h.tenant_id::text, p.tenant_id::text
               FROM %s h JOIN %s p ON %s
              WHERE h.tenant_id <> p.tenant_id',
            r.conname, r.hija::text, r.padre::text,
            CASE WHEN r.pk_sql IS NULL THEN 'jsonb_build_object(''ctid'', h.ctid::text)'
                 ELSE 'jsonb_build_object(' || r.pk_sql || ')' END,
            r.hija, r.padre, r.union_sql);
    END LOOP;
END $$;

COMMENT ON FUNCTION core.incoherencias_tenant() IS
'KC-DB-03-3/03-2: filas hijas cuyo tenant_id no coincide con el de su padre, en toda FK
(escalar o compuesta) entre dos tablas con tenant_id, generadas desde pg_constraint.
Base de V21 y consulta de reparación.';

-- ================================================================
-- ARCHIVO: db/migrations/014_fks_compuestas_not_valid.sql
-- ================================================================
-- ============================================================================
-- KALLICODE · 014_fks_compuestas_not_valid.sql
-- KC-DB-03-2 (DB-F01) — Paso 1/3: FK compuestas con tenant_id, NOT VALID.
--
-- Cada FK escalar hija.x -> padre(id) recibe una gemela compuesta
-- (tenant_id, x) -> padre(tenant_id, id): la base rechaza que una fila cuelgue
-- de un padre de OTRO tenant. NOT VALID no revisa las filas existentes (eso es
-- 015) pero protege desde ya toda escritura nueva. Es solo catálogo: el
-- bloqueo dura un instante; lock_timeout evita encolarse tras una transacción
-- larga. Requiere 012 (UNIQUE (tenant_id, id) en los padres).
--
-- Generado desde pg_constraint; conserva ON DELETE y el modo diferido de cada
-- FK. ON DELETE SET NULL pasa a SET NULL (col): en una FK compuesta, SET NULL
-- vaciaría también tenant_id, que es NOT NULL. Las 41 FK:
--   cm.concepts.curado_por -> core.users
--   cm.curation_queue.revisado_por -> core.users
--   cm.incidents.ticket_id -> core.tickets
--   core.audit_exports.solicitado_por -> core.users
--   core.audit_exports.ticket_id -> core.tickets
--   core.escalations.job_id -> core.jobs ON DELETE CASCADE
--   core.gate_signatures.actor_id -> core.users
--   core.gate_signatures.spec_id -> core.specs
--   core.gate_signatures.ticket_id -> core.tickets ON DELETE CASCADE
--   core.invitations.invitado_por -> core.users
--   core.jobs.ticket_id -> core.tickets ON DELETE CASCADE
--   core.job_transitions.job_id -> core.jobs ON DELETE CASCADE
--   core.llm_steps.job_id -> core.jobs ON DELETE CASCADE
--   core.llm_steps.ticket_id -> core.tickets ON DELETE CASCADE
--   core.notifications.ticket_id -> core.tickets ON DELETE CASCADE
--   core.notifications.user_id -> core.users ON DELETE CASCADE
--   core.onboarding_documents.subido_por -> core.users
--   core.password_reset_tokens.user_id -> core.users ON DELETE CASCADE
--   core.production_lines.job_id -> core.jobs DEFERRABLE INITIALLY DEFERRED
--   core.qa_results.qa_run_id -> core.qa_runs ON DELETE CASCADE
--   core.qa_runs.spec_id -> core.specs
--   core.qa_runs.ticket_id -> core.tickets ON DELETE CASCADE
--   core.refresh_tokens.user_id -> core.users ON DELETE CASCADE
--   core.security_findings.ticket_id -> core.tickets ON DELETE CASCADE
--   core.spec_alternatives.spec_id -> core.specs ON DELETE CASCADE
--   core.spec_criteria.spec_id -> core.specs ON DELETE CASCADE
--   core.specs.ticket_id -> core.tickets ON DELETE CASCADE
--   core.ticket_attachments.subido_por -> core.users
--   core.ticket_attachments.ticket_id -> core.tickets ON DELETE CASCADE
--   core.tickets.cancelado_por -> core.users
--   core.tickets.duplicado_de -> core.tickets
--   core.tickets.reportado_por -> core.users
--   core.ticket_watchers.ticket_id -> core.tickets ON DELETE CASCADE
--   core.ticket_watchers.user_id -> core.users ON DELETE CASCADE
--   core.upgrade_requests.solicitado_por -> core.users
--   core.usage_loc.ticket_id -> core.tickets ON DELETE SET NULL (ticket_id)
--   core.usage_tokens.ticket_id -> core.tickets ON DELETE CASCADE
--   core.webhook_inbox.connection_id -> core.connections ON DELETE CASCADE
--   core.webhook_inbox.ticket_id -> core.tickets
--   vec.doc_chunks.documento_id -> core.onboarding_documents ON DELETE CASCADE
--   vec.ticket_embeddings.ticket_id -> core.tickets ON DELETE CASCADE
--
-- Las gemelas llevan el sufijo _t; 016 retira las escalares y les devuelve
-- el nombre original. Sin BEGIN/COMMIT: la transacción la abre el runner.
-- ============================================================================

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

ALTER TABLE cm.concepts
    ADD CONSTRAINT concepts_curado_por_fkey_t
    FOREIGN KEY (tenant_id, curado_por)
    REFERENCES core.users (tenant_id, id) NOT VALID;

ALTER TABLE cm.curation_queue
    ADD CONSTRAINT curation_queue_revisado_por_fkey_t
    FOREIGN KEY (tenant_id, revisado_por)
    REFERENCES core.users (tenant_id, id) NOT VALID;

ALTER TABLE cm.incidents
    ADD CONSTRAINT incidents_ticket_id_fkey_t
    FOREIGN KEY (tenant_id, ticket_id)
    REFERENCES core.tickets (tenant_id, id) NOT VALID;

ALTER TABLE core.audit_exports
    ADD CONSTRAINT audit_exports_solicitado_por_fkey_t
    FOREIGN KEY (tenant_id, solicitado_por)
    REFERENCES core.users (tenant_id, id) NOT VALID;

ALTER TABLE core.audit_exports
    ADD CONSTRAINT audit_exports_ticket_id_fkey_t
    FOREIGN KEY (tenant_id, ticket_id)
    REFERENCES core.tickets (tenant_id, id) NOT VALID;

ALTER TABLE core.escalations
    ADD CONSTRAINT escalations_job_id_fkey_t
    FOREIGN KEY (tenant_id, job_id)
    REFERENCES core.jobs (tenant_id, id) ON DELETE CASCADE NOT VALID;

ALTER TABLE core.gate_signatures
    ADD CONSTRAINT gate_signatures_actor_id_fkey_t
    FOREIGN KEY (tenant_id, actor_id)
    REFERENCES core.users (tenant_id, id) NOT VALID;

ALTER TABLE core.gate_signatures
    ADD CONSTRAINT gate_signatures_spec_id_fkey_t
    FOREIGN KEY (tenant_id, spec_id)
    REFERENCES core.specs (tenant_id, id) NOT VALID;

ALTER TABLE core.gate_signatures
    ADD CONSTRAINT gate_signatures_ticket_id_fkey_t
    FOREIGN KEY (tenant_id, ticket_id)
    REFERENCES core.tickets (tenant_id, id) ON DELETE CASCADE NOT VALID;

ALTER TABLE core.invitations
    ADD CONSTRAINT invitations_invitado_por_fkey_t
    FOREIGN KEY (tenant_id, invitado_por)
    REFERENCES core.users (tenant_id, id) NOT VALID;

ALTER TABLE core.jobs
    ADD CONSTRAINT jobs_ticket_id_fkey_t
    FOREIGN KEY (tenant_id, ticket_id)
    REFERENCES core.tickets (tenant_id, id) ON DELETE CASCADE NOT VALID;

ALTER TABLE core.job_transitions
    ADD CONSTRAINT job_transitions_job_id_fkey_t
    FOREIGN KEY (tenant_id, job_id)
    REFERENCES core.jobs (tenant_id, id) ON DELETE CASCADE NOT VALID;

ALTER TABLE core.llm_steps
    ADD CONSTRAINT llm_steps_job_id_fkey_t
    FOREIGN KEY (tenant_id, job_id)
    REFERENCES core.jobs (tenant_id, id) ON DELETE CASCADE NOT VALID;

ALTER TABLE core.llm_steps
    ADD CONSTRAINT llm_steps_ticket_id_fkey_t
    FOREIGN KEY (tenant_id, ticket_id)
    REFERENCES core.tickets (tenant_id, id) ON DELETE CASCADE NOT VALID;

ALTER TABLE core.notifications
    ADD CONSTRAINT notifications_ticket_id_fkey_t
    FOREIGN KEY (tenant_id, ticket_id)
    REFERENCES core.tickets (tenant_id, id) ON DELETE CASCADE NOT VALID;

ALTER TABLE core.notifications
    ADD CONSTRAINT notifications_user_id_fkey_t
    FOREIGN KEY (tenant_id, user_id)
    REFERENCES core.users (tenant_id, id) ON DELETE CASCADE NOT VALID;

ALTER TABLE core.onboarding_documents
    ADD CONSTRAINT onboarding_documents_subido_por_fkey_t
    FOREIGN KEY (tenant_id, subido_por)
    REFERENCES core.users (tenant_id, id) NOT VALID;

ALTER TABLE core.password_reset_tokens
    ADD CONSTRAINT password_reset_tokens_user_id_fkey_t
    FOREIGN KEY (tenant_id, user_id)
    REFERENCES core.users (tenant_id, id) ON DELETE CASCADE NOT VALID;

ALTER TABLE core.production_lines
    ADD CONSTRAINT lines_job_fk_t
    FOREIGN KEY (tenant_id, job_id)
    REFERENCES core.jobs (tenant_id, id) DEFERRABLE INITIALLY DEFERRED NOT VALID;

ALTER TABLE core.qa_results
    ADD CONSTRAINT qa_results_qa_run_id_fkey_t
    FOREIGN KEY (tenant_id, qa_run_id)
    REFERENCES core.qa_runs (tenant_id, id) ON DELETE CASCADE NOT VALID;

ALTER TABLE core.qa_runs
    ADD CONSTRAINT qa_runs_spec_id_fkey_t
    FOREIGN KEY (tenant_id, spec_id)
    REFERENCES core.specs (tenant_id, id) NOT VALID;

ALTER TABLE core.qa_runs
    ADD CONSTRAINT qa_runs_ticket_id_fkey_t
    FOREIGN KEY (tenant_id, ticket_id)
    REFERENCES core.tickets (tenant_id, id) ON DELETE CASCADE NOT VALID;

ALTER TABLE core.refresh_tokens
    ADD CONSTRAINT refresh_tokens_user_id_fkey_t
    FOREIGN KEY (tenant_id, user_id)
    REFERENCES core.users (tenant_id, id) ON DELETE CASCADE NOT VALID;

ALTER TABLE core.security_findings
    ADD CONSTRAINT security_findings_ticket_id_fkey_t
    FOREIGN KEY (tenant_id, ticket_id)
    REFERENCES core.tickets (tenant_id, id) ON DELETE CASCADE NOT VALID;

ALTER TABLE core.spec_alternatives
    ADD CONSTRAINT spec_alternatives_spec_id_fkey_t
    FOREIGN KEY (tenant_id, spec_id)
    REFERENCES core.specs (tenant_id, id) ON DELETE CASCADE NOT VALID;

ALTER TABLE core.spec_criteria
    ADD CONSTRAINT spec_criteria_spec_id_fkey_t
    FOREIGN KEY (tenant_id, spec_id)
    REFERENCES core.specs (tenant_id, id) ON DELETE CASCADE NOT VALID;

ALTER TABLE core.specs
    ADD CONSTRAINT specs_ticket_id_fkey_t
    FOREIGN KEY (tenant_id, ticket_id)
    REFERENCES core.tickets (tenant_id, id) ON DELETE CASCADE NOT VALID;

ALTER TABLE core.ticket_attachments
    ADD CONSTRAINT ticket_attachments_subido_por_fkey_t
    FOREIGN KEY (tenant_id, subido_por)
    REFERENCES core.users (tenant_id, id) NOT VALID;

ALTER TABLE core.ticket_attachments
    ADD CONSTRAINT ticket_attachments_ticket_id_fkey_t
    FOREIGN KEY (tenant_id, ticket_id)
    REFERENCES core.tickets (tenant_id, id) ON DELETE CASCADE NOT VALID;

ALTER TABLE core.tickets
    ADD CONSTRAINT tickets_cancelado_por_fkey_t
    FOREIGN KEY (tenant_id, cancelado_por)
    REFERENCES core.users (tenant_id, id) NOT VALID;

ALTER TABLE core.tickets
    ADD CONSTRAINT tickets_duplicado_de_fkey_t
    FOREIGN KEY (tenant_id, duplicado_de)
    REFERENCES core.tickets (tenant_id, id) NOT VALID;

ALTER TABLE core.tickets
    ADD CONSTRAINT tickets_reportado_por_fkey_t
    FOREIGN KEY (tenant_id, reportado_por)
    REFERENCES core.users (tenant_id, id) NOT VALID;

ALTER TABLE core.ticket_watchers
    ADD CONSTRAINT ticket_watchers_ticket_id_fkey_t
    FOREIGN KEY (tenant_id, ticket_id)
    REFERENCES core.tickets (tenant_id, id) ON DELETE CASCADE NOT VALID;

ALTER TABLE core.ticket_watchers
    ADD CONSTRAINT ticket_watchers_user_id_fkey_t
    FOREIGN KEY (tenant_id, user_id)
    REFERENCES core.users (tenant_id, id) ON DELETE CASCADE NOT VALID;

ALTER TABLE core.upgrade_requests
    ADD CONSTRAINT upgrade_requests_solicitado_por_fkey_t
    FOREIGN KEY (tenant_id, solicitado_por)
    REFERENCES core.users (tenant_id, id) NOT VALID;

ALTER TABLE core.usage_loc
    ADD CONSTRAINT usage_loc_ticket_id_fkey_t
    FOREIGN KEY (tenant_id, ticket_id)
    REFERENCES core.tickets (tenant_id, id) ON DELETE SET NULL (ticket_id) NOT VALID;

ALTER TABLE core.usage_tokens
    ADD CONSTRAINT usage_tokens_ticket_id_fkey_t
    FOREIGN KEY (tenant_id, ticket_id)
    REFERENCES core.tickets (tenant_id, id) ON DELETE CASCADE NOT VALID;

ALTER TABLE core.webhook_inbox
    ADD CONSTRAINT webhook_inbox_connection_id_fkey_t
    FOREIGN KEY (tenant_id, connection_id)
    REFERENCES core.connections (tenant_id, id) ON DELETE CASCADE NOT VALID;

ALTER TABLE core.webhook_inbox
    ADD CONSTRAINT webhook_inbox_ticket_id_fkey_t
    FOREIGN KEY (tenant_id, ticket_id)
    REFERENCES core.tickets (tenant_id, id) NOT VALID;

ALTER TABLE vec.doc_chunks
    ADD CONSTRAINT doc_chunks_documento_id_fkey_t
    FOREIGN KEY (tenant_id, documento_id)
    REFERENCES core.onboarding_documents (tenant_id, id) ON DELETE CASCADE NOT VALID;

ALTER TABLE vec.ticket_embeddings
    ADD CONSTRAINT ticket_embeddings_ticket_id_fkey_t
    FOREIGN KEY (tenant_id, ticket_id)
    REFERENCES core.tickets (tenant_id, id) ON DELETE CASCADE NOT VALID;

-- ================================================================
-- ARCHIVO: db/migrations/015_fks_compuestas_validate.sql
-- ================================================================
-- ============================================================================
-- KALLICODE · 015_fks_compuestas_validate.sql
-- KC-DB-03-2 (DB-F01) — Paso 2/3: VALIDATE de las FK compuestas de 014.
--
-- Revisa las filas existentes sin bloquear escrituras (SHARE UPDATE EXCLUSIVE
-- en la hija). Va en archivo aparte para que un fallo aquí no deshaga 014, que
-- ya protege toda escritura nueva. Si falla, hay filas de un tenant colgadas
-- de otro: listarlas con
--   SELECT * FROM core.incoherencias_tenant();
-- repararlas y volver a ejecutar el runner (VALIDATE es reejecutable).
-- ============================================================================
-- kc:sin-transaccion

SET lock_timeout = '5s';
SET statement_timeout = '30min';

ALTER TABLE cm.concepts VALIDATE CONSTRAINT concepts_curado_por_fkey_t;
ALTER TABLE cm.curation_queue VALIDATE CONSTRAINT curation_queue_revisado_por_fkey_t;
ALTER TABLE cm.incidents VALIDATE CONSTRAINT incidents_ticket_id_fkey_t;
ALTER TABLE core.audit_exports VALIDATE CONSTRAINT audit_exports_solicitado_por_fkey_t;
ALTER TABLE core.audit_exports VALIDATE CONSTRAINT audit_exports_ticket_id_fkey_t;
ALTER TABLE core.escalations VALIDATE CONSTRAINT escalations_job_id_fkey_t;
ALTER TABLE core.gate_signatures VALIDATE CONSTRAINT gate_signatures_actor_id_fkey_t;
ALTER TABLE core.gate_signatures VALIDATE CONSTRAINT gate_signatures_spec_id_fkey_t;
ALTER TABLE core.gate_signatures VALIDATE CONSTRAINT gate_signatures_ticket_id_fkey_t;
ALTER TABLE core.invitations VALIDATE CONSTRAINT invitations_invitado_por_fkey_t;
ALTER TABLE core.jobs VALIDATE CONSTRAINT jobs_ticket_id_fkey_t;
ALTER TABLE core.job_transitions VALIDATE CONSTRAINT job_transitions_job_id_fkey_t;
ALTER TABLE core.llm_steps VALIDATE CONSTRAINT llm_steps_job_id_fkey_t;
ALTER TABLE core.llm_steps VALIDATE CONSTRAINT llm_steps_ticket_id_fkey_t;
ALTER TABLE core.notifications VALIDATE CONSTRAINT notifications_ticket_id_fkey_t;
ALTER TABLE core.notifications VALIDATE CONSTRAINT notifications_user_id_fkey_t;
ALTER TABLE core.onboarding_documents VALIDATE CONSTRAINT onboarding_documents_subido_por_fkey_t;
ALTER TABLE core.password_reset_tokens VALIDATE CONSTRAINT password_reset_tokens_user_id_fkey_t;
ALTER TABLE core.production_lines VALIDATE CONSTRAINT lines_job_fk_t;
ALTER TABLE core.qa_results VALIDATE CONSTRAINT qa_results_qa_run_id_fkey_t;
ALTER TABLE core.qa_runs VALIDATE CONSTRAINT qa_runs_spec_id_fkey_t;
ALTER TABLE core.qa_runs VALIDATE CONSTRAINT qa_runs_ticket_id_fkey_t;
ALTER TABLE core.refresh_tokens VALIDATE CONSTRAINT refresh_tokens_user_id_fkey_t;
ALTER TABLE core.security_findings VALIDATE CONSTRAINT security_findings_ticket_id_fkey_t;
ALTER TABLE core.spec_alternatives VALIDATE CONSTRAINT spec_alternatives_spec_id_fkey_t;
ALTER TABLE core.spec_criteria VALIDATE CONSTRAINT spec_criteria_spec_id_fkey_t;
ALTER TABLE core.specs VALIDATE CONSTRAINT specs_ticket_id_fkey_t;
ALTER TABLE core.ticket_attachments VALIDATE CONSTRAINT ticket_attachments_subido_por_fkey_t;
ALTER TABLE core.ticket_attachments VALIDATE CONSTRAINT ticket_attachments_ticket_id_fkey_t;
ALTER TABLE core.tickets VALIDATE CONSTRAINT tickets_cancelado_por_fkey_t;
ALTER TABLE core.tickets VALIDATE CONSTRAINT tickets_duplicado_de_fkey_t;
ALTER TABLE core.tickets VALIDATE CONSTRAINT tickets_reportado_por_fkey_t;
ALTER TABLE core.ticket_watchers VALIDATE CONSTRAINT ticket_watchers_ticket_id_fkey_t;
ALTER TABLE core.ticket_watchers VALIDATE CONSTRAINT ticket_watchers_user_id_fkey_t;
ALTER TABLE core.upgrade_requests VALIDATE CONSTRAINT upgrade_requests_solicitado_por_fkey_t;
ALTER TABLE core.usage_loc VALIDATE CONSTRAINT usage_loc_ticket_id_fkey_t;
ALTER TABLE core.usage_tokens VALIDATE CONSTRAINT usage_tokens_ticket_id_fkey_t;
ALTER TABLE core.webhook_inbox VALIDATE CONSTRAINT webhook_inbox_connection_id_fkey_t;
ALTER TABLE core.webhook_inbox VALIDATE CONSTRAINT webhook_inbox_ticket_id_fkey_t;
ALTER TABLE vec.doc_chunks VALIDATE CONSTRAINT doc_chunks_documento_id_fkey_t;
ALTER TABLE vec.ticket_embeddings VALIDATE CONSTRAINT ticket_embeddings_ticket_id_fkey_t;

RESET lock_timeout;
RESET statement_timeout;

-- ================================================================
-- ARCHIVO: db/migrations/016_fks_retirar_escalares.sql
-- ================================================================
-- ============================================================================
-- KALLICODE · 016_fks_retirar_escalares.sql
-- KC-DB-03-2 (DB-F01) — Paso 3/3: retirar las FK escalares.
--
-- Validadas las compuestas (015), las escalares sobran: se eliminan y cada
-- compuesta recupera el nombre original (sin el sufijo _t), así los mensajes
-- de error y cualquier referencia por nombre no cambian. DROP CONSTRAINT toma
-- un bloqueo exclusivo de un instante; todo va en una transacción con
-- lock_timeout: o se aplica entero o nada.
-- ============================================================================

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '1min';

ALTER TABLE cm.concepts DROP CONSTRAINT concepts_curado_por_fkey;
ALTER TABLE cm.concepts RENAME CONSTRAINT concepts_curado_por_fkey_t TO concepts_curado_por_fkey;

ALTER TABLE cm.curation_queue DROP CONSTRAINT curation_queue_revisado_por_fkey;
ALTER TABLE cm.curation_queue RENAME CONSTRAINT curation_queue_revisado_por_fkey_t TO curation_queue_revisado_por_fkey;

ALTER TABLE cm.incidents DROP CONSTRAINT incidents_ticket_id_fkey;
ALTER TABLE cm.incidents RENAME CONSTRAINT incidents_ticket_id_fkey_t TO incidents_ticket_id_fkey;

ALTER TABLE core.audit_exports DROP CONSTRAINT audit_exports_solicitado_por_fkey;
ALTER TABLE core.audit_exports RENAME CONSTRAINT audit_exports_solicitado_por_fkey_t TO audit_exports_solicitado_por_fkey;

ALTER TABLE core.audit_exports DROP CONSTRAINT audit_exports_ticket_id_fkey;
ALTER TABLE core.audit_exports RENAME CONSTRAINT audit_exports_ticket_id_fkey_t TO audit_exports_ticket_id_fkey;

ALTER TABLE core.escalations DROP CONSTRAINT escalations_job_id_fkey;
ALTER TABLE core.escalations RENAME CONSTRAINT escalations_job_id_fkey_t TO escalations_job_id_fkey;

ALTER TABLE core.gate_signatures DROP CONSTRAINT gate_signatures_actor_id_fkey;
ALTER TABLE core.gate_signatures RENAME CONSTRAINT gate_signatures_actor_id_fkey_t TO gate_signatures_actor_id_fkey;

ALTER TABLE core.gate_signatures DROP CONSTRAINT gate_signatures_spec_id_fkey;
ALTER TABLE core.gate_signatures RENAME CONSTRAINT gate_signatures_spec_id_fkey_t TO gate_signatures_spec_id_fkey;

ALTER TABLE core.gate_signatures DROP CONSTRAINT gate_signatures_ticket_id_fkey;
ALTER TABLE core.gate_signatures RENAME CONSTRAINT gate_signatures_ticket_id_fkey_t TO gate_signatures_ticket_id_fkey;

ALTER TABLE core.invitations DROP CONSTRAINT invitations_invitado_por_fkey;
ALTER TABLE core.invitations RENAME CONSTRAINT invitations_invitado_por_fkey_t TO invitations_invitado_por_fkey;

ALTER TABLE core.jobs DROP CONSTRAINT jobs_ticket_id_fkey;
ALTER TABLE core.jobs RENAME CONSTRAINT jobs_ticket_id_fkey_t TO jobs_ticket_id_fkey;

ALTER TABLE core.job_transitions DROP CONSTRAINT job_transitions_job_id_fkey;
ALTER TABLE core.job_transitions RENAME CONSTRAINT job_transitions_job_id_fkey_t TO job_transitions_job_id_fkey;

ALTER TABLE core.llm_steps DROP CONSTRAINT llm_steps_job_id_fkey;
ALTER TABLE core.llm_steps RENAME CONSTRAINT llm_steps_job_id_fkey_t TO llm_steps_job_id_fkey;

ALTER TABLE core.llm_steps DROP CONSTRAINT llm_steps_ticket_id_fkey;
ALTER TABLE core.llm_steps RENAME CONSTRAINT llm_steps_ticket_id_fkey_t TO llm_steps_ticket_id_fkey;

ALTER TABLE core.notifications DROP CONSTRAINT notifications_ticket_id_fkey;
ALTER TABLE core.notifications RENAME CONSTRAINT notifications_ticket_id_fkey_t TO notifications_ticket_id_fkey;

ALTER TABLE core.notifications DROP CONSTRAINT notifications_user_id_fkey;
ALTER TABLE core.notifications RENAME CONSTRAINT notifications_user_id_fkey_t TO notifications_user_id_fkey;

ALTER TABLE core.onboarding_documents DROP CONSTRAINT onboarding_documents_subido_por_fkey;
ALTER TABLE core.onboarding_documents RENAME CONSTRAINT onboarding_documents_subido_por_fkey_t TO onboarding_documents_subido_por_fkey;

ALTER TABLE core.password_reset_tokens DROP CONSTRAINT password_reset_tokens_user_id_fkey;
ALTER TABLE core.password_reset_tokens RENAME CONSTRAINT password_reset_tokens_user_id_fkey_t TO password_reset_tokens_user_id_fkey;

ALTER TABLE core.production_lines DROP CONSTRAINT lines_job_fk;
ALTER TABLE core.production_lines RENAME CONSTRAINT lines_job_fk_t TO lines_job_fk;

ALTER TABLE core.qa_results DROP CONSTRAINT qa_results_qa_run_id_fkey;
ALTER TABLE core.qa_results RENAME CONSTRAINT qa_results_qa_run_id_fkey_t TO qa_results_qa_run_id_fkey;

ALTER TABLE core.qa_runs DROP CONSTRAINT qa_runs_spec_id_fkey;
ALTER TABLE core.qa_runs RENAME CONSTRAINT qa_runs_spec_id_fkey_t TO qa_runs_spec_id_fkey;

ALTER TABLE core.qa_runs DROP CONSTRAINT qa_runs_ticket_id_fkey;
ALTER TABLE core.qa_runs RENAME CONSTRAINT qa_runs_ticket_id_fkey_t TO qa_runs_ticket_id_fkey;

ALTER TABLE core.refresh_tokens DROP CONSTRAINT refresh_tokens_user_id_fkey;
ALTER TABLE core.refresh_tokens RENAME CONSTRAINT refresh_tokens_user_id_fkey_t TO refresh_tokens_user_id_fkey;

ALTER TABLE core.security_findings DROP CONSTRAINT security_findings_ticket_id_fkey;
ALTER TABLE core.security_findings RENAME CONSTRAINT security_findings_ticket_id_fkey_t TO security_findings_ticket_id_fkey;

ALTER TABLE core.spec_alternatives DROP CONSTRAINT spec_alternatives_spec_id_fkey;
ALTER TABLE core.spec_alternatives RENAME CONSTRAINT spec_alternatives_spec_id_fkey_t TO spec_alternatives_spec_id_fkey;

ALTER TABLE core.spec_criteria DROP CONSTRAINT spec_criteria_spec_id_fkey;
ALTER TABLE core.spec_criteria RENAME CONSTRAINT spec_criteria_spec_id_fkey_t TO spec_criteria_spec_id_fkey;

ALTER TABLE core.specs DROP CONSTRAINT specs_ticket_id_fkey;
ALTER TABLE core.specs RENAME CONSTRAINT specs_ticket_id_fkey_t TO specs_ticket_id_fkey;

ALTER TABLE core.ticket_attachments DROP CONSTRAINT ticket_attachments_subido_por_fkey;
ALTER TABLE core.ticket_attachments RENAME CONSTRAINT ticket_attachments_subido_por_fkey_t TO ticket_attachments_subido_por_fkey;

ALTER TABLE core.ticket_attachments DROP CONSTRAINT ticket_attachments_ticket_id_fkey;
ALTER TABLE core.ticket_attachments RENAME CONSTRAINT ticket_attachments_ticket_id_fkey_t TO ticket_attachments_ticket_id_fkey;

ALTER TABLE core.tickets DROP CONSTRAINT tickets_cancelado_por_fkey;
ALTER TABLE core.tickets RENAME CONSTRAINT tickets_cancelado_por_fkey_t TO tickets_cancelado_por_fkey;

ALTER TABLE core.tickets DROP CONSTRAINT tickets_duplicado_de_fkey;
ALTER TABLE core.tickets RENAME CONSTRAINT tickets_duplicado_de_fkey_t TO tickets_duplicado_de_fkey;

ALTER TABLE core.tickets DROP CONSTRAINT tickets_reportado_por_fkey;
ALTER TABLE core.tickets RENAME CONSTRAINT tickets_reportado_por_fkey_t TO tickets_reportado_por_fkey;

ALTER TABLE core.ticket_watchers DROP CONSTRAINT ticket_watchers_ticket_id_fkey;
ALTER TABLE core.ticket_watchers RENAME CONSTRAINT ticket_watchers_ticket_id_fkey_t TO ticket_watchers_ticket_id_fkey;

ALTER TABLE core.ticket_watchers DROP CONSTRAINT ticket_watchers_user_id_fkey;
ALTER TABLE core.ticket_watchers RENAME CONSTRAINT ticket_watchers_user_id_fkey_t TO ticket_watchers_user_id_fkey;

ALTER TABLE core.upgrade_requests DROP CONSTRAINT upgrade_requests_solicitado_por_fkey;
ALTER TABLE core.upgrade_requests RENAME CONSTRAINT upgrade_requests_solicitado_por_fkey_t TO upgrade_requests_solicitado_por_fkey;

ALTER TABLE core.usage_loc DROP CONSTRAINT usage_loc_ticket_id_fkey;
ALTER TABLE core.usage_loc RENAME CONSTRAINT usage_loc_ticket_id_fkey_t TO usage_loc_ticket_id_fkey;

ALTER TABLE core.usage_tokens DROP CONSTRAINT usage_tokens_ticket_id_fkey;
ALTER TABLE core.usage_tokens RENAME CONSTRAINT usage_tokens_ticket_id_fkey_t TO usage_tokens_ticket_id_fkey;

ALTER TABLE core.webhook_inbox DROP CONSTRAINT webhook_inbox_connection_id_fkey;
ALTER TABLE core.webhook_inbox RENAME CONSTRAINT webhook_inbox_connection_id_fkey_t TO webhook_inbox_connection_id_fkey;

ALTER TABLE core.webhook_inbox DROP CONSTRAINT webhook_inbox_ticket_id_fkey;
ALTER TABLE core.webhook_inbox RENAME CONSTRAINT webhook_inbox_ticket_id_fkey_t TO webhook_inbox_ticket_id_fkey;

ALTER TABLE vec.doc_chunks DROP CONSTRAINT doc_chunks_documento_id_fkey;
ALTER TABLE vec.doc_chunks RENAME CONSTRAINT doc_chunks_documento_id_fkey_t TO doc_chunks_documento_id_fkey;

ALTER TABLE vec.ticket_embeddings DROP CONSTRAINT ticket_embeddings_ticket_id_fkey;
ALTER TABLE vec.ticket_embeddings RENAME CONSTRAINT ticket_embeddings_ticket_id_fkey_t TO ticket_embeddings_ticket_id_fkey;

-- ================================================================
-- ARCHIVO: db/migrations/017_pk_para_particion.sql
-- ================================================================
-- Migración 017: Rediseño de PKs para habilitar particionado por rango temporal (KC-DB-03-5)
-- Cierra hallazgo DB-F09: Las tablas de crecimiento ilimitado requieren que la clave
-- de partición forme parte de la clave primaria.

SET lock_timeout = '5s';
SET statement_timeout = '30s';



-- 1. audit.audit_events -> PK (creado_en, id)
ALTER TABLE audit.audit_events DROP CONSTRAINT IF EXISTS audit_events_pkey;
ALTER TABLE audit.audit_events ADD CONSTRAINT audit_events_pkey PRIMARY KEY (creado_en, id);

-- 2. core.usage_tokens -> PK (creado_en, id)
ALTER TABLE core.usage_tokens DROP CONSTRAINT IF EXISTS usage_tokens_pkey;
ALTER TABLE core.usage_tokens ADD CONSTRAINT usage_tokens_pkey PRIMARY KEY (creado_en, id);

-- 3. core.job_transitions -> PK (creado_en, id)
ALTER TABLE core.job_transitions DROP CONSTRAINT IF EXISTS job_transitions_pkey;
ALTER TABLE core.job_transitions ADD CONSTRAINT job_transitions_pkey PRIMARY KEY (creado_en, id);

-- 4. core.webhook_inbox -> PK (recibido_en, id)
ALTER TABLE core.webhook_inbox DROP CONSTRAINT IF EXISTS webhook_inbox_pkey;
ALTER TABLE core.webhook_inbox ADD CONSTRAINT webhook_inbox_pkey PRIMARY KEY (recibido_en, id);

-- 5. core.notifications -> PK (creada_en, id)
ALTER TABLE core.notifications DROP CONSTRAINT IF EXISTS notifications_pkey;
ALTER TABLE core.notifications ADD CONSTRAINT notifications_pkey PRIMARY KEY (creada_en, id);


-- ================================================================
-- ARCHIVO: db/migrations/018_indices_concurrentes_fks.sql
-- ================================================================
-- kc:sin-transaccion
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_audit_exports_tenant_solicitado_por ON core.audit_exports (tenant_id, solicitado_por);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_audit_exports_tenant_ticket_id ON core.audit_exports (tenant_id, ticket_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_escalations_tenant_job_id ON core.escalations (tenant_id, job_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_gate_signatures_tenant_actor_id ON core.gate_signatures (tenant_id, actor_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_gate_signatures_tenant_spec_id ON core.gate_signatures (tenant_id, spec_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_gate_signatures_tenant_ticket_id ON core.gate_signatures (tenant_id, ticket_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_invitations_tenant_invitado_por ON core.invitations (tenant_id, invitado_por);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_job_transitions_tenant_job_id ON core.job_transitions (tenant_id, job_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_jobs_tenant_ticket_id ON core.jobs (tenant_id, ticket_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_llm_steps_tenant_job_id ON core.llm_steps (tenant_id, job_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_llm_steps_tenant_ticket_id ON core.llm_steps (tenant_id, ticket_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_model_assignments_tenant_prov_fb ON core.model_assignments (tenant_id, fallback_proveedor);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_model_assignments_tenant_prov_ppal ON core.model_assignments (tenant_id, principal_proveedor);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_notifications_tenant_ticket_id ON core.notifications (tenant_id, ticket_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_notifications_tenant_user_id ON core.notifications (tenant_id, user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_onboarding_documents_tenant_subido_por ON core.onboarding_documents (tenant_id, subido_por);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_password_reset_tokens_tenant_user_id ON core.password_reset_tokens (tenant_id, user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_production_lines_tenant_job_id ON core.production_lines (tenant_id, job_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_qa_results_tenant_qa_run_id ON core.qa_results (tenant_id, qa_run_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_qa_runs_tenant_spec_id ON core.qa_runs (tenant_id, spec_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_qa_runs_tenant_ticket_id ON core.qa_runs (tenant_id, ticket_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_refresh_tokens_tenant_user_id ON core.refresh_tokens (tenant_id, user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_security_findings_tenant_ticket_id ON core.security_findings (tenant_id, ticket_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_spec_alternatives_tenant_spec_id ON core.spec_alternatives (tenant_id, spec_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_spec_criteria_tenant_spec_id ON core.spec_criteria (tenant_id, spec_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_specs_tenant_ticket_id ON core.specs (tenant_id, ticket_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ticket_attachments_tenant_subido_por ON core.ticket_attachments (tenant_id, subido_por);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ticket_attachments_tenant_ticket_id ON core.ticket_attachments (tenant_id, ticket_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ticket_watchers_tenant_ticket_id ON core.ticket_watchers (tenant_id, ticket_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ticket_watchers_tenant_user_id ON core.ticket_watchers (tenant_id, user_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tickets_tenant_cancelado_por ON core.tickets (tenant_id, cancelado_por);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tickets_tenant_duplicado_de ON core.tickets (tenant_id, duplicado_de);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tickets_tenant_reportado_por ON core.tickets (tenant_id, reportado_por);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_upgrade_requests_tenant_solicitado_por ON core.upgrade_requests (tenant_id, solicitado_por);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_usage_loc_tenant_ticket_id ON core.usage_loc (tenant_id, ticket_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_usage_tokens_tenant_ticket_id ON core.usage_tokens (tenant_id, ticket_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_webhook_inbox_tenant_connection_id ON core.webhook_inbox (tenant_id, connection_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_webhook_inbox_tenant_ticket_id ON core.webhook_inbox (tenant_id, ticket_id);
-- ================================================================
-- ARCHIVO: db/migrations/019_cm_curacion_snapshots.sql
-- ================================================================
-- ============================================================================
-- KALLICODE · 019_cm_curacion_snapshots.sql
-- KC-DB-04-3 (CM-F05) — Cola de curación y refresco por snapshot en lugar de
-- MERGE incremental.
--
-- El refresco diario con MERGE incremental dejaba nodos y aristas fantasma:
-- lo que desaparecía del repositorio nunca se borraba del grafo. Con snapshots:
--   1. el snapshot nuevo se carga en estado 'en_progreso' (la carga ya existe);
--      cada nodo/arista que sube queda marcado con su snapshot_id;
--   2. cm.publicar_snapshot() verifica recuentos y mueve el puntero
--      (cm.snapshot_vigente) en UNA transacción: ningún lector ve un estado
--      intermedio;
--   3. el snapshot anterior queda 'retirado' y cm.retirar_snapshot() borra sus
--      nodos, y por cascada sus aristas, de forma diferida.
-- Lo que sigue marcado con el snapshot viejo es justo lo que el nuevo no vio:
-- los fantasmas.
--
-- Además, toda arista o concepto con confianza < 0,75 se rechaza en su tabla y
-- se registra en cm.curation_queue (trigger).
--
-- Nota: el ticket nombra esta migración 011, pero 011 ya existe.
-- Nota: 'cargando' del ticket = estado 'en_progreso' del esquema vigente.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Estado 'retirado' para el snapshot sustituido.
-- ---------------------------------------------------------------------------
ALTER TABLE cm.repo_snapshots DROP CONSTRAINT snapshots_estado_chk;
ALTER TABLE cm.repo_snapshots ADD CONSTRAINT snapshots_estado_chk
    CHECK (estado IN ('en_progreso','completo','fallido','pendiente_intervencion','retirado'));

-- ---------------------------------------------------------------------------
-- 2. Marca de snapshot en los nodos y aristas que aún no la tenían
--    (cm.files ya la tiene; symbols y db_columns cuelgan de files y db_tables
--    por ON DELETE CASCADE). Nullable: lo ingerido antes de esta migración no
--    pertenece a ningún snapshot y la retirada nunca lo toca.
-- ---------------------------------------------------------------------------
ALTER TABLE cm.db_tables   ADD COLUMN snapshot_id text;
ALTER TABLE cm.definitions ADD COLUMN snapshot_id text;
ALTER TABLE cm.concepts    ADD COLUMN snapshot_id text;
ALTER TABLE cm.edges       ADD COLUMN snapshot_id text;

ALTER TABLE cm.db_tables ADD CONSTRAINT db_tables_snapshot_fkey
    FOREIGN KEY (tenant_id, snapshot_id) REFERENCES cm.repo_snapshots(tenant_id, id) NOT VALID;
ALTER TABLE cm.definitions ADD CONSTRAINT definitions_snapshot_fkey
    FOREIGN KEY (tenant_id, snapshot_id) REFERENCES cm.repo_snapshots(tenant_id, id) NOT VALID;
ALTER TABLE cm.concepts ADD CONSTRAINT concepts_snapshot_fkey
    FOREIGN KEY (tenant_id, snapshot_id) REFERENCES cm.repo_snapshots(tenant_id, id) NOT VALID;
ALTER TABLE cm.edges ADD CONSTRAINT edges_snapshot_fkey
    FOREIGN KEY (tenant_id, snapshot_id) REFERENCES cm.repo_snapshots(tenant_id, id) NOT VALID;

ALTER TABLE cm.db_tables   VALIDATE CONSTRAINT db_tables_snapshot_fkey;
ALTER TABLE cm.definitions VALIDATE CONSTRAINT definitions_snapshot_fkey;
ALTER TABLE cm.concepts    VALIDATE CONSTRAINT concepts_snapshot_fkey;
ALTER TABLE cm.edges       VALIDATE CONSTRAINT edges_snapshot_fkey;

CREATE INDEX files_snapshot_idx       ON cm.files       (tenant_id, snapshot_id);
CREATE INDEX db_tables_snapshot_idx   ON cm.db_tables   (tenant_id, snapshot_id);
CREATE INDEX definitions_snapshot_idx ON cm.definitions (tenant_id, snapshot_id);
CREATE INDEX concepts_snapshot_idx    ON cm.concepts    (tenant_id, snapshot_id);
CREATE INDEX edges_snapshot_idx       ON cm.edges       (tenant_id, snapshot_id);

-- ---------------------------------------------------------------------------
-- 3. Puntero al snapshot vigente: una fila por tenant.
-- ---------------------------------------------------------------------------
CREATE TABLE cm.snapshot_vigente (
    tenant_id      text PRIMARY KEY REFERENCES core.organizations(id),
    snapshot_id    text NOT NULL,
    actualizado_en timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, snapshot_id) REFERENCES cm.repo_snapshots(tenant_id, id)
);

GRANT SELECT, INSERT, UPDATE, DELETE ON cm.snapshot_vigente TO kallicode_app;
ALTER TABLE cm.snapshot_vigente ENABLE ROW LEVEL SECURITY;
ALTER TABLE cm.snapshot_vigente FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON cm.snapshot_vigente
    USING (tenant_id = core.current_tenant())
    WITH CHECK (tenant_id = core.current_tenant());

-- ---------------------------------------------------------------------------
-- 4. Umbral de confianza y cola de curación (trigger).
-- ---------------------------------------------------------------------------
CREATE FUNCTION cm.umbral_confianza() RETURNS numeric
    LANGUAGE sql IMMUTABLE AS $$ SELECT 0.75::numeric $$;

-- Arista con confianza < umbral: no entra en cm.edges, queda pendiente de
-- revisión humana en cm.curation_queue (sin duplicar si ya estaba pendiente).
CREATE FUNCTION cm.edges_confianza_trg() RETURNS trigger
    LANGUAGE plpgsql AS $$
DECLARE
    v_conf numeric;
BEGIN
    IF jsonb_typeof(NEW.props -> 'confidence') IS DISTINCT FROM 'number' THEN
        RETURN NEW;
    END IF;
    v_conf := (NEW.props ->> 'confidence')::numeric;
    IF v_conf >= cm.umbral_confianza() THEN
        RETURN NEW;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM cm.curation_queue
         WHERE tenant_id = NEW.tenant_id AND tipo = 'enlace' AND estado = 'pendiente'
           AND payload @> jsonb_build_object(
                 'tipo', NEW.tipo, 'src_id', NEW.src_id, 'dst_id', NEW.dst_id)
    ) THEN
        INSERT INTO cm.curation_queue (id, tenant_id, tipo, payload)
        VALUES ('cq_' || replace(gen_random_uuid()::text, '-', ''), NEW.tenant_id, 'enlace',
                jsonb_build_object(
                    'tipo', NEW.tipo,
                    'src_kind', NEW.src_kind, 'src_id', NEW.src_id,
                    'dst_kind', NEW.dst_kind, 'dst_id', NEW.dst_id,
                    'confidence', v_conf, 'umbral', cm.umbral_confianza(),
                    'snapshot_id', NEW.snapshot_id));
    END IF;
    RETURN NULL;   -- rechazada: la fila no se inserta/actualiza
END $$;

CREATE TRIGGER edges_confianza
    BEFORE INSERT OR UPDATE OF props ON cm.edges
    FOR EACH ROW EXECUTE FUNCTION cm.edges_confianza_trg();

CREATE FUNCTION cm.concepts_confianza_trg() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.confianza IS NULL OR NEW.confianza >= cm.umbral_confianza() THEN
        RETURN NEW;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM cm.curation_queue
         WHERE tenant_id = NEW.tenant_id AND tipo = 'concepto' AND estado = 'pendiente'
           AND payload @> jsonb_build_object('id', NEW.id)
    ) THEN
        INSERT INTO cm.curation_queue (id, tenant_id, tipo, payload)
        VALUES ('cq_' || replace(gen_random_uuid()::text, '-', ''), NEW.tenant_id, 'concepto',
                jsonb_build_object(
                    'id', NEW.id, 'name_en', NEW.name_en, 'name_local', NEW.name_local,
                    'descripcion', NEW.descripcion,
                    'confidence', NEW.confianza, 'umbral', cm.umbral_confianza(),
                    'snapshot_id', NEW.snapshot_id));
    END IF;
    RETURN NULL;
END $$;

CREATE TRIGGER concepts_confianza
    BEFORE INSERT OR UPDATE OF confianza ON cm.concepts
    FOR EACH ROW EXECUTE FUNCTION cm.concepts_confianza_trg();

-- ---------------------------------------------------------------------------
-- 5. Estadísticas del snapshot: nodos por kind y aristas por kind de origen.
--    Alimenta el informe de ingesta de CodeMapping.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cm.stats_snapshot(p_snapshot text)
    RETURNS TABLE (kind text, nodos bigint, aristas bigint)
    LANGUAGE sql STABLE AS $$
    WITH n AS (
        SELECT 'file'::text AS k, count(*) AS c FROM cm.files WHERE snapshot_id = p_snapshot
        UNION ALL
        SELECT 'symbol', count(*) FROM cm.symbols s
          JOIN cm.files f ON f.tenant_id = s.tenant_id AND f.id = s.file_id
         WHERE f.snapshot_id = p_snapshot
        UNION ALL
        SELECT 'db_table', count(*) FROM cm.db_tables WHERE snapshot_id = p_snapshot
        UNION ALL
        SELECT 'db_column', count(*) FROM cm.db_columns c
          JOIN cm.db_tables t ON t.tenant_id = c.tenant_id AND t.id = c.table_id
         WHERE t.snapshot_id = p_snapshot
        UNION ALL
        SELECT 'definition', count(*) FROM cm.definitions WHERE snapshot_id = p_snapshot
        UNION ALL
        SELECT 'concept', count(*) FROM cm.concepts WHERE snapshot_id = p_snapshot
    ), a AS (
        SELECT src_kind AS k, count(*) AS c FROM cm.edges
         WHERE snapshot_id = p_snapshot GROUP BY src_kind
    )
    SELECT n.k, n.c, coalesce(a.c, 0) FROM n LEFT JOIN a ON a.k = n.k ORDER BY n.k
$$;

-- ---------------------------------------------------------------------------
-- 6. Publicación atómica: verifica recuentos, marca 'completo' el nuevo, mueve
--    el puntero y marca 'retirado' el anterior, todo en la transacción del
--    llamador. Devuelve el id del snapshot sustituido (NULL si era el primero).
--    Si algo falla, nada cambia: el puntero sigue en el snapshot anterior.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cm.publicar_snapshot(p_snapshot text, p_nodos bigint, p_aristas bigint)
    RETURNS text
    LANGUAGE plpgsql AS $$
DECLARE
    v_tenant text := core.current_tenant();
    v_estado text;
    v_previo text;
    v_nodos  bigint;
    v_aristas bigint;
BEGIN
    SELECT estado INTO v_estado FROM cm.repo_snapshots
     WHERE tenant_id = v_tenant AND id = p_snapshot FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'snapshot % inexistente', p_snapshot USING ERRCODE = 'no_data_found';
    END IF;
    IF v_estado <> 'en_progreso' THEN
        RAISE EXCEPTION 'snapshot % en estado %, solo se publica desde en_progreso',
            p_snapshot, v_estado USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT coalesce(sum(nodos), 0), coalesce(sum(aristas), 0) INTO v_nodos, v_aristas
      FROM cm.stats_snapshot(p_snapshot);
    IF v_nodos <> p_nodos OR v_aristas <> p_aristas THEN
        RAISE EXCEPTION 'recuentos del snapshot % no coinciden: cargados % nodos / % aristas, esperados % / %',
            p_snapshot, v_nodos, v_aristas, p_nodos, p_aristas USING ERRCODE = 'check_violation';
    END IF;

    SELECT snapshot_id INTO v_previo FROM cm.snapshot_vigente
     WHERE tenant_id = v_tenant FOR UPDATE;

    UPDATE cm.repo_snapshots SET estado = 'completo', finalizado_en = now()
     WHERE tenant_id = v_tenant AND id = p_snapshot;

    INSERT INTO cm.snapshot_vigente (tenant_id, snapshot_id) VALUES (v_tenant, p_snapshot)
    ON CONFLICT (tenant_id) DO UPDATE
        SET snapshot_id = EXCLUDED.snapshot_id, actualizado_en = now();

    IF v_previo IS NOT NULL AND v_previo <> p_snapshot THEN
        UPDATE cm.repo_snapshots SET estado = 'retirado'
         WHERE tenant_id = v_tenant AND id = v_previo;
    ELSE
        v_previo := NULL;
    END IF;
    RETURN v_previo;
END $$;

-- ---------------------------------------------------------------------------
-- 7. Retirada diferida: borra los nodos de un snapshot 'retirado' y, por
--    cascada, sus aristas (las propias y cualquiera que apunte a un nodo ya
--    inexistente: las aristas son polimórficas y no tienen FK al nodo).
-- ---------------------------------------------------------------------------
CREATE FUNCTION cm._nodo_existe(p_kind text, p_id text) RETURNS boolean
    LANGUAGE sql STABLE AS $$
    SELECT CASE p_kind
        WHEN 'file'       THEN EXISTS (SELECT 1 FROM cm.files       WHERE id = p_id)
        WHEN 'symbol'     THEN EXISTS (SELECT 1 FROM cm.symbols     WHERE id = p_id)
        WHEN 'db_table'   THEN EXISTS (SELECT 1 FROM cm.db_tables   WHERE id = p_id)
        WHEN 'db_column'  THEN EXISTS (SELECT 1 FROM cm.db_columns  WHERE id = p_id)
        WHEN 'definition' THEN EXISTS (SELECT 1 FROM cm.definitions WHERE id = p_id)
        WHEN 'concept'    THEN EXISTS (SELECT 1 FROM cm.concepts    WHERE id = p_id)
        ELSE false
    END
$$;

CREATE FUNCTION cm.retirar_snapshot(p_snapshot text)
    RETURNS TABLE (nodos_borrados bigint, aristas_borradas bigint)
    LANGUAGE plpgsql AS $$
DECLARE
    v_tenant  text := core.current_tenant();
    v_estado  text;
    v_nodos   bigint := 0;
    v_aristas bigint := 0;
    v_n       bigint;
BEGIN
    SELECT estado INTO v_estado FROM cm.repo_snapshots
     WHERE tenant_id = v_tenant AND id = p_snapshot FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'snapshot % inexistente', p_snapshot USING ERRCODE = 'no_data_found';
    END IF;
    IF v_estado <> 'retirado' THEN
        RAISE EXCEPTION 'snapshot % en estado %, solo se retira un snapshot ya sustituido',
            p_snapshot, v_estado USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Cuenta antes de borrar: files y db_tables arrastran symbols y db_columns.
    SELECT sum(nodos) INTO v_nodos FROM cm.stats_snapshot(p_snapshot);

    DELETE FROM cm.edges WHERE tenant_id = v_tenant AND snapshot_id = p_snapshot;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_aristas := v_n;

    DELETE FROM cm.concepts    WHERE tenant_id = v_tenant AND snapshot_id = p_snapshot;
    DELETE FROM cm.definitions WHERE tenant_id = v_tenant AND snapshot_id = p_snapshot;
    DELETE FROM cm.db_tables   WHERE tenant_id = v_tenant AND snapshot_id = p_snapshot;
    DELETE FROM cm.files       WHERE tenant_id = v_tenant AND snapshot_id = p_snapshot;

    -- Aristas de otros snapshots que colgaban de un nodo recién borrado.
    DELETE FROM cm.edges
     WHERE tenant_id = v_tenant
       AND NOT (cm._nodo_existe(src_kind, src_id) AND cm._nodo_existe(dst_kind, dst_id));
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_aristas := v_aristas + v_n;

    RETURN QUERY SELECT coalesce(v_nodos, 0), v_aristas;
END $$;

GRANT EXECUTE ON FUNCTION cm.stats_snapshot(text)                   TO kallicode_app;
GRANT EXECUTE ON FUNCTION cm.publicar_snapshot(text, bigint, bigint) TO kallicode_app;
GRANT EXECUTE ON FUNCTION cm.retirar_snapshot(text)                 TO kallicode_app;

-- ================================================================
-- ARCHIVO: db/migrations/020_indices_edges_include.sql
-- ================================================================
-- kc:sin-transaccion
CREATE INDEX CONCURRENTLY IF NOT EXISTS edges_out_ix ON cm.edges (tenant_id, src_id, tipo, dst_id) INCLUDE (src_kind, dst_kind, props);
CREATE INDEX CONCURRENTLY IF NOT EXISTS edges_in_ix ON cm.edges (tenant_id, dst_id, tipo, src_id) INCLUDE (src_kind, dst_kind, props);
-- ================================================================
-- ARCHIVO: db/migrations/021_catalogo_tipos_grafo.sql
-- ================================================================
-- Migración 021: Catálogo generado de tipos de nodo y arista (KC-DB-04-6)
-- Formaliza el metamodelo del grafo de CodeMapping cm.* en tablas de catálogo y vistas de consulta.

SET lock_timeout = '5s';
SET statement_timeout = '30s';


-- 1. Catálogo canónico de tipos de nodo
CREATE TABLE IF NOT EXISTS cm.node_types (
    kind            text PRIMARY KEY,
    categoria       text NOT NULL, -- 'codigo', 'base_datos', 'semantica'
    descripcion     text NOT NULL,
    creado_en       timestamptz NOT NULL DEFAULT now()
);

INSERT INTO cm.node_types (kind, categoria, descripcion) VALUES
    ('file', 'codigo', 'Archivo fuente indexado en el repositorio'),
    ('symbol', 'codigo', 'Símbolo del AST: función, clase, método, interfaz, enum o tipo'),
    ('db_table', 'base_datos', 'Tabla relacional de esquema SQL analizado'),
    ('db_column', 'base_datos', 'Columna relacional con atributos y tipos'),
    ('definition', 'semantica', 'Unidad de definición semántica vectorizada'),
    ('concept', 'semantica', 'Concepto de dominio o término de ontología')
ON CONFLICT (kind) DO NOTHING;

-- 2. Catálogo canónico de tipos de arista
CREATE TABLE IF NOT EXISTS cm.edge_types (
    tipo            text PRIMARY KEY,
    es_dirigida     boolean NOT NULL DEFAULT true,
    descripcion     text NOT NULL,
    creado_en       timestamptz NOT NULL DEFAULT now()
);

INSERT INTO cm.edge_types (tipo, es_dirigida, descripcion) VALUES
    ('DEFINES', true, 'El archivo u objeto define un símbolo o entidad'),
    ('CALLS', true, 'Invocación o referencia de llamada entre símbolos'),
    ('HAS_COLUMN', true, 'Pertenencia estructural de una columna a una tabla'),
    ('REFERENCES', true, 'Referencia foránea o dependencia entre tablas/entidades'),
    ('USES_TABLE', true, 'Símbolo de código ejecuta lecturas o escrituras sobre tabla SQL'),
    ('REALIZED_BY', true, 'Concepto de negocio materializado en código o tabla'),
    ('RELATES', false, 'Relación semántica simétrica entre conceptos ontológicos'),
    ('EXPRESSES', true, 'Símbolo o archivo expresa un concepto o definición de negocio')
ON CONFLICT (tipo) DO NOTHING;

-- 3. Vista de catálogo generado de reglas válidas de aristas (metamodelo)
CREATE OR REPLACE VIEW cm.v_catalogo_grafo AS
SELECT 
    e.tipo AS edge_type,
    e.es_dirigida,
    e.descripcion AS edge_descripcion,
    array_agg(DISTINCT n_src.kind ORDER BY n_src.kind) AS src_kinds_validos,
    array_agg(DISTINCT n_dst.kind ORDER BY n_dst.kind) AS dst_kinds_validos
FROM cm.edge_types e
CROSS JOIN cm.node_types n_src
CROSS JOIN cm.node_types n_dst
GROUP BY e.tipo, e.es_dirigida, e.descripcion;

-- Permisos de lectura
GRANT SELECT ON cm.node_types TO kallicode_app, kallicode_worker;
GRANT SELECT ON cm.edge_types TO kallicode_app, kallicode_worker;
GRANT SELECT ON cm.v_catalogo_grafo TO kallicode_app, kallicode_worker;


-- ================================================================
-- ARCHIVO: db/migrations/022_vec_fk_cm.sql
-- ================================================================
-- ============================================================================
-- KALLICODE · 022_vec_fk_cm.sql
-- KC-DB-04-4 (DB-F18) — Consolidación de vec.definition_embeddings contra cm.nodes.
--
-- vec.definition_embeddings.nodo_ref era un text libre documentado como «id del
-- nodo en el grafo (Neo4j)», y de_capa_chk restringía capa a
-- ('definicion','negocio','codigo'), tres valores que no corresponden a ningún
-- kind del grafo real. Con cm desplegado (KC-ONB-03-1, 002_esquema_cm.sql):
--
--   1. cm.nodes(tenant_id, id, kind): registro único de nodos del grafo. Los
--      nodos viven en seis tablas (files, symbols, db_tables, db_columns,
--      definitions, concepts); una FK no puede apuntar a seis tablas, así que
--      cm.nodes se mantiene sincronizada con triggers y es el destino de la FK.
--   2. capa pasa a ser el kind del nodo (catálogo cm.node_types) y los datos
--      existentes se convierten, dejando constancia en vec.acta_conversion_capa.
--   3. nodo_ref pasa a FK compuesta (tenant_id, nodo_ref) -> cm.nodes(tenant_id, id)
--      con ON DELETE CASCADE: borrar un nodo borra su embedding en la misma
--      transacción, y ningún embedding puede apuntar a un nodo de otro tenant.
--
-- Nota: el ticket nombra esta migración 012, pero 012 ya existe.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. cm.nodes: un registro por nodo, con su kind.
-- ---------------------------------------------------------------------------
CREATE TABLE cm.nodes (
    tenant_id text NOT NULL REFERENCES core.organizations(id),
    id        text NOT NULL,
    kind      text NOT NULL REFERENCES cm.node_types(kind),
    PRIMARY KEY (tenant_id, id)
);
CREATE INDEX nodes_kind_idx ON cm.nodes (tenant_id, kind);

GRANT SELECT, INSERT, UPDATE, DELETE ON cm.nodes TO kallicode_app;
ALTER TABLE cm.nodes ENABLE ROW LEVEL SECURITY;
ALTER TABLE cm.nodes FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON cm.nodes
    USING (tenant_id = core.current_tenant())
    WITH CHECK (tenant_id = core.current_tenant());

-- Sincronización: cada fila de una tabla de nodos registra/retira su nodo.
-- TG_ARGV[0] es el kind. Un id repetido entre kinds distintos viola la PK y
-- aborta la escritura (el id de un nodo es único por tenant, sea cual sea su kind).
CREATE FUNCTION cm.nodes_sync_ins_trg() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO cm.nodes (tenant_id, id, kind) VALUES (NEW.tenant_id, NEW.id, TG_ARGV[0]);
    RETURN NULL;
END $$;

CREATE FUNCTION cm.nodes_sync_del_trg() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM cm.nodes
     WHERE tenant_id = OLD.tenant_id AND id = OLD.id AND kind = TG_ARGV[0];
    RETURN NULL;
END $$;

CREATE TRIGGER nodes_sync_ins AFTER INSERT ON cm.files
    FOR EACH ROW EXECUTE FUNCTION cm.nodes_sync_ins_trg('file');
CREATE TRIGGER nodes_sync_ins AFTER INSERT ON cm.symbols
    FOR EACH ROW EXECUTE FUNCTION cm.nodes_sync_ins_trg('symbol');
CREATE TRIGGER nodes_sync_ins AFTER INSERT ON cm.db_tables
    FOR EACH ROW EXECUTE FUNCTION cm.nodes_sync_ins_trg('db_table');
CREATE TRIGGER nodes_sync_ins AFTER INSERT ON cm.db_columns
    FOR EACH ROW EXECUTE FUNCTION cm.nodes_sync_ins_trg('db_column');
CREATE TRIGGER nodes_sync_ins AFTER INSERT ON cm.definitions
    FOR EACH ROW EXECUTE FUNCTION cm.nodes_sync_ins_trg('definition');
CREATE TRIGGER nodes_sync_ins AFTER INSERT ON cm.concepts
    FOR EACH ROW EXECUTE FUNCTION cm.nodes_sync_ins_trg('concept');

CREATE TRIGGER nodes_sync_del AFTER DELETE ON cm.files
    FOR EACH ROW EXECUTE FUNCTION cm.nodes_sync_del_trg('file');
CREATE TRIGGER nodes_sync_del AFTER DELETE ON cm.symbols
    FOR EACH ROW EXECUTE FUNCTION cm.nodes_sync_del_trg('symbol');
CREATE TRIGGER nodes_sync_del AFTER DELETE ON cm.db_tables
    FOR EACH ROW EXECUTE FUNCTION cm.nodes_sync_del_trg('db_table');
CREATE TRIGGER nodes_sync_del AFTER DELETE ON cm.db_columns
    FOR EACH ROW EXECUTE FUNCTION cm.nodes_sync_del_trg('db_column');
CREATE TRIGGER nodes_sync_del AFTER DELETE ON cm.definitions
    FOR EACH ROW EXECUTE FUNCTION cm.nodes_sync_del_trg('definition');
CREATE TRIGGER nodes_sync_del AFTER DELETE ON cm.concepts
    FOR EACH ROW EXECUTE FUNCTION cm.nodes_sync_del_trg('concept');

-- Relleno de lo ya cargado (el runner corre como kallicode_admin, BYPASSRLS).
INSERT INTO cm.nodes (tenant_id, id, kind) SELECT tenant_id, id, 'file'       FROM cm.files;
INSERT INTO cm.nodes (tenant_id, id, kind) SELECT tenant_id, id, 'symbol'     FROM cm.symbols;
INSERT INTO cm.nodes (tenant_id, id, kind) SELECT tenant_id, id, 'db_table'   FROM cm.db_tables;
INSERT INTO cm.nodes (tenant_id, id, kind) SELECT tenant_id, id, 'db_column'  FROM cm.db_columns;
INSERT INTO cm.nodes (tenant_id, id, kind) SELECT tenant_id, id, 'definition' FROM cm.definitions;
INSERT INTO cm.nodes (tenant_id, id, kind) SELECT tenant_id, id, 'concept'    FROM cm.concepts;

-- ---------------------------------------------------------------------------
-- 2. Acta de conversión de capa -> kind. Solo la lee el admin (sin GRANT al app).
--    Cada fila resume un par (capa antigua -> kind nuevo). Los embeddings cuyo
--    nodo_ref no existe en cm.nodes no tienen a qué convertirse: se eliminan
--    (son datos derivados, el siguiente refresco los regenera) y quedan
--    listados en ids_huerfanos.
-- ---------------------------------------------------------------------------
CREATE TABLE vec.acta_conversion_capa (
    id               bigserial PRIMARY KEY,
    migracion        text NOT NULL,
    capa_antigua     text NOT NULL,
    capa_nueva       text,                       -- NULL en la fila de huérfanos
    filas_convertidas bigint NOT NULL DEFAULT 0,
    filas_huerfanas  bigint NOT NULL DEFAULT 0,
    ids_huerfanos    jsonb NOT NULL DEFAULT '[]',
    ejecutado_en     timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE vec.definition_embeddings DROP CONSTRAINT de_capa_chk;

INSERT INTO vec.acta_conversion_capa (migracion, capa_antigua, capa_nueva, filas_convertidas)
SELECT '022_vec_fk_cm.sql', d.capa, n.kind, count(*)
  FROM vec.definition_embeddings d
  JOIN cm.nodes n ON n.tenant_id = d.tenant_id AND n.id = d.nodo_ref
 GROUP BY d.capa, n.kind;

INSERT INTO vec.acta_conversion_capa (migracion, capa_antigua, filas_huerfanas, ids_huerfanos)
SELECT '022_vec_fk_cm.sql', d.capa, count(*),
       jsonb_agg(jsonb_build_object('tenant_id', d.tenant_id, 'id', d.id, 'nodo_ref', d.nodo_ref))
  FROM vec.definition_embeddings d
 WHERE NOT EXISTS (SELECT 1 FROM cm.nodes n WHERE n.tenant_id = d.tenant_id AND n.id = d.nodo_ref)
 GROUP BY d.capa;

UPDATE vec.definition_embeddings d
   SET capa = n.kind
  FROM cm.nodes n
 WHERE n.tenant_id = d.tenant_id AND n.id = d.nodo_ref;

DELETE FROM vec.definition_embeddings d
 WHERE NOT EXISTS (SELECT 1 FROM cm.nodes n WHERE n.tenant_id = d.tenant_id AND n.id = d.nodo_ref);

-- ---------------------------------------------------------------------------
-- 3. Restricciones nuevas. capa admite exactamente los kinds del grafo
--    (cm.node_types); nodo_ref es FK compuesta a cm.nodes. La UNIQUE
--    (tenant_id, nodo_ref) existente (de_nodo_uq) respalda la FK en el lado hijo.
-- ---------------------------------------------------------------------------
ALTER TABLE vec.definition_embeddings ADD CONSTRAINT de_capa_chk
    CHECK (capa IN ('file','symbol','db_table','db_column','definition','concept'));

ALTER TABLE vec.definition_embeddings ADD CONSTRAINT de_nodo_fk
    FOREIGN KEY (tenant_id, nodo_ref) REFERENCES cm.nodes (tenant_id, id)
    ON DELETE CASCADE NOT VALID;
ALTER TABLE vec.definition_embeddings VALIDATE CONSTRAINT de_nodo_fk;

COMMENT ON COLUMN vec.definition_embeddings.nodo_ref IS
    'id del nodo en cm.nodes (FK compuesta con tenant_id, ON DELETE CASCADE)';
COMMENT ON COLUMN vec.definition_embeddings.capa IS
    'kind del nodo: file | symbol | db_table | db_column | definition | concept';

-- ================================================================
-- ARCHIVO: db/migrations/023_hnsw_iterative_scan.sql
-- ================================================================
-- kc:sin-transaccion
DROP INDEX CONCURRENTLY IF EXISTS vec.definition_embeddings_hnsw_ix;
CREATE INDEX CONCURRENTLY IF NOT EXISTS definition_embeddings_hnsw_ix ON vec.definition_embeddings USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);
-- ================================================================
-- ARCHIVO: db/migrations/024_cadena_auditoria.sql
-- ================================================================
-- ============================================================================
-- KALLICODE · 024_cadena_auditoria.sql
-- KC-DB-05-1 (DB-F04, BLOQUEANTE) — audit.verify_chain verifica el
-- encadenamiento y audit.chain_heads queda protegida.
--
-- Dos defectos de la cadena de auditoría (db/03_triggers.sql, db/04_rls.sql):
--
--   1. verify_chain recalculaba el sello de cada fila y lo comparaba con el
--      almacenado, pero nunca comprobaba que sello_previo coincidiera con el
--      sello del evento anterior: cada evento se validaba contra sí mismo, así
--      que borrar o truncar eventos intermedios dejaba la cadena «íntegra».
--   2. 04_rls.sql concedía UPDATE sobre audit.chain_heads a kallicode_app y
--      ningún trigger la protegía: el rol de la aplicación podía ajustar
--      ultimo_sello y eventos para que V16/V17 cuadraran tras borrar eventos.
--
-- Corrección:
--   * verify_chain exige el encadenamiento (sello_previo = sello del eslabón
--     anterior; génesis = repeat('0', 64)) y devuelve eventos esperados frente
--     a observados.
--   * kallicode_app pierde INSERT/UPDATE/DELETE/TRUNCATE sobre chain_heads: solo
--     la actualiza audit.seal_event (SECURITY DEFINER). Un trigger rechaza
--     cualquier retroceso o reescritura de la cabeza.
--   * V16 y V17 se reescriben sobre la función corregida y detectan huecos.
--
-- Nota: el ticket nombra esta migración 013, pero 013 ya existe.
--
-- Nota de diseño: el encadenamiento se verifica como propiedad del conjunto de
-- eventos (cada sello_previo es el génesis o el sello de otro evento del
-- tenant; ningún sello_previo se repite) y no recorriendo por id. El id se
-- asigna ANTES de que seal_event tome el candado de la cabeza, así que con
-- escrituras concurrentes del mismo tenant el orden por id puede diferir del
-- orden real de la cadena y una verificación por id daría falsas alarmas.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Índice para resolver sello_previo -> evento anterior sin recorrer la tabla.
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS audit_events_sello_ix ON audit.audit_events (tenant_id, sello);

-- ---------------------------------------------------------------------------
-- 2. verify_chain: sello propio + encadenamiento + recuento.
--    integra = false si algún evento (a) no cuadra con su sello, (b) apunta a
--    un eslabón que ya no existe, (c) comparte eslabón anterior con otro
--    (bifurcación) o (d) el recuento observado difiere del de chain_heads.
--    primer_evento_roto es el id menor entre los (a)-(c); un recorte de cola no
--    tiene evento «roto» y se delata solo por eventos_esperados <> observados.
--    Con ventana (p_desde/p_hasta) no hay recuento esperado: es NULL.
-- ---------------------------------------------------------------------------
DROP FUNCTION audit.verify_chain(text, timestamptz, timestamptz);

CREATE FUNCTION audit.verify_chain(p_tenant text,
                                   p_desde timestamptz DEFAULT NULL,
                                   p_hasta timestamptz DEFAULT NULL)
RETURNS TABLE (integra boolean,
               eventos_verificados bigint,
               primer_evento_roto bigint,
               eventos_esperados bigint,
               eventos_observados bigint)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    genesis constant text := repeat('0', 64);
    sin_ventana boolean := (p_desde IS NULL AND p_hasta IS NULL);
    n bigint;
    roto bigint;
BEGIN
    WITH ev AS (
        SELECT e.id,
               encode(sha256(convert_to(
                   e.sello_previo || e.tenant_id || e.evento || e.resumen
                   || coalesce(e.datos::text, '') || coalesce(e.ticket_id, '')
                   || coalesce(e.actor_id, '')
                   || to_char(e.creado_en, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                   'UTF8')), 'hex') <> e.sello AS sello_malo,
               (e.sello_previo <> genesis AND NOT EXISTS (
                   SELECT 1 FROM audit.audit_events p
                    WHERE p.tenant_id = e.tenant_id AND p.sello = e.sello_previo
               )) AS eslabon_perdido,
               (count(*) OVER (PARTITION BY e.sello_previo) > 1) AS bifurcado
          FROM audit.audit_events e
         WHERE e.tenant_id = p_tenant
           AND (p_desde IS NULL OR e.creado_en >= p_desde)
           AND (p_hasta IS NULL OR e.creado_en <= p_hasta)
    )
    SELECT count(*), min(id) FILTER (WHERE sello_malo OR eslabon_perdido OR bifurcado)
      INTO n, roto
      FROM ev;

    eventos_verificados := n;
    eventos_observados  := n;
    primer_evento_roto  := roto;
    eventos_esperados   := NULL;
    IF sin_ventana THEN
        SELECT h.eventos INTO eventos_esperados
          FROM audit.chain_heads h WHERE h.tenant_id = p_tenant;
    END IF;

    integra := roto IS NULL
               AND (eventos_esperados IS NULL OR eventos_esperados = n);
    RETURN NEXT;
END $$;

COMMENT ON FUNCTION audit.verify_chain(text, timestamptz, timestamptz) IS
'KC-DB-05-1: verifica sello propio, encadenamiento (sello_previo = sello del eslabon anterior, genesis repeat(0,64)) y recuento contra chain_heads. Usada por validar_integridad (V16/V17) y GET /audit/integrity.';

-- ---------------------------------------------------------------------------
-- 3. seal_event: único camino de escritura de chain_heads.
--    SECURITY DEFINER (dueño: kallicode_admin) para poder quitarle a la
--    aplicación todo permiso de escritura sobre la cabeza. Una sola
--    actualización por evento (eventos + 1 y ultimo_sello a la vez), tras tomar
--    el candado de la fila: la cadena no se bifurca.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.seal_event() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE prev text;
BEGIN
    -- La función corre con privilegios de su dueño: no puede sellar eventos de
    -- otro tenant aunque el INSERT lo pida (la política RLS lo rechazaría, pero
    -- solo después de haber tocado la cabeza ajena).
    IF coalesce(core.current_tenant(), '') <> ''
       AND NEW.tenant_id <> core.current_tenant() THEN
        RAISE EXCEPTION 'audit.seal_event: el evento es de otro tenant (%)', NEW.tenant_id
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    INSERT INTO audit.chain_heads (tenant_id) VALUES (NEW.tenant_id)
        ON CONFLICT (tenant_id) DO NOTHING;
    -- Bloquea la cabeza de cadena del tenant hasta el COMMIT:
    SELECT ultimo_sello INTO prev
      FROM audit.chain_heads WHERE tenant_id = NEW.tenant_id FOR UPDATE;

    NEW.sello_previo := prev;
    NEW.creado_en    := now();
    NEW.sello := encode(sha256(convert_to(
        prev
        || NEW.tenant_id
        || NEW.evento
        || NEW.resumen
        || coalesce(NEW.datos::text, '')
        || coalesce(NEW.ticket_id, '')
        || coalesce(NEW.actor_id, '')
        || to_char(NEW.creado_en, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
        'UTF8')), 'hex');

    UPDATE audit.chain_heads
       SET eventos = eventos + 1, ultimo_sello = NEW.sello
     WHERE tenant_id = NEW.tenant_id;
    RETURN NEW;
END $$;

-- ---------------------------------------------------------------------------
-- 4. La aplicación pierde la escritura sobre chain_heads (conserva SELECT:
--    verify_chain y V16/V17 la leen).
-- ---------------------------------------------------------------------------
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON audit.chain_heads FROM kallicode_app;

-- ---------------------------------------------------------------------------
-- 5. Inmutabilidad de la cabeza: solo se admite avanzar de uno en uno. Ni la
--    aplicación ni un rol privilegiado pueden hacerla retroceder o reescribirla
--    sin desactivar este trigger a propósito. Borrar una cabeza solo se permite
--    si el tenant ya no tiene eventos (p. ej. limpieza de pruebas).
-- ---------------------------------------------------------------------------
CREATE FUNCTION audit.chain_heads_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.tenant_id <> OLD.tenant_id OR NEW.eventos <> OLD.eventos + 1 THEN
            RAISE EXCEPTION
                'audit.chain_heads: la cabeza solo avanza de uno en uno (eventos % -> %)',
                OLD.eventos, NEW.eventos USING ERRCODE = 'raise_exception';
        END IF;
        RETURN NEW;
    END IF;
    -- DELETE
    IF EXISTS (SELECT 1 FROM audit.audit_events WHERE tenant_id = OLD.tenant_id) THEN
        RAISE EXCEPTION 'audit.chain_heads: el tenant % aun tiene eventos; no se puede borrar su cabeza',
            OLD.tenant_id USING ERRCODE = 'raise_exception';
    END IF;
    RETURN OLD;
END $$;

CREATE TRIGGER trg_chain_heads_guard
    BEFORE UPDATE OR DELETE ON audit.chain_heads
    FOR EACH ROW EXECUTE FUNCTION audit.chain_heads_guard();

CREATE FUNCTION audit.chain_heads_no_truncate() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'audit.chain_heads: TRUNCATE prohibido' USING ERRCODE = 'raise_exception';
END $$;

CREATE TRIGGER trg_chain_heads_no_truncate
    BEFORE TRUNCATE ON audit.chain_heads
    FOR EACH STATEMENT EXECUTE FUNCTION audit.chain_heads_no_truncate();

-- ---------------------------------------------------------------------------
-- 6. validar_integridad(): V01-V21 idénticos a 011_v21_coherencia_tenant.sql
--    salvo V16 y V17 (PostgreSQL no permite cambiar un chequeo: se reemplaza
--    la función).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.validar_integridad()
RETURNS TABLE (chequeo text, descripcion text, problemas bigint)
LANGUAGE plpgsql STABLE AS $$
BEGIN

-- V01 · Suscripción vigente: todo tenant activo debe tener exactamente una.
chequeo := 'V01_suscripcion_vigente';
descripcion := 'Tenants sin suscripción vigente (o con más de una)';
SELECT count(*) INTO problemas FROM (
    SELECT o.id
      FROM core.organizations o
      LEFT JOIN core.subscriptions s
             ON s.tenant_id = o.id AND s.finaliza_el IS NULL
     WHERE o.eliminado_en IS NULL
     GROUP BY o.id
    HAVING count(s.id) <> 1
) q;
RETURN NEXT;

-- V02 · Ticket ⇄ job: la etapa visible del ticket debe corresponder al job activo.
chequeo := 'V02_espejo_ticket_job';
descripcion := 'Tickets activos cuya etapa no corresponde al estado de su job';
SELECT count(*) INTO problemas
  FROM core.tickets t
  JOIN core.jobs j ON j.ticket_id = t.id
             AND j.estado NOT IN ('produccion','cancelado','cerrado_duplicado')
 WHERE t.etapa <> CASE j.estado
        WHEN 'gate1' THEN 'design'
        WHEN 'gate2' THEN 'qa'
        WHEN 'gate3' THEN 'deploy'
        WHEN 'deploy_preflight' THEN 'deploy'
        WHEN 'pendiente_asignacion' THEN 'triage'
        WHEN 'pausado_por_cuota' THEN 'en_cola_por_cuota'
        WHEN 'escalado_humano' THEN t.etapa
        ELSE j.estado END;
RETURN NEXT;

-- V03 · Gate 3 sin gates 1 y 2 (el trigger lo impide; verificación de defensa).
chequeo := 'V03_gate3_sin_previos';
descripcion := 'Aprobaciones de Gate 3 sin aprobación previa de gates 1 y 2';
SELECT count(*) INTO problemas
  FROM core.gate_signatures g3
 WHERE g3.gate = 3 AND g3.accion = 'aprobado'
   AND 2 > (SELECT count(DISTINCT g.gate) FROM core.gate_signatures g
             WHERE g.ticket_id = g3.ticket_id
               AND g.gate IN (1,2) AND g.accion = 'aprobado'
               AND g.creado_en <= g3.creado_en);
RETURN NEXT;

-- V04 · Tickets en producción con las tres firmas.
chequeo := 'V04_produccion_sin_firmas';
descripcion := 'Tickets en producción sin las tres firmas de gates';
SELECT count(*) INTO problemas
  FROM core.tickets t
 WHERE t.etapa = 'produccion'
   AND 3 > (SELECT count(DISTINCT gate) FROM core.gate_signatures
             WHERE ticket_id = t.id AND accion = 'aprobado');
RETURN NEXT;

-- V05 · Specs: exactamente una alternativa recomendada por versión.
chequeo := 'V05_spec_recomendada';
descripcion := 'Specs sin exactamente una alternativa recomendada';
SELECT count(*) INTO problemas FROM (
    SELECT s.id FROM core.specs s
      LEFT JOIN core.spec_alternatives a ON a.spec_id = s.id AND a.recomendada
     GROUP BY s.id HAVING count(a.alt_id) <> 1
) q;
RETURN NEXT;

-- V06 · Specs aprobadas con alternativa elegida.
chequeo := 'V06_spec_aprobada_sin_eleccion';
descripcion := 'Specs aprobadas (Gate 1) sin alternativa elegida';
SELECT count(*) INTO problemas FROM (
    SELECT s.id FROM core.specs s
     WHERE s.estado = 'aprobada'
       AND NOT EXISTS (SELECT 1 FROM core.spec_alternatives a
                        WHERE a.spec_id = s.id AND a.elegida)
       AND EXISTS (SELECT 1 FROM core.spec_alternatives a WHERE a.spec_id = s.id)
) q;
RETURN NEXT;

-- V07 · Matriz de QA completa: cada corrida cubre todos los criterios de su spec.
chequeo := 'V07_matriz_qa_completa';
descripcion := 'Corridas de QA que no cubren todos los criterios de la spec';
SELECT count(*) INTO problemas FROM (
    SELECT r.id
      FROM core.qa_runs r
      JOIN core.spec_criteria c ON c.spec_id = r.spec_id
      LEFT JOIN core.qa_results q ON q.qa_run_id = r.id AND q.criterio_id = c.criterio_id
     GROUP BY r.id
    HAVING count(c.criterio_id) <> count(q.criterio_id)
) q;
RETURN NEXT;

-- V08 · Resultados de QA que referencian criterios inexistentes en la spec.
chequeo := 'V08_qa_criterio_fantasma';
descripcion := 'Resultados de QA con criterio_id que no existe en la spec de la corrida';
SELECT count(*) INTO problemas
  FROM core.qa_results q
  JOIN core.qa_runs r ON r.id = q.qa_run_id
 WHERE NOT EXISTS (SELECT 1 FROM core.spec_criteria c
                    WHERE c.spec_id = r.spec_id AND c.criterio_id = q.criterio_id);
RETURN NEXT;

-- V09 · Deploy bloqueado: tickets en produccion con hallazgos bloqueantes abiertos.
chequeo := 'V09_produccion_con_bloqueantes';
descripcion := 'Tickets en producción con hallazgos de seguridad bloqueantes abiertos';
SELECT count(*) INTO problemas
  FROM core.tickets t
 WHERE t.etapa = 'produccion'
   AND EXISTS (SELECT 1 FROM core.security_findings f
                WHERE f.ticket_id = t.id AND f.bloquea AND f.estado = 'abierto');
RETURN NEXT;

-- V10 · Agregado de cuota: usage_cycles debe cuadrar con la suma de usage_loc.
chequeo := 'V10_cuota_cuadra';
descripcion := 'Ciclos cuyo agregado no cuadra con la suma de usage_loc';
SELECT count(*) INTO problemas FROM (
    SELECT c.tenant_id, c.ciclo
      FROM core.usage_cycles c
      LEFT JOIN core.usage_loc l ON l.tenant_id = c.tenant_id AND l.ciclo = c.ciclo
     GROUP BY c.tenant_id, c.ciclo, c.loc_consumidas
    HAVING c.loc_consumidas <> coalesce(sum(greatest(l.netas,0)), 0)
) q;
RETURN NEXT;

-- V11 · Líneas: coherencia production_lines ⇄ jobs.
chequeo := 'V11_lineas_coherentes';
descripcion := 'Líneas ocupadas sin job activo o jobs con línea no reflejada';
SELECT count(*) INTO problemas FROM (
    SELECT pl.tenant_id, pl.numero
      FROM core.production_lines pl
      LEFT JOIN core.jobs j ON j.id = pl.job_id
             AND j.estado NOT IN ('produccion','cancelado','cerrado_duplicado')
     WHERE (pl.estado = 'ocupada') <> (j.id IS NOT NULL)
    UNION ALL
    SELECT j.tenant_id, j.linea
      FROM core.jobs j
      LEFT JOIN core.production_lines pl
             ON pl.tenant_id = j.tenant_id AND pl.numero = j.linea AND pl.job_id = j.id
     WHERE j.linea IS NOT NULL
       AND j.estado NOT IN ('produccion','cancelado','cerrado_duplicado')
       AND pl.job_id IS NULL
) q;
RETURN NEXT;

-- V12 · Líneas concurrentes dentro del plan (QU-2).
chequeo := 'V12_lineas_dentro_del_plan';
descripcion := 'Tenants con más jobs en línea que líneas de su plan';
SELECT count(*) INTO problemas FROM (
    SELECT j.tenant_id
      FROM core.jobs j
      JOIN core.subscriptions s ON s.tenant_id = j.tenant_id AND s.finaliza_el IS NULL
      JOIN core.plans p ON p.codigo = s.plan_codigo
     WHERE j.linea IS NOT NULL
       AND j.estado NOT IN ('produccion','cancelado','cerrado_duplicado')
     GROUP BY j.tenant_id, p.lineas
    HAVING p.lineas IS NOT NULL AND count(*) > p.lineas
) q;
RETURN NEXT;

-- V13 · Duplicados: cadena sin ciclos de un nivel y sin duplicado_de colgante.
chequeo := 'V13_duplicados_validos';
descripcion := 'Tickets duplicados que apuntan a otro duplicado (cadenas)';
SELECT count(*) INTO problemas
  FROM core.tickets t
  JOIN core.tickets d ON d.id = t.duplicado_de
 WHERE d.duplicado_de IS NOT NULL;
RETURN NEXT;

-- V14 · Embeddings huérfanos o faltantes (vec ⇄ core).
chequeo := 'V14_embeddings_tickets';
descripcion := 'Tickets activos (>1 h) sin embedding de deduplicación';
SELECT count(*) INTO problemas
  FROM core.tickets t
 WHERE t.etapa NOT IN ('cancelado','cerrado_duplicado')
   AND t.creado_en < now() - interval '1 hour'
   AND NOT EXISTS (SELECT 1 FROM vec.ticket_embeddings e WHERE e.ticket_id = t.id);
RETURN NEXT;

-- V15 · Dimensión de embeddings homogénea (1024).
chequeo := 'V15_dimension_embeddings';
descripcion := 'Embeddings con dimensión distinta de 1024';
SELECT (SELECT count(*) FROM vec.ticket_embeddings     WHERE vector_dims(embedding) <> 1024)
     + (SELECT count(*) FROM vec.doc_chunks            WHERE vector_dims(embedding) <> 1024)
     + (SELECT count(*) FROM vec.definition_embeddings WHERE vector_dims(embedding) <> 1024)
  INTO problemas;
RETURN NEXT;

-- V16 · Cadena de auditoría íntegra (recorre todos los tenants visibles):
--       sello propio, encadenamiento (sello_previo = sello del eslabón anterior)
--       y recuento contra chain_heads (KC-DB-05-1, DB-F04).
chequeo := 'V16_cadena_auditoria';
descripcion := 'Tenants con cadena de auditoría rota: sello alterado, eslabón perdido o eventos faltantes (ver audit.verify_chain)';
SELECT count(*) INTO problemas FROM (
    SELECT h.tenant_id
      FROM audit.chain_heads h,
           LATERAL audit.verify_chain(h.tenant_id) v
     WHERE NOT v.integra
) q;
RETURN NEXT;

-- V17 · Cabeza de cadena consistente con los eventos: mismo último sello y
--       mismo número de eventos (un hueco por borrado delata la diferencia),
--       y ningún tenant con eventos sin cabeza (KC-DB-05-1, DB-F04).
chequeo := 'V17_cabeza_cadena';
descripcion := 'chain_heads que no cuadra con los eventos: último sello distinto, eventos de menos o de más, o eventos sin cabeza';
SELECT count(*) INTO problemas FROM (
    SELECT h.tenant_id
      FROM audit.chain_heads h
      LEFT JOIN LATERAL (
          SELECT count(*) AS n,
                 (array_agg(e.sello ORDER BY e.id DESC))[1] AS ultimo
            FROM audit.audit_events e
           WHERE e.tenant_id = h.tenant_id) ev ON true
     WHERE ev.n <> h.eventos
        OR ev.ultimo IS DISTINCT FROM (CASE WHEN h.eventos > 0 THEN h.ultimo_sello END)
    UNION
    SELECT e.tenant_id
      FROM audit.audit_events e
     WHERE NOT EXISTS (SELECT 1 FROM audit.chain_heads h WHERE h.tenant_id = e.tenant_id)
) q;
RETURN NEXT;

-- V18 · Webhooks: fallidos estancados (>24 h sin reproceso).
chequeo := 'V18_webhooks_estancados';
descripcion := 'Entradas de webhook_inbox fallidas hace más de 24 h';
SELECT count(*) INTO problemas
  FROM core.webhook_inbox
 WHERE estado = 'fallido' AND recibido_en < now() - interval '24 hours';
RETURN NEXT;

-- V19 · Adjuntos huérfanos vencidos (>48 h sin asociar): candidatos a purga.
chequeo := 'V19_adjuntos_huerfanos';
descripcion := 'Adjuntos sin ticket asociado hace más de 48 h';
SELECT count(*) INTO problemas
  FROM core.ticket_attachments
 WHERE ticket_id IS NULL AND creado_en < now() - interval '48 hours';
RETURN NEXT;

-- V20 · Gates aprobados apuntando a specs de otro ticket.
chequeo := 'V20_gate_spec_coherente';
descripcion := 'Firmas de Gate 1 cuya spec no pertenece al mismo ticket';
SELECT count(*) INTO problemas
  FROM core.gate_signatures g
  JOIN core.specs s ON s.id = g.spec_id
 WHERE g.spec_id IS NOT NULL AND s.ticket_id <> g.ticket_id;
RETURN NEXT;


-- V21 · Coherencia de tenant padre/hijo (KC-DB-03-3, DB-F01). Las relaciones se
--       generan desde pg_constraint: ver core.incoherencias_tenant().
chequeo := 'V21_coherencia_tenant';
SELECT count(*),
       'Filas cuyo tenant no coincide con el de su padre'
       || coalesce(' en: ' || string_agg(DISTINCT relacion || ' (' || tabla_hija || ')', ', '), '')
  INTO problemas, descripcion
  FROM core.incoherencias_tenant();
RETURN NEXT;

END $$;

COMMENT ON FUNCTION core.validar_integridad() IS
'Batería de chequeos de integridad de negocio. Programar ejecución nocturna y
alertar si cualquier fila devuelve problemas > 0. Los chequeos V16/V17 verifican
la cadena de hashes de auditoría (sello, encadenamiento y recuento, KC-DB-05-1); V10/V12 la validación comercial; V21 la
coherencia de tenant entre padre e hijo (KC-DB-03-2 depende de que esté en 0).';


-- ================================================================
-- ARCHIVO: db/migrations/025_append_only_probatorias.sql
-- ================================================================
-- ============================================================================
-- KALLICODE · 025_append_only_probatorias.sql
-- KC-DB-05-2 — Append-only y congelación de las tablas probatorias.
--
-- 04_rls.sql:15 concede SELECT, INSERT, UPDATE y DELETE sobre las 36 tablas de
-- core al rol de la aplicación. La única congelación de contenido era
-- trg_specs_freeze (core.specs) y la única tabla append-only, audit.audit_events:
-- quedaban reescribibles y borrables la firma humana que autoriza el despliegue,
-- el registro de los pasos del LLM, las transiciones de los jobs, las corridas y
-- resultados de QA, los hallazgos de seguridad y el consumo de LOC.
--
--   * gate_signatures, llm_steps, job_transitions, qa_runs, qa_results y
--     usage_loc pasan a ser append-only: kallicode_app pierde UPDATE y DELETE y
--     un trigger lo impide también a nivel de motor (incluido un rol privilegiado).
--   * security_findings admite únicamente la transición de estado y de veredicto,
--     con justificación obligatoria; rechaza cambiar regla, archivo, línea,
--     severidad o título (y cualquier otro campo) y no se puede borrar.
--   * Una corrección se registra como fila de compensación: usage_loc con
--     tipo = 'ajuste' y una corrida de QA nueva (docs/append_only_probatorias.md).
--
-- Cascadas referenciales: borrar un ticket o un job sigue arrastrando a sus hijos
-- (ON DELETE CASCADE) y usage_loc.ticket_id sigue pasando a NULL (ON DELETE SET
-- NULL). Esas acciones las dispara el padre y se ejecutan a profundidad de trigger
-- mayor que 1; el trigger solo bloquea la mutación directa (profundidad 1). La
-- aplicación no borra tickets ni jobs (usa eliminado_en).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Permisos: la aplicación pierde la mutación.
-- ---------------------------------------------------------------------------
REVOKE UPDATE, DELETE ON
    core.gate_signatures, core.llm_steps, core.job_transitions,
    core.qa_runs, core.qa_results, core.usage_loc,
    core.security_findings
FROM kallicode_app;

-- security_findings: solo puede cambiar lo que una transición legítima toca.
GRANT UPDATE (estado, veredicto, justificacion, actualizado_en)
    ON core.security_findings TO kallicode_app;

-- ---------------------------------------------------------------------------
-- 2. Seis tablas append-only: ninguna mutación directa, tampoco para un rol
--    privilegiado (que tendría que desactivar el trigger a propósito).
-- ---------------------------------------------------------------------------
CREATE FUNCTION core.probatoria_append_only() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    -- Las acciones referenciales (CASCADE / SET NULL) las dispara el borrado del
    -- padre: su trigger de sistema es el nivel 1 y esta fila se mueve en el nivel 2.
    IF pg_trigger_depth() > 1 THEN
        RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    RAISE EXCEPTION '%.% es append-only: % prohibido; corrige con una fila de compensacion',
        TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP USING ERRCODE = 'raise_exception';
END $$;

CREATE TRIGGER trg_probatoria_append_only
    BEFORE UPDATE OR DELETE ON core.gate_signatures
    FOR EACH ROW EXECUTE FUNCTION core.probatoria_append_only();
CREATE TRIGGER trg_probatoria_append_only
    BEFORE UPDATE OR DELETE ON core.llm_steps
    FOR EACH ROW EXECUTE FUNCTION core.probatoria_append_only();
CREATE TRIGGER trg_probatoria_append_only
    BEFORE UPDATE OR DELETE ON core.job_transitions
    FOR EACH ROW EXECUTE FUNCTION core.probatoria_append_only();
CREATE TRIGGER trg_probatoria_append_only
    BEFORE UPDATE OR DELETE ON core.qa_runs
    FOR EACH ROW EXECUTE FUNCTION core.probatoria_append_only();
CREATE TRIGGER trg_probatoria_append_only
    BEFORE UPDATE OR DELETE ON core.qa_results
    FOR EACH ROW EXECUTE FUNCTION core.probatoria_append_only();
CREATE TRIGGER trg_probatoria_append_only
    BEFORE UPDATE OR DELETE ON core.usage_loc
    FOR EACH ROW EXECUTE FUNCTION core.probatoria_append_only();

-- ---------------------------------------------------------------------------
-- 3. security_findings: solo la transición de estado y de veredicto.
--    Inmutables: id, tenant_id, ticket_id, origen, regla, archivo, linea,
--    severidad, titulo, fix_diff_ref, bloquea y creado_en. Cambiar estado o
--    veredicto exige una justificación no vacía y distinta de la anterior.
--    (trg_security_findings_updated sigue fijando actualizado_en.)
-- ---------------------------------------------------------------------------
CREATE FUNCTION core.security_findings_transicion() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF pg_trigger_depth() > 1 THEN
            RETURN OLD;                               -- cascada desde el ticket
        END IF;
        RAISE EXCEPTION 'core.security_findings es append-only: DELETE prohibido'
            USING ERRCODE = 'raise_exception';
    END IF;

    IF NEW.id            IS DISTINCT FROM OLD.id
    OR NEW.tenant_id     IS DISTINCT FROM OLD.tenant_id
    OR NEW.ticket_id     IS DISTINCT FROM OLD.ticket_id
    OR NEW.origen        IS DISTINCT FROM OLD.origen
    OR NEW.regla         IS DISTINCT FROM OLD.regla
    OR NEW.archivo       IS DISTINCT FROM OLD.archivo
    OR NEW.linea         IS DISTINCT FROM OLD.linea
    OR NEW.severidad     IS DISTINCT FROM OLD.severidad
    OR NEW.titulo        IS DISTINCT FROM OLD.titulo
    OR NEW.fix_diff_ref  IS DISTINCT FROM OLD.fix_diff_ref
    OR NEW.bloquea       IS DISTINCT FROM OLD.bloquea
    OR NEW.creado_en     IS DISTINCT FROM OLD.creado_en THEN
        RAISE EXCEPTION
            'core.security_findings: solo se admite la transicion de estado y de veredicto'
            USING ERRCODE = 'raise_exception';
    END IF;

    IF NEW.estado IS DISTINCT FROM OLD.estado OR NEW.veredicto IS DISTINCT FROM OLD.veredicto THEN
        IF NEW.justificacion IS NULL OR btrim(NEW.justificacion) = '' THEN
            RAISE EXCEPTION
                'core.security_findings: la transicion de estado o veredicto exige justificacion'
                USING ERRCODE = 'raise_exception';
        END IF;
        IF OLD.justificacion IS NOT NULL AND NEW.justificacion = OLD.justificacion THEN
            RAISE EXCEPTION
                'core.security_findings: la justificacion debe explicar esta transicion, no repetir la anterior'
                USING ERRCODE = 'raise_exception';
        END IF;
    END IF;
    RETURN NEW;
END $$;

-- Se llama «a_» para ejecutarse antes que trg_security_findings_updated (orden alfabético).
CREATE TRIGGER trg_a_security_findings_transicion
    BEFORE UPDATE OR DELETE ON core.security_findings
    FOR EACH ROW EXECUTE FUNCTION core.security_findings_transicion();

COMMENT ON FUNCTION core.probatoria_append_only() IS
'KC-DB-05-2: tablas probatorias append-only (gate_signatures, llm_steps, job_transitions, qa_runs, qa_results, usage_loc). Bloquea UPDATE/DELETE directos; deja pasar las acciones referenciales del padre.';
COMMENT ON FUNCTION core.security_findings_transicion() IS
'KC-DB-05-2: security_findings solo admite la transicion de estado y de veredicto con justificacion; no se puede borrar directamente.';

-- ================================================================
-- ARCHIVO: db/migrations/026_ciclo_cuota_aniversario.sql
-- ================================================================
-- Migración 026: Ciclo de cuota por aniversario desde subscriptions (KC-DB-05-4)

SET lock_timeout = '5s';
SET statement_timeout = '30s';



CREATE OR REPLACE FUNCTION core.obtener_ciclo_cuota_actual(p_tenant_id text, p_fecha date DEFAULT CURRENT_DATE)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_inicia_el date;
    v_dia_aniv int;
    v_anio int;
    v_mes int;
    v_ultimo_dia_mes int;
    v_dia_objetivo int;
    v_ciclo_inicio date;
BEGIN
    -- 1. Buscar la suscripción vigente del tenant
    SELECT inicia_el INTO v_inicia_el
    FROM core.subscriptions
    WHERE tenant_id = p_tenant_id
      AND finaliza_el IS NULL
      AND estado IN ('activa', 'periodo_gracia')
    LIMIT 1;

    IF v_inicia_el IS NULL THEN
        RETURN to_char(p_fecha, 'YYYY-MM');
    END IF;

    v_dia_aniv := EXTRACT(DAY FROM v_inicia_el)::int;
    v_anio := EXTRACT(YEAR FROM p_fecha)::int;
    v_mes := EXTRACT(MONTH FROM p_fecha)::int;

    -- Determinar el último día del mes actual evaluado
    v_ultimo_dia_mes := EXTRACT(DAY FROM (make_date(v_anio, v_mes, 1) + INTERVAL '1 month - 1 day'))::int;
    v_dia_objetivo := LEAST(v_dia_aniv, v_ultimo_dia_mes);

    -- Si la fecha actual aún no alcanza el día objetivo en el mes corriente,
    -- el ciclo actual empezó en el mes anterior
    IF EXTRACT(DAY FROM p_fecha)::int < v_dia_objetivo THEN
        p_fecha := (p_fecha - INTERVAL '1 month')::date;
        v_anio := EXTRACT(YEAR FROM p_fecha)::int;
        v_mes := EXTRACT(MONTH FROM p_fecha)::int;
        
        v_ultimo_dia_mes := EXTRACT(DAY FROM (make_date(v_anio, v_mes, 1) + INTERVAL '1 month - 1 day'))::int;
        v_dia_objetivo := LEAST(v_dia_aniv, v_ultimo_dia_mes);
    END IF;

    v_ciclo_inicio := make_date(v_anio, v_mes, v_dia_objetivo);

    RETURN to_char(v_ciclo_inicio, 'YYYY-MM-DD');
END;
$$;

GRANT EXECUTE ON FUNCTION core.obtener_ciclo_cuota_actual(text, date) TO kallicode_app, kallicode_worker;


-- ================================================================
-- ARCHIVO: db/migrations/027_constraints_gates_findings.sql
-- ================================================================
-- Migración 027: Constraints en gate_signatures y security_findings (KC-DB-05-5)
-- Refuerza la integridad en firmas de compuertas y hallazgos de seguridad.

SET lock_timeout = '5s';
SET statement_timeout = '30s';



-- 1. Restricciones en core.gate_signatures
-- Si accion = 'cambios_pedidos', devolver_a y comentario son obligatorios.
-- Si accion = 'aprobado', devolver_a debe ser nulo.
ALTER TABLE core.gate_signatures
    ADD CONSTRAINT gs_accion_coherencia_chk
    CHECK (
        (accion = 'aprobado' AND devolver_a IS NULL)
        OR
        (accion = 'cambios_pedidos' AND devolver_a IS NOT NULL AND comentario IS NOT NULL AND length(trim(comentario)) > 0)
    );

-- Sello no puede ser una cadena vacía o solo espacios
ALTER TABLE core.gate_signatures
    ADD CONSTRAINT gs_sello_formato_chk
    CHECK (length(trim(sello)) > 0);

-- Comentario no puede ser una cadena de solo espacios
ALTER TABLE core.gate_signatures
    ADD CONSTRAINT gs_comentario_no_vacio_chk
    CHECK (comentario IS NULL OR length(trim(comentario)) > 0);


-- 2. Restricciones en core.security_findings
-- Línea de código positiva si existe
ALTER TABLE core.security_findings
    ADD CONSTRAINT sf_linea_pos_chk
    CHECK (linea IS NULL OR linea > 0);

-- Título no vacío
ALTER TABLE core.security_findings
    ADD CONSTRAINT sf_titulo_no_vacio_chk
    CHECK (length(trim(titulo)) > 0);


-- ================================================================
-- ARCHIVO: db/migrations/028_cuota_delta.sql
-- ================================================================
-- ============================================================================
-- KALLICODE · 028_cuota_delta.sql
-- KC-DB-05-3 (DB-F07, ALTO) — Trigger de cuota que respeta los ajustes
-- negativos y reacciona a UPDATE y DELETE.
--
-- core.accumulate_loc acumulaba greatest(NEW.netas, 0): un usage_loc de tipo
-- 'ajuste' con netas = -500 (un crédito comercial explícitamente permitido por
-- loc_netas_chk, que solo exige la aritmética cuando tipo = 'pr') se aceptaba en
-- la tabla y se descartaba en el agregado sin error ni aviso. Además
-- trg_usage_loc_acumula era AFTER INSERT únicamente: un UPDATE o un DELETE
-- desincronizaban usage_cycles para siempre, y V10 replicaba el mismo greatest(),
-- así que tampoco lo detectaba.
--
-- Corrección:
--   * El trigger pasa a AFTER INSERT OR UPDATE OF (tenant_id, ciclo, netas) OR
--     DELETE y aplica el delta de cada fila SIN greatest(): INSERT suma +netas,
--     DELETE resta netas y UPDATE aplica la diferencia (o mueve la fila de ciclo).
--   * El piso en cero se aplica solo al total acumulado del ciclo. Para que ese
--     piso no haga perder crédito (100 consumidas, ajuste -300 y luego +50 debe
--     dejar 0, no 50), usage_cycles guarda además la suma real de netas, que puede
--     ser negativa (loc_netas); loc_consumidas = greatest(loc_netas, 0).
--   * V10 compara contra la suma real de usage_loc y se agrega V22: ningún ciclo
--     puede tener loc_consumidas negativo.
--
-- Nota: el ticket nombra esta migración 015, pero 015 ya existe.
-- Nota: desde KC-DB-05-2 usage_loc es append-only; las reacciones a UPDATE y
--       DELETE solo se ejercitan en mantenimiento privilegiado (el trigger de
--       inmutabilidad desactivado a propósito) y en la cascada SET NULL del
--       ticket, que no cambia netas, tenant ni ciclo y por eso no dispara nada.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. usage_cycles guarda la suma real de netas del ciclo (puede ser negativa).
-- ---------------------------------------------------------------------------
ALTER TABLE core.usage_cycles ADD COLUMN loc_netas integer NOT NULL DEFAULT 0;

COMMENT ON COLUMN core.usage_cycles.loc_netas IS
'KC-DB-05-3: suma real de usage_loc.netas del ciclo (un crédito mayor que lo consumido la deja negativa). loc_consumidas = greatest(loc_netas, 0).';

-- ---------------------------------------------------------------------------
-- 2. Umbral del ciclo según el límite del plan vigente (lógica de T6 sin cambios).
-- ---------------------------------------------------------------------------
CREATE FUNCTION core.umbral_cuota(p_tenant text, p_consumidas integer) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
    lim integer;
BEGIN
    SELECT p.loc_mes INTO lim
      FROM core.subscriptions s JOIN core.plans p ON p.codigo = s.plan_codigo
     WHERE s.tenant_id = p_tenant AND s.finaliza_el IS NULL;

    IF lim IS NULL THEN
        RETURN 'normal';                                 -- Enterprise: sin límite
    ELSIF p_consumidas >= lim THEN
        RETURN 'agotado';
    ELSIF p_consumidas >= lim * 0.8 THEN
        RETURN 'aviso_80';
    END IF;
    RETURN 'normal';
END $$;

-- ---------------------------------------------------------------------------
-- 3. Aplica un delta al ciclo en una sola sentencia (el UPSERT bloquea la fila:
--    dos cambios simultáneos del mismo ciclo se serializan). p_crear = false
--    para las salidas (DELETE, o el ciclo viejo de un UPDATE): si el ciclo no
--    existe no hay nada que ajustar y no se crea una fila nueva.
-- ---------------------------------------------------------------------------
CREATE FUNCTION core.aplicar_delta_loc(p_tenant text, p_ciclo text, p_delta integer,
                                       p_crear boolean DEFAULT true) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF p_crear THEN
        INSERT INTO core.usage_cycles (tenant_id, ciclo, loc_netas, loc_consumidas, umbral)
        VALUES (p_tenant, p_ciclo, p_delta, greatest(p_delta, 0),
                core.umbral_cuota(p_tenant, greatest(p_delta, 0)))
        ON CONFLICT (tenant_id, ciclo) DO UPDATE
           SET loc_netas      = core.usage_cycles.loc_netas + p_delta,
               loc_consumidas = greatest(core.usage_cycles.loc_netas + p_delta, 0),
               umbral         = core.umbral_cuota(
                                    p_tenant, greatest(core.usage_cycles.loc_netas + p_delta, 0)),
               actualizado_en = now();
    ELSE
        UPDATE core.usage_cycles
           SET loc_netas      = loc_netas + p_delta,
               loc_consumidas = greatest(loc_netas + p_delta, 0),
               umbral         = core.umbral_cuota(p_tenant, greatest(loc_netas + p_delta, 0)),
               actualizado_en = now()
         WHERE tenant_id = p_tenant AND ciclo = p_ciclo;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 4. El trigger de acumulación: INSERT, UPDATE y DELETE, sin greatest() por fila.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.accumulate_loc() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        PERFORM core.aplicar_delta_loc(NEW.tenant_id, NEW.ciclo, NEW.netas);
    ELSIF TG_OP = 'DELETE' THEN
        PERFORM core.aplicar_delta_loc(OLD.tenant_id, OLD.ciclo, -OLD.netas, false);
    ELSIF NEW.tenant_id = OLD.tenant_id AND NEW.ciclo = OLD.ciclo THEN
        IF NEW.netas <> OLD.netas THEN
            PERFORM core.aplicar_delta_loc(NEW.tenant_id, NEW.ciclo, NEW.netas - OLD.netas);
        END IF;
    ELSE
        -- La fila cambió de ciclo (o de tenant): sale del viejo y entra al nuevo.
        PERFORM core.aplicar_delta_loc(OLD.tenant_id, OLD.ciclo, -OLD.netas, false);
        PERFORM core.aplicar_delta_loc(NEW.tenant_id, NEW.ciclo, NEW.netas);
    END IF;
    RETURN NULL;                                         -- trigger AFTER: se ignora
END $$;

DROP TRIGGER trg_usage_loc_acumula ON core.usage_loc;
CREATE TRIGGER trg_usage_loc_acumula
    AFTER INSERT OR UPDATE OF tenant_id, ciclo, netas OR DELETE ON core.usage_loc
    FOR EACH ROW EXECUTE FUNCTION core.accumulate_loc();

-- ---------------------------------------------------------------------------
-- 5. Reparar lo ya acumulado: los ciclos que descartaron ajustes negativos (o que
--    cambiaron por UPDATE/DELETE) se recalculan desde usage_loc. Corre como
--    kallicode_admin (BYPASSRLS), sobre todos los tenants.
-- ---------------------------------------------------------------------------
UPDATE core.usage_cycles c
   SET loc_netas      = s.neto,
       loc_consumidas = greatest(s.neto, 0),
       umbral         = core.umbral_cuota(c.tenant_id, greatest(s.neto, 0)),
       actualizado_en = now()
  FROM (SELECT c2.tenant_id, c2.ciclo, coalesce(sum(l.netas), 0)::integer AS neto
          FROM core.usage_cycles c2
          LEFT JOIN core.usage_loc l ON l.tenant_id = c2.tenant_id AND l.ciclo = c2.ciclo
         GROUP BY c2.tenant_id, c2.ciclo) s
 WHERE c.tenant_id = s.tenant_id AND c.ciclo = s.ciclo
   AND (c.loc_netas <> s.neto OR c.loc_consumidas <> greatest(s.neto, 0));

-- ---------------------------------------------------------------------------
-- 6. validar_integridad(): V01-V21 idénticos a 024_cadena_auditoria.sql salvo V10,
--    que compara contra la suma real de usage_loc, y el chequeo nuevo V22.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.validar_integridad()
RETURNS TABLE (chequeo text, descripcion text, problemas bigint)
LANGUAGE plpgsql STABLE AS $$
BEGIN

-- V01 · Suscripción vigente: todo tenant activo debe tener exactamente una.
chequeo := 'V01_suscripcion_vigente';
descripcion := 'Tenants sin suscripción vigente (o con más de una)';
SELECT count(*) INTO problemas FROM (
    SELECT o.id
      FROM core.organizations o
      LEFT JOIN core.subscriptions s
             ON s.tenant_id = o.id AND s.finaliza_el IS NULL
     WHERE o.eliminado_en IS NULL
     GROUP BY o.id
    HAVING count(s.id) <> 1
) q;
RETURN NEXT;

-- V02 · Ticket ⇄ job: la etapa visible del ticket debe corresponder al job activo.
chequeo := 'V02_espejo_ticket_job';
descripcion := 'Tickets activos cuya etapa no corresponde al estado de su job';
SELECT count(*) INTO problemas
  FROM core.tickets t
  JOIN core.jobs j ON j.ticket_id = t.id
             AND j.estado NOT IN ('produccion','cancelado','cerrado_duplicado')
 WHERE t.etapa <> CASE j.estado
        WHEN 'gate1' THEN 'design'
        WHEN 'gate2' THEN 'qa'
        WHEN 'gate3' THEN 'deploy'
        WHEN 'deploy_preflight' THEN 'deploy'
        WHEN 'pendiente_asignacion' THEN 'triage'
        WHEN 'pausado_por_cuota' THEN 'en_cola_por_cuota'
        WHEN 'escalado_humano' THEN t.etapa
        ELSE j.estado END;
RETURN NEXT;

-- V03 · Gate 3 sin gates 1 y 2 (el trigger lo impide; verificación de defensa).
chequeo := 'V03_gate3_sin_previos';
descripcion := 'Aprobaciones de Gate 3 sin aprobación previa de gates 1 y 2';
SELECT count(*) INTO problemas
  FROM core.gate_signatures g3
 WHERE g3.gate = 3 AND g3.accion = 'aprobado'
   AND 2 > (SELECT count(DISTINCT g.gate) FROM core.gate_signatures g
             WHERE g.ticket_id = g3.ticket_id
               AND g.gate IN (1,2) AND g.accion = 'aprobado'
               AND g.creado_en <= g3.creado_en);
RETURN NEXT;

-- V04 · Tickets en producción con las tres firmas.
chequeo := 'V04_produccion_sin_firmas';
descripcion := 'Tickets en producción sin las tres firmas de gates';
SELECT count(*) INTO problemas
  FROM core.tickets t
 WHERE t.etapa = 'produccion'
   AND 3 > (SELECT count(DISTINCT gate) FROM core.gate_signatures
             WHERE ticket_id = t.id AND accion = 'aprobado');
RETURN NEXT;

-- V05 · Specs: exactamente una alternativa recomendada por versión.
chequeo := 'V05_spec_recomendada';
descripcion := 'Specs sin exactamente una alternativa recomendada';
SELECT count(*) INTO problemas FROM (
    SELECT s.id FROM core.specs s
      LEFT JOIN core.spec_alternatives a ON a.spec_id = s.id AND a.recomendada
     GROUP BY s.id HAVING count(a.alt_id) <> 1
) q;
RETURN NEXT;

-- V06 · Specs aprobadas con alternativa elegida.
chequeo := 'V06_spec_aprobada_sin_eleccion';
descripcion := 'Specs aprobadas (Gate 1) sin alternativa elegida';
SELECT count(*) INTO problemas FROM (
    SELECT s.id FROM core.specs s
     WHERE s.estado = 'aprobada'
       AND NOT EXISTS (SELECT 1 FROM core.spec_alternatives a
                        WHERE a.spec_id = s.id AND a.elegida)
       AND EXISTS (SELECT 1 FROM core.spec_alternatives a WHERE a.spec_id = s.id)
) q;
RETURN NEXT;

-- V07 · Matriz de QA completa: cada corrida cubre todos los criterios de su spec.
chequeo := 'V07_matriz_qa_completa';
descripcion := 'Corridas de QA que no cubren todos los criterios de la spec';
SELECT count(*) INTO problemas FROM (
    SELECT r.id
      FROM core.qa_runs r
      JOIN core.spec_criteria c ON c.spec_id = r.spec_id
      LEFT JOIN core.qa_results q ON q.qa_run_id = r.id AND q.criterio_id = c.criterio_id
     GROUP BY r.id
    HAVING count(c.criterio_id) <> count(q.criterio_id)
) q;
RETURN NEXT;

-- V08 · Resultados de QA que referencian criterios inexistentes en la spec.
chequeo := 'V08_qa_criterio_fantasma';
descripcion := 'Resultados de QA con criterio_id que no existe en la spec de la corrida';
SELECT count(*) INTO problemas
  FROM core.qa_results q
  JOIN core.qa_runs r ON r.id = q.qa_run_id
 WHERE NOT EXISTS (SELECT 1 FROM core.spec_criteria c
                    WHERE c.spec_id = r.spec_id AND c.criterio_id = q.criterio_id);
RETURN NEXT;

-- V09 · Deploy bloqueado: tickets en produccion con hallazgos bloqueantes abiertos.
chequeo := 'V09_produccion_con_bloqueantes';
descripcion := 'Tickets en producción con hallazgos de seguridad bloqueantes abiertos';
SELECT count(*) INTO problemas
  FROM core.tickets t
 WHERE t.etapa = 'produccion'
   AND EXISTS (SELECT 1 FROM core.security_findings f
                WHERE f.ticket_id = t.id AND f.bloquea AND f.estado = 'abierto');
RETURN NEXT;

-- V10 · Agregado de cuota: usage_cycles debe cuadrar con la suma real de usage_loc.
--       La suma real puede ser negativa (créditos mayores que lo consumido);
--       el piso en cero se aplica solo al total del ciclo (KC-DB-05-3, DB-F07).
chequeo := 'V10_cuota_cuadra';
descripcion := 'Ciclos cuyo agregado no cuadra con la suma de usage_loc (netas reales, piso en cero solo en el total)';
SELECT count(*) INTO problemas FROM (
    SELECT c.tenant_id, c.ciclo
      FROM core.usage_cycles c
      LEFT JOIN core.usage_loc l ON l.tenant_id = c.tenant_id AND l.ciclo = c.ciclo
     GROUP BY c.tenant_id, c.ciclo, c.loc_netas, c.loc_consumidas
    HAVING c.loc_netas <> coalesce(sum(l.netas), 0)
        OR c.loc_consumidas <> greatest(coalesce(sum(l.netas), 0), 0)
) q;
RETURN NEXT;

-- V11 · Líneas: coherencia production_lines ⇄ jobs.
chequeo := 'V11_lineas_coherentes';
descripcion := 'Líneas ocupadas sin job activo o jobs con línea no reflejada';
SELECT count(*) INTO problemas FROM (
    SELECT pl.tenant_id, pl.numero
      FROM core.production_lines pl
      LEFT JOIN core.jobs j ON j.id = pl.job_id
             AND j.estado NOT IN ('produccion','cancelado','cerrado_duplicado')
     WHERE (pl.estado = 'ocupada') <> (j.id IS NOT NULL)
    UNION ALL
    SELECT j.tenant_id, j.linea
      FROM core.jobs j
      LEFT JOIN core.production_lines pl
             ON pl.tenant_id = j.tenant_id AND pl.numero = j.linea AND pl.job_id = j.id
     WHERE j.linea IS NOT NULL
       AND j.estado NOT IN ('produccion','cancelado','cerrado_duplicado')
       AND pl.job_id IS NULL
) q;
RETURN NEXT;

-- V12 · Líneas concurrentes dentro del plan (QU-2).
chequeo := 'V12_lineas_dentro_del_plan';
descripcion := 'Tenants con más jobs en línea que líneas de su plan';
SELECT count(*) INTO problemas FROM (
    SELECT j.tenant_id
      FROM core.jobs j
      JOIN core.subscriptions s ON s.tenant_id = j.tenant_id AND s.finaliza_el IS NULL
      JOIN core.plans p ON p.codigo = s.plan_codigo
     WHERE j.linea IS NOT NULL
       AND j.estado NOT IN ('produccion','cancelado','cerrado_duplicado')
     GROUP BY j.tenant_id, p.lineas
    HAVING p.lineas IS NOT NULL AND count(*) > p.lineas
) q;
RETURN NEXT;

-- V13 · Duplicados: cadena sin ciclos de un nivel y sin duplicado_de colgante.
chequeo := 'V13_duplicados_validos';
descripcion := 'Tickets duplicados que apuntan a otro duplicado (cadenas)';
SELECT count(*) INTO problemas
  FROM core.tickets t
  JOIN core.tickets d ON d.id = t.duplicado_de
 WHERE d.duplicado_de IS NOT NULL;
RETURN NEXT;

-- V14 · Embeddings huérfanos o faltantes (vec ⇄ core).
chequeo := 'V14_embeddings_tickets';
descripcion := 'Tickets activos (>1 h) sin embedding de deduplicación';
SELECT count(*) INTO problemas
  FROM core.tickets t
 WHERE t.etapa NOT IN ('cancelado','cerrado_duplicado')
   AND t.creado_en < now() - interval '1 hour'
   AND NOT EXISTS (SELECT 1 FROM vec.ticket_embeddings e WHERE e.ticket_id = t.id);
RETURN NEXT;

-- V15 · Dimensión de embeddings homogénea (1024).
chequeo := 'V15_dimension_embeddings';
descripcion := 'Embeddings con dimensión distinta de 1024';
SELECT (SELECT count(*) FROM vec.ticket_embeddings     WHERE vector_dims(embedding) <> 1024)
     + (SELECT count(*) FROM vec.doc_chunks            WHERE vector_dims(embedding) <> 1024)
     + (SELECT count(*) FROM vec.definition_embeddings WHERE vector_dims(embedding) <> 1024)
  INTO problemas;
RETURN NEXT;

-- V16 · Cadena de auditoría íntegra (recorre todos los tenants visibles):
--       sello propio, encadenamiento (sello_previo = sello del eslabón anterior)
--       y recuento contra chain_heads (KC-DB-05-1, DB-F04).
chequeo := 'V16_cadena_auditoria';
descripcion := 'Tenants con cadena de auditoría rota: sello alterado, eslabón perdido o eventos faltantes (ver audit.verify_chain)';
SELECT count(*) INTO problemas FROM (
    SELECT h.tenant_id
      FROM audit.chain_heads h,
           LATERAL audit.verify_chain(h.tenant_id) v
     WHERE NOT v.integra
) q;
RETURN NEXT;

-- V17 · Cabeza de cadena consistente con los eventos: mismo último sello y
--       mismo número de eventos (un hueco por borrado delata la diferencia),
--       y ningún tenant con eventos sin cabeza (KC-DB-05-1, DB-F04).
chequeo := 'V17_cabeza_cadena';
descripcion := 'chain_heads que no cuadra con los eventos: último sello distinto, eventos de menos o de más, o eventos sin cabeza';
SELECT count(*) INTO problemas FROM (
    SELECT h.tenant_id
      FROM audit.chain_heads h
      LEFT JOIN LATERAL (
          SELECT count(*) AS n,
                 (array_agg(e.sello ORDER BY e.id DESC))[1] AS ultimo
            FROM audit.audit_events e
           WHERE e.tenant_id = h.tenant_id) ev ON true
     WHERE ev.n <> h.eventos
        OR ev.ultimo IS DISTINCT FROM (CASE WHEN h.eventos > 0 THEN h.ultimo_sello END)
    UNION
    SELECT e.tenant_id
      FROM audit.audit_events e
     WHERE NOT EXISTS (SELECT 1 FROM audit.chain_heads h WHERE h.tenant_id = e.tenant_id)
) q;
RETURN NEXT;

-- V18 · Webhooks: fallidos estancados (>24 h sin reproceso).
chequeo := 'V18_webhooks_estancados';
descripcion := 'Entradas de webhook_inbox fallidas hace más de 24 h';
SELECT count(*) INTO problemas
  FROM core.webhook_inbox
 WHERE estado = 'fallido' AND recibido_en < now() - interval '24 hours';
RETURN NEXT;

-- V19 · Adjuntos huérfanos vencidos (>48 h sin asociar): candidatos a purga.
chequeo := 'V19_adjuntos_huerfanos';
descripcion := 'Adjuntos sin ticket asociado hace más de 48 h';
SELECT count(*) INTO problemas
  FROM core.ticket_attachments
 WHERE ticket_id IS NULL AND creado_en < now() - interval '48 hours';
RETURN NEXT;

-- V20 · Gates aprobados apuntando a specs de otro ticket.
chequeo := 'V20_gate_spec_coherente';
descripcion := 'Firmas de Gate 1 cuya spec no pertenece al mismo ticket';
SELECT count(*) INTO problemas
  FROM core.gate_signatures g
  JOIN core.specs s ON s.id = g.spec_id
 WHERE g.spec_id IS NOT NULL AND s.ticket_id <> g.ticket_id;
RETURN NEXT;


-- V21 · Coherencia de tenant padre/hijo (KC-DB-03-3, DB-F01). Las relaciones se
--       generan desde pg_constraint: ver core.incoherencias_tenant().
chequeo := 'V21_coherencia_tenant';
SELECT count(*),
       'Filas cuyo tenant no coincide con el de su padre'
       || coalesce(' en: ' || string_agg(DISTINCT relacion || ' (' || tabla_hija || ')', ', '), '')
  INTO problemas, descripcion
  FROM core.incoherencias_tenant();
RETURN NEXT;

-- V22 · Ningún ciclo de cuota puede tener loc_consumidas negativo (KC-DB-05-3, DB-F07).
chequeo := 'V22_consumo_no_negativo';
descripcion := 'Ciclos de cuota con loc_consumidas negativo';
SELECT count(*) INTO problemas FROM core.usage_cycles WHERE loc_consumidas < 0;
RETURN NEXT;

END $$;

COMMENT ON FUNCTION core.validar_integridad() IS
'Batería de chequeos de integridad de negocio. Programar ejecución nocturna y
alertar si cualquier fila devuelve problemas > 0. Los chequeos V16/V17 verifican
la cadena de hashes de auditoría (sello, encadenamiento y recuento, KC-DB-05-1); V10/V12 la validación comercial (V10 contra la suma real de usage_loc, V22 sin consumo negativo, KC-DB-05-3); V21 la
coherencia de tenant entre padre e hijo (KC-DB-03-2 depende de que esté en 0).';


-- ================================================================
-- ARCHIVO: db/migrations/029_audit_events_procedencia.sql
-- ================================================================
-- ============================================================================
-- KALLICODE · 029_audit_events_procedencia.sql
-- KC-DB-05-6 — Procedencia de la acción en los eventos de auditoría.
--
-- audit.audit_events guardaba qué se hizo y quién lo firmó, pero no desde dónde ni
-- en qué petición, mientras core.refresh_tokens sí guarda ip inet y user_agent text.
-- Se añaden ip inet, user_agent text y request_id text, y el trigger de sellado
-- (T3, audit.seal_event) los incorpora al canónico bajo una columna version_sello
-- que identifica el formato, para no invalidar la cadena existente:
--
--   version_sello = 1  canónico original: sin los tres campos nuevos.
--   version_sello = 2  canónico con ip, user_agent y request_id.
--
-- Los eventos ya existentes quedan en versión 1 (DEFAULT 1) y siguen verificando con
-- su fórmula original; todo evento nuevo lo fija el trigger en versión 2 (la
-- aplicación no puede elegir la versión).
--
-- El canónico vive en UNA sola función, audit.calcular_sello(), que usan tanto
-- audit.seal_event como audit.verify_chain: si el formato cambiara en una y no en
-- la otra, toda la cadena parecería manipulada.
--
-- Esta migración también sanea las bases donde se aplicó una versión anterior no
-- mergeada de este ticket (028_audit_events_network_context.sql), que había dejado
-- request_id como uuid y reemplazado seal_event por otra basada en digest() de
-- pgcrypto, extensión que el proyecto no instala.
--
-- Nota: el ticket se desarrolló como 028; esa numeración la ocupa 028_cuota_delta.sql.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Columnas. IF NOT EXISTS y la conversión de uuid a text hacen que la migración
--    sea válida tanto en una base nueva como en una que aplicó la versión anterior.
-- ---------------------------------------------------------------------------
ALTER TABLE audit.audit_events ADD COLUMN IF NOT EXISTS ip           inet;
ALTER TABLE audit.audit_events ADD COLUMN IF NOT EXISTS user_agent   text;
ALTER TABLE audit.audit_events ADD COLUMN IF NOT EXISTS request_id   text;
ALTER TABLE audit.audit_events ADD COLUMN IF NOT EXISTS version_sello smallint NOT NULL DEFAULT 1;

DO $$
BEGIN
    IF (SELECT data_type FROM information_schema.columns
         WHERE table_schema = 'audit' AND table_name = 'audit_events'
           AND column_name = 'request_id') = 'uuid' THEN
        ALTER TABLE audit.audit_events ALTER COLUMN request_id TYPE text USING request_id::text;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'audit.audit_events'::regclass
                      AND conname = 'ae_version_sello_chk') THEN
        ALTER TABLE audit.audit_events
            ADD CONSTRAINT ae_version_sello_chk CHECK (version_sello IN (1, 2)) NOT VALID;
    END IF;
END $$;

ALTER TABLE audit.audit_events VALIDATE CONSTRAINT ae_version_sello_chk;

COMMENT ON COLUMN audit.audit_events.ip IS
'KC-DB-05-6: dirección de origen de la solicitud que originó el evento. Sellada desde la versión 2.';
COMMENT ON COLUMN audit.audit_events.user_agent IS
'KC-DB-05-6: cabecera User-Agent del cliente HTTP. Sellada desde la versión 2.';
COMMENT ON COLUMN audit.audit_events.request_id IS
'KC-DB-05-6: identificador de correlación de la solicitud (texto libre, p. ej. un UUID). Sellado desde la versión 2.';
COMMENT ON COLUMN audit.audit_events.version_sello IS
'KC-DB-05-6: formato del canónico del sello. 1 = original (sin ip/user_agent/request_id); 2 = con ellos. Lo fija el trigger de sellado.';

-- ---------------------------------------------------------------------------
-- 2. Canónico del sello, en un solo lugar. La versión 1 es EXACTAMENTE la fórmula
--    original de seal_event (db/03_triggers.sql): no debe cambiar nunca. La versión 2
--    agrega ip, user_agent y request_id separados por chr(31) (separador de unidad)
--    para que un valor no pueda «prestar» caracteres al vecino.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.calcular_sello(e audit.audit_events) RETURNS text
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
    SELECT encode(sha256(convert_to(
        CASE e.version_sello
            WHEN 1 THEN
                e.sello_previo || e.tenant_id || e.evento || e.resumen
                || coalesce(e.datos::text, '') || coalesce(e.ticket_id, '')
                || coalesce(e.actor_id, '')
                || to_char(e.creado_en, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
            ELSE
                e.sello_previo || e.tenant_id || e.evento || e.resumen
                || coalesce(e.datos::text, '') || coalesce(e.ticket_id, '')
                || coalesce(e.actor_id, '')
                || chr(31) || coalesce(abbrev(e.ip), '')
                || chr(31) || coalesce(e.user_agent, '')
                || chr(31) || coalesce(e.request_id, '')
                || chr(31)
                || to_char(e.creado_en, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
        END,
        'UTF8')), 'hex')
$$;

COMMENT ON FUNCTION audit.calcular_sello(audit.audit_events) IS
'KC-DB-05-6: canónico del sello según e.version_sello. Usada por seal_event y verify_chain; el formato de la versión 1 es inmutable.';

-- ---------------------------------------------------------------------------
-- 3. audit.seal_event (versión de KC-DB-05-1, 024_cadena_auditoria.sql): el único
--    cambio es que fija version_sello = 2 y calcula el sello con calcular_sello().
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.seal_event() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE prev text;
BEGIN
    -- La función corre con privilegios de su dueño: no puede sellar eventos de
    -- otro tenant aunque el INSERT lo pida (la política RLS lo rechazaría, pero
    -- solo después de haber tocado la cabeza ajena).
    IF coalesce(core.current_tenant(), '') <> ''
       AND NEW.tenant_id <> core.current_tenant() THEN
        RAISE EXCEPTION 'audit.seal_event: el evento es de otro tenant (%)', NEW.tenant_id
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    INSERT INTO audit.chain_heads (tenant_id) VALUES (NEW.tenant_id)
        ON CONFLICT (tenant_id) DO NOTHING;
    -- Bloquea la cabeza de cadena del tenant hasta el COMMIT:
    SELECT ultimo_sello INTO prev
      FROM audit.chain_heads WHERE tenant_id = NEW.tenant_id FOR UPDATE;

    NEW.sello_previo := prev;
    NEW.creado_en    := now();
    NEW.version_sello := 2;           -- la aplicación no elige el formato
    NEW.sello := audit.calcular_sello(NEW);

    UPDATE audit.chain_heads
       SET eventos = eventos + 1, ultimo_sello = NEW.sello
     WHERE tenant_id = NEW.tenant_id;
    RETURN NEW;
END $$;

-- ---------------------------------------------------------------------------
-- 4. audit.verify_chain (versión de KC-DB-05-1): el único cambio es que recalcula el
--    sello con calcular_sello(), que respeta la versión de cada evento.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.verify_chain(p_tenant text,
                                   p_desde timestamptz DEFAULT NULL,
                                   p_hasta timestamptz DEFAULT NULL)
RETURNS TABLE (integra boolean,
               eventos_verificados bigint,
               primer_evento_roto bigint,
               eventos_esperados bigint,
               eventos_observados bigint)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    genesis constant text := repeat('0', 64);
    sin_ventana boolean := (p_desde IS NULL AND p_hasta IS NULL);
    n bigint;
    roto bigint;
BEGIN
    WITH ev AS (
        SELECT e.id,
               audit.calcular_sello(e) <> e.sello AS sello_malo,
               (e.sello_previo <> genesis AND NOT EXISTS (
                   SELECT 1 FROM audit.audit_events p
                    WHERE p.tenant_id = e.tenant_id AND p.sello = e.sello_previo
               )) AS eslabon_perdido,
               (count(*) OVER (PARTITION BY e.sello_previo) > 1) AS bifurcado
          FROM audit.audit_events e
         WHERE e.tenant_id = p_tenant
           AND (p_desde IS NULL OR e.creado_en >= p_desde)
           AND (p_hasta IS NULL OR e.creado_en <= p_hasta)
    )
    SELECT count(*), min(id) FILTER (WHERE sello_malo OR eslabon_perdido OR bifurcado)
      INTO n, roto
      FROM ev;

    eventos_verificados := n;
    eventos_observados  := n;
    primer_evento_roto  := roto;
    eventos_esperados   := NULL;
    IF sin_ventana THEN
        SELECT h.eventos INTO eventos_esperados
          FROM audit.chain_heads h WHERE h.tenant_id = p_tenant;
    END IF;

    integra := roto IS NULL
               AND (eventos_esperados IS NULL OR eventos_esperados = n);
    RETURN NEXT;
END $$;

-- ================================================================
-- ARCHIVO: db/migrations/030_audit_events_request_id.sql
-- ================================================================
-- kc:sin-transaccion
-- ============================================================================
-- KALLICODE · 030_audit_events_request_id.sql
-- KC-DB-05-6 — Procedencia de la acción en los eventos de auditoría (DB-F19).
--
-- 1. Índice (tenant_id, request_id) para correlacionar un evento de auditoría con
--    la traza del log central a partir del identificador de la solicitud. Es
--    parcial (solo filas con request_id): los eventos sin él no se buscan por ahí.
--    Se crea CONCURRENTLY para no bloquear las escrituras de auditoría; por eso
--    este archivo va sin transacción (cada sentencia es re-ejecutable).
-- 2. audit.eventos_sin_request_id(): cuenta, por tenant, los eventos posteriores a
--    la migración 029 (los de version_sello >= 2) que no traen request_id. Es una
--    función de consulta y NO un chequeo de core.validar_integridad(): esa batería
--    alerta con cualquier problema > 0 (apps/workers housekeeping) y, mientras la
--    API no propague el request_id, todos los eventos nuevos lo traerían vacío.
-- ============================================================================

CREATE INDEX CONCURRENTLY IF NOT EXISTS audit_events_request_id_ix
    ON audit.audit_events (tenant_id, request_id)
    WHERE request_id IS NOT NULL;

CREATE OR REPLACE FUNCTION audit.eventos_sin_request_id(p_desde timestamptz DEFAULT NULL)
RETURNS TABLE (tenant_id text, eventos_posteriores bigint, sin_request_id bigint)
LANGUAGE sql STABLE AS $$
    SELECT e.tenant_id,
           count(*),
           count(*) FILTER (WHERE e.request_id IS NULL)
      FROM audit.audit_events e
     WHERE e.version_sello >= 2
       AND (p_desde IS NULL OR e.creado_en >= p_desde)
     GROUP BY e.tenant_id
     ORDER BY e.tenant_id
$$;

COMMENT ON FUNCTION audit.eventos_sin_request_id(timestamptz) IS
'KC-DB-05-6: por tenant, eventos posteriores a la migración 029 (version_sello >= 2) y cuántos no traen request_id. Con RLS, un tenant solo ve el suyo.';

-- ================================================================
-- ARCHIVO: db/migrations/031_optimizacion_consultas_grafo.sql
-- ================================================================
-- kc:sin-transaccion
-- Migración 031: Optimización de consultas recurrentes sobre el grafo (KC-DB-06-3)
-- Índices tenant-first y cubrientes para cm.repo_snapshots, cm.symbols y cm.files.

-- 1. Búsqueda de snapshots por commit y estado con orden temporal
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_repo_snapshots_tenant_commit_estado
    ON cm.repo_snapshots (tenant_id, commit_sha, estado, iniciado_en DESC);

-- 2. Búsqueda directa del último snapshot completo (Index-Only Scan)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_repo_snapshots_ultimo_completo
    ON cm.repo_snapshots (tenant_id, finalizado_en DESC NULLS LAST, iniciado_en DESC)
    INCLUDE (commit_sha)
    WHERE estado = 'completo';

-- 3. JOIN y filtrado recurrente de símbolos por archivo
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_symbols_tenant_file_id
    ON cm.symbols (tenant_id, file_id)
    INCLUDE (id, kind, name);

-- 4. Reconciliación rápida de hashes de archivos sin tocar heap
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_files_tenant_path_sha
    ON cm.files (tenant_id, path)
    INCLUDE (sha256, id);
-- ================================================================
-- ARCHIVO: db/migrations/032_indices_tenant_first.sql
-- ================================================================
-- kc:sin-transaccion
-- ============================================================================
-- KALLICODE · 032_indices_tenant_first.sql
-- KC-DB-06-2 (DB-F26) — Convención tenant-first aplicada a los índices que la incumplen.
--
-- db/02_indexes.sql declaraba «todo índice multi-tenant comienza por tenant_id», para que el
-- filtro implícito de RLS (tenant_id = core.current_tenant()) sea barato: con tenant_id como
-- primera columna el planificador lo resuelve DENTRO del índice. Un índice que no empieza por
-- tenant_id obliga a filtrar por la política DESPUÉS de la búsqueda.
--
-- Esta migración reescribe los 17 índices de acceso que la incumplían y que admiten la
-- convención (los demás son excepciones documentadas en docs/plan-indices.md):
--
--   * 11 se reescriben con tenant_id como primera columna, conservando el resto del orden.
--   * 6 ya tienen un equivalente tenant-first (los índices de FK de la migración 018, con las
--     mismas columnas): reescribirlos produciría un duplicado, así que solo se retiran.
--
-- Sin ventana sin índice: primero se crean (CONCURRENTLY) todos los nuevos y solo después se
-- retiran (CONCURRENTLY) los viejos. Por eso el archivo va sin transacción; cada sentencia es
-- re-ejecutable (IF NOT EXISTS / IF EXISTS).
--
-- Si un CREATE INDEX CONCURRENTLY falla a mitad deja un índice INVÁLIDO con ese nombre y el
-- IF NOT EXISTS de una nueva ejecución lo daría por bueno: antes de reintentar hay que borrarlo
-- (DROP INDEX CONCURRENTLY <nombre>). test_convencion_indices.py comprueba que no queden índices
-- inválidos.
--
-- Nota: el ticket nombra esta migración 019, pero 019 ya existe.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Índices nuevos, tenant-first.
-- ---------------------------------------------------------------------------
CREATE INDEX CONCURRENTLY IF NOT EXISTS gates_tenant_ticket_ix
    ON core.gate_signatures (tenant_id, ticket_id, gate, creado_en);
CREATE INDEX CONCURRENTLY IF NOT EXISTS gates_tenant_actor_ix
    ON core.gate_signatures (tenant_id, actor_id, creado_en DESC);
CREATE INDEX CONCURRENTLY IF NOT EXISTS job_transitions_tenant_job_ix
    ON core.job_transitions (tenant_id, job_id, creado_en);
CREATE INDEX CONCURRENTLY IF NOT EXISTS llm_steps_tenant_job_ix
    ON core.llm_steps (tenant_id, job_id, creado_en);
CREATE INDEX CONCURRENTLY IF NOT EXISTS llm_steps_tenant_ticket_etapa_ix
    ON core.llm_steps (tenant_id, ticket_id, etapa);
CREATE INDEX CONCURRENTLY IF NOT EXISTS notifications_tenant_user_ix
    ON core.notifications (tenant_id, user_id, creada_en DESC);
CREATE INDEX CONCURRENTLY IF NOT EXISTS notifications_tenant_noleidas_ix
    ON core.notifications (tenant_id, user_id) WHERE NOT leida;
CREATE INDEX CONCURRENTLY IF NOT EXISTS refresh_tokens_tenant_user_activos_ix
    ON core.refresh_tokens (tenant_id, user_id) WHERE usado_en IS NULL AND NOT revocado;
CREATE INDEX CONCURRENTLY IF NOT EXISTS qa_runs_tenant_ticket_ix
    ON core.qa_runs (tenant_id, ticket_id, corrida DESC);
CREATE INDEX CONCURRENTLY IF NOT EXISTS specs_tenant_ticket_ix
    ON core.specs (tenant_id, ticket_id, version DESC);
CREATE INDEX CONCURRENTLY IF NOT EXISTS usage_tokens_tenant_ticket_etapa_ix
    ON core.usage_tokens (tenant_id, ticket_id, etapa);

-- ---------------------------------------------------------------------------
-- 2. Retirada de los índices reemplazados (ya existe su sucesor tenant-first).
-- ---------------------------------------------------------------------------
DROP INDEX CONCURRENTLY IF EXISTS core.gates_ticket_ix;
DROP INDEX CONCURRENTLY IF EXISTS core.gates_actor_ix;
DROP INDEX CONCURRENTLY IF EXISTS core.job_transitions_job_ix;
DROP INDEX CONCURRENTLY IF EXISTS core.llm_steps_job_ix;
DROP INDEX CONCURRENTLY IF EXISTS core.llm_steps_ticket_etapa_ix;
DROP INDEX CONCURRENTLY IF EXISTS core.notifications_user_ix;
DROP INDEX CONCURRENTLY IF EXISTS core.notifications_noleidas_ix;
DROP INDEX CONCURRENTLY IF EXISTS core.refresh_tokens_user_ix;
DROP INDEX CONCURRENTLY IF EXISTS core.qa_runs_ticket_ix;
DROP INDEX CONCURRENTLY IF EXISTS core.specs_ticket_ix;
DROP INDEX CONCURRENTLY IF EXISTS core.usage_tokens_ticket_ix;

-- ---------------------------------------------------------------------------
-- 3. Retirada de los índices cuyo equivalente tenant-first YA existe (migración 018):
--      attachments_ticket_ix  (ticket_id)     -> idx_ticket_attachments_tenant_ticket_id
--      findings_ticket_ix     (ticket_id)     -> idx_security_findings_tenant_ticket_id
--      usage_loc_ticket_ix    (ticket_id)     -> idx_usage_loc_tenant_ticket_id
--      watchers_user_ix       (user_id)       -> idx_ticket_watchers_tenant_user_id
--      tickets_reporter_ix    (reportado_por) -> idx_tickets_tenant_reportado_por
--      tickets_duplicado_ix   (duplicado_de, parcial) -> idx_tickets_tenant_duplicado_de
-- ---------------------------------------------------------------------------
DROP INDEX CONCURRENTLY IF EXISTS core.attachments_ticket_ix;
DROP INDEX CONCURRENTLY IF EXISTS core.findings_ticket_ix;
DROP INDEX CONCURRENTLY IF EXISTS core.usage_loc_ticket_ix;
DROP INDEX CONCURRENTLY IF EXISTS core.watchers_user_ix;
DROP INDEX CONCURRENTLY IF EXISTS core.tickets_reporter_ix;
DROP INDEX CONCURRENTLY IF EXISTS core.tickets_duplicado_ix;

-- ================================================================
-- ARCHIVO: db/migrations/033_particion_auditoria.sql
-- ================================================================
-- ============================================================================
-- KALLICODE · 033_particion_auditoria.sql
-- KC-DB-07-1 (DB-F09, ALTO) — audit.audit_events particionada por rango mensual
-- de creado_en con pg_partman.
--
-- audit_events es la tabla que más crece del modelo y la única que no se puede
-- truncar (es la prueba). 02_indexes.sql ya anunciaba «particionar a partir de
-- ~50M de filas» sin ejecutarlo, y la clave primaria (creado_en, id) se rediseñó
-- en 017_pk_para_particion.sql precisamente para poder hacerlo. Aquí se ejecuta:
--
--   * La tabla pasa a PARTITION BY RANGE (creado_en), con una partición por mes
--     (UTC), una partición DEFAULT y doce meses futuros pre-creados.
--   * pg_partman crea la partición siguiente sin intervención manual: la
--     mantiene su worker (pg_partman_bgw) o, en su defecto, cualquier planificador
--     que ejecute CALL partman.run_maintenance_proc() (docs/particionado_auditoria.md).
--   * Los seis índices de auditoría pasan a ser por partición (se declaran en la
--     tabla padre y PostgreSQL los crea en cada partición).
--   * El trigger de sellado (trg_audit_seal), el de inmutabilidad
--     (trg_audit_immutable), la política RLS, los permisos, las restricciones y la
--     FK a core.organizations se reproducen idénticos: verify_chain, V16 y V17 no
--     cambian.
--   * No se aplica retención: la auditoría no se borra (retention queda en NULL).
--
-- Cómo se convierte: PostgreSQL no convierte una tabla existente en particionada,
-- así que la migración crea la tabla nueva, copia las filas CONSERVANDO id y sello
-- (el trigger de sellado se desactiva solo durante la copia: recalcularlo
-- rompería la cadena), verifica que no se perdió ni se alteró nada y retira la
-- tabla antigua. Todo ocurre en una transacción: si cualquier verificación falla,
-- no queda nada a medias. Durante la copia la tabla está bloqueada para escritura
-- (ver el ensayo con 5 millones de filas en docs/particionado_auditoria.md).
--
-- La reversión (particionada -> tabla simple) está en
-- db/tools/revertir_particion_auditoria.sql.
--
-- Requisito: la extensión pg_partman (00_extensiones.sql; imagen db/postgres/).
-- Nota: el ticket nombra esta migración 024_particion_auditoria.sql, pero 024
-- ya existe (cadena de auditoría); es la 033.
-- ============================================================================

SET LOCAL lock_timeout = '30s';
-- Los límites de las particiones se calculan en la zona horaria de la sesión:
-- siempre en UTC, para que no dependan de quién ejecute la migración.
SET LOCAL timezone = 'UTC';

-- ---------------------------------------------------------------------------
-- 0. Precondiciones
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_partman') THEN
        RAISE EXCEPTION
            '033: falta la extensión pg_partman. Créela con db/00_extensiones.sql (superusuario) sobre una imagen que la incluya (db/postgres/) o habilítela en el servidor (en Azure, azure.extensions) y vuelva a ejecutar.';
    END IF;
    IF NOT has_schema_privilege('kallicode_admin', 'partman', 'USAGE, CREATE') THEN
        RAISE EXCEPTION
            '033: kallicode_admin no tiene permisos sobre el esquema partman. Vuelva a ejecutar db/00_extensiones.sql como superusuario.';
    END IF;
END $$;

-- Los objetos nuevos quedan a nombre de kallicode_admin, como el resto del esquema
-- (04_rls.sql). Si el runner ya es kallicode_admin esto no cambia nada.
SET LOCAL ROLE kallicode_admin;

DO $$
DECLARE
    antes bigint;
    despues bigint;
    ids_antes bigint;
    ids_despues bigint;
    sellos_antes numeric;
    sellos_despues numeric;
    desde date;
    mes date;
    r record;
BEGIN
    -- Idempotencia: si ya está particionada no hay nada que hacer.
    IF (SELECT c.relkind FROM pg_class c WHERE c.oid = 'audit.audit_events'::regclass) = 'p' THEN
        RAISE NOTICE '033: audit.audit_events ya está particionada; se omite.';
        RETURN;
    END IF;

    LOCK TABLE audit.audit_events IN ACCESS EXCLUSIVE MODE;

    -- Huella de la tabla antigua, para comparar al final.
    SELECT count(*), coalesce(sum(id), 0), coalesce(sum(hashtext(sello)::numeric), 0), min(creado_en)::date
      INTO antes, ids_antes, sellos_antes, desde
      FROM audit.audit_events;

    -- -----------------------------------------------------------------------
    -- 1. La tabla antigua se aparta con sus índices y restricciones renombrados
    --    (los nombres originales pasan a la tabla nueva).
    -- -----------------------------------------------------------------------
    ALTER TABLE audit.audit_events RENAME TO audit_events_pre033;
    FOR r IN
        SELECT conname FROM pg_constraint
         WHERE conrelid = 'audit.audit_events_pre033'::regclass
    LOOP
        EXECUTE format('ALTER TABLE audit.audit_events_pre033 RENAME CONSTRAINT %I TO %I',
                       r.conname, r.conname || '_pre033');
    END LOOP;
    FOR r IN
        SELECT c.relname
          FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
         WHERE i.indrelid = 'audit.audit_events_pre033'::regclass
           AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conindid = i.indexrelid)
    LOOP
        EXECUTE format('ALTER INDEX audit.%I RENAME TO %I', r.relname, r.relname || '_pre033');
    END LOOP;

    -- -----------------------------------------------------------------------
    -- 2. Tabla nueva: mismas columnas, misma clave (creado_en, id).
    -- -----------------------------------------------------------------------
    CREATE TABLE audit.audit_events (
        id                bigint GENERATED ALWAYS AS IDENTITY,
        tenant_id         text NOT NULL,
        ticket_id         text,                              -- sin FK: la auditoría sobrevive a todo
        job_id            text,
        etapa             text,
        actor_tipo        text NOT NULL,                     -- humano | agente | sistema
        actor_id          text,                              -- user_id o nombre del agente
        evento            text NOT NULL,                     -- código estable (gate_firmado, spec_generada...)
        resumen           text NOT NULL,                     -- texto visible en el portal
        datos             jsonb,                             -- payload estructurado del evento
        modelo            text,                              -- si actor agente
        step_id           text,                              -- ref a core.llm_steps
        sello_previo      text NOT NULL,
        sello             text NOT NULL,                     -- SHA-256(sello_previo || canónico)
        creado_en         timestamptz NOT NULL DEFAULT now(),
        ip                inet,
        user_agent        text,
        request_id        text,
        version_sello     smallint NOT NULL DEFAULT 1,
        CONSTRAINT audit_events_pkey PRIMARY KEY (creado_en, id),
        CONSTRAINT audit_events_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES core.organizations(id),
        CONSTRAINT ae_actor_chk CHECK (actor_tipo IN ('humano','agente','sistema')),
        CONSTRAINT ae_sello_chk CHECK (sello ~ '^[0-9a-f]{64}$'),
        CONSTRAINT ae_version_sello_chk CHECK (version_sello IN (1, 2))
    ) PARTITION BY RANGE (creado_en);

    COMMENT ON COLUMN audit.audit_events.ip IS
        'KC-DB-05-6: dirección de origen de la solicitud que originó el evento. Sellada desde la versión 2.';
    COMMENT ON COLUMN audit.audit_events.user_agent IS
        'KC-DB-05-6: cabecera User-Agent del cliente HTTP. Sellada desde la versión 2.';
    COMMENT ON COLUMN audit.audit_events.request_id IS
        'KC-DB-05-6: identificador de correlación de la solicitud (texto libre, p. ej. un UUID). Sellado desde la versión 2.';
    COMMENT ON COLUMN audit.audit_events.version_sello IS
        'KC-DB-05-6: formato del canónico del sello. 1 = original (sin ip/user_agent/request_id); 2 = con ellos. Lo fija el trigger de sellado.';

    -- Índices por partición: se declaran en el padre y se crean en cada partición.
    CREATE INDEX audit_tenant_fecha_ix ON audit.audit_events (tenant_id, creado_en DESC);
    CREATE INDEX audit_ticket_ix       ON audit.audit_events (tenant_id, ticket_id, creado_en);
    CREATE INDEX audit_actor_ix        ON audit.audit_events (tenant_id, actor_tipo, creado_en DESC);
    CREATE INDEX audit_evento_ix       ON audit.audit_events (tenant_id, evento);
    CREATE INDEX audit_events_sello_ix ON audit.audit_events (tenant_id, sello);
    CREATE INDEX audit_events_request_id_ix ON audit.audit_events (tenant_id, request_id)
        WHERE request_id IS NOT NULL;

    -- Triggers: se declaran en el padre y PostgreSQL los replica en cada partición.
    CREATE TRIGGER trg_audit_seal
        BEFORE INSERT ON audit.audit_events
        FOR EACH ROW EXECUTE FUNCTION audit.seal_event();
    CREATE TRIGGER trg_audit_immutable
        BEFORE UPDATE OR DELETE ON audit.audit_events
        FOR EACH ROW EXECUTE FUNCTION audit.forbid_mutation();

    -- RLS y permisos, como en 04_rls.sql. Las particiones NO reciben permisos para
    -- la aplicación: solo se llega a ellas a través del padre, que lleva la política.
    ALTER TABLE audit.audit_events ENABLE ROW LEVEL SECURITY;
    ALTER TABLE audit.audit_events FORCE ROW LEVEL SECURITY;
    CREATE POLICY tenant_isolation ON audit.audit_events
        USING (tenant_id = core.current_tenant())
        WITH CHECK (tenant_id = core.current_tenant());
    REVOKE ALL ON audit.audit_events FROM PUBLIC;
    GRANT SELECT, INSERT ON audit.audit_events TO kallicode_app, kallicode_admin;

    -- -----------------------------------------------------------------------
    -- 3. El canónico del sello (029) recibe la fila como el tipo de la tabla:
    --    se redefine para el tipo de la tabla nueva (la antigua conserva el suyo
    --    hasta que se retira, más abajo).
    -- -----------------------------------------------------------------------
    CREATE OR REPLACE FUNCTION audit.calcular_sello(e audit.audit_events) RETURNS text
    LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $f$
        SELECT encode(sha256(convert_to(
            CASE e.version_sello
                WHEN 1 THEN
                    e.sello_previo || e.tenant_id || e.evento || e.resumen
                    || coalesce(e.datos::text, '') || coalesce(e.ticket_id, '')
                    || coalesce(e.actor_id, '')
                    || to_char(e.creado_en, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
                ELSE
                    e.sello_previo || e.tenant_id || e.evento || e.resumen
                    || coalesce(e.datos::text, '') || coalesce(e.ticket_id, '')
                    || coalesce(e.actor_id, '')
                    || chr(31) || coalesce(abbrev(e.ip), '')
                    || chr(31) || coalesce(e.user_agent, '')
                    || chr(31) || coalesce(e.request_id, '')
                    || chr(31)
                    || to_char(e.creado_en, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
            END,
            'UTF8')), 'hex')
    $f$;
    COMMENT ON FUNCTION audit.calcular_sello(audit.audit_events) IS
        'KC-DB-05-6: canónico del sello según e.version_sello. Usada por seal_event y verify_chain; el formato de la versión 1 es inmutable.';

    -- -----------------------------------------------------------------------
    -- 4. pg_partman: una partición por mes (UTC), doce meses de antelación y una
    --    partición DEFAULT. Las particiones arrancan en el mes de la fila más
    --    antigua (o en el mes actual si la tabla está vacía) para que cada fila
    --    existente tenga su partición.
    -- -----------------------------------------------------------------------
    PERFORM partman.create_parent(
        p_parent_table   := 'audit.audit_events',
        p_control        := 'creado_en',
        p_interval       := '1 month',
        p_type           := 'range',
        p_premake        := 12,
        p_start_partition := to_char(date_trunc('month', coalesce(desde, current_date)::timestamp),
                                     'YYYY-MM-DD HH24:MI:SS'),
        p_default_table  := true,
        p_jobmon         := false);

    -- La auditoría no se borra: sin retención. Las particiones nuevas no heredan
    -- permisos (solo se accede por el padre).
    UPDATE partman.part_config
       SET retention = NULL, retention_keep_table = true, inherit_privileges = false,
           infinite_time_partitions = true
     WHERE parent_table = 'audit.audit_events';

    -- -----------------------------------------------------------------------
    -- 5. Copia conservando id y sello: el trigger de sellado recalcularía
    --    sello_previo/sello y rompería la cadena, y el de inmutabilidad no aplica.
    -- -----------------------------------------------------------------------
    ALTER TABLE audit.audit_events DISABLE TRIGGER trg_audit_seal;
    -- Mes a mes: cada sentencia escribe en una sola partición (menos memoria y WAL por
    -- sentencia y mejor localidad en los índices que copiarlo todo de una vez).
    IF antes > 0 THEN
        FOR mes IN
            SELECT g::date
              FROM generate_series(date_trunc('month', desde::timestamp),
                                   date_trunc('month', (SELECT max(creado_en) FROM audit.audit_events_pre033)
                                                       AT TIME ZONE 'UTC'),
                                   interval '1 month') AS g
        LOOP
            INSERT INTO audit.audit_events
                   (id, tenant_id, ticket_id, job_id, etapa, actor_tipo, actor_id, evento, resumen, datos,
                    modelo, step_id, sello_previo, sello, creado_en, ip, user_agent, request_id, version_sello)
            OVERRIDING SYSTEM VALUE
            SELECT id, tenant_id, ticket_id, job_id, etapa, actor_tipo, actor_id, evento, resumen, datos,
                   modelo, step_id, sello_previo, sello, creado_en, ip, user_agent, request_id, version_sello
              FROM audit.audit_events_pre033
             WHERE creado_en >= mes::timestamptz
               AND creado_en <  (mes + interval '1 month')::timestamptz;
        END LOOP;
    END IF;
    ALTER TABLE audit.audit_events ENABLE TRIGGER trg_audit_seal;

    -- La identidad continúa donde terminó la tabla antigua.
    EXECUTE format('ALTER TABLE audit.audit_events ALTER COLUMN id RESTART WITH %s',
                   coalesce((SELECT max(id) FROM audit.audit_events_pre033), 0) + 1);

    -- -----------------------------------------------------------------------
    -- 6. Verificación: misma cantidad, mismos ids, mismos sellos, nada en la
    --    partición DEFAULT. Si algo no cuadra, se revierte toda la migración.
    -- -----------------------------------------------------------------------
    SELECT count(*), coalesce(sum(id), 0), coalesce(sum(hashtext(sello)::numeric), 0)
      INTO despues, ids_despues, sellos_despues
      FROM audit.audit_events;

    IF despues <> antes OR ids_despues <> ids_antes OR sellos_despues <> sellos_antes THEN
        RAISE EXCEPTION '033: la copia no coincide (filas % -> %, ids % -> %, sellos % -> %)',
            antes, despues, ids_antes, ids_despues, sellos_antes, sellos_despues;
    END IF;
    IF EXISTS (SELECT 1 FROM ONLY audit.audit_events_default) THEN
        RAISE EXCEPTION '033: hay filas en la partición DEFAULT; falta una partición para su fecha';
    END IF;

    -- -----------------------------------------------------------------------
    -- 7. Se retira la tabla antigua (y su versión de calcular_sello).
    -- -----------------------------------------------------------------------
    DROP FUNCTION audit.calcular_sello(audit.audit_events_pre033);
    DROP TABLE audit.audit_events_pre033;

    RAISE NOTICE '033: audit.audit_events particionada (% filas copiadas).', despues;
END $$;

ANALYZE audit.audit_events;

-- ================================================================
-- ARCHIVO: db/migrations/034_retencion_policies.sql
-- ================================================================
-- Migración 034: Creación de core.retention_policies (KC-DB-07-4)
-- Define ventanas de retención y ciclo de vida de datos particionados / históricos por tenant.

CREATE TABLE IF NOT EXISTS core.retention_policies (
    id TEXT NOT NULL DEFAULT ('ret_' || substr(md5(random()::text || clock_timestamp()::text), 1, 16)),
    tenant_id TEXT NOT NULL,
    entity_name TEXT NOT NULL,
    retention_days INTEGER NOT NULL,
    action TEXT NOT NULL DEFAULT 'detach',
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT retention_policies_pkey PRIMARY KEY (tenant_id, entity_name),
    CONSTRAINT retention_policies_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES core.organizations(id) ON DELETE CASCADE,
    CONSTRAINT retention_policies_days_chk CHECK (retention_days > 0),
    CONSTRAINT retention_policies_action_chk CHECK (action IN ('detach', 'drop', 'archive'))
);

CREATE INDEX IF NOT EXISTS idx_retention_policies_tenant_active
    ON core.retention_policies (tenant_id, is_active);

-- Habilitar y forzar Row-Level Security
ALTER TABLE core.retention_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.retention_policies FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tenant_isolation ON core.retention_policies;
CREATE POLICY tenant_isolation ON core.retention_policies
    FOR ALL
    USING (tenant_id = core.current_tenant())
    WITH CHECK (tenant_id = core.current_tenant());
-- ================================================================
-- ARCHIVO: db/migrations/035_particion_consumo.sql
-- ================================================================
-- ============================================================================
-- KALLICODE · 035_particion_consumo.sql
-- KC-DB-07-2 (DB-F09, ALTO) — core.usage_tokens y core.job_transitions
-- particionadas por rango mensual de creado_en con pg_partman, siguiendo el
-- patrón de 033_particion_auditoria.sql (KC-DB-07-1).
--
--   * usage_tokens acumula una fila por invocación de modelo y job_transitions una
--     por cambio de estado de job: las dos crecen sin techo y rotan mucho. Sus
--     claves primarias ya incluían creado_en (017_pk_para_particion.sql).
--   * Cada tabla pasa a PARTITION BY RANGE (creado_en): una partición por mes
--     (UTC), doce meses futuros pre-creados y una partición DEFAULT. pg_partman
--     crea la siguiente sin intervención manual (pg_partman_bgw o cualquier
--     planificador que ejecute CALL partman.run_maintenance_proc()).
--   * Las claves ajenas compuestas del Sprint 3 siguen declaradas y validadas
--     (en la tabla padre y en cada partición): usage_tokens -> tickets(tenant_id, id)
--     y job_transitions -> jobs(tenant_id, id), ambas con ON DELETE CASCADE.
--   * Los índices (3 y 3), los CHECK, la FK a core.organizations, la política RLS,
--     los permisos y el trigger de solo-añadir de job_transitions se reproducen
--     idénticos. No se aplica retención (la fijará core.retention_policies, 034).
--   * Autovacuum por tabla (§9.3), fijado aquí y no en el servidor: ver la sección 3.
--
-- Cómo se convierte (igual que 033): se crea la tabla nueva, se copia mes a mes
-- conservando id, se verifica (filas, ids y una huella del contenido) y se retira
-- la antigua. Una transacción por archivo: si algo no cuadra, no queda nada a
-- medias. Durante la copia cada tabla está bloqueada para escritura. Idempotente.
--
-- Requisito: pg_partman (00_extensiones.sql; imagen db/postgres/).
-- Nota: el ticket nombra esta migración 025_particion_consumo.sql, pero 025 ya
-- existe (append-only de las probatorias) y la 034 la tomó retention_policies.
-- ============================================================================

SET LOCAL lock_timeout = '30s';
SET LOCAL timezone = 'UTC';   -- límites de partición siempre en UTC

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_partman') THEN
        RAISE EXCEPTION
            '035: falta la extensión pg_partman. Créela con db/00_extensiones.sql (superusuario) sobre una imagen que la incluya (db/postgres/) o habilítela en el servidor (en Azure, azure.extensions) y vuelva a ejecutar.';
    END IF;
    IF NOT has_schema_privilege('kallicode_admin', 'partman', 'USAGE, CREATE') THEN
        RAISE EXCEPTION
            '035: kallicode_admin no tiene permisos sobre el esquema partman. Vuelva a ejecutar db/00_extensiones.sql como superusuario.';
    END IF;
END $$;

-- Las particiones no heredan la política RLS del padre: la aplicación no debe tener acceso a ellas
-- (04_rls.sql concede por defecto permisos sobre toda tabla nueva de core). El event trigger de
-- 00_extensiones.sql se los quita en cuanto se crean; sin él, las particiones que cree pg_partman
-- cada mes quedarían legibles para la aplicación sin filtro de tenant.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_event_trigger WHERE evtname = 'kc_particiones_sin_acceso' AND evtenabled <> 'D') THEN
        RAISE EXCEPTION
            '035: falta el event trigger kc_particiones_sin_acceso. Ejecute db/00_extensiones.sql como superusuario (si el servidor no permite event triggers, no se puede particionar tablas con RLS en core).';
    END IF;
END $$;

-- Los objetos nuevos quedan a nombre de kallicode_admin, como el resto del esquema.
SET LOCAL ROLE kallicode_admin;

-- ============================================================================
-- 1. core.usage_tokens
-- ============================================================================
DO $$
DECLARE
    antes bigint;
    despues bigint;
    ids_antes bigint;
    ids_despues bigint;
    huella_antes numeric;
    huella_despues numeric;
    desde date;
    mes date;
BEGIN
    IF (SELECT c.relkind FROM pg_class c WHERE c.oid = 'core.usage_tokens'::regclass) = 'p' THEN
        RAISE NOTICE '035: core.usage_tokens ya está particionada; se omite.';
        RETURN;
    END IF;

    LOCK TABLE core.usage_tokens IN ACCESS EXCLUSIVE MODE;

    SELECT count(*), coalesce(sum(id), 0),
           coalesce(sum(hashtext(tenant_id || ticket_id || etapa || modelo || tier || tokens_in || tokens_out
                                 || invocaciones || duracion_ms || creado_en::text)::numeric), 0),
           min(creado_en)::date
      INTO antes, ids_antes, huella_antes, desde
      FROM core.usage_tokens;

    -- La tabla antigua se aparta con sus índices y restricciones renombrados.
    ALTER TABLE core.usage_tokens RENAME TO usage_tokens_pre035;
    ALTER TABLE core.usage_tokens_pre035 RENAME CONSTRAINT usage_tokens_pkey TO usage_tokens_pkey_pre035;
    ALTER TABLE core.usage_tokens_pre035 RENAME CONSTRAINT usage_tokens_tenant_id_fkey TO usage_tokens_tenant_id_fkey_pre035;
    ALTER TABLE core.usage_tokens_pre035 RENAME CONSTRAINT usage_tokens_ticket_id_fkey TO usage_tokens_ticket_id_fkey_pre035;
    ALTER TABLE core.usage_tokens_pre035 RENAME CONSTRAINT ut_pos_chk TO ut_pos_chk_pre035;
    ALTER TABLE core.usage_tokens_pre035 RENAME CONSTRAINT ut_tier_chk TO ut_tier_chk_pre035;
    ALTER INDEX core.idx_usage_tokens_tenant_ticket_id RENAME TO idx_usage_tokens_tenant_ticket_id_pre035;
    ALTER INDEX core.usage_tokens_tenant_ix RENAME TO usage_tokens_tenant_ix_pre035;
    ALTER INDEX core.usage_tokens_tenant_ticket_etapa_ix RENAME TO usage_tokens_tenant_ticket_etapa_ix_pre035;

    CREATE TABLE core.usage_tokens (
        id                bigint GENERATED ALWAYS AS IDENTITY,
        tenant_id         text NOT NULL,
        ticket_id         text NOT NULL,
        etapa             text NOT NULL,
        modelo            text NOT NULL,
        tier              text NOT NULL,
        invocaciones      integer NOT NULL DEFAULT 1,
        tokens_in         integer NOT NULL,
        tokens_out        integer NOT NULL,
        duracion_ms       integer NOT NULL,
        creado_en         timestamptz NOT NULL DEFAULT now(),
        CONSTRAINT usage_tokens_pkey PRIMARY KEY (creado_en, id),
        CONSTRAINT usage_tokens_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES core.organizations(id),
        CONSTRAINT usage_tokens_ticket_id_fkey FOREIGN KEY (tenant_id, ticket_id)
            REFERENCES core.tickets(tenant_id, id) ON DELETE CASCADE,
        CONSTRAINT ut_pos_chk CHECK (tokens_in >= 0 AND tokens_out >= 0),
        CONSTRAINT ut_tier_chk CHECK (tier IN ('flash', 'pro', 'fable'))
    ) PARTITION BY RANGE (creado_en);

    CREATE INDEX idx_usage_tokens_tenant_ticket_id    ON core.usage_tokens (tenant_id, ticket_id);
    CREATE INDEX usage_tokens_tenant_ix               ON core.usage_tokens (tenant_id, creado_en);
    CREATE INDEX usage_tokens_tenant_ticket_etapa_ix  ON core.usage_tokens (tenant_id, ticket_id, etapa);

    ALTER TABLE core.usage_tokens ENABLE ROW LEVEL SECURITY;
    ALTER TABLE core.usage_tokens FORCE ROW LEVEL SECURITY;
    CREATE POLICY tenant_isolation ON core.usage_tokens
        USING (tenant_id = core.current_tenant())
        WITH CHECK (tenant_id = core.current_tenant());
    REVOKE ALL ON core.usage_tokens FROM PUBLIC;
    GRANT SELECT, INSERT, UPDATE, DELETE ON core.usage_tokens TO kallicode_app;

    PERFORM partman.create_parent(
        p_parent_table    := 'core.usage_tokens',
        p_control         := 'creado_en',
        p_interval        := '1 month',
        p_type            := 'range',
        p_premake         := 12,
        p_start_partition := to_char(date_trunc('month', coalesce(desde, current_date)::timestamp),
                                     'YYYY-MM-DD HH24:MI:SS'),
        p_default_table   := true,
        p_jobmon          := false);
    UPDATE partman.part_config
       SET retention = NULL, retention_keep_table = true, inherit_privileges = false,
           infinite_time_partitions = true
     WHERE parent_table = 'core.usage_tokens';

    -- Copia mes a mes (una sola partición por sentencia), conservando id.
    IF antes > 0 THEN
        FOR mes IN
            SELECT g::date
              FROM generate_series(date_trunc('month', desde::timestamp),
                                   date_trunc('month', (SELECT max(creado_en) FROM core.usage_tokens_pre035)
                                                       AT TIME ZONE 'UTC'),
                                   interval '1 month') AS g
        LOOP
            INSERT INTO core.usage_tokens
                   (id, tenant_id, ticket_id, etapa, modelo, tier, invocaciones, tokens_in, tokens_out,
                    duracion_ms, creado_en)
            OVERRIDING SYSTEM VALUE
            SELECT id, tenant_id, ticket_id, etapa, modelo, tier, invocaciones, tokens_in, tokens_out,
                   duracion_ms, creado_en
              FROM core.usage_tokens_pre035
             WHERE creado_en >= mes::timestamptz
               AND creado_en <  (mes + interval '1 month')::timestamptz;
        END LOOP;
    END IF;
    EXECUTE format('ALTER TABLE core.usage_tokens ALTER COLUMN id RESTART WITH %s',
                   coalesce((SELECT max(id) FROM core.usage_tokens_pre035), 0) + 1);

    SELECT count(*), coalesce(sum(id), 0),
           coalesce(sum(hashtext(tenant_id || ticket_id || etapa || modelo || tier || tokens_in || tokens_out
                                 || invocaciones || duracion_ms || creado_en::text)::numeric), 0)
      INTO despues, ids_despues, huella_despues
      FROM core.usage_tokens;
    IF despues <> antes OR ids_despues <> ids_antes OR huella_despues <> huella_antes THEN
        RAISE EXCEPTION '035: usage_tokens: la copia no coincide (filas % -> %, ids % -> %, huella % -> %)',
            antes, despues, ids_antes, ids_despues, huella_antes, huella_despues;
    END IF;
    IF EXISTS (SELECT 1 FROM ONLY core.usage_tokens_default) THEN
        RAISE EXCEPTION '035: usage_tokens: hay filas en la partición DEFAULT; falta una partición para su fecha';
    END IF;

    DROP TABLE core.usage_tokens_pre035;
    RAISE NOTICE '035: core.usage_tokens particionada (% filas copiadas).', despues;
END $$;

-- ============================================================================
-- 2. core.job_transitions
-- ============================================================================
DO $$
DECLARE
    antes bigint;
    despues bigint;
    ids_antes bigint;
    ids_despues bigint;
    huella_antes numeric;
    huella_despues numeric;
    desde date;
    mes date;
BEGIN
    IF (SELECT c.relkind FROM pg_class c WHERE c.oid = 'core.job_transitions'::regclass) = 'p' THEN
        RAISE NOTICE '035: core.job_transitions ya está particionada; se omite.';
        RETURN;
    END IF;

    LOCK TABLE core.job_transitions IN ACCESS EXCLUSIVE MODE;

    SELECT count(*), coalesce(sum(id), 0),
           coalesce(sum(hashtext(tenant_id || job_id || de_estado || a_estado || coalesce(motivo, '')
                                 || coalesce(contexto::text, '') || actor || creado_en::text)::numeric), 0),
           min(creado_en)::date
      INTO antes, ids_antes, huella_antes, desde
      FROM core.job_transitions;

    ALTER TABLE core.job_transitions RENAME TO job_transitions_pre035;
    ALTER TABLE core.job_transitions_pre035 RENAME CONSTRAINT job_transitions_pkey TO job_transitions_pkey_pre035;
    ALTER TABLE core.job_transitions_pre035 RENAME CONSTRAINT job_transitions_tenant_id_fkey TO job_transitions_tenant_id_fkey_pre035;
    ALTER TABLE core.job_transitions_pre035 RENAME CONSTRAINT job_transitions_job_id_fkey TO job_transitions_job_id_fkey_pre035;
    ALTER INDEX core.idx_job_transitions_tenant_job_id RENAME TO idx_job_transitions_tenant_job_id_pre035;
    ALTER INDEX core.job_transitions_tenant_job_ix RENAME TO job_transitions_tenant_job_ix_pre035;

    CREATE TABLE core.job_transitions (
        id                bigint GENERATED ALWAYS AS IDENTITY,
        tenant_id         text NOT NULL,
        job_id            text NOT NULL,
        de_estado         text NOT NULL,
        a_estado          text NOT NULL,
        motivo            text,
        contexto          jsonb,
        actor             text NOT NULL DEFAULT 'sistema',   -- sistema | svc:<agente> | user:<id>
        creado_en         timestamptz NOT NULL DEFAULT now(),
        CONSTRAINT job_transitions_pkey PRIMARY KEY (creado_en, id),
        CONSTRAINT job_transitions_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES core.organizations(id),
        CONSTRAINT job_transitions_job_id_fkey FOREIGN KEY (tenant_id, job_id)
            REFERENCES core.jobs(tenant_id, id) ON DELETE CASCADE
    ) PARTITION BY RANGE (creado_en);

    CREATE INDEX idx_job_transitions_tenant_job_id ON core.job_transitions (tenant_id, job_id);
    CREATE INDEX job_transitions_tenant_job_ix     ON core.job_transitions (tenant_id, job_id, creado_en);

    -- Solo-añadir (025_append_only_probatorias.sql): el trigger se declara en el padre y
    -- PostgreSQL lo replica en cada partición.
    CREATE TRIGGER trg_probatoria_append_only
        BEFORE UPDATE OR DELETE ON core.job_transitions
        FOR EACH ROW EXECUTE FUNCTION core.probatoria_append_only();

    ALTER TABLE core.job_transitions ENABLE ROW LEVEL SECURITY;
    ALTER TABLE core.job_transitions FORCE ROW LEVEL SECURITY;
    CREATE POLICY tenant_isolation ON core.job_transitions
        USING (tenant_id = core.current_tenant())
        WITH CHECK (tenant_id = core.current_tenant());
    REVOKE ALL ON core.job_transitions FROM PUBLIC;
    GRANT SELECT, INSERT ON core.job_transitions TO kallicode_app;
    -- Los permisos por defecto de core (04_rls.sql) le dieron también UPDATE y DELETE: 025 los retira.
    REVOKE UPDATE, DELETE ON core.job_transitions FROM kallicode_app;

    PERFORM partman.create_parent(
        p_parent_table    := 'core.job_transitions',
        p_control         := 'creado_en',
        p_interval        := '1 month',
        p_type            := 'range',
        p_premake         := 12,
        p_start_partition := to_char(date_trunc('month', coalesce(desde, current_date)::timestamp),
                                     'YYYY-MM-DD HH24:MI:SS'),
        p_default_table   := true,
        p_jobmon          := false);
    UPDATE partman.part_config
       SET retention = NULL, retention_keep_table = true, inherit_privileges = false,
           infinite_time_partitions = true
     WHERE parent_table = 'core.job_transitions';

    IF antes > 0 THEN
        FOR mes IN
            SELECT g::date
              FROM generate_series(date_trunc('month', desde::timestamp),
                                   date_trunc('month', (SELECT max(creado_en) FROM core.job_transitions_pre035)
                                                       AT TIME ZONE 'UTC'),
                                   interval '1 month') AS g
        LOOP
            INSERT INTO core.job_transitions
                   (id, tenant_id, job_id, de_estado, a_estado, motivo, contexto, actor, creado_en)
            OVERRIDING SYSTEM VALUE
            SELECT id, tenant_id, job_id, de_estado, a_estado, motivo, contexto, actor, creado_en
              FROM core.job_transitions_pre035
             WHERE creado_en >= mes::timestamptz
               AND creado_en <  (mes + interval '1 month')::timestamptz;
        END LOOP;
    END IF;
    EXECUTE format('ALTER TABLE core.job_transitions ALTER COLUMN id RESTART WITH %s',
                   coalesce((SELECT max(id) FROM core.job_transitions_pre035), 0) + 1);

    SELECT count(*), coalesce(sum(id), 0),
           coalesce(sum(hashtext(tenant_id || job_id || de_estado || a_estado || coalesce(motivo, '')
                                 || coalesce(contexto::text, '') || actor || creado_en::text)::numeric), 0)
      INTO despues, ids_despues, huella_despues
      FROM core.job_transitions;
    IF despues <> antes OR ids_despues <> ids_antes OR huella_despues <> huella_antes THEN
        RAISE EXCEPTION '035: job_transitions: la copia no coincide (filas % -> %, ids % -> %, huella % -> %)',
            antes, despues, ids_antes, ids_despues, huella_antes, huella_despues;
    END IF;
    IF EXISTS (SELECT 1 FROM ONLY core.job_transitions_default) THEN
        RAISE EXCEPTION '035: job_transitions: hay filas en la partición DEFAULT; falta una partición para su fecha';
    END IF;

    DROP TABLE core.job_transitions_pre035;
    RAISE NOTICE '035: core.job_transitions particionada (% filas copiadas).', despues;
END $$;

-- ============================================================================
-- 3. Autovacuum por tabla (§9.3)
--
-- Los parámetros de almacenamiento (y por tanto los de autovacuum) no se pueden fijar en una
-- tabla particionada: se fijan en cada partición. pg_partman copia a cada partición NUEVA los
-- de su tabla plantilla; aquí se fijan en la plantilla y en las particiones que ya existen.
--
--   usage_tokens      scale_factor 0,02  · insert_scale_factor 0,02 · analyze_scale_factor 0,01
--   job_transitions   scale_factor 0,05  · insert_scale_factor 0,05 · analyze_scale_factor 0,02
--
-- Por qué: son tablas de inserción continua (una fila por invocación de modelo y una por cambio
-- de estado de job) que se leen justo después de escribirse. Con el 20 % por defecto, el
-- autovacuum de una partición caliente espera a acumular una quinta parte de filas nuevas, y
-- hasta entonces el mapa de visibilidad (index-only scans), las estadísticas y el congelado de
-- filas quedan atrasados; con 2-5 % reacciona antes y en tandas más pequeñas. usage_tokens rota
-- más (varias filas por paso de cada ticket), por eso lleva el valor más estricto. Las
-- particiones de meses pasados ya no reciben escrituras: el autovacuum las deja en paz una vez
-- congeladas. Si el volumen cambia, se ajustan aquí y en la plantilla, no en el servidor.
-- ============================================================================
DO $$
DECLARE
    t record;
    p record;
    opciones text;
BEGIN
    FOR t IN
        SELECT * FROM (VALUES
            ('core.usage_tokens',    '0.02', '0.02', '0.01'),
            ('core.job_transitions', '0.05', '0.05', '0.02')
        ) AS v(tabla, sf, isf, asf)
    LOOP
        opciones := format('autovacuum_vacuum_scale_factor = %s, autovacuum_vacuum_insert_scale_factor = %s, autovacuum_analyze_scale_factor = %s',
                           t.sf, t.isf, t.asf);
        -- Plantilla de pg_partman: la heredan las particiones que cree el mantenimiento.
        EXECUTE format('ALTER TABLE %s SET (%s)',
                       (SELECT template_table FROM partman.part_config WHERE parent_table = t.tabla), opciones);
        -- Particiones existentes (incluida la DEFAULT).
        FOR p IN
            SELECT i.inhrelid::regclass::text AS particion
              FROM pg_inherits i WHERE i.inhparent = t.tabla::regclass
        LOOP
            EXECUTE format('ALTER TABLE %s SET (%s)', p.particion, opciones);
        END LOOP;
    END LOOP;
END $$;

-- ============================================================================
-- 4. V21 y las particiones
--
-- core.incoherencias_tenant() (013) recorre TODAS las claves ajenas de pg_constraint. Una tabla
-- particionada reproduce cada FK en cada partición (constraint con conparentid <> 0), y la
-- función las seguiría con SELECT directo sobre cada partición: duplicaría el trabajo y, al
-- ejecutarla la aplicación (V21 la llama kallicode_app), fallaría con «permission denied» porque
-- la aplicación no tiene acceso a las particiones. Se excluyen las FK heredadas: la de la tabla
-- padre ya cubre todas sus filas, porque consultar el padre recorre las particiones.
-- Es la definición de 013 con una sola condición añadida (c.conparentid = 0).
-- ============================================================================
CREATE OR REPLACE FUNCTION core.incoherencias_tenant()
RETURNS TABLE (relacion text, tabla_hija text, tabla_padre text,
               fila jsonb, tenant_hija text, tenant_padre text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT c.conname,
               c.conrelid::regclass  AS hija,
               c.confrelid::regclass AS padre,
               -- Unión hija/padre por las columnas de la FK, sin la pareja de tenant:
               (SELECT string_agg(format('p.%I = h.%I', pa.attname, ha.attname), ' AND ')
                  FROM unnest(c.conkey, c.confkey) AS k(hijo_n, padre_n)
                  JOIN pg_attribute ha ON ha.attrelid = c.conrelid  AND ha.attnum = k.hijo_n
                  JOIN pg_attribute pa ON pa.attrelid = c.confrelid AND pa.attnum = k.padre_n
                 WHERE NOT (ha.attname = 'tenant_id' AND pa.attname = 'tenant_id')
               ) AS union_sql,
               -- Clave primaria de la hija como jsonb, para identificar la fila:
               (SELECT string_agg(format('%L, h.%I', a.attname, a.attname), ', ')
                  FROM pg_index i
                  JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
                 WHERE i.indrelid = c.conrelid AND i.indisprimary
               ) AS pk_sql
          FROM pg_constraint c
         WHERE c.contype = 'f'
           AND c.conparentid = 0            -- KC-DB-07-2: no las FK clonadas en cada partición
           -- la hija y el padre tienen tenant_id (escalar o compuesta, da igual)
           AND EXISTS (SELECT 1 FROM pg_attribute
                        WHERE attrelid = c.conrelid AND attname = 'tenant_id' AND NOT attisdropped)
           AND EXISTS (SELECT 1 FROM pg_attribute
                        WHERE attrelid = c.confrelid AND attname = 'tenant_id' AND NOT attisdropped)
         ORDER BY c.conrelid::regclass::text, c.conname
    LOOP
        CONTINUE WHEN r.union_sql IS NULL;  -- FK solo por tenant_id: nada que comparar
        RETURN QUERY EXECUTE format(
            'SELECT %L::text, %L::text, %L::text, %s, h.tenant_id::text, p.tenant_id::text
               FROM %s h JOIN %s p ON %s
              WHERE h.tenant_id <> p.tenant_id',
            r.conname, r.hija::text, r.padre::text,
            CASE WHEN r.pk_sql IS NULL THEN 'jsonb_build_object(''ctid'', h.ctid::text)'
                 ELSE 'jsonb_build_object(' || r.pk_sql || ')' END,
            r.hija, r.padre, r.union_sql);
    END LOOP;
END $$;

COMMENT ON FUNCTION core.incoherencias_tenant() IS
'KC-DB-03-3/03-2: filas hijas cuyo tenant_id no coincide con el de su padre, en toda FK
(escalar o compuesta) entre dos tablas con tenant_id, generadas desde pg_constraint.
Base de V21 y consulta de reparación. KC-DB-07-2: se omiten las FK clonadas en las
particiones (conparentid <> 0): la de la tabla padre ya las cubre.';

-- ============================================================================
-- 4. Comprobación final: la aplicación no tiene ningún permiso sobre las particiones
-- ============================================================================
DO $$
DECLARE
    expuestas text;
BEGIN
    SELECT string_agg(c.oid::regclass::text, ', ') INTO expuestas
      FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
     WHERE i.inhparent IN ('core.usage_tokens'::regclass, 'core.job_transitions'::regclass)
       AND (has_table_privilege('kallicode_app', c.oid, 'SELECT, INSERT, UPDATE, DELETE')
            OR has_any_column_privilege('kallicode_app', c.oid, 'SELECT, INSERT, UPDATE'));
    IF expuestas IS NOT NULL THEN
        RAISE EXCEPTION '035: particiones con permisos para kallicode_app (se saltarían la RLS del padre): %', expuestas;
    END IF;
END $$;

ANALYZE core.usage_tokens;
ANALYZE core.job_transitions;

-- ================================================================
-- ARCHIVO: db/migrations/036_particion_colas.sql
-- ================================================================
-- ============================================================================
-- KALLICODE · 036_particion_colas.sql
-- KC-DB-07-3 (DB-F09, ALTO) — core.webhook_inbox y core.notifications
-- particionadas por rango mensual con pg_partman, y purga por partición.
--
--   * webhook_inbox guarda el payload crudo de cada entrega; notifications una fila por
--     aviso y usuario. El §9.3 fija 90 días de retención para los webhooks procesados.
--     Con la tabla simple la purga era un DELETE masivo (housekeeping.py) que deja bloat;
--     particionadas, vencer un mes es un DROP de la partición: instantáneo y sin bloat.
--   * Cada tabla pasa a PARTITION BY RANGE: una partición por mes, doce meses futuros
--     pre-creados y una partición DEFAULT; pg_partman crea la siguiente sin intervención.
--   * Índices (4 y 4), CHECK, claves ajenas compuestas, RLS (incluida la política
--     worker_colas), permisos y la lógica de las colas quedan idénticos. El índice parcial de
--     la cola (webhook_inbox_pend_ix) pasa a ser uno por partición.
--   * core.purgar_particiones_vencidas() elimina (DROP) las particiones vencidas, nunca hace
--     DELETE, y NO elimina una partición de webhook_inbox con entregas 'pendiente' (sección 4).
--
-- IDEMPOTENCIA DE LAS ENTREGAS (wi_delivery_uq). Una restricción UNIQUE de una tabla
-- particionada debe incluir la clave de partición. Si la clave fuera recibido_en (un instante
-- distinto en cada entrega), UNIQUE (connection_id, delivery_id, recibido_en) NUNCA se violaría
-- y la restricción dejaría de deduplicar. Por eso webhook_inbox se particiona por una columna
-- NUEVA, recibido_mes (el primer día del mes UTC de la recepción), y la unicidad pasa a ser
-- (connection_id, delivery_id, recibido_mes): una entrega no puede repetirse DENTRO DEL MISMO
-- MES. Efecto: un reintento del proveedor que llegue en un mes distinto al de la primera
-- entrega (p. ej. entre el 31 y el 1) ya no se reconoce como duplicado. La API debe insertar
-- con ON CONFLICT DO NOTHING sin objetivo (un objetivo (connection_id, delivery_id) ya no
-- coincide con ninguna restricción); wi_mes_chk mantiene recibido_mes coherente con recibido_en.
-- La PK pasa a (recibido_mes, id) (017 la había dejado en (recibido_en, id)).
--
-- Se convierte como 033/035: tabla nueva, copia mes a mes conservando id, verificación
-- (filas, ids, huella) y retirada de la antigua, todo en una transacción. Durante la copia
-- cada tabla está bloqueada para escritura. Idempotente.
--
-- Requisito: pg_partman y el event trigger de db/00_extensiones.sql (ver 035).
-- Nota: el ticket nombra esta migración 026_particion_colas.sql, pero 026 ya existe.
-- ============================================================================

SET LOCAL lock_timeout = '30s';
SET LOCAL timezone = 'UTC';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_partman') THEN
        RAISE EXCEPTION
            '036: falta la extensión pg_partman. Créela con db/00_extensiones.sql (superusuario) sobre una imagen que la incluya (db/postgres/) o habilítela en el servidor (en Azure, azure.extensions) y vuelva a ejecutar.';
    END IF;
    IF NOT has_schema_privilege('kallicode_admin', 'partman', 'USAGE, CREATE') THEN
        RAISE EXCEPTION
            '036: kallicode_admin no tiene permisos sobre el esquema partman. Vuelva a ejecutar db/00_extensiones.sql como superusuario.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_event_trigger WHERE evtname = 'kc_particiones_sin_acceso' AND evtenabled <> 'D') THEN
        RAISE EXCEPTION
            '036: falta el event trigger kc_particiones_sin_acceso (las particiones no heredan la RLS del padre). Ejecute db/00_extensiones.sql como superusuario.';
    END IF;
END $$;

SET LOCAL ROLE kallicode_admin;

-- Barrido retroactivo: ninguna partición existente de core o vec debe ser accesible para la
-- aplicación ni el worker (no heredan la política RLS del padre). El event trigger lo hace con las
-- que se crean desde ahora; esto cubre las de bases donde se particionó antes de reforzarlo.
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT c.oid::regclass::text AS tabla
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE c.relispartition AND n.nspname IN ('core', 'vec')
           AND (has_table_privilege('kallicode_app', c.oid, 'SELECT, INSERT, UPDATE, DELETE')
                OR has_table_privilege('kallicode_worker', c.oid, 'SELECT, INSERT, UPDATE, DELETE'))
    LOOP
        EXECUTE format('REVOKE ALL ON TABLE %s FROM kallicode_app, kallicode_worker', r.tabla);
        RAISE NOTICE '036: se retiró el acceso de la aplicación a la partición %', r.tabla;
    END LOOP;
END $$;

-- ============================================================================
-- 1. core.webhook_inbox
-- ============================================================================
DO $$
DECLARE
    antes bigint;
    despues bigint;
    ids_antes bigint;
    ids_despues bigint;
    huella_antes numeric;
    huella_despues numeric;
    desde date;
    mes date;
    r record;
BEGIN
    IF (SELECT c.relkind FROM pg_class c WHERE c.oid = 'core.webhook_inbox'::regclass) = 'p' THEN
        RAISE NOTICE '036: core.webhook_inbox ya está particionada; se omite.';
        RETURN;
    END IF;

    LOCK TABLE core.webhook_inbox IN ACCESS EXCLUSIVE MODE;

    SELECT count(*), coalesce(sum(id), 0),
           coalesce(sum(hashtext(tenant_id || connection_id || delivery_id || coalesce(evento, '') || payload::text
                                 || estado || coalesce(error_detalle, '') || coalesce(ticket_id, '')
                                 || recibido_en::text || coalesce(procesado_en::text, ''))::numeric), 0),
           min(recibido_en)::date
      INTO antes, ids_antes, huella_antes, desde
      FROM core.webhook_inbox;

    ALTER TABLE core.webhook_inbox RENAME TO webhook_inbox_pre036;
    FOR r IN SELECT conname FROM pg_constraint WHERE conrelid = 'core.webhook_inbox_pre036'::regclass LOOP
        EXECUTE format('ALTER TABLE core.webhook_inbox_pre036 RENAME CONSTRAINT %I TO %I', r.conname, r.conname || '_pre036');
    END LOOP;
    FOR r IN
        SELECT c.relname FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
         WHERE i.indrelid = 'core.webhook_inbox_pre036'::regclass
           AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conindid = i.indexrelid)
    LOOP
        EXECUTE format('ALTER INDEX core.%I RENAME TO %I', r.relname, r.relname || '_pre036');
    END LOOP;

    CREATE TABLE core.webhook_inbox (
        id                bigint GENERATED ALWAYS AS IDENTITY,
        tenant_id         text NOT NULL,
        connection_id     text NOT NULL,
        delivery_id       text NOT NULL,
        evento            text,
        payload           jsonb NOT NULL,
        estado            text NOT NULL DEFAULT 'pendiente',
        error_detalle     text,
        ticket_id         text,
        recibido_en       timestamptz NOT NULL DEFAULT now(),
        procesado_en      timestamptz,
        -- Clave de partición: primer día del mes UTC de la recepción (ver la cabecera).
        recibido_mes      date NOT NULL DEFAULT date_trunc('month', now() AT TIME ZONE 'UTC')::date,
        CONSTRAINT webhook_inbox_pkey PRIMARY KEY (recibido_mes, id),
        CONSTRAINT wi_delivery_uq UNIQUE (connection_id, delivery_id, recibido_mes),
        CONSTRAINT wi_mes_chk CHECK (recibido_mes = date_trunc('month', recibido_en AT TIME ZONE 'UTC')::date),
        CONSTRAINT wi_estado_chk CHECK (estado IN ('pendiente', 'procesado', 'ignorado', 'fallido')),
        CONSTRAINT webhook_inbox_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES core.organizations(id),
        CONSTRAINT webhook_inbox_connection_id_fkey FOREIGN KEY (tenant_id, connection_id)
            REFERENCES core.connections(tenant_id, id) ON DELETE CASCADE,
        CONSTRAINT webhook_inbox_ticket_id_fkey FOREIGN KEY (tenant_id, ticket_id)
            REFERENCES core.tickets(tenant_id, id)
    ) PARTITION BY RANGE (recibido_mes);

    CREATE INDEX idx_webhook_inbox_tenant_connection_id ON core.webhook_inbox (tenant_id, connection_id);
    CREATE INDEX idx_webhook_inbox_tenant_ticket_id     ON core.webhook_inbox (tenant_id, ticket_id);
    CREATE INDEX webhook_inbox_pend_ix                  ON core.webhook_inbox (estado, recibido_en)
        WHERE estado IN ('pendiente', 'fallido');
    CREATE INDEX webhook_inbox_tenant_ix                ON core.webhook_inbox (tenant_id, recibido_en DESC);

    ALTER TABLE core.webhook_inbox ENABLE ROW LEVEL SECURITY;
    ALTER TABLE core.webhook_inbox FORCE ROW LEVEL SECURITY;
    CREATE POLICY tenant_isolation ON core.webhook_inbox
        USING (tenant_id = core.current_tenant())
        WITH CHECK (tenant_id = core.current_tenant());
    -- 010_rol_worker.sql: el worker barre la cola de TODOS los tenants.
    CREATE POLICY worker_colas ON core.webhook_inbox TO kallicode_worker USING (true);
    REVOKE ALL ON core.webhook_inbox FROM PUBLIC;
    GRANT SELECT, INSERT, UPDATE, DELETE ON core.webhook_inbox TO kallicode_app;
    GRANT SELECT, UPDATE, DELETE ON core.webhook_inbox TO kallicode_worker;

    PERFORM partman.create_parent(
        p_parent_table    := 'core.webhook_inbox',
        p_control         := 'recibido_mes',
        p_interval        := '1 month',
        p_type            := 'range',
        p_premake         := 12,
        p_start_partition := to_char(date_trunc('month', coalesce(desde, current_date)::timestamp), 'YYYY-MM-DD'),
        p_default_table   := true,
        p_jobmon          := false);
    UPDATE partman.part_config
       SET retention = NULL, retention_keep_table = true, inherit_privileges = false,
           infinite_time_partitions = true
     WHERE parent_table = 'core.webhook_inbox';

    IF antes > 0 THEN
        FOR mes IN
            SELECT g::date
              FROM generate_series(date_trunc('month', desde::timestamp),
                                   date_trunc('month', (SELECT max(recibido_en) FROM core.webhook_inbox_pre036)
                                                       AT TIME ZONE 'UTC'),
                                   interval '1 month') AS g
        LOOP
            INSERT INTO core.webhook_inbox
                   (id, tenant_id, connection_id, delivery_id, evento, payload, estado, error_detalle, ticket_id,
                    recibido_en, procesado_en, recibido_mes)
            OVERRIDING SYSTEM VALUE
            SELECT id, tenant_id, connection_id, delivery_id, evento, payload, estado, error_detalle, ticket_id,
                   recibido_en, procesado_en, date_trunc('month', recibido_en AT TIME ZONE 'UTC')::date
              FROM core.webhook_inbox_pre036
             WHERE recibido_en >= mes::timestamptz
               AND recibido_en <  (mes + interval '1 month')::timestamptz;
        END LOOP;
    END IF;
    EXECUTE format('ALTER TABLE core.webhook_inbox ALTER COLUMN id RESTART WITH %s',
                   coalesce((SELECT max(id) FROM core.webhook_inbox_pre036), 0) + 1);

    SELECT count(*), coalesce(sum(id), 0),
           coalesce(sum(hashtext(tenant_id || connection_id || delivery_id || coalesce(evento, '') || payload::text
                                 || estado || coalesce(error_detalle, '') || coalesce(ticket_id, '')
                                 || recibido_en::text || coalesce(procesado_en::text, ''))::numeric), 0)
      INTO despues, ids_despues, huella_despues
      FROM core.webhook_inbox;
    IF despues <> antes OR ids_despues <> ids_antes OR huella_despues <> huella_antes THEN
        RAISE EXCEPTION '036: webhook_inbox: la copia no coincide (filas % -> %, ids % -> %, huella % -> %)',
            antes, despues, ids_antes, ids_despues, huella_antes, huella_despues;
    END IF;
    IF EXISTS (SELECT 1 FROM ONLY core.webhook_inbox_default) THEN
        RAISE EXCEPTION '036: webhook_inbox: hay filas en la partición DEFAULT; falta una partición para su fecha';
    END IF;

    DROP TABLE core.webhook_inbox_pre036;
    RAISE NOTICE '036: core.webhook_inbox particionada (% filas copiadas).', despues;
END $$;

-- ============================================================================
-- 2. core.notifications
-- ============================================================================
DO $$
DECLARE
    antes bigint;
    despues bigint;
    ids_antes numeric;
    ids_despues numeric;
    huella_antes numeric;
    huella_despues numeric;
    desde date;
    mes date;
    r record;
BEGIN
    IF (SELECT c.relkind FROM pg_class c WHERE c.oid = 'core.notifications'::regclass) = 'p' THEN
        RAISE NOTICE '036: core.notifications ya está particionada; se omite.';
        RETURN;
    END IF;

    LOCK TABLE core.notifications IN ACCESS EXCLUSIVE MODE;

    SELECT count(*), coalesce(sum(hashtext(id)::numeric), 0),
           coalesce(sum(hashtext(id || tenant_id || user_id || tipo || titulo || coalesce(cuerpo, '')
                                 || coalesce(ticket_id, '') || leida::text || creada_en::text)::numeric), 0),
           min(creada_en)::date
      INTO antes, ids_antes, huella_antes, desde
      FROM core.notifications;

    ALTER TABLE core.notifications RENAME TO notifications_pre036;
    FOR r IN SELECT conname FROM pg_constraint WHERE conrelid = 'core.notifications_pre036'::regclass LOOP
        EXECUTE format('ALTER TABLE core.notifications_pre036 RENAME CONSTRAINT %I TO %I', r.conname, r.conname || '_pre036');
    END LOOP;
    FOR r IN
        SELECT c.relname FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
         WHERE i.indrelid = 'core.notifications_pre036'::regclass
           AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conindid = i.indexrelid)
    LOOP
        EXECUTE format('ALTER INDEX core.%I RENAME TO %I', r.relname, r.relname || '_pre036');
    END LOOP;

    CREATE TABLE core.notifications (
        id                text NOT NULL,
        tenant_id         text NOT NULL,
        user_id           text NOT NULL,
        tipo              text NOT NULL,
        titulo            text NOT NULL,
        cuerpo            text,
        ticket_id         text,
        leida             boolean NOT NULL DEFAULT false,
        creada_en         timestamptz NOT NULL DEFAULT now(),
        CONSTRAINT notifications_pkey PRIMARY KEY (creada_en, id),
        CONSTRAINT nt_tipo_chk CHECK (tipo IN ('cambio_etapa', 'gate_pendiente', 'ticket_cerrado',
                                               'aviso_cuota', 'seguridad', 'sistema')),
        CONSTRAINT notifications_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES core.organizations(id),
        CONSTRAINT notifications_ticket_id_fkey FOREIGN KEY (tenant_id, ticket_id)
            REFERENCES core.tickets(tenant_id, id) ON DELETE CASCADE,
        CONSTRAINT notifications_user_id_fkey FOREIGN KEY (tenant_id, user_id)
            REFERENCES core.users(tenant_id, id) ON DELETE CASCADE
    ) PARTITION BY RANGE (creada_en);

    CREATE INDEX idx_notifications_tenant_ticket_id  ON core.notifications (tenant_id, ticket_id);
    CREATE INDEX idx_notifications_tenant_user_id    ON core.notifications (tenant_id, user_id);
    CREATE INDEX notifications_tenant_noleidas_ix    ON core.notifications (tenant_id, user_id) WHERE NOT leida;
    CREATE INDEX notifications_tenant_user_ix        ON core.notifications (tenant_id, user_id, creada_en DESC);

    ALTER TABLE core.notifications ENABLE ROW LEVEL SECURITY;
    ALTER TABLE core.notifications FORCE ROW LEVEL SECURITY;
    CREATE POLICY tenant_isolation ON core.notifications
        USING (tenant_id = core.current_tenant())
        WITH CHECK (tenant_id = core.current_tenant());
    REVOKE ALL ON core.notifications FROM PUBLIC;
    GRANT SELECT, INSERT, UPDATE, DELETE ON core.notifications TO kallicode_app;

    PERFORM partman.create_parent(
        p_parent_table    := 'core.notifications',
        p_control         := 'creada_en',
        p_interval        := '1 month',
        p_type            := 'range',
        p_premake         := 12,
        p_start_partition := to_char(date_trunc('month', coalesce(desde, current_date)::timestamp),
                                     'YYYY-MM-DD HH24:MI:SS'),
        p_default_table   := true,
        p_jobmon          := false);
    UPDATE partman.part_config
       SET retention = NULL, retention_keep_table = true, inherit_privileges = false,
           infinite_time_partitions = true
     WHERE parent_table = 'core.notifications';

    IF antes > 0 THEN
        FOR mes IN
            SELECT g::date
              FROM generate_series(date_trunc('month', desde::timestamp),
                                   date_trunc('month', (SELECT max(creada_en) FROM core.notifications_pre036)
                                                       AT TIME ZONE 'UTC'),
                                   interval '1 month') AS g
        LOOP
            INSERT INTO core.notifications
                   (id, tenant_id, user_id, tipo, titulo, cuerpo, ticket_id, leida, creada_en)
            SELECT id, tenant_id, user_id, tipo, titulo, cuerpo, ticket_id, leida, creada_en
              FROM core.notifications_pre036
             WHERE creada_en >= mes::timestamptz
               AND creada_en <  (mes + interval '1 month')::timestamptz;
        END LOOP;
    END IF;

    SELECT count(*), coalesce(sum(hashtext(id)::numeric), 0),
           coalesce(sum(hashtext(id || tenant_id || user_id || tipo || titulo || coalesce(cuerpo, '')
                                 || coalesce(ticket_id, '') || leida::text || creada_en::text)::numeric), 0)
      INTO despues, ids_despues, huella_despues
      FROM core.notifications;
    IF despues <> antes OR ids_despues <> ids_antes OR huella_despues <> huella_antes THEN
        RAISE EXCEPTION '036: notifications: la copia no coincide (filas % -> %, ids % -> %, huella % -> %)',
            antes, despues, ids_antes, ids_despues, huella_antes, huella_despues;
    END IF;
    IF EXISTS (SELECT 1 FROM ONLY core.notifications_default) THEN
        RAISE EXCEPTION '036: notifications: hay filas en la partición DEFAULT; falta una partición para su fecha';
    END IF;

    DROP TABLE core.notifications_pre036;
    RAISE NOTICE '036: core.notifications particionada (% filas copiadas).', despues;
END $$;

-- ============================================================================
-- 3. Retención por partición: configuración
--
-- La purga es de TABLA, no de tenant: una partición se elimina entera, así que no puede aplicarse
-- por tenant (core.retention_policies, 034, es por tenant y no gobierna esto). Los 90 días del
-- webhook_inbox son los del §9.3. Para notifications el ticket no fija plazo: se propone el mismo
-- (90 días); se cambia con un UPDATE de esta tabla, sin tocar código. Un NULL no existe: para
-- no purgar una tabla, se borra su fila.
-- ============================================================================
CREATE TABLE IF NOT EXISTS core.retencion_particiones (
    tabla       text PRIMARY KEY,
    retencion   interval NOT NULL,
    CONSTRAINT rp_retencion_chk CHECK (retencion >= interval '1 day')
);
COMMENT ON TABLE core.retencion_particiones IS
'KC-DB-07-3: plazo tras el cual core.purgar_particiones_vencidas() elimina (DROP) una partición. Global, no por tenant.';
REVOKE ALL ON core.retencion_particiones FROM PUBLIC, kallicode_app, kallicode_worker;
INSERT INTO core.retencion_particiones (tabla, retencion) VALUES
    ('core.webhook_inbox', interval '90 days'),
    ('core.notifications', interval '90 days')
ON CONFLICT (tabla) DO NOTHING;

-- ============================================================================
-- 4. Purga por partición
--
-- Elimina (DROP TABLE) las particiones cuyo límite superior ya cumplió el plazo: TODAS sus filas
-- son más antiguas que la retención. Nunca ejecuta DELETE. Salvaguardas:
--   * webhook_inbox: una partición con entregas 'pendiente' (sin procesar) NO se elimina; el
--     motivo queda en el resultado para que alguien las atienda. fallido/ignorado/procesado sí.
--   * Si no consigue el bloqueo en 5 s (consultas largas sobre la tabla), omite la partición y
--     lo intentará en la siguiente ejecución.
--   * La partición DEFAULT y las del mes en curso y futuras no cumplen nunca el plazo.
-- p_simular = true informa sin eliminar. Quien la ejecuta debe ser dueño de las particiones
-- (kallicode_admin: housekeeping la llama cada hora).
-- ============================================================================
CREATE OR REPLACE FUNCTION core.purgar_particiones_vencidas(p_ahora timestamptz DEFAULT now(),
                                                            p_simular boolean DEFAULT false)
RETURNS TABLE (tabla text, particion text, hasta timestamptz, filas bigint, accion text, motivo text)
LANGUAGE plpgsql
SET timezone = 'UTC' AS $$
DECLARE
    cfg record;
    part record;
    pendientes bigint;
BEGIN
    FOR cfg IN SELECT rp.tabla AS t, rp.retencion AS ret FROM core.retencion_particiones rp ORDER BY rp.tabla LOOP
        FOR part IN
            SELECT c.oid::regclass::text AS nombre,
                   (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'TO \(''([^'']+)''\)'))[1]::timestamptz AS limite
              FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
             WHERE i.inhparent = cfg.t::regclass
               AND pg_get_expr(c.relpartbound, c.oid) <> 'DEFAULT'
             ORDER BY 2
        LOOP
            CONTINUE WHEN part.limite IS NULL OR part.limite > p_ahora - cfg.ret;

            tabla := cfg.t; particion := part.nombre; hasta := part.limite;
            EXECUTE format('SELECT count(*) FROM %s', part.nombre) INTO filas;

            IF cfg.t = 'core.webhook_inbox' THEN
                EXECUTE format('SELECT count(*) FROM %s WHERE estado = ''pendiente''', part.nombre) INTO pendientes;
                IF pendientes > 0 THEN
                    accion := 'omitida';
                    motivo := format('tiene %s entregas pendientes de procesar', pendientes);
                    RETURN NEXT;
                    CONTINUE;
                END IF;
            END IF;

            IF p_simular THEN
                accion := 'simulada'; motivo := NULL;
                RETURN NEXT;
                CONTINUE;
            END IF;

            BEGIN
                SET LOCAL lock_timeout = '5s';
                EXECUTE format('DROP TABLE %s', part.nombre);
                accion := 'eliminada'; motivo := NULL;
            EXCEPTION WHEN lock_not_available THEN
                accion := 'omitida'; motivo := 'no se obtuvo el bloqueo en 5 s; se reintenta en la próxima ejecución';
            END;
            RETURN NEXT;
        END LOOP;
    END LOOP;
END $$;

COMMENT ON FUNCTION core.purgar_particiones_vencidas(timestamptz, boolean) IS
'KC-DB-07-3: elimina (DROP, nunca DELETE) las particiones cuyo plazo de core.retencion_particiones venció. No elimina particiones de webhook_inbox con entregas pendientes. Devuelve qué hizo con cada una.';
REVOKE ALL ON FUNCTION core.purgar_particiones_vencidas(timestamptz, boolean) FROM PUBLIC, kallicode_app, kallicode_worker;

-- ============================================================================
-- 5. Comprobación final: la aplicación y el worker no tienen permisos sobre las particiones
-- ============================================================================
DO $$
DECLARE
    expuestas text;
BEGIN
    SELECT string_agg(c.oid::regclass::text, ', ') INTO expuestas
      FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
     WHERE i.inhparent IN ('core.webhook_inbox'::regclass, 'core.notifications'::regclass)
       AND (has_table_privilege('kallicode_app', c.oid, 'SELECT, INSERT, UPDATE, DELETE')
            OR has_table_privilege('kallicode_worker', c.oid, 'SELECT, INSERT, UPDATE, DELETE'));
    IF expuestas IS NOT NULL THEN
        RAISE EXCEPTION '036: particiones con permisos para la aplicación o el worker (se saltarían la RLS del padre): %', expuestas;
    END IF;
END $$;

ANALYZE core.webhook_inbox;
ANALYZE core.notifications;

-- ================================================================
-- ARCHIVO: db/migrations/037_particion_vectorial_tenant.sql
-- ================================================================
-- Migración 037: Particionado LIST por tenant en colecciones vectoriales (KC-DB-08-4)

-- ============================================================================
-- 1. Particionado de vec.definition_embeddings
-- ============================================================================
ALTER TABLE vec.definition_embeddings RENAME TO definition_embeddings_old;
ALTER TABLE vec.definition_embeddings_old RENAME CONSTRAINT definition_embeddings_pkey TO definition_embeddings_old_pkey;
ALTER TABLE vec.definition_embeddings_old DROP CONSTRAINT IF EXISTS de_nodo_uq;
DROP INDEX IF EXISTS vec.definition_emb_tenant_ix;
DROP INDEX IF EXISTS vec.definition_embeddings_hnsw_ix;

CREATE TABLE vec.definition_embeddings (
    id text NOT NULL,
    tenant_id text NOT NULL,
    nodo_ref text NOT NULL,
    capa text NOT NULL,
    nombre text NOT NULL,
    descripcion text NOT NULL,
    modulo text,
    embedding vector(1024) NOT NULL,
    actualizado_en timestamptz NOT NULL DEFAULT now(),
    modelo_embedding text NOT NULL DEFAULT 'bge-m3',
    texto_hash text NOT NULL,
    CONSTRAINT definition_embeddings_pkey PRIMARY KEY (tenant_id, id),
    CONSTRAINT de_nodo_uq UNIQUE (tenant_id, nodo_ref),
    CONSTRAINT de_capa_chk CHECK (capa = ANY (ARRAY['file'::text, 'symbol'::text, 'db_table'::text, 'db_column'::text, 'definition'::text, 'concept'::text])),
    CONSTRAINT definition_embeddings_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES core.organizations(id) ON DELETE CASCADE,
    CONSTRAINT de_nodo_fk FOREIGN KEY (tenant_id, nodo_ref) REFERENCES cm.nodes(tenant_id, id) ON DELETE CASCADE
) PARTITION BY LIST (tenant_id);

CREATE TABLE vec.definition_embeddings_default PARTITION OF vec.definition_embeddings DEFAULT;

INSERT INTO vec.definition_embeddings (
    id, tenant_id, nodo_ref, capa, nombre, descripcion, modulo,
    embedding, actualizado_en, modelo_embedding, texto_hash
)
SELECT
    id, tenant_id, nodo_ref, capa, nombre, descripcion, modulo,
    embedding, actualizado_en, modelo_embedding, texto_hash
FROM vec.definition_embeddings_old;

DROP TABLE vec.definition_embeddings_old;

CREATE INDEX definition_emb_tenant_ix ON vec.definition_embeddings (tenant_id, capa, modulo);
CREATE INDEX definition_embeddings_hnsw_ix ON vec.definition_embeddings USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);

-- ============================================================================
-- 2. Particionado de vec.doc_chunks (Ingesta documental CodeMapping)
-- ============================================================================
DROP TABLE IF EXISTS vec.doc_chunks CASCADE;
DROP INDEX IF EXISTS vec.doc_chunks_tenant_ix;
DROP INDEX IF EXISTS vec.doc_chunks_hnsw_ix;

CREATE TABLE vec.doc_chunks (
    id text NOT NULL,
    tenant_id text NOT NULL,
    document_id text NOT NULL,
    chunk_index integer NOT NULL,
    content text NOT NULL,
    embedding vector(1024) NOT NULL,
    creado_en timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT doc_chunks_pkey PRIMARY KEY (tenant_id, id),
    CONSTRAINT doc_chunks_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES core.organizations(id) ON DELETE CASCADE
) PARTITION BY LIST (tenant_id);

CREATE TABLE vec.doc_chunks_default PARTITION OF vec.doc_chunks DEFAULT;

CREATE INDEX doc_chunks_tenant_ix ON vec.doc_chunks (tenant_id, document_id);
CREATE INDEX doc_chunks_hnsw_ix ON vec.doc_chunks USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);

-- ============================================================================
-- 3. Row-Level Security y Permisos
-- ============================================================================
ALTER TABLE vec.definition_embeddings ENABLE ROW LEVEL SECURITY;
ALTER TABLE vec.definition_embeddings FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON vec.definition_embeddings;
CREATE POLICY tenant_isolation ON vec.definition_embeddings FOR ALL USING (tenant_id = core.current_tenant());

ALTER TABLE vec.doc_chunks ENABLE ROW LEVEL SECURITY;
ALTER TABLE vec.doc_chunks FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON vec.doc_chunks;
CREATE POLICY tenant_isolation ON vec.doc_chunks FOR ALL USING (tenant_id = core.current_tenant());

ALTER TABLE vec.definition_embeddings OWNER TO kallicode_admin;
ALTER TABLE vec.definition_embeddings_default OWNER TO kallicode_admin;
ALTER TABLE vec.doc_chunks OWNER TO kallicode_admin;
ALTER TABLE vec.doc_chunks_default OWNER TO kallicode_admin;

GRANT ALL ON SCHEMA vec TO kallicode_admin;
GRANT ALL ON ALL TABLES IN SCHEMA vec TO kallicode_admin;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA vec TO kallicode_app, kallicode_worker;
GRANT USAGE ON SCHEMA vec TO kallicode_app, kallicode_worker;