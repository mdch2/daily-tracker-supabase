# ADR-008: edición de hábitos con vigencia semanal

- Estado: aceptada.
- Fecha y confirmación del usuario: 2026-10-23.
- Amplía ADR-007 exclusivamente para edición de nombre, frecuencia y meta.

## Decisión

El nombre es metadato editable de efecto inmediato. La frecuencia (diaria, días elegidos o X días distintos por semana) y el mínimo cuantitativo cambian desde el comienzo de la próxima semana de la cuenta. El servidor calcula esa fecha después de bloquear el hábito, con su zona IANA e inicio lunes/domingo. No se divide una semana entre configuraciones ni se reinterpreta el pasado.

Se conserva la identidad del hábito y un historial de definiciones por effective_from, único por hábito/fecha. Una definición aplicada queda inmutable. Antes de su aplicación, el cambio pendiente para la próxima semana puede sustituirse atómicamente con un token actualizado. Modalidad, unidad, zona e inicio de semana permanecen fijos; no se añaden conversiones, pausas ni archivo.

rename_habit cambia solo el nombre. edit_habit guarda nombre inmediato y configuración futura en una transacción. Ambas RPC usan identidad de operación, comprobante privado y updated_at observado; un conflicto obliga a recargar y revisar. Reintentar una operación confirmada devuelve su comprobante sin revertir cambios posteriores. Se conserva el payload original de creación para que renombrar no rompa su idempotencia.

record_habit_day selecciona la definición vigente en occurrence_date. Las correcciones conservan la ventana de hoy y siete fechas anteriores, su unidad y sus reglas históricas. Las lecturas del cliente reciben todas las versiones y resuelven la apropiada para cada fecha; los tipos provienen de PostgreSQL.

## Alternativas y consecuencias

Se descartó aplicar los cambios hoy: podría dividir un período semanal y exigir reglas de transición adicionales. Tampoco se actualiza una definición histórica. Reemplazar una versión aún futura permite revisar la intención sin crear vigencias superpuestas ni modificar registros.

El nombre actualizado se muestra también al consultar historial; no representa una nueva identidad ni modifica registros. El cliente informa la fecha programada y muestra la configuración pendiente; mantiene la actual hasta su aplicación. Si la semana cambia durante el guardado, rige la próxima semana calculada al confirmar en el servidor.

La primera entrega local no se desplegó en remoto. La lectura pasa de una definición a varias: los clientes locales deben actualizarse junto a este contrato antes de usar edición. No se autoriza despliegue remoto.

## Verificación

Migraciones incrementales 20261023000100 y 20261023000200, pgTAP con propietario, otro usuario e identidad ausente/anon; cadenas en base aislada y conservación exacta de hábito, definición y registro; concurrencia real de reintentos y ediciones obsoletas. Véase [contrato](../habit-editing.md).
