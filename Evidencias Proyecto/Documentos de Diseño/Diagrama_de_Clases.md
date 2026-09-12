```mermaid.
classDiagram

    class Organization {
        +text id
        +text nombre
        +boolean fabrica_activa
        +timestamptz creado_en
        +crear_linea_produccion()
        +verificar_cuota_loc()
    }

    class User {
        +text id
        +text tenant_id
        +text email
        +text rol
        +text password_hash
        +autenticar(password)
        +generar_jwt_pair()
    }

    class Ticket {
        +text id
        +text tenant_id
        +text numero
        +text tipo
        +text etapa
        +smallint gate_pendiente
        +text prioridad_pipeline
        +avanzar_etapa(nueva_etapa)
        +bloquear_en_gate(gate_num)
    }

    class Spec {
        +text id
        +text tenant_id
        +text ticket_id
        +integer version
        +text estado
        +text spec_md_ref
        +aprobar_spec()
        +rechazar_spec()
    }

    class SpecCriterion {
        +text spec_id
        +text criterio_id
        +text given_txt
        +text when_txt
        +text then_txt
        +evaluar_cumplimiento()
    }

    class Job {
        +text id
        +text tenant_id
        +text ticket_id
        +text estado
        +integer linea
        +asignar_linea(num_linea)
        +transicionar(nuevo_estado)
    }

    class GateSignature {
        +text id
        +text tenant_id
        +text ticket_id
        +smallint gate
        +text accion
        +text actor_id
        +text sello_sha256
        +firmar_digitalmente(actor_id, hash_evidencia)
    }

    class QARun {
        +text id
        +text tenant_id
        +text ticket_id
        +integer corrida
        +jsonb regresion
        +ejecutar_en_sandbox()
        +obtener_evidencias_blob()
    }

    class SecurityFinding {
        +text id
        +text tenant_id
        +text ticket_id
        +text origen
        +text severidad
        +boolean bloquea
        +evaluar_bloqueo_deploy()
    }

    class AuditEvent {
        +bigint id
        +text tenant_id
        +text actor_id
        +text evento
        +text sello_previo
        +text sello
        +calcular_sha256_cadena()
        +verificar_integridad_sello()
    }

    %% Relaciones
    Organization "1" -- "0..*" User : posee
    Organization "1" -- "0..*" Ticket : registra
    User "1" -- "0..*" Ticket : reporta
    Ticket "1" -- "0..*" Spec : versiona
    Spec "1" -- "1..*" SpecCriterion : contiene
    Ticket "1" -- "1" Job : ejecuta
    Ticket "1" -- "0..3" GateSignature : exige
    Ticket "1" -- "0..*" QARun : verifica
    Ticket "1" -- "0..*" SecurityFinding : escanea
    Organization "1" -- "0..*" AuditEvent : sella
    User "1" -- "0..*" GateSignature : autoriza