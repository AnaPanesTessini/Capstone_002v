# Diagrama de Clases — KalliCode (implementación)

**Versión:** `kallicode-backend`, rama `develop`, commit `f04519f` · **Fecha:** 28-10-2026 · **Responsable:** Luis Ibáñez (QA2)
**Método:** las clases, atributos, métodos y herencias se extrajeron analizando el código fuente con el módulo `ast` de Python (sin ejecutarlo). Solo se dibujan las relaciones confirmadas en el código: herencia declarada, tipos de atributos y de retorno, e imports.

## 1. Lo primero: cómo está construido el backend

El backend **no usa un ORM**: no hay modelos SQLAlchemy ni clases de dominio como `Ticket` o `Job` con métodos propios. La arquitectura es **funcional por capas**:

```
 Petición HTTP
      │
      ▼
 routers/ (15)  ── funciones FastAPI por recurso; validan entrada con DTOs Pydantic
      │
      ▼
 servicios/ + kallicode_core ── lógica compartida: seguridad, sesión con RLS, LLM, auditoría
      │
      ▼
 SQL directo (asyncpg) ── la base de datos aplica las reglas: RLS, CHECK, triggers
                          (correlativo KC-####, historial de estados, sello de auditoría)
```

Las clases que existen son de **infraestructura**: configuración, contratos de datos (DTOs), clientes de servicios externos, enums y errores. Las **reglas de negocio** viven en los routers, en las funciones de `kallicode_core` y en la propia base de datos (restricciones y triggers). Por eso el modelo de datos está en el MER y aquí se muestra la estructura de clases del código.

**Inventario:** 95 clases en el código de producción (sin pruebas).

| Paquete | Clases | Qué son |
|---|---:|---|
| `apps/api` | 55 | 51 DTOs Pydantic de entrada/salida (7 en `esquemas/interna.py` + 44 en los routers), 2 clases de contexto de petición y 2 middlewares |
| `packages/core` | 20 | Configuración, errores, claims JWT, enums del pipeline y del LLM, contrato del grafo, migraciones, log |
| `packages/codemapping` | 14 | Ingesta del grafo: cargador, snapshots, parser, embeddings, bóveda |
| `packages/testing` | 4 | Utilidades de QA: bóveda local, almacenamiento Azurite, stub LLM |
| `apps/workers` | 2 | Cliente de la API interna y decisión del orquestador |

## 2. Diagramas

### 2.1 Núcleo compartido (`packages/core`)

![Núcleo](img/Clases_1_core.png)

Lo más relevante:
- **`EstadoJob`** es la máquina de estados del pipeline: 16 estados, incluidos los tres gates humanos (`GATE1`, `GATE2`, `GATE3`) y los estados de excepción (`PAUSADO_POR_CUOTA`, `ESCALADO_HUMANO`).
- **`Tier`** (flash → pro → fable) son los tres niveles de modelo LLM. `ResultadoPaso` registra cada llamada: tokens, duración, confianza y validación.
- **`GrafoCliente`** es un `Protocol`, una interfaz: define *qué* debe ofrecer el grafo sin atarse a una implementación. `GrafoClienteDoble` es su **doble de prueba**, que aplica la regla de desbloqueo del Plan de Programa (§9.3): trabajar contra el contrato mientras otro equipo implementa.
- **`ClaimsUsuario`** y **`ClaimsServicio`** son el contenido de los JWT, con un token distinto para personas y para servicios internos.

