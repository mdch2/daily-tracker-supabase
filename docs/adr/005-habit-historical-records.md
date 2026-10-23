# ADR-005: registro y corrección de días anteriores en hábitos

- Estado: aceptada para registro/corrección de los siete días anteriores y recálculo de estadísticas y rachas afectadas; detalle de escritura y cálculo completo pendientes.
- Fecha: 2026-10-21.

## Contexto

El usuario confirma que se podrán registrar y corregir días anteriores. El MVP incluye hábitos binarios y cuantitativos con metas mínimas, programación por días y frecuencia semanal por días distintos, según [ADR-002](002-habit-measurement-modes.md) y [ADR-003](003-habit-recurrence-modes.md).

La zona elegida por cuenta y los límites históricos se conservan, según [ADR-004](004-account-week-start.md). Conservar esos límites no equivale a prohibir corregir un registro de una fecha anterior.

## Decisión

- Permitir registrar una realización o cantidad correspondiente a un día anterior.
- Permitir corregir el cumplimiento binario o el valor cuantitativo de una fecha anterior.
- Mantener separadas la fecha de negocio a la que corresponde el registro y el instante real en que se guardó o corrigió. Corregir ayer no autoriza al cliente a escribir timestamps de servidor ni a fingir que la escritura ocurrió ayer.
- Aplicar el contexto histórico de la fecha: programación, meta, unidad, zona y período que correspondan. No usar por omisión la meta o la zona actuales para reinterpretar el pasado.
- Conservar los límites originales de las semanas cerradas. Una corrección pertenece al período histórico de su fecha, sin mover otras fechas a otra semana.

El usuario limita el registro y la corrección histórica a los últimos siete días anteriores. La ventana no autoriza por sí sola fechas previas al inicio del hábito, días no elegibles, hábitos archivados o fechas futuras; esos límites mantienen su propio contrato.

## Ventana histórica de siete días confirmada

El 21 de octubre de 2026, el usuario elige los últimos siete días para el registro y la corrección histórica. Por tratarse de días anteriores, el corte se define como las siete fechas anteriores a la fecha actual de negocio de la cuenta; el día actual permanece editable como operación corriente.

Si `D` es la fecha actual obtenida del reloj del servidor en la zona IANA elegida para la cuenta, las fechas históricas admitidas están en `[D - 7 días, D)`, incluyendo el primer límite. Para hoy y el historial, la ventana conjunta es `[D - 7 días, D]`, siempre que la fecha sea elegible para ese hábito.

- Contar fechas locales, no un intervalo móvil de 168 horas ni la semana del calendario. El día elegido para comenzar la semana no altera esta ventana.
- Aplicar el mismo corte al registro omitido, a marcar/desmarcar un binario y a añadir/corregir cantidades de fechas anteriores.
- Validar el corte en el servidor al aceptar una escritura nueva; el reloj del cliente y la fecha en que se abrió el formulario no autorizan un guardado fuera de ventana.
- Cuando una escritura pasa a estar fuera de ventana antes de guardarse, rechazar el cambio conservando la entrada e informar del motivo. No moverlo silenciosamente a otra fecha.
- Reintentar una operación ya confirmada con el mismo identificador y contenido sigue devolviendo su resultado sin volver a escribir, aunque su fecha haya salido de ventana. Si nunca se confirmó, el reintento es una nueva aceptación pendiente y debe respetar el corte vigente.
- El corte limita nuevas escrituras, no la consulta ni conservación del historial. No borrar registros al superar siete días.
- Una corrección admitida recalcula todos los resultados afectados con las reglas históricas, aunque para hacerlo se necesiten registros o secuencias fuera de esta ventana. No truncar una racha al séptimo día.

### Ejemplos de frontera

Fecha de negocio controlada: `D = 2026-10-21`. Se supone la misma zona de cuenta y fechas elegibles. Estos son criterios de diseño, no pruebas ejecutadas.

| Fecha del registro | Resultado de una escritura nueva                                  |
| ------------------ | ----------------------------------------------------------------- |
| 2026-10-14         | Histórica admitida: primer día de la ventana, siete días antes.   |
| 2026-10-20         | Histórica admitida: ayer.                                         |
| 2026-10-13         | Fuera de ventana: no se permite registrar ni corregir.            |
| 2026-10-21         | Día actual editable; no consume uno de los siete días anteriores. |

Al pasar a `D = 2026-10-22`, la primera fecha histórica editable pasa al 15 de octubre. Un formulario abierto antes del cambio de día no conserva autorización para una escritura nueva del 14.

## Criterios para la futura escritura

- La autorización sigue siendo por propietario. La fecha pasada no permite editar hábitos o registros ajenos.
- Distinguir confirmar/desmarcar un hábito binario de añadir un aporte o fijar un total cuantitativo. Las dos operaciones cuantitativas confirmadas mantienen identidades de acción y reintentos sin duplicación.
- Una corrección debe ser atómica y detectar conflictos con otras escrituras sobre el mismo día. Conservar la entrada ante un fallo y comunicar éxito solo después de confirmar el guardado.
- No borrar silenciosamente aportes para simular una corrección de total ni cambiar la identidad del hábito. La representación de operaciones, revisiones y estado diario se elegirá al cerrar el esquema.
- El cliente no puede transferir propietario ni modificar timestamps de servidor. La futura migración debe definir privilegios, RLS y validación de elegibilidad en el límite de escritura.

