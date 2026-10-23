# Modelo de datos

## Esquema implementado

La migración inicial define public.profiles para la API y la migración incremental de seguridad refuerza sus permisos. Ambas pertenecen exclusivamente a este repositorio. No se crean tablas de funcionalidades todavía inexistentes.

| Columna                 | Contrato                                                                                              |
| ----------------------- | ----------------------------------------------------------------------------------------------------- |
| id                      | UUID, PK y FK a auth.users(id). El trigger Auth crea el perfil.                                       |
| display_name            | Texto opcional; entre 1 y 100 caracteres recortados cuando existe.                                    |
| time_zone               | Texto opcional validado contra pg_timezone_names al actualizar; ninguna zona de producto por defecto. |
| created_at / updated_at | timestamptz, definidos por servidor; cliente sin permiso para escribirlos.                            |

El índice de PK cubre búsquedas y políticas por propietario; no hacen falta índices duplicados.
Solo authenticated tiene SELECT y UPDATE de display_name/time_zone. RLS limita ambas operaciones a auth.uid() = id.
La matriz y las normas obligatorias se documentan en [security.md](security.md). No hay INSERT ni DELETE de cliente. La eliminación administrativa de una cuenta elimina explícitamente su perfil por FK; no se define todavía borrado en cascada de datos de negocio.
El trigger ignora user_metadata para no convertir contenido editable en un dato confiable de autorización. Un backfill cubre cuentas anteriores a la migración.

## Diseño preliminar, sin DDL aplicado

Cada módulo futuro tendrá UUID estable generado antes de enviar, user_id no nulo a auth.users, created_at y updated_at de servidor, privilegios mínimos y RLS por propietario.
El esquema de sus campos funcionales se cerrará con criterios de aceptación, antes de una migración.

| Entidad           | Núcleo propuesto                                               | Relaciones, restricciones e índices a validar                                                                                                                                                                                                                                                          |
| ----------------- | -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| habits            | id, user_id, name, archived_at                                 | Índice (user_id, archived_at); archivo conserva historial. Recurrencia versionada por fecha efectiva al definir su contrato.                                                                                                                                                                           |
| habit_completions | id, user_id, habit_id, occurrence_date, recorded_at, time_zone | FK compuesta (habit_id,user_id) a habits(id,user_id), con UNIQUE correspondiente en habits. Si se elige cumplimiento binario: UNIQUE(habit_id,occurrence_date) y confirmar/revertir por ocurrencia. Para cantidades se necesita otro contrato de idempotencia; no aplicar esa unicidad por anticipado. |
| routines          | id, user_id, name, archived_at                                 | Índice por propietario/archivo. Las actividades y su orden requieren una tabla hija solo cuando se defina qué agrupa una rutina.                                                                                                                                                                       |
| goals             | id, user_id, title, archived_at                                | Unidad, objetivo y avance manual/derivado pendientes; no persistir porcentajes calculables sin contrato de actualización.                                                                                                                                                                              |
| journal_entries   | id, user_id, entry_date, body                                  | Índice (user_id,entry_date); UNIQUE(user_id,entry_date) solo si se decide una entrada por fecha. No presuponerlo ahora.                                                                                                                                                                                |

Las FKs simples a una entidad privada no bastan para impedir que un usuario vincule un ID ajeno: usar propiedad compuesta y pruebas de escritura cruzada.
No habrá transferencias de propietario desde cliente. Los borrados deberán restringirse o modelarse explícitamente para no destruir historial.
Las búsquedas futuras por historial tendrán paginación e índice por hábito/fecha cuando exista la consulta.

## Modalidades de hábitos confirmadas

El MVP incluirá hábitos binarios y cuantitativos, según [ADR-002](adr/002-habit-measurement-modes.md). Están confirmados ambos modos y las dos formas de registrar cantidades: añadir un aporte y fijar el total. El contrato de persistencia sigue en diseño.

| Modalidad    | Qué registra                | Datos propuestos para evaluar el progreso                       |
| ------------ | --------------------------- | --------------------------------------------------------------- |
| Binaria      | Realización de la actividad | Confirmación asociada a una ocurrencia elegible.                |
| Cuantitativa | Cantidad medida             | Valor registrado, unidad y meta vigente en el período evaluado. |