```mermaid
classDiagram
    direction TB
    namespace kallicode_core {
        class Settings {
            <<BaseSettings>>
            +str env
            +str database_url
            +str redis_url
            +str blob_account_url
            +str jwt_private_key
            +str jwt_public_key
            +validar_base_de_datos()
        }
        class AppError {
            +codigo
            +http
            +mensaje
            +detalle
        }
        class ClaimsUsuario {
            <<BaseModel>>
            +str sub
            +str org
            +str rol
            +str jti
            +str typ
            +int iat
            +bool restringido
        }
        class ClaimsServicio {
            <<BaseModel>>
            +str sub
            +str org
            +str svc
            +str jti
            +str typ
            +int iat
            +int line
        }
        class EstadoJob {
            <<StrEnum>>
            PENDIENTE_ASIGNACION
            TRIAGE
            DESIGN
            GATE1
            BUILD
            QA
            GATE2
            SECURITY
            DEPLOY_PREFLIGHT
            GATE3
            DEPLOY
            PRODUCCION
            PAUSADO_POR_CUOTA
            ESCALADO_HUMANO
            CANCELADO
            CERRADO_DUPLICADO
        }
        class Tier {
            <<StrEnum>>
            FLASH
            PRO
            FABLE
        }
        class ConfigTier {
            <<dataclass>>
            +Tier tier
            +str modelo
            +str base_url
            +str protocolo
            +int max_tokens_salida
        }
        class ResultadoPaso {
            <<dataclass>>
            +str paso_id
            +Tier tier
            +str modelo
            +dict salida
            +float confianza
            +str validacion
            +int tokens_in
            +int tokens_out
            +int duracion_ms
        }
        class LLMEscaladoHumano {
            +paso_id
            +motivo
            +intentos
        }
        class GrafoCliente {
            <<Protocol>>
            +subgrafo_ticket(tenant_id, ticket_id) Subgrafo
            +impacto(tenant_id, nodo_ref, k) Impacto
            +inventario_ui(tenant_id)
        }
        class GrafoClienteDoble {
            +registrar_subgrafo(ticket_id, subgrafo)
            +registrar_impacto(nodo_ref, impacto)
        }
        class Subgrafo {
            <<dataclass>>
            +tuple nodos
            +tuple aristas
            +esta_vacio() bool
        }
        class Impacto {
            <<dataclass>>
            +int radio
            +str riesgo
            +tuple modulos
            +tuple tablas
            +esta_vacio() bool
        }
        class Migracion {
            <<dataclass>>
            +str archivo
            +str sql
            +str sha256
            +bool sin_transaccion
        }
        class Resultado {
            <<dataclass>>
            +list aplicadas
            +list adoptadas
        }
        class MigracionError
        class Log {
            +debug(evento)
            +info(evento)
            +warning(evento)
            +error(evento, exc_info)
            +critical(evento, exc_info)
        }
    }
    Exception <|-- AppError
    Exception <|-- LLMEscaladoHumano
    Exception <|-- MigracionError
    GrafoClienteDoble ..|> GrafoCliente : implementa (doble de prueba)
    GrafoCliente ..> Subgrafo : retorna
    GrafoCliente ..> Impacto : retorna
    ConfigTier --> Tier
    ResultadoPaso --> Tier

```

### 2.2 API y workers (`apps/api`, `apps/workers`)

![API y workers](img/Clases_2_api_workers.png)

- **`UsuarioActual`** y **`ServicioActual`** representan *quién* hace la petición. Se construyen a partir de los claims del JWT y llevan el `tenant_id` con que se abre la sesión RLS.
- **`ModeloInterno`** es la base de los contratos de la API interna `/internal/v1`, la que usan los agentes del pipeline. `CriterioResultadoIn` **compone** una lista de `EvidenciaRefIn`: cada resultado de un criterio de aceptación lleva sus evidencias.
- **`ClienteInterno`** es el cliente que usa el orquestador para mover un job entre estados. **`Decision`** es la salida de la política del orquestador: avanzar, reintentar o escalar a un humano.
- No se dibujan los middlewares de seguridad (`CabecerasSeguridadMiddleware`, `LimiteCuerpoMiddleware`) ni los 44 DTOs de los routers. Se listan en la sección 3.

