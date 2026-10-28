# ADR-009: Rutinas v1

- Estado: aceptada e implementada localmente.
- Fecha: 2026-10-27.
- Alcance: únicamente Rutinas.

La autorización del usuario confirma implementar Rutinas según las reglas acordadas y sus referencias visuales. Se adopta el [contrato v1](../routines-v1.md), que concreta el [plan de datos](../routines-goals-plan.md). Metas personales conserva su estado de propuesta y no recibe tablas, funciones o permisos.

Se separan identidad, definición temporal, identidad estable de paso, membresía de versión y estado diario propio. Los hábitos vinculados conservan sus registros y operaciones de origen. Un único comprobante privado cubre las operaciones de Rutinas; se descarta crear dos almacenes equivalentes. El móvil combina las lecturas de ambos contratos y evalúa mediante sus reglas públicas, sin una escritura independiente de cumplimiento agregado.

Las escrituras están cerradas a DML directo y se aceptan solo por RPC autorizadas, atómicas, idempotentes y con control de concurrencia. RLS y FKs compuestas protegen propiedad y relaciones; no hay cascadas destructivas. El esquema y las pruebas viven exclusivamente aquí.

La migración es aditiva y local. Se conserva historia de hábitos/perfiles y compatibilidad de sus contratos; no se resetean datos ni se despliega remotamente. El contrato v1 registra evidencia real de pgTAP, reproducción, concurrencia y generación de tipos.
