# Edición de hábitos

Amplía [hábitos v1](habits-v1.md) y [ADR-007](adr/007-first-habit-delivery.md) según [ADR-008](adr/008-habit-editing.md).

- rename_habit(operation_id, habit_id, name, expected_updated_at): nombre inmediato.
- edit_habit(operation_id, habit_id, name, expected_updated_at, schedule_type, weekday_mask?, weekly_target?, target_milliunits?): nombre inmediato y configuración desde la próxima semana de la cuenta.
- Devuelven operation_id, habit_id y updated_at; edit_habit devuelve además effective_from autoritativo. El comprobante confirma la operación; no reemplaza una lectura actual.
- Se conserva modalidad/unidad/calendario. Una meta cuantitativa es positiva y usa las milésimas/rangos v1; una binaria no recibe cantidad.
- Conflicto HT008; identidad reutilizada con otro contenido HT005. Se mantienen los demás códigos seguros v1.

habit_definitions admite varias versiones únicas por (habit_id, effective_from). Las versiones aplicadas no se editan; solo la futura de la próxima semana puede reemplazarse por RPC. La FK de los registros sigue conservando la definición histórica. record_habit_day resuelve por fecha de ocurrencia bajo el mismo bloqueo de hábito.

Los clientes solo tienen SELECT propio por RLS. No hay UPDATE/INSERT/DELETE directo, transferencia de propietario ni timestamps editables. Los comprobantes y payloads de creación están en private, con RLS y sin grants de cliente. Las funciones privilegiadas fijan search_path vacío y exigen auth.uid().

Tipos generados por pnpm db:types e importados en el móvil. No se modifica una migración anterior ni se resetean datos. El cambio de lectura a múltiples definiciones requiere el cliente actualizado de esta entrega local; no se despliega en remoto.

Verificación 2026-10-23: pnpm db:test con 216 comprobaciones; cadena aislada, conservación exacta de datos y dos conexiones concurrentes para aportes, reintentos, renombres y cambios de configuración; lint SQL sin errores. La matriz y los detalles están en [security.md](security.md).