```mermaid
classDiagram
    direction LR
    namespace kallicode_api {
        class UsuarioActual {
            <<dataclass>>
            +str user_id
            +str tenant_id
            +str rol
            +bool restringido
            +actor()
        }
        class ServicioActual {
            <<dataclass>>
            +str servicio
            +str tenant_id
            +int linea
            +actor()
        }
        class ModeloInterno {
            <<BaseModel>>
        }
        class EvidenciaRefIn {
            +str tipo
            +str blob_ref
        }
        class CriterioResultadoIn {
            +str criterio_id
            +str resultado
            +str extracto_fallo
            +list~EvidenciaRefIn~ evidencias
            +validar_extracto_en_fallo()
        }
        class VeredictoVisualIn {
            +str criterio_id
            +str veredicto
            +str observado
            +str region
        }
        class PlanTestIn {
            +str nombre
            +str tipo
            +str comando
            +list criterios
        }
        class MigracionIn {
            +str archivo
            +str descripcion
            +str rollback
        }
        class TicketProactivoIn {
            +str titulo
            +str cuerpo
        }
    }
    namespace kallicode_workers {
        class ClienteInterno {
            -_base
            -_servicio
            -_http
            +transicionar()
            +publicar_paso()
            +publicar_triage()
            +escalar()
            +cerrar()
        }
        class Decision {
            <<dataclass frozen>>
            +accion avanzar|reintentar|escalar
            +str motivo
            +str severidad
        }
    }
    class ClaimsUsuario {
        <<kallicode_core>>
    }
    class ClaimsServicio {
        <<kallicode_core>>
    }
    ModeloInterno <|-- EvidenciaRefIn
    ModeloInterno <|-- CriterioResultadoIn
    ModeloInterno <|-- VeredictoVisualIn
    ModeloInterno <|-- PlanTestIn
    ModeloInterno <|-- MigracionIn
    ModeloInterno <|-- TicketProactivoIn
    CriterioResultadoIn *-- EvidenciaRefIn
    UsuarioActual ..> ClaimsUsuario : usa
    ServicioActual ..> ClaimsServicio : usa

```

### 2.3 CodeMapping y utilidades de pruebas (`packages/codemapping`, `packages/testing`)

![CodeMapping y testing](img/Clases_3_codemapping_testing.png)

- **`GraphLoader`** y **`SnapshotManager`** cargan el grafo del código del cliente en el esquema `cm`, una foto (*snapshot*) por cada ingesta. Esto conecta con `cm.repo_snapshots` del MER.
- **`ResolvedorBovedaCliente`** obtiene las credenciales del cliente desde la bóveda y las entrega como `SecretStr`, que no se imprimen en los logs.
- En `kallicode_testing`, **`LocalKeyVaultMock`** (cifrado AES-GCM), **`QAStorageClient`** (Azurite) y **`LLMStub`** son los dobles que permiten probar sin nube. Son los mismos que ejercitan los casos de prueba CP-06, CP-15 y CP-13.

```mermaid
classDiagram
    direction LR
    namespace kallicode_codemapping {
        class CMSettings {
            <<BaseSettings>>
            +str tenant_id
            +str repo_url
            +str store_database_url
            +str tei_endpoint_url
            +list exclude_dirs
            +int max_file_bytes
            +client_id()
        }
        class GraphLoader {
            +dsn
            +tenant_id
            +start_snapshot(commit_sha, rama)
            +find_resumable_snapshot(commit_sha)
            +marcar_fase(snapshot_id, fase_actual)
            +load_files(snapshot_id, files)
            +complete_snapshot(snapshot_id, estado, motivo)
            +close()
        }
        class SnapshotManager {
            +dsn
            +tenant_id
            +obtener_o_crear_snapshot(commit_sha, rama, trace_id)
            +registrar_evento(snapshot_id, trace_id, fase)
            +registrar_checkpoint(snapshot_id, fase, stats_fase)
            +marcar_completado(snapshot_id, total_stats, trace_id)
            +marcar_fallido(snapshot_id, error_msg, fase)
        }
        class Symbol {
            <<dataclass>>
            +str id
            +str file
            +str language
            +str kind
            +str name
            +int start_line
            +int end_line
            +str signature
            +list calls
            +list imports
        }
        class CurationItem {
            <<dataclass>>
            +str id
            +str tenant_id
            +str snapshot_id
            +str tipo
            +float confianza
            +str estado
            +to_payload()
            +to_row()
        }
        class TEIEmbeddingClient {
            +base_url
            +timeout
            +embed_texts(texts)
            +embed_texts_sync(texts)
        }
        class ResolvedorBovedaCliente {
            +resolver_conexion(tenant_id, connection_id, db_session)
        }
        class CredencialesConexion {
            <<BaseModel>>
            +str tenant_id
            +str connection_id
            +SecretStr repo_url_segura
            +SecretStr db_url_segura
        }
        class EstimacionPresupuesto {
            <<dataclass>>
            +int total_tokens_estimados
            +float costo_usd_estimado
            +int cuota_disponible
            +bool presupuesto_suficiente
        }
        class BudgetExceededError
        class SchemaExtractionTimeout
    }
    namespace kallicode_testing {
        class LocalKeyVaultMock {
            -_aesgcm
            -_store_path
            +set_secret(secret_name, secret_value)
            +get_secret(secret_name)
            +purge_vault()
        }
        class QAStorageClient {
            +client
            +initialize_buckets()
            +upload_file(bucket_name, blob_name, data)
            +download_file(bucket_name, blob_name)
            +close()
        }
        class LLMStub {
            +generate_test_code(prompt, model, simulate_error)
        }
        class SuiteResult {
            <<TypedDict>>
            +int passed
            +int failed
            +float duration_ms
        }
    }
    ResolvedorBovedaCliente ..> CredencialesConexion : retorna
    RuntimeError <|-- BudgetExceededError
    Exception <|-- SchemaExtractionTimeout

```

