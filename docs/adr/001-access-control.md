# ADR-001: autorización privada y permisos explícitos

- Estado: aceptada.
- Fecha: 2026-10-17.

## Contexto

La migración inicial ya protege profiles mediante RLS y permisos de columnas. Sin embargo, los defaults de Supabase otorgan permisos amplios sobre objetos nuevos en public y PostgreSQL concede EXECUTE a PUBLIC en funciones nuevas. Una tabla sin RLS o una función privilegiada podrían quedar accesibles por omisión.

## Decisión

Denegar acceso por defecto y conceder solo lo necesario junto al objeto y sus políticas, en una migración versionada ejecutada como postgres. Mantener la migración transferida intacta y aplicar el refuerzo mediante 20261017000100_security_baseline.sql.

Revocar los defaults de tablas, secuencias y funciones de postgres en public/private para PUBLIC, anon, authenticated y service_role. Revocar también EXECUTE global para funciones nuevas: la revocación por esquema no puede restar un permiso global. No modificar defaults de roles internos ni permisos de extensiones existentes.

Mantener profiles privado por auth.uid(), con identidad no nula, SELECT propio y UPDATE propio limitado a display_name/time_zone; sin INSERT, DELETE ni transferencia de propietario desde clientes. Auth conserva creación y eliminación administrativa. Las funciones de trigger permanecen internas y sin ejecución cliente.

La matriz, las reglas sobre vistas/RPC y el procedimiento de verificación están en [security.md](../security.md) y [AGENTS.md](../../AGENTS.md#normas-obligatorias-de-autorización-y-rls).

## Consecuencias

- Las funciones futuras de postgres en cualquier esquema, incluidas extensiones nuevas, necesitan revisar sus grants de ejecución. Los tests conceden únicamente permisos auxiliares de pgTAP dentro de su transacción.
- Cambiar de rol creador o añadir esquemas requiere revisar otros defaults. No se habilita RLS automáticamente: cada tabla debe activarla explícitamente y los tests revisan las tablas de aplicación expuestas.
- RLS no limita roles BYPASSRLS, superusuarios ni normalmente al propietario. Las pruebas de aislamiento usan roles cliente reales y nunca service_role.
- No hay cambios de datos ni del contrato de columnas. La base existente se actualiza sin reset; las pruebas revierten sus fixtures. Las correcciones posteriores también serán incrementales.