La estructura deberá distinguir identidad del hábito, programación/meta con vigencia y registros. El nombre preliminar `habit_completions` no significa que cada aporte cuantitativo sea ya un cumplimiento. Su cardinalidad y nombre definitivo dependen del contrato de escritura.

Para cantidades se admiten ambas operaciones: añadir un aporte (`addAmount`) y fijar el total del período (`setTotal`). Fijar 1.000 ml cuando se llevan 500 ml deja 1.000 ml, no 1.500 ml. Ambas operaciones necesitan una identidad estable para reintentos; detección de duplicados y modificación deben ser atómicas. Una corrección basada en un total desactualizado debe detectar el conflicto. Los criterios y ejemplos están en ADR-002. No aplicar por anticipado `UNIQUE(habit_id, occurrence_date)` a aportes individuales ni implementar incrementos sin idempotencia. Solo se incluyen metas cuantitativas mínimas: el total confirmado de una fecha elegible debe alcanzar o superar la meta vigente en la misma unidad. Un total inferior es progreso parcial; el exceso se conserva, sin generar días adicionales. Se excluyen límites máximos. El registro y la corrección de días anteriores están aceptados en ADR-005. Siguen pendientes unidades, precisión, cierre de períodos, detalle de corrección dentro de los siete días anteriores confirmados, estrategia del recálculo ya confirmado y cambios históricos de configuración.

## Programación de hábitos confirmada

Según [ADR-003](adr/003-habit-recurrence-modes.md), el MVP admite programación diaria, días de semana concretos y X cumplimientos por semana sin días fijos. La primera familia asigna días; la segunda evalúa una frecuencia semanal flexible.

La programación/meta debe tener vigencia explícita y distinguir el modo de medición de la recurrencia. Como propuesta, necesita tipo de programación, días elegidos o frecuencia semanal según el tipo, y contexto temporal explícito. No se ha fijado DDL ni una representación universal de recurrencias.

La frecuencia semanal cuenta días distintos con cumplimiento, con un máximo de uno por hábito y fecha de negocio. X es un entero entre 1 y 7 para una semana completa; las semanas parciales siguen pendientes. Repetir el hábito varias veces el lunes no sustituye miércoles o viernes. En cuantitativos se admiten varios aportes por fecha, pero como máximo un día de cumplimiento: no se cuentan aportes como días ni se traslada el exceso a otras fechas. El estado diario y las operaciones de aporte necesitan identidades distintas. El inicio de semana es lunes o domingo, elegido por cuenta y compartido entre dispositivos, según [ADR-004](adr/004-account-week-start.md). La zona IANA también es elegida por cuenta, persistida en Supabase y compartida entre dispositivos; no sigue automáticamente la zona del teléfono ni cambia al viajar. Quedan pendientes selección inicial y transición de cambios manuales de zona/inicio de semana, semanas parciales, cierre de días sin mínimo alcanzado y detalle del recálculo tras correcciones ya confirmado en ADR-005.

## Preferencia semanal de la cuenta confirmada

El inicio de semana se elige entre lunes y domingo y se conserva en Supabase por cuenta, según [ADR-004](adr/004-account-week-start.md). No pertenece al almacenamiento local de idioma/tema. Su futura representación podría ser un campo como `week_start_day`; todavía no existe ni modifica el contrato implementado de `profiles`.

Los días y semanas se interpretan con la zona IANA elegida para la cuenta, común a todos sus dispositivos y sin cambio automático al viajar. `profiles.time_zone` ya existe; mientras sea nulo no debe inferirse una zona. Los registros deben conservar fecha de negocio y contexto temporal aplicados, en lugar de reconstruir el pasado con la zona actual del perfil. Cada semana cerrada conserva sus límites y contexto temporal; no se recalcula usando la preferencia actual. Hace falta conservar períodos o configuración con vigencia suficiente para reconstruirlos, además del valor actual de la preferencia.

Siguen abiertos el flujo de selección inicial, la fecha efectiva de cambios manuales de zona o inicio de semana y el tratamiento de períodos de transición/parciales. El cambio entre lunes y domingo necesita evitar períodos superpuestos y fechas sin evaluar; no se resuelve mediante una actualización global del perfil. No se ha aplicado DDL.

