```mermaid.
erDiagram

    %% ==========================================
    %% ESQUEMA CORE: Operación, Usuarios y Pipeline
    %% ==========================================

    core_plans {
        text codigo PK "starter | growth | enterprise"
        text nombre
        integer lineas
        integer loc_mes
        integer max_usuarios
        integer storage_mb
    }

    core_organizations {
        text id PK "org_<ulid>"
        text nombre
        text estado "activa | suspendida | eliminada"
        boolean fabrica_activa
        timestamptz creado_en
        timestamptz eliminado_en
    }

    core_subscriptions {
        text id PK "sub_<ulid>"
        text tenant_id FK "REFERENCES core_organizations(id)"
        text plan_codigo FK "REFERENCES core_plans(codigo)"
        text estado "activa | periodo_gracia | suspendida"
        date inicia_el
        date renueva_el
    }

    core_users {
        text id PK "u_<ulid>"
        text tenant_id FK "REFERENCES core_organizations(id)"
        text email
        text nombre
        text rol "owner | admin | architect | approver | member | viewer"
        text estado "activo | invitado | desactivado"
        text password_hash "Argon2id"
    }

    core_refresh_tokens {
        text id PK "rt_<ulid>"
        text tenant_id FK "REFERENCES core_organizations(id)"
        text user_id FK "REFERENCES core_users(id)"
        text token_hash "SHA-256"
        timestamptz expira_en
        boolean revocado
    }

    core_tickets {
        text id PK "tk_<ulid>"
        text tenant_id FK "REFERENCES core_organizations(id)"
        text numero "KC-#### (correlativo tenant)"
        text tipo "bug | mejora | funcionalidad | seguridad"
        text titulo
        text prioridad "alta | media | baja"
        text prioridad_pipeline "P1 | P2 | P3 | P4"
        text etapa "triage | design | build | qa | security | deploy | produccion"
        smallint gate_pendiente "1 | 2 | 3"
        text origen "portal | jira | github | kallicode_help | corestream"
        text reportado_por FK "REFERENCES core_users(id)"
        text duplicado_de FK "REFERENCES core_tickets(id)"
    }

    core_ticket_watchers {
        text ticket_id PK, FK "REFERENCES core_tickets(id)"
        text user_id PK, FK "REFERENCES core_users(id)"
        text tenant_id FK "REFERENCES core_organizations(id)"
        timestamptz creado_en
    }

    core_specs {
        text id PK "sp_<ulid>"
        text tenant_id FK "REFERENCES core_organizations(id)"
        text ticket_id FK "REFERENCES core_tickets(id)"
        integer version
        text estado "pendiente_gate1 | aprobada | reemplazada | rechazada"
        text spec_md_ref "Blob storage ref"
    }

    core_spec_alternatives {
        text spec_id PK, FK "REFERENCES core_specs(id)"
        text alt_id PK "A | B | C"
        text tenant_id FK "REFERENCES core_organizations(id)"
        text titulo
        text riesgo "bajo | medio | alto"
        boolean recomendada
        boolean elegida
    }

    core_spec_criteria {
        text spec_id PK, FK "REFERENCES core_specs(id)"
        text criterio_id PK "AC-1, AC-2..."
        text tenant_id FK "REFERENCES core_organizations(id)"
        text given_txt
        text when_txt
        text then_txt
    }

    core_production_lines {
        text tenant_id PK, FK "REFERENCES core_organizations(id)"
        integer numero PK
        text estado "disponible | ocupada | mantenimiento"
        text job_id FK "REFERENCES core_jobs(id)"
    }

    core_jobs {
        text id PK "job_<ulid>"
        text tenant_id FK "REFERENCES core_organizations(id)"
        text ticket_id FK "REFERENCES core_tickets(id)"
        text estado "pendiente_asignacion | triage | design | gate1 | build | qa | gate2 | security | deploy | produccion"
        integer linea FK
        text prioridad "P1 | P2 | P3 | P4"
    }

    core_job_transitions {
        bigint id PK
        text tenant_id FK "REFERENCES core_organizations(id)"
        text job_id FK "REFERENCES core_jobs(id)"
        text estado_anterior
        text estado_nuevo
        timestamptz creado_en
    }

    core_llm_steps {
        bigint id PK
        text tenant_id FK "REFERENCES core_organizations(id)"
        text job_id FK "REFERENCES core_jobs(id)"
        text ticket_id FK "REFERENCES core_tickets(id)"
        text etapa
        text modelo
        text tier "flash | pro | fable"
        integer tokens_in
        integer tokens_out
    }

    core_gate_signatures {
        text id PK "gs_<ulid>"
        text tenant_id FK "REFERENCES core_organizations(id)"
        text ticket_id FK "REFERENCES core_tickets(id)"
        smallint gate "1 | 2 | 3"
        text accion "aprobado | cambios_pedidos"
        text actor_id FK "REFERENCES core_users(id)"
        text spec_id FK "REFERENCES core_specs(id)"
        text sello "SHA-256 hash evento audit"
    }

    core_qa_runs {
        text id PK "qr_<ulid>"
        text tenant_id FK "REFERENCES core_organizations(id)"
        text ticket_id FK "REFERENCES core_tickets(id)"
        text spec_id FK "REFERENCES core_specs(id)"
        integer corrida
        jsonb regresion
    }

    core_qa_results {
        text qa_run_id PK, FK "REFERENCES core_qa_runs(id)"
        text criterio_id PK "AC-n de spec_criteria"
        text tenant_id FK "REFERENCES core_organizations(id)"
        text resultado "pasa | falla | flaky"
        text extracto_fallo
        jsonb evidencias
    }

    core_security_findings {
        text id PK "sf_<ulid>"
        text tenant_id FK "REFERENCES core_organizations(id)"
        text ticket_id FK "REFERENCES core_tickets(id)"
        text origen "sast | sca | secrets"
        text severidad "critica | alta | media | baja"
        text veredicto "confirmado | falso_positivo | pendiente"
        boolean bloquea
    }

    core_usage_loc {
        bigint id PK
        text tenant_id FK "REFERENCES core_organizations(id)"
        text ticket_id FK "REFERENCES core_tickets(id)"
        text ciclo "YYYY-MM"
        text tipo "pr | ajuste"
        integer anadidas
        integer eliminadas
        integer netas
    }

    core_usage_cycles {
        text tenant_id PK, FK "REFERENCES core_organizations(id)"
        text ciclo PK "YYYY-MM"
        integer loc_consumidas
        text umbral "normal | aviso_80 | agotado"
    }

    core_connections {
        text id PK "cn_<ulid>"
        text tenant_id FK "REFERENCES core_organizations(id)"
        text categoria "repositorio | tickets | cicd | database"
        text proveedor "github | jira | gitlab | postgresql..."
        text secreto_ref "Key Vault Ref"
        text estado "conectada | pendiente | error"
    }

    core_webhook_inbox {
        bigint id PK
        text tenant_id FK "REFERENCES core_organizations(id)"
        text connection_id FK "REFERENCES core_connections(id)"
        text delivery_id
        text estado "pendiente | procesado | ignorado | fallido"
    }

    %% ==========================================
    %% ESQUEMA AUDIT: Auditoría Inmutable (Append-Only)
    %% ==========================================

    audit_chain_heads {
        text tenant_id PK, FK "REFERENCES core_organizations(id)"
        text ultimo_sello "Génesis o SHA-256 actual"
        bigint eventos
    }

    audit_audit_events {
        bigint id PK
        text tenant_id FK "REFERENCES core_organizations(id)"
        text ticket_id "Referencia lógica sin FK"
        text job_id "Referencia lógica sin FK"
        text actor_tipo "humano | agente | sistema"
        text actor_id
        text evento "gate_firmado, spec_generada..."
        text resumen
        jsonb datos
        text sello_previo
        text sello "SHA-256(prev || tenant || ev || payload)"
    }

    %% ==========================================
    %% ESQUEMA VEC: Ingesta Vectorial (pgvector)
    %% ==========================================

    vec_ticket_embeddings {
        text ticket_id PK, FK "REFERENCES core_tickets(id)"
        text tenant_id FK "REFERENCES core_organizations(id)"
        vector_1024 embedding "BGE-M3 HNSW"
        text texto_hash
    }

    vec_doc_chunks {
        bigint id PK
        text tenant_id FK "REFERENCES core_organizations(id)"
        text documento_id FK "REFERENCES onboarding_documents(id)"
        integer chunk_idx
        text contenido
        vector_1024 embedding "BGE-M3 HNSW"
    }

    vec_definition_embeddings {
        text id PK "de_<ulid>"
        text tenant_id FK "REFERENCES core_organizations(id)"
        text nodo_ref "Neo4j / Grafo Ref"
        text capa "definicion | negocio | codigo"
        vector_1024 embedding "BGE-M3 HNSW"
    }

    %% ==========================================
    %% RELACIONES Y CARDINALIDADES
    %% ==========================================

    core_plans ||--o{ core_subscriptions : "define_cuotas"
    core_organizations ||--o{ core_subscriptions : "posee"
    core_organizations ||--o{ core_users : "pertenecen"
    core_organizations ||--o{ core_tickets : "registra"
    core_organizations ||--o{ core_connections : "integra"
    core_organizations ||--|| core_production_lines : "asigna_lineas"
    core_organizations ||--|| audit_chain_heads : "mantiene_cabeza"

    core_users ||--o{ core_refresh_tokens : "emite"
    core_users ||--o{ core_tickets : "reporta"
    core_users ||--o{ core_gate_signatures : "firma"

    core_tickets ||--o{ core_specs : "versiona"
    core_tickets ||--o{ core_jobs : "ejecuta_pipeline"
    core_tickets ||--o{ core_gate_signatures : "exige_gates"
    core_tickets ||--o{ core_qa_runs : "verifica_qa"
    core_tickets ||--o{ core_security_findings : "escanea"
    core_tickets ||--|| vec_ticket_embeddings : "deduplica_vectorial"
    core_tickets ||--o{ core_ticket_watchers : "suscrito"
    core_users ||--o{ core_ticket_watchers : "notificado"

    core_specs ||--o{ core_spec_alternatives : "propone"
    core_specs ||--o{ core_spec_criteria : "exige_criterios"

    core_jobs ||--o{ core_job_transitions : "registra_transicion"
    core_jobs ||--o{ core_llm_steps : "traza_llm"

    core_qa_runs ||--o{ core_qa_results : "detalla_matriz"
    core_connections ||--o{ core_webhook_inbox : "recibe_eventos"

    core_tickets ||--o{ core_usage_loc : "descuenta_loc"
    core_organizations ||--o{ core_usage_cycles : "acumula_mensual"
    core_organizations ||--o{ audit_audit_events : "sella_auditoria"
    core_organizations ||--o{ vec_doc_chunks : "indexa_documentos"
    core_organizations ||--o{ vec_definition_embeddings : "mapea_grafo"