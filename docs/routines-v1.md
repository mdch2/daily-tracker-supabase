# Rutinas v1: contrato implementado

Fecha: 2026-10-27. Migración incremental `20261027000100_routines.sql`, aplicada localmente sin reset ni cambios remotos. Implementa únicamente Rutinas. Metas personales sigue en diseño.

## Reglas

Rutinas agrupa 1–30 pasos propios binarios o hábitos existentes, al menos uno obligatorio y sin repetir un hábito dentro de una definición. Nombre y etiquetas propias de 1–100 caracteres recortados. El orden es orientativo. Frecuencia diaria o por días concretos, sin objetivo semanal flexible propio. Inicio hoy según servidor y calendario confirmado.

Los obligatorios elegibles determinan el cumplimiento; opcionales y hábitos semanales flexibles no crean obligaciones diarias. Un día sin obligatorios elegibles no se considera completado automáticamente. La evaluación de vínculos usa las reglas y definiciones históricas de Hábitos; no hay contadores o marcas independientes de rutina completada.

Registro y corrección de pasos propios solo hoy. Un paso vinculado llama al escritor existente de Hábitos y nunca crea una copia de su estado. Las correcciones históricas permitidas en Hábitos se reflejan al evaluar las rutinas correspondientes.

Nombre inmediato; pasos/programación desde la próxima semana de cuenta. Versiones aplicadas y registros permanecen. Archivar bloquea escrituras propias y edición, excluye fechas posteriores al archivo y conserva la consulta del historial. No hay restauración ni borrado definitivo.

## Persistencia

Se crean `routines`, `routine_definitions`, `routine_steps`, `routine_definition_steps` y `routine_step_day_records`. Sus claves compuestas preservan propietario, rutina, definición y paso. La FK al hábito verifica también pertenencia. Los registros propios tienen PK paso/fecha, revisión y booleano no nulo; ausencia difiere de false.

Las definiciones son únicas por rutina/fecha efectiva. Las membresías tienen orden único, consecutivo, 1–30 pasos y obligatoriedad validada con restricciones diferibles. Se comprueba que solo pasos propios tengan título propio y que no se repita un hábito. Un trigger de registros exige tipo propio y definición/programación histórica aplicables.

La única tabla privada nueva es `routine_operations`, que conserva identidad, petición normalizada y resultado original de creación, edición, archivo y registro. Sustituye las dos tablas propuestas inicialmente por una sola responsabilidad real. No es un historial que se sume para calcular cumplimiento.

## RPC y lecturas

- `create_routine(id,name,schedule_type,steps,weekday_mask?)`: devuelve UUID confirmado. Los pasos reciben `id`, `kind` (own/habit), `title` o `habit_id` y `required`. La posición procede del orden del array. Definiciones con identidad generada en servidor; creación y comprobante son atómicos.
- `edit_routine(operation_id,routine_id,name,expected_updated_at,schedule_type?,steps?,weekday_mask?)`: sin configuración, nombre inmediato; con configuración, reemplaza/crea solo la versión futura de próxima semana. Devuelve operación, rutina, updated_at y effective_from nullable.
- `archive_routine(operation_id,routine_id,expected_updated_at)`: conserva registros, devuelve comprobante y bloquea nuevas escrituras.
- `record_routine_step(operation_id,routine_id,step_id,occurrence_date,completed,expected_revision)`: acepta solo pasos propios de hoy, con revisión observada (0 para ausencia); devuelve identidad, fecha, booleano y revisión original.
- `get_routines(ids?,offset=0,archived=false)`: invocadora, devuelve hasta 20 identidades con todas sus definiciones/membresías en JSON y has_more. IDs concretos permiten consultar detalle archivado. Se exige identidad autenticada, offset válido y hasta 20 IDs.
- Los estados propios se leen con SELECT bajo RLS y rangos limitados en el adaptador. El historial consulta una rutina y hasta 28 fechas (máximo 840 estados). La vista diaria agrupa hasta 10 rutinas por consulta.

No se crea get_routine_window: el móvil compone contratos de Rutinas y Hábitos, sin imports de adaptadores entre features. Esa composición no promete una instantánea global entre llamadas independientes y no publica lecturas parciales tras un fallo. No se define ni modifica ningún contrato de Metas.

## Concurrencia y errores

Identidad de operación bloqueada mediante advisory lock por usuario/UUID, comprobante reconocido antes de validar de nuevo la ventana de aceptación, referencias a hábitos bloqueadas en orden estable y después padre de rutina. Registro propio y archivo solo necesitan el padre; Hábitos no bloquea dependencias derivadas. No hay transacción distribuida entre pasos.

Una operación repetida devuelve el resultado original sin aplicar otra escritura, incluso tras archivo. Cambiar payload con la misma identidad falla. Dos sustituciones sobre la misma revisión no ganan ambas. Edición/archivo usan timestamp observado y generan un token estrictamente posterior al anterior. Tras esperas se vuelve a comprobar la fecha; un cruce de fecha durante creación/edición se rechaza para revisar.

SQLSTATE seguros: RT001 identidad ausente; RT002 calendario pendiente; RT003 entrada inválida; RT004 recurso no disponible; RT005 operación reutilizada; RT006 fuera de ventana; RT007 fecha/paso no elegible; RT008 conflicto; RT009 archivado; RT011 flexible solo opcional; RT012 sin solapamiento obligatorio. El móvil los traduce en es/en; no muestra mensajes internos.

## Autorización

RLS activada en las cinco tablas públicas y el comprobante privado. Solo authenticated recibe SELECT propio sobre las públicas; sin INSERT/UPDATE/DELETE directo, transferencia de propietario ni timestamps cliente. PUBLIC, anon y service_role no reciben grants nuevos. FKs y RPC impiden vínculos privados cruzados.

Las cuatro escrituras son SECURITY DEFINER por la ausencia deliberada de DML cliente, con search_path vacío y autorización explícita por auth.uid. La lectura get_routines es SECURITY INVOKER y usa RLS. Helpers privados sin EXECUTE cliente. No se confía en user_id enviado ni en metadatos editables.

## Verificación

- `pnpm db:test`: 301 comprobaciones pgTAP en seis archivos, incluidas 85 nuevas de Rutinas, correctas sobre PostgreSQL local con roles cliente A/B/anon e identidad ausente.
- `pnpm db:test:routines:isolated`: mismo runner que la cadena aislada de Hábitos, ahora extendido con Rutinas. Reproduce todas las migraciones de aplicación, conserva perfil/hábito/definición/registro previo y ejecuta pgTAP; usa una tabla Auth mínima sintética y auth.uid real, sin reemplazar la prueba del servicio Auth.
- Dos conexiones reales verifican creación y registro duplicados, revisiones/configuraciones obsoletas, edición simultánea con registro y archivo repetido. Se conserva el estado vigente al reintentar un comprobante anterior.
- Lint SQL local: sin problemas en Rutinas; persiste un warning previo de variable no usada en create_habit.
- Tipos generados desde PostgreSQL y entregados al móvil. Sin snapshots manuales ni despliegues remotos.

Los fixtures pgTAP se revierten y la base de reproducción es temporal, con identificador generado/validado por el runner y eliminación exclusiva de esa base al terminar. No se resetea la instancia de trabajo. Las pruebas del backend no sustituyen revisión visual ni validación nativa.