## 3. Contratos de la API (DTOs Pydantic en los routers)

| Router | DTOs |
|---|---|
| `auth` | LoginIn, TokensOut, RefreshIn, LogoutIn, ForgotIn, ResetIn, AcceptIn |
| `internal` | JobIn, AssignIn, StateIn, StepIn, TriageResultIn, AlternativaIn, CriterioSpecIn, SpecIn, EvidenciaIn, HallazgoIn, FindingsIn, PreflightIn, DeployResultIn, LocIn, EscalationIn, DlqReprocesarIn |
| `tickets` | TicketIn, CriterioIn, FeatureIn, PreviewIn, TicketPatch, AdjuntoIn, WatcherIn |
| `connections` | ConexionIn, ConexionPatch, BranchMapIn, DocIn |
| `users` | MePatch, InviteIn, UserPatch |
| `gates` | FirmaIn, CambiosIn |
| `audit` · `curation` · `notifications` · `organization` · `plans` | ExportIn · CuracionDecisionIn · LeidaIn · OrgPatch · UpgradeIn |

## 4. Relación con el diagrama de clases anterior (`Diagrama_de_Clases.md`)

El diagrama anterior muestra 10 clases de dominio (`Organization`, `User`, `Ticket`, `Spec`, `Job`…) con 16 métodos. Se contrastaron con el código:

- **Las 10 clases corresponden a tablas reales** de la base (ver MER), así que el modelo de datos que representan es correcto.
- **15 de los 16 métodos no existen en el código** (`avanzar_etapa`, `aprobar_spec`, `firmar_digitalmente`, `generar_jwt_pair`, `verificar_cuota_loc`…). Solo `transicionar` existe, y está en `ClienteInterno`, no en una clase `Job`.

**Recomendación:** mantener ese diagrama, pero **renombrarlo como "Modelo de dominio (conceptual)"** y aclarar que sus operaciones describen *qué* hace el sistema, no *dónde* está el código. Este documento queda como diagrama de clases **de implementación**. Así ambos son correctos y ninguno se contradice con el repositorio.

## 5. Hallazgo detectado durante el análisis

| ID | Hallazgo | Ubicación | Impacto |
|---|---|---|---|
| H-06 | El archivo de inicialización del paquete del orquestador está mal nombrado: `__init_.py` (un guion bajo final) en lugar de `__init__.py` | `apps/workers/src/kallicode_workers/orquestador/__init_.py` | Python no lo ejecuta como inicializador del paquete, así que sus exportaciones (`__all__ = ["ClienteInterno", "Decision", "ciclo", "decidir"]`) no se cargan; el paquete funciona solo como *namespace package*. Corresponde reportarlo al equipo dueño del orquestador (E2) |
