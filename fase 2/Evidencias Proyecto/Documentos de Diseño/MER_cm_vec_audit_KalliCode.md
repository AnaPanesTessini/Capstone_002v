# Modelo Entidad-Relación — Esquemas `cm`, `vec` y `audit` · KalliCode

**Versión de la base de datos:** `kallicode-backend`, rama `develop`, commit `f04519f` · **Fecha:** 28-10-2026 · **Responsable:** Luis Ibáñez (QA2)
**Método:** el mismo que en `MER_core_KalliCode.md`. Los diagramas se generaron desde el catálogo de una base PostgreSQL 16 construida con los scripts reales del repositorio.

Convenciones: toda tabla con `tenant_id` referencia a `core.organizations` (no se dibuja). Las FK entre tablas son compuestas `(tenant_id, x_id)`. Las entidades de otros esquemas (`core_users`, `core_tickets`, `cm_nodes`) aparecen solo como referencia.

## E. Esquema cm — Grafo de conocimiento del código (CodeMapping)

![E. Esquema cm — Grafo de conocimiento del código (CodeMapping)](img/MER_E.png)

| Tabla | Características | ¿Estaba en el MER anterior? |
|---|---|---|
| `cm.concepts` | RLS forzado | **Nueva** |
| `cm.curation_queue` | RLS forzado | **Nueva** |
| `cm.db_columns` | RLS forzado | **Nueva** |
| `cm.db_tables` | RLS forzado | **Nueva** |
| `cm.definitions` | RLS forzado | **Nueva** |
| `cm.edge_types` | sin RLS (catálogo global / técnica) | **Nueva** |
| `cm.edges` | RLS forzado | **Nueva** |
| `cm.files` | RLS forzado | **Nueva** |
| `cm.incidents` | RLS forzado | **Nueva** |
| `cm.node_types` | sin RLS (catálogo global / técnica) | **Nueva** |
| `cm.nodes` | RLS forzado | **Nueva** |
| `cm.nuggets` | RLS forzado | **Nueva** |
| `cm.repo_snapshots` | RLS forzado | **Nueva** |
| `cm.snapshot_vigente` | RLS forzado | **Nueva** |
| `cm.symbols` | RLS forzado | **Nueva** |

**Para entender este esquema:**
- `cm` guarda el **grafo de conocimiento del código del cliente**: archivos, símbolos (funciones y clases), tablas y columnas de su base de datos, definiciones y conceptos de negocio. Antes vivía en Neo4j y Qdrant; la decisión **D18** lo trasladó a PostgreSQL para tener un solo motor y el mismo aislamiento RLS.
- `repo_snapshots` es el centro: cada ingesta de un repositorio genera una foto (commit y rama), y casi todo cuelga de ella. `snapshot_vigente` apunta a la foto activa de cada tenant.
- **`cm.edges` no tiene FK hacia los nodos, y es intencional.** Es una tabla de aristas *polimórfica*: `src_kind`/`dst_kind` indican si el extremo es un archivo, símbolo, tabla, columna, definición o concepto, y un `CHECK` restringe esos valores y el `tipo` de arista (`DEFINES`, `CALLS`, `HAS_COLUMN`, `REFERENCES`, `USES_TABLE`, `REALIZED_BY`, `RELATES`, `EXPRESSES`). Es el patrón habitual para representar un grafo en una base relacional.
- `node_types` y `edge_types` son catálogos globales (iguales para todos los clientes), por eso no tienen RLS.

```mermaid
erDiagram
    cm_concepts {
        text id PK
        text tenant_id PK, FK, UK
        text name_en UK
        text name_local
        text descripcion
        numeric confianza
        text curado_por FK
        timestamptz curado_en
        text snapshot_id FK
    }
    cm_curation_queue {
        text id PK
        text tenant_id PK, FK
        text tipo
        jsonb payload
        text estado
        text revisado_por FK
        timestamptz revisado_en
        timestamptz creado_en
    }
    cm_db_columns {
        text id PK
        text tenant_id PK, FK, UK
        text table_id FK, UK
        text nombre UK
        text tipo
        boolean nullable
    }
    cm_db_tables {
        text id PK
        text tenant_id PK, FK, UK
        text esquema UK
        text nombre UK
        text snapshot_id FK
    }
    cm_definitions {
        text id PK
        text tenant_id PK, FK
        text modulo
        text nombre
        text kind
        text descripcion
        text snapshot_id FK
    }
    cm_edge_types {
        text tipo PK
        boolean es_dirigida
        text descripcion
        timestamptz creado_en
    }
    cm_edges {
        text tenant_id PK, FK
        text tipo PK
        text src_kind
        text src_id PK
        text dst_kind
        text dst_id PK
        jsonb props
        text snapshot_id FK
    }
    cm_files {
        text id PK
        text tenant_id PK, FK, UK
        text path UK
        text language
        text sha256
        text snapshot_id FK
    }
    cm_incidents {
        text id PK
        text tenant_id PK, FK
        text ticket_id FK
        text resumen
        text causa
        text correccion
        jsonb nodos_afectados
        timestamptz creado_en
    }
    cm_node_types {
        text kind PK
        text categoria
        text descripcion
        timestamptz creado_en
    }
    cm_nodes {
        text tenant_id PK, FK
        text id PK
        text kind FK
    }
    cm_nuggets {
        text id PK
        text tenant_id PK, FK
        text regla
        jsonb scope_refs
        text evidencia_ref
        text estado
    }
    cm_repo_snapshots {
        text id PK
        text tenant_id PK, FK
        text commit_sha
        text rama
        text estado
        text fase_actual
        jsonb stats
        timestamptz iniciado_en
        timestamptz finalizado_en
    }
    cm_snapshot_vigente {
        text tenant_id PK, FK
        text snapshot_id FK
        timestamptz actualizado_en
    }
    cm_symbols {
        text id PK
        text tenant_id PK, FK
        text file_id FK
        text kind
        text name
        integer start_line
        integer end_line
        text signature
        text descripcion
        text role
    }
    core_users {
        text id PK, UK
        text email UK
        text nombre
    }
    core_tickets {
        text id PK, UK
        text titulo
    }
    cm_repo_snapshots |o--o{ cm_concepts : "snapshot_id"
    core_users |o--o{ cm_concepts : "curado_por"
    core_users |o--o{ cm_curation_queue : "revisado_por"
    cm_db_tables ||--o{ cm_db_columns : "table_id"
    cm_repo_snapshots |o--o{ cm_db_tables : "snapshot_id"
    cm_repo_snapshots |o--o{ cm_definitions : "snapshot_id"
    cm_repo_snapshots |o--o{ cm_edges : "snapshot_id"
    cm_repo_snapshots ||--o{ cm_files : "snapshot_id"
    core_tickets |o--o{ cm_incidents : "ticket_id"
    cm_node_types ||--o{ cm_nodes : "kind"
    cm_repo_snapshots ||--o{ cm_snapshot_vigente : "snapshot_id"
    cm_files ||--o{ cm_symbols : "file_id"
```