## Ejemplos de aceptación del alcance

Los ejemplos suponen fechas elegibles y dentro de la ventana de siete días anteriores confirmada. Son criterios de diseño, no pruebas ejecutadas.

| Acción                                                                              | Resultado esperado de datos                                                                                               |
| ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Registrar hoy una realización de ayer                                               | El cumplimiento corresponde a ayer; la escritura se registra con el instante actual del servidor.                         |
| Corregir de 15 a 20 páginas un día anterior con meta mínima vigente de 20           | El total confirmado de esa fecha pasa a 20 y satisface su mínimo, sin generar dos días de cumplimiento.                   |
| Corregir de 20 a 15 páginas esa misma fecha                                         | El total confirmado pasa a 15 y deja de satisfacer ese mínimo; no se conserva un booleano de cumplimiento contradictorio. |
| Corregir un día de una semana cerrada después de cambiar el inicio de semana actual | La fecha permanece asociada a sus límites históricos originales.                                                          |
| Reintentar la misma corrección confirmada                                           | No se vuelve a aplicar su efecto ni se duplica el registro.                                                               |

## Recálculo de métricas y rachas confirmado

El 21 de octubre de 2026, el usuario acepta que registrar o corregir un día anterior recalcule las estadísticas y rachas afectadas. La política actúa en ambas direcciones: completar un día puede recuperar o ampliar una racha y reducir/desmarcar su cumplimiento puede reducirla o interrumpirla, según las reglas aplicables.

- Derivar los resultados de los registros corregidos usando programación, meta, unidad, zona y límites que correspondían a cada fecha. No aplicar la configuración actual al pasado.
- Mantener estables las fechas de negocio y los límites de semanas históricas. Su progreso y resultado sí pueden actualizarse cuando cambia un registro de ese período.
- Compartir los mismos resultados en dashboard, calendario, detalle y estadísticas. No corregir una pantalla dejando las demás con resultados anteriores presentados como actuales.
- Identificar todos los resultados afectados: una corrección puede modificar una secuencia de racha posterior a la fecha corregida; no limitar el recálculo a una única celda del calendario.
- No almacenar contadores o porcentajes independientes que contradigan los registros. Si se materializan derivados, su invalidación/actualización debe formar parte del contrato de escritura y lectura, con un estado coherente ante fallos.
- Reintentar una corrección ya confirmada no aplica de nuevo su efecto. Tampoco puede restablecer una proyección vieja sobre registros más recientes.

### Ejemplos del efecto confirmado

Se supone un hábito diario con tres fechas consecutivas elegibles, sin otras fechas completadas junto a esa secuencia. Los ejemplos se refieren a la racha de esa secuencia, no a una racha actual calculada sin reloj explícito. El umbral del caso diario es de tres días.

| Cambio de datos                                                            | Resultado esperado del recálculo                                                                     |
| -------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Lunes y miércoles completos; registrar el martes como completo             | La secuencia pasa a tener tres días consecutivos y alcanza el umbral de activación.                  |
| En esa secuencia, corregir el martes para que deje de cumplir              | La secuencia deja de tener tres días consecutivos; no se conserva artificialmente su racha anterior. |
| Una semana histórica pasa de 2/3 a 3/3 días distintos tras corregir un día | Su progreso pasa a 3/3 dentro de los mismos límites semanales originales.                            |
| Después se corrige otro de esos días para que deje de cumplir              | El progreso vuelve a 2/3; la semana no conserva un resultado contradictorio de 3/3.                  |

Estos son criterios de diseño, no pruebas ejecutadas. El recálculo está decidido; las fórmulas completas para pausas, días no programados, semanas parciales y recurrencias no diarias siguen pendientes. No se extrapola el umbral de tres días a semanas.

## Otras decisiones pendientes

- Fecha de inicio del hábito y elegibilidad de días no programados. La ventana de siete días anteriores ya está confirmada.
- Comportamiento en fechas anteriores al archivo o dentro de pausas. El soporte de pausa/reanudación y el máximo de tres días calendario consecutivos de protección de racha están aceptados en [ADR-006](006-habit-pauses.md); editar pausas retroactivamente o registrar actividad dentro de ellas sigue pendiente.
- Edición de un aporte individual frente a corrección del total, reversión y conservación del historial de cambios.
- Reglas de cálculo completas y estrategia de actualización de resultados derivados antes de implementar.

## Alcance

Documentación de producto y criterios de diseño. No crea tablas, migraciones, RPC, algoritmos ni pantallas. Las reglas pendientes no se implementan por omisión.

## Actualización de implementación: 22 de octubre de 2026

El [ADR-007](007-first-habit-delivery.md) y el [contrato v1](../habits-v1.md) cierran e implementan la primera entrega de registro. Las propuestas y pendientes anteriores describen el contexto original; los cambios de configuración, pausas y rachas siguen aplazados, conservando sus decisiones aprobadas.