## Registro y corrección histórica confirmados

Según [ADR-005](adr/005-habit-historical-records.md), se admite registrar y corregir días anteriores para hábitos binarios y cuantitativos. La fecha de negocio del registro es distinta del instante de escritura/corrección, que corresponde al servidor. La elegibilidad y la meta se evalúan con el contexto histórico de esa fecha, sin cambiar sus límites semanales originales.

La ventana histórica permite las siete fechas anteriores a la fecha actual de la cuenta; hoy sigue editable. Con fecha actual `D` obtenida del reloj servidor en la zona elegida, las escrituras históricas nuevas requieren `D - 7 <= occurrence_date < D`. El corte se valida al guardar, no al abrir el formulario; se cuentan fechas y no 168 horas. La ventana no depende del inicio de semana y no limita la consulta ni la conservación del historial. La edición no habilita por omisión fechas futuras, anteriores al inicio del hábito o no programadas. También siguen pendientes el tratamiento de pausas/archivo, el detalle de reversión y la representación del historial de cambios.

Una corrección de cantidad puede hacer que esa fecha alcance o deje de alcanzar su mínimo. Las estadísticas y rachas afectadas se recalculan con los registros corregidos y las reglas históricas; pueden aumentar o reducirse, manteniendo las mismas fechas y límites de períodos. Las fórmulas completas y la estrategia de actualización siguen pendientes; no se guardan resultados contradictorios como otra fuente de verdad. Conservar una semana cerrada significa conservar sus límites, sin convertirlo por omisión en un bloqueo de edición de registros.

## Pausa y reanudación confirmadas

Según [ADR-006](adr/006-habit-pauses.md), se puede pausar y reanudar conservando historial. Cada pausa dura de uno a tres días calendario consecutivos en la zona de la cuenta, incluyendo la fecha de inicio. El intervalo conceptual `[start_date, end_date)` termina al comenzar la fecha posterior al último día pausado; la programación habitual se reanuda automáticamente. También se admite reanudar antes.

Cada hábito tiene un máximo de tres fechas protegidas en cualquier ventana móvil de treinta fechas, `[D - 29 días, D]`. Se pueden usar juntas o separadas y se recuperan al salir de ventana. Fechas consumidas y reservadas deben validarse de forma atómica contra el historial, evitando solicitudes concurrentes que excedan el presupuesto. Cerrar/reabrir no renueva disponibilidad; dividir un descanso continuo no elude el máximo de tres días consecutivos.

La pausa conserva una racha previa válida sin sumar días, cantidades ni cumplimiento semanal. Terminarla no rompe la racha a medianoche: la persona debe cumplir el siguiente día exigible según su programación. Los días no programados fuera de pausa siguen siendo descanso normal y no consumen presupuesto.

Se necesitan intervalos históricos y contexto temporal, sin usar un único booleano mutable. Siguen pendientes el efecto en metas semanales, fórmulas no diarias, fase previa a la activación, actividad durante una pausa, edición retroactiva y detalle de fechas de inicio/reanudación anticipada. No se ha aplicado DDL.

## Fechas e historial

Un instante UTC no sustituye a una fecha de negocio. Una ocurrencia usará date y la zona IANA que permita interpretar cómo se asignó ese día; los eventos usan timestamptz.
Cambios de zona, medianoche, horario de verano y fecha efectiva de recurrencias requieren un contrato de producto.
No se calcula ninguna racha o porcentaje en esta entrega. Las métricas futuras consumirán las mismas programaciones y registros que calendario y dashboard.
No se marca un día sin programación como fallo ni se reinterpreta el pasado por editar la definición actual.

## Tipos y migración

types/database.types.ts se genera desde PostgreSQL local mediante Supabase CLI; no es un snapshot escrito a mano. La app móvil importa el artefacto por su propio comando, sin compartir fuentes.
pnpm db:types usa Supabase CLI contra PostgreSQL local y sustituye el archivo de forma atómica solo si recibe una definición Database válida.
Las migraciones son incrementales; no editar una migración ya aplicada a un entorno compartido.
Antes de migraciones destructivas se necesita una estrategia de respaldo/recuperación acorde al cambio.