## F. Esquemas vec y audit — Embeddings y cadena de auditoría

![F. Esquemas vec y audit — Embeddings y cadena de auditoría](img/MER_F.png)

| Tabla | Características | ¿Estaba en el MER anterior? |
|---|---|---|
| `audit.audit_events` | particionada, RLS forzado | Sí |
| `audit.chain_heads` | RLS forzado | Sí |
| `vec.acta_conversion_capa` | sin RLS (catálogo global / técnica) | **Nueva** |
| `vec.definition_embeddings` | particionada, RLS forzado | Sí |
| `vec.doc_chunks` | particionada, RLS forzado | Sí |
| `vec.ticket_embeddings` | RLS forzado | Sí |

**Para entender estos esquemas:**
- **`vec`** guarda los *embeddings* (vectores numéricos del significado de un texto) que usa la búsqueda semántica con pgvector: definiciones del grafo, fragmentos de documentos y tickets (para detectar duplicados). `definition_embeddings` y `doc_chunks` están particionadas por tenant.
- `vec.acta_conversion_capa` es una tabla **técnica**: registra una conversión de datos hecha por una migración. No es de negocio.
- **`audit`** es la cadena de auditoría inmutable. Cada fila de `audit_events` guarda `sello_previo` y `sello` (hash): cada evento queda encadenado al anterior, así que alterar uno rompe la cadena y se detecta. `chain_heads` guarda el último sello de cada tenant.
- **`audit_events` no tiene FK a `tickets` ni a `jobs`, y es intencional.** Un registro de auditoría debe sobrevivir aunque el objeto auditado cambie o se elimine, por eso referencia por identificador lógico y no por clave foránea. Las tablas probatorias son *append-only* (migración `025_append_only_probatorias.sql`).

```mermaid
erDiagram
    audit_audit_events {
        bigint id PK
        text tenant_id FK
        text ticket_id
        text job_id
        text etapa
        text actor_tipo
        text actor_id
        text evento
        text resumen
        jsonb datos
        text modelo
        text step_id
        text sello_previo
        text sello
        timestamptz creado_en PK
        inet ip
        text user_agent
        text request_id
        smallint version_sello
    }
    audit_chain_heads {
        text tenant_id PK, FK
        text ultimo_sello
        bigint eventos
    }
    vec_acta_conversion_capa {
        bigint id PK
        text migracion
        text capa_antigua
        text capa_nueva
        bigint filas_convertidas
        bigint filas_huerfanas
        jsonb ids_huerfanos
        timestamptz ejecutado_en
    }
    vec_definition_embeddings {
        text id PK
        text tenant_id PK, FK, UK
        text nodo_ref FK, UK
        text capa
        text nombre
        text descripcion
        text modulo
        vector embedding
        timestamptz actualizado_en
        text modelo_embedding
        text texto_hash
    }
    vec_doc_chunks {
        text id PK
        text tenant_id PK, FK
        text document_id
        integer chunk_index
        text content
        vector embedding
        timestamptz creado_en
    }
    vec_ticket_embeddings {
        text ticket_id PK, FK
        text tenant_id FK
        vector embedding
        text modelo_embedding
        text texto_hash
        timestamptz creado_en
    }
    cm_nodes {
        text tenant_id PK, FK
        text id PK
        text kind FK
    }
    core_tickets {
        text id PK, UK
        text titulo
    }
    cm_nodes ||--o{ vec_definition_embeddings : "nodo_ref"
    core_tickets ||--o{ vec_ticket_embeddings : "ticket_id"
```

## Diferencias con el MER anterior (`MER.md`)

- El MER anterior incluía 5 de estas 21 tablas (las de `vec` y `audit`) y **ninguna del esquema `cm`**. Como el esquema `cm` nace de la decisión D18, el modelo anterior no reflejaba ese cambio de arquitectura.
- Con este documento y `MER_core_KalliCode.md` quedan modeladas las **60 tablas** de la base de datos.
