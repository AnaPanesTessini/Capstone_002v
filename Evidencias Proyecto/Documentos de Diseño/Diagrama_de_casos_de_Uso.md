```mermaid.
flowchart LR
    %% Actores
    subgraph Actores["Actores del Sistema"]
        direction TB
        C["Cliente / Portal (E4)"]
        A["Agente IA (Fábrica E2 / E1)"]
        Q["Aprobador / Arquitecto (E3)"]
        ADM["Administrador (kallicode-admin)"]
    end

    %% Límite del Sistema
    subgraph KalliCode["Sistema KalliCode (SaaS Multi-Tenant)"]
        direction TB
        
        subgraph M_Ingesta["Módulo 1: Ingesta y Gestión de Tickets"]
            UC01(["UC-01: Crear / Importar Ticket (Jira/GitHub/Help)"])
            UC02(["UC-02: Consultar Estado y Consumo de Línea"])
        end

        subgraph M_Pipeline["Módulo 2: Pipeline Agéntico de 6 Etapas"]
            UC03(["UC-03: Ejecutar Triage y Consulta Vectorial CodeMapping"])
            UC04(["UC-04: Generar Especificación Técnica y Criterios BDD"])
            UC05(["UC-05: Generar Código Aislado y Abrir Pull Request"])
            UC06(["UC-06: Generar y Ejecutar Pruebas QA en Sandbox"])
            UC07(["UC-07: Ejecutar Escaneo de Seguridad SAST / SCA / Secretos"])
            UC08(["UC-08: Desplegar y Verificar Post-Deploy"])
        end

        subgraph M_Gobernanza["Módulo 3: Gobernanza y Gates Criptográficos"]
            UC09(["UC-09: Revisar Especificación y Firmar Gate 1"])
            UC10(["UC-10: Revisar Evidencias QA/Pruebas y Firmar Gate 2"])
            UC11(["UC-11: Verificar Precondiciones y Emitir Firma SHA-256 Gate 3"])
            UC12(["UC-12: Consultar y Descargar Expediente Auditoría WORM"])
        end

        subgraph M_Admin["Módulo 4: Administración y Plataforma Cross-Tenant"]
            UC13(["UC-13: Gestionar Organizaciones y Cuotas LOC"])
            UC14(["UC-14: Monitorear SLAs, Workers y Colas Redis Streams"])
            UC15(["UC-15: Auditoría Cross-Tenant en Modo Justificado"])
        end
    end

    %% Relaciones
    C --> UC01
    C --> UC02
    C --> UC09
    C --> UC12

    A --> UC03
    A --> UC04
    A --> UC05
    A --> UC06
    A --> UC07
    A --> UC08

    Q --> UC09
    Q --> UC10
    Q --> UC11
    Q --> UC12

    ADM --> UC13
    ADM --> UC14
    ADM --> UC15