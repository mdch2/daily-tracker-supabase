# ADR-002: hábitos binarios y cuantitativos en el MVP

- Estado: aceptada para modalidades, ambas formas de registro y metas cuantitativas mínimas; persistencia y detalle temporal pendientes.
- Fecha: 2026-10-21.

## Contexto

Durante la revisión del modelo de hábitos, el usuario confirma que el MVP incluye hábitos cuantitativos además de hábitos de hecho/no hecho. La propuesta anterior de hábitos y cumplimientos todavía no tiene DDL aplicado.

## Decisión

El diseño debe contemplar ambos modos:

- Binario: registrar si se realizó la actividad.
- Cuantitativo: registrar una cantidad asociada a una unidad y a una meta; por ejemplo, agua en litros, lectura en páginas o caminata en pasos. Los ejemplos ilustran el alcance y no fijan un catálogo de unidades.

El usuario confirma ambas formas de registro cuantitativo: añadir un aporte y fijar el total. Son operaciones distintas; fijar un total sustituye el valor acumulado del período indicado, no añade esa cantidad. Deben distinguirse los registros parciales del cumplimiento calculado. La cardinalidad de tablas sigue pendiente. El criterio cuantitativo mínimo se detalla a continuación.

## Criterio cuantitativo confirmado

El 21 de octubre de 2026, el usuario confirma que solo se incluyen metas mínimas: alcanzar o superar una cantidad. Los hábitos con límites máximos de consumo quedan fuera del alcance actual.

Para una fecha elegible y una meta vigente, el criterio es `confirmed_amount >= target_amount`, usando la misma unidad. El valor utilizado debe estar confirmado por el guardado; una entrada local pendiente o fallida no cuenta como progreso guardado.

- Un valor positivo por debajo de la meta representa progreso parcial; no cumple todavía el criterio diario.
- Alcanzar la meta o superarla cumple el criterio cuantitativo de esa fecha. No hace falta esperar al final del día para alcanzar un mínimo.
- Superar la meta conserva la cantidad registrada; no equivale a varios cumplimientos ni se traslada a otras fechas. La frecuencia semanal sigue contando como máximo un día por fecha.
- La ausencia de registro no se convierte silenciosamente en cero ni en un fallo definitivo mientras el período siga abierto.
- La representación visual de porcentajes, el cierre de días no completados y las políticas de corrección histórica siguen pendientes. No se introduce un porcentaje como fuente de verdad ni un cumplimiento irreversible independiente del valor registrado.

### Ejemplos de aceptación del mínimo

Se supone una fecha elegible, meta vigente de 20 páginas y valores confirmados en la misma unidad. Los ejemplos son criterios de diseño, no pruebas ejecutadas.

| Total confirmado | Resultado                                                                             |
| ---------------- | ------------------------------------------------------------------------------------- |
| 15 páginas       | Progreso parcial; la meta diaria aún no se alcanza.                                   |
| 20 páginas       | Meta diaria alcanzada; un día como máximo para el conteo semanal.                     |
| 30 páginas       | Meta diaria alcanzada; se conservan 30 páginas y sigue contando como un solo día.     |
| Registro ausente | Sin valor confirmado; no inventar cero ni cerrar el período como fallido por omisión. |

## Registro cuantitativo confirmado

El 21 de octubre de 2026, el usuario confirma las dos operaciones propuestas:

| Operación conceptual | Intención                                           | Ejemplo con un total previo de 500 ml      |
| -------------------- | --------------------------------------------------- | ------------------------------------------ |
| `addAmount`          | Añadir un nuevo aporte al período indicado.         | Añadir 250 ml deja 750 ml.                 |
| `setTotal`           | Establecer el valor acumulado del período indicado. | Fijar 1.000 ml deja 1.000 ml, no 1.500 ml. |

Los nombres son conceptuales: todavía no definen RPC, tablas ni contratos móviles. En las modalidades confirmadas en [ADR-003](003-habit-recurrence-modes.md), las cantidades se registran por fecha de negocio; la frecuencia semanal cuenta días distintos que cumplen el criterio diario. No se acumulan aportes de varias fechas para convertirlos en días adicionales. Las cantidades del ejemplo no cierran un catálogo de unidades.

### Criterios para la futura escritura

- Cada acción tiene un identificador estable creado antes del envío. Reintentar la misma acción con el mismo contenido no vuelve a aplicar su efecto; reutilizar el identificador con otro contenido se rechaza.
- Repetir intencionadamente un aporte usa un identificador nuevo. Dos aportes de 250 ml son distintos aunque coincidan sus valores.
- La detección de duplicados y la modificación del total deben confirmarse en una misma transacción. Un fallo no puede dejar solo una de las dos partes guardada.
- Las escrituras del mismo hábito/período deben coordinarse en PostgreSQL. Una corrección basada en un total desactualizado debe detectar el conflicto y permitir revisar/reintentar, conservando la entrada; no sobrescribir silenciosamente aportes que el usuario aún no ha visto.
- Identidad, propietario, período y definición vigente de unidad deben validarse antes de escribir. No sumar unidades incompatibles ni inferir una conversión todavía no contratada.
- El total confirmado y el resultado de una operación son distintos. La respuesta conservada de un reintento no autoriza a reemplazar un total más reciente en el cliente.
- Se debe elegir una representación de origen coherente al cerrar el esquema: registro de operaciones, total con comprobantes u otra estructura mínima que garantice estas reglas. No mantener dos fuentes de verdad independientes.

### Ejemplos de aceptación para reintentos

Estas secuencias son criterios de diseño, no pruebas ejecutadas. Cada letra identifica una acción distinta sobre el mismo hábito/período; se supone escritura sobre la versión vigente y una unidad compatible.

| Acción                                  | Total confirmado después de la acción |
| --------------------------------------- | ------------------------------------- |
| A: añadir 250 ml sobre un total de 0 ml | 250 ml                                |
| Reintentar A                            | 250 ml                                |
| B: añadir otros 250 ml                  | 500 ml                                |
| C: fijar el total en 750 ml             | 750 ml                                |
| Reintentar C                            | 750 ml                                |
| D: añadir 250 ml                        | 1.000 ml                              |
| Reintentar C después de D               | 1.000 ml; C no se vuelve a aplicar    |

## Consecuencias para el diseño propuesto

- Separar identidad del hábito, definición vigente de su programación/meta y registros realizados.
- Considerar valor objetivo, unidad y valor registrado para cantidades. Los nombres de columnas, precisión, unidades permitidas y reglas de validación se cerrarán con el contrato.
- Definir el comportamiento al editar meta, unidad o modo de medición, conservando la interpretación del historial.
- Distinguir establecer un total de añadir un aporte. Los reintentos de una misma operación no deben incrementar el progreso accidentalmente; el mecanismo de idempotencia dependerá de la operación elegida.
- No equiparar ausencia de registro con cero ni con una confirmación binaria negativa sin definir su semántica.
- Dashboard, calendario y estadísticas consumirán las mismas reglas. No se guarda un porcentaje o una racha como fuente de verdad.
- Mantener RLS por propietario, relaciones entre entidades del mismo propietario y timestamps de servidor en la futura migración.

## Decisiones pendientes

1. Persistencia y detalle de los contratos de añadir un aporte y fijar el total, ya incluidos; edición o reversión de una operación anterior.
2. Evaluación y cierre de fechas sin meta alcanzada, porcentajes de presentación y detalle del recálculo tras correcciones, ya aprobado en ADR-005. El criterio de mínimo (`confirmed_amount >= target_amount`), el progreso parcial y la conservación del exceso ya están definidos.
3. Días elegibles, selección inicial/transición de cambios temporales y cierre del período. La zona se elige por cuenta y no cambia automáticamente al viajar, según [ADR-004](004-account-week-start.md). Las modalidades de recurrencia y el conteo semanal por días distintos están aceptados en [ADR-003](003-habit-recurrence-modes.md). El valor cuantitativo corresponde a la fecha de negocio; los límites temporales y el cierre de períodos siguen pendientes. El mínimo se alcanza con un valor guardado y confirmado que llegue a la meta o la supere.
4. Unidades, números enteros/decimales, precisión y límites.
5. Detalle de las correcciones históricas, contratos de pausa, archivo y fecha efectiva de cambios de programación/meta. Pausar/reanudar y el máximo de tres días calendario consecutivos para proteger la racha están aceptados en [ADR-006](006-habit-pauses.md); el conteo se hace por fechas en la zona de la cuenta. La reanudación automática y el presupuesto de tres fechas protegidas por hábito en una ventana móvil de treinta fechas están aprobados; los casos especiales siguen pendientes. Registrar y corregir los siete días anteriores, además del día actual, y recalcular sus estadísticas/rachas afectadas está aceptado en [ADR-005](005-habit-historical-records.md).
6. Cálculo de rachas para cada modalidad; el umbral de tres días del producto no resuelve estos casos.

## Alcance de esta decisión

Documentación de producto y diseño preliminar. No crea tablas, migraciones, RPC, algoritmos ni escrituras móviles. Quedan aceptados los dos modos de hábito, ambas formas de registro cuantitativo y metas exclusivamente mínimas. El diseño técnico descrito guía la futura implementación; no es funcionalidad disponible.

## Actualización de implementación: 22 de octubre de 2026

El [ADR-007](007-first-habit-delivery.md) y el [contrato v1](../habits-v1.md) cierran e implementan la primera entrega de registro. Las propuestas y pendientes anteriores describen el contexto original; los cambios de configuración, pausas y rachas siguen aplazados, conservando sus decisiones aprobadas.
