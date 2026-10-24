```mermaid.
flowchart TD
    %% Inicio
    Start([🟢 Inicio: Ingesta de Ticket]) --> Triage[Stage 1: Triage Agéntico & CodeMapping]

    %% Stage 1: Triage
    Triage --> Triage_Check{¿Es duplicado o inválido?}
    Triage_Check -- Sí --> Triage_Close[Cerrar Ticket & Notificar Cliente] --> End_Closed([🔴 Fin: Ticket Descartado])
    Triage_Check -- No --> Design[Stage 2: Design & Especificación BDD]

    %% Stage 2: Design
    Design --> Spec_Gen[Generar Markdown + Criterios Given-When-Then]
    Spec_Gen --> Gate1{Gobernanza humana: Gate 1\nAprobación de Spec}

    %% Gate 1
    Gate1 -- Cambios Pedidos / Rechazado --> Spec_Fix[Revisar Requerimiento / Ajustar Spec] --> Design
    Gate1 -- Aprobado & Firmado --> Build[Stage 3: Build Agéntico]

    %% Stage 3: Build
    Build --> Code_Gen[Generar Código en Sandbox + Diffs Atómicos]
    Code_Gen --> Open_PR[Abrir Pull Request en Repositorio]
    Open_PR --> QA[Stage 4: QA & Automated Testing]

    %% Stage 4: QA
    QA --> QA_Exec[Sintetizar y Ejecutar Pruebas Playwright/pytest]
    QA_Exec --> QA_Check{¿Pruebas 100% Exitosas?}
    QA_Check -- Falla --> Auto_Repair[Agente de Inferencia: Auto-Reparación de Código]
    Auto_Repair --> Repair_Check{¿Max 3 Reintentos?}
    Repair_Check -- Sí --> Code_Gen
    Repair_Check -- No --> Escalation_Human[Escalar a Desarrollador Humano] --> End_Manual([🟠 Fin: Intervención Manual Required])

    QA_Check -- Pasa --> Gate2{Gobernanza humana: Gate 2\nAprobación Evidencias QA}

    %% Gate 2
    Gate2 -- Rechazado --> Build
    Gate2 -- Aprobado & Firmado --> Security[Stage 5: Security Scan]

    %% Stage 5: Security
    Security --> Sec_Scan[Ejecutar SAST + SCA + Detección Secretos]
    Sec_Scan --> Sec_Check{¿Hallazgos Críticos/Altos?}
    Sec_Check -- Sí --> Sec_Fix[Agente SecOps: Aplicar Remedación Atómica] --> Security
    Sec_Check -- No --> Gate3{Gobernanza humana: Gate 3\nFirma Criptográfica Arquitecto}

    %% Gate 3
    Gate3 -- Rechazado --> Escalation_Human
    Gate3 -- Aprobado SHA-256 --> Deploy[Stage 6: Deploy & Post-Verification]

    %% Stage 6: Deploy
    Deploy --> Merge_PR[Merge de PR & Despliegue Automatizado]
    Merge_PR --> Post_Check{¿Verificación Smoke Test OK?}
    Post_Check -- Falla --> Rollback[Ejecutar Rollback Automático] --> Escalation_Human
    Post_Check -- OK --> Close_Success[Sellar Expediente en Auditoría WORM & Cerrar Ticket]
    Close_Success --> End_OK([🟢 Fin: Entregado en Producción])