# Plan de datos: rutinas y metas personales

Fecha: 2026-10-27. Diseño propuesto, sin DDL, migraciones, RPC implementadas ni permisos concedidos. Las reglas confirmadas por el usuario y la propuesta funcional completa están en el repositorio móvil: `docs/architecture/adr/008-routines-personal-goals.md` y `docs/architecture/routines-goals-plan.md`. La aprobación de una definición funcional no constituye evidencia de implementación o autorización de despliegue.

Este documento es la fuente del diseño de persistencia para estos módulos. No copiar su esquema al repositorio móvil ni importar fuentes entre repositorios. El móvil recibirá contratos de servicios y tipos generados únicamente cuando exista una implementación verificada.

## Decisiones funcionales confirmadas

- Rutinas con pasos propios y hábitos existentes, obligatorios u opcionales y orden orientativo. Se completan al realizar todos los obligatorios; los opcionales no bloquean.
- Rutinas diarias o en días concretos. Registro/corrección desde Rutinas solo hoy, por fecha del servidor en la zona de cuenta. Historial consultable.
- Las correcciones de hábitos conservan su contrato actual y se reflejan en las rutinas y metas vinculadas. No se duplica ni congela el registro del hábito.
- Metas personales de cantidad o hitos de igual peso; fuente manual o vinculada según la meta, sin mezclar ambas.
- Una meta vinculada usa un hábito. El mismo hábito puede contribuir a varias metas, sin repartir sus registros.
- Metas con inicio y fecha límite opcional. Vencimiento permite continuar, reprogramar o archivar; las correcciones pueden deshacer el logro.

Las políticas restantes de este documento son propuestas de diseño para revisión junto con el plan móvil.

## Convenciones comunes

UUID estables creados antes del envío, propietario derivado de `auth.uid()`, timestamps de servidor `timestamptz` y fechas de negocio `date`. El cliente no envía propietario ni tiempos de servidor. El calendario debe estar confirmado; no se infiere zona ni inicio de semana.

Los nombres se recortan y validan en aplicación y PostgreSQL. Cantidades en milésimas enteras, rango 0–999999999999; metas/aportes positivos y sustituciones desde cero. No hay conversiones de unidades ni operaciones en coma flotante.

Las relaciones privadas llevan pertenencia compuesta. Para cada padre se define una clave única que incluya identidad y propietario; las FKs hijas deben referenciar esa clave, además de exigir coherencia entre entidad, definición, paso y fecha. No hay cascadas destructivas de negocio, transferencia de propietario ni DELETE cliente. Los datos existentes no se transforman.

## Rutinas: entidades propuestas

| Entidad                             | Campos y propósito                                                                                                                                                                                                         |
| ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `public.routines`                   | `id`, `user_id`, `name`, `start_date`, `archived_at?`, `created_at`, `updated_at`. Identidad, nombre inmediato y ciclo de vida. Inicio hoy al confirmar servidor.                                                          |
| `public.routine_definitions`        | `id`, `routine_id`, `user_id`, `effective_from`, `schedule_type`, `weekday_mask?`, `time_zone`, `week_start_day`. Programación versionada; unicidad por rutina/fecha efectiva.                                             |
| `public.routine_steps`              | `id`, `routine_id`, `user_id`, `step_kind`, `habit_id?`. Identidad estable de paso, propio o vinculado. Tipo y hábito son inmutables.                                                                                      |
| `public.routine_definition_steps`   | `definition_id`, `routine_id`, `step_id`, `user_id`, `position`, `is_required`, `own_title?`. Pertenencia, orden, obligatoriedad y etiqueta propia con vigencia.                                                           |
| `public.routine_step_day_records`   | `step_id`, `routine_id`, `user_id`, `occurrence_date`, `definition_id`, `completed`, `revision`, `recorded_at`, `updated_at`. Estado confirmado de un paso propio por fecha. Nunca contiene estados de hábitos vinculados. |
| `private.routine_creation_requests` | Identidad de creación por usuario, petición normalizada y resultado original para reintentos.                                                                                                                              |
| `private.routine_operations`        | `user_id`, `operation_id`, tipo de operación, entidad, petición normalizada, resultado y timestamp de servidor. Comprobantes de edición, archivo y registro, no otro estado de cumplimiento.                               |

### Integridad y validación de rutinas

- Nombre y etiquetas de pasos propios: 1–100 caracteres recortados. Definición de 1–30 pasos, posiciones enteras únicas y contiguas, al menos uno obligatorio.
- `daily` exige máscara nula; `weekdays` exige máscara de 1–127 con lunes=1 a domingo=64. Sin recurrencia semanal flexible propia.
- Paso propio sin hábito; paso vinculado con hábito propio existente y sin etiqueta propia. No repetir el mismo hábito dentro de una definición de rutina.
- `routine_definition_steps` exige que definición y paso pertenezcan a la misma rutina/propietario. Un registro propio referencia la membresía histórica completa, no solo una definición o paso aislados.
- Solo los pasos propios tienen registros en `routine_step_day_records`. PK por `(step_id, occurrence_date)`, revisión positiva y booleano no nulo. Ausencia se distingue de false.
- La RPC de registro resuelve la definición vigente para la fecha bajo bloqueo, comprueba membresía, tipo propio y elegibilidad. No basta una FK para validar que la definición sea la temporalmente aplicable.
- Los hábitos flexibles solo pueden vincularse como opcionales. No imponer una obligación diaria nueva. La validación se comprueba al crear/editar; un cambio posterior del hábito se interpreta con su definición histórica, excluyendo de obligaciones diarias al flexible incluso si una versión anterior del vínculo lo marcaba obligatorio. La lectura informa esa incompatibilidad de configuración para corregir la próxima versión de rutina.
- La creación/edición exige algún solapamiento entre la programación de la rutina y al menos un obligatorio elegible. Una fecha con cero obligatorios elegibles se muestra no evaluable, sin éxito automático.
- Nombre inmediato; definición inicial desde hoy y cambios estructurales desde la próxima semana de cuenta. Versiones aplicadas inmutables; solo la futura puede reemplazarse antes de entrar en vigor. Identidades de pasos retirados se conservan.
- Archivar guarda timestamp de servidor, bloquea nuevas escrituras y excluye fechas posteriores al archivo. El resultado de la fecha de archivo y anteriores se conserva como evaluación derivada, sensible a correcciones permitidas de hábitos. No se admite restauración inicial.

Los pasos vinculados se leen desde `habit_day_records` y las definiciones de Hábitos. No hay tabla de completados de rutina ni escritura «completar todo». Un registro de hábito desde una rutina llama `record_habit_day` existente sin una segunda escritura de paso.

### Índices de rutinas

Claves de pertenencia compuesta además de PK, unicidad `(routine_id, effective_from)`, `(definition_id, position)` y membresía `(definition_id, routine_id, step_id, user_id)`. Índice de listado por `(user_id, archived_at, created_at, id)`; pasos vinculados por `(user_id, habit_id, routine_id)`; registros por `(routine_id, occurrence_date, step_id)` cuando la PK del paso no cubra la lectura. No duplicar índices que ya cubran estas consultas.

Las restricciones de cardinalidad/obligatoriedad y de coherencia entre varias filas se aplican mediante RPC transaccionales y triggers de restricción diferibles donde haga falta garantizar el estado al commit. Deben seguir protegiendo datos aunque un futuro mantenimiento no use el cliente móvil.

## Metas: entidades propuestas

| Entidad                          | Campos y propósito                                                                                                                                                                                                                                            |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `public.goals`                   | `id`, `user_id`, `mode`, `progress_source`, `start_date`, `time_zone`, `unit_label?`, `habit_id?`, `linked_metric?`, `created_at`, `updated_at`. Identidad y parámetros inmutables de medida/origen.                                                          |
| `public.goal_versions`           | `id`, `goal_id`, `user_id`, `version`, `effective_at`, `name`, `description?`, `target_milliunits?`, `deadline?`, `archived_at?`. Snapshot inmutable de configuración editable. La mayor versión es la vigente; no se duplica un puntero de estado funcional. |
| `public.goal_milestones`         | `id`, `goal_id`, `user_id`, `position`, `name`, `threshold_milliunits?`. Hitos de igual peso fijados al crear; umbral solo cuando la fuente es vinculada.                                                                                                     |
| `public.goal_amount_day_records` | `goal_id`, `user_id`, `occurrence_date`, `amount_milliunits`, `revision`, `recorded_at`, `updated_at`. Un total manual por fecha, no un porcentaje ni una copia de hábitos.                                                                                   |
| `public.goal_milestone_records`  | `milestone_id`, `goal_id`, `user_id`, `completed`, `completion_date?`, `revision`, `recorded_at`, `updated_at`. Estado manual de un hito.                                                                                                                     |
| `private.goal_creation_requests` | Identidad de creación por usuario, payload normalizado y resultado para reintentos.                                                                                                                                                                           |
| `private.goal_operations`        | UUID de operación por usuario, tipo, petición normalizada y comprobante original de edición, archivo o registro.                                                                                                                                              |

No hay `goal_progress` mutable, contadores de días, banderas de logro persistidas ni duplicación de registros vinculados. Los acumulados y el cumplimiento se derivan al leer. Un historial de comprobantes no se suma para reconstruir cantidades: el origen son los totales diarios actuales.

### Integridad y validación de metas

- Nombre 1–100; descripción nula o hasta 2.000 caracteres, normalizando vacío a nulo. Inicio hoy o futuro, nunca anterior a la aceptación inicial. Zona copiada del calendario confirmado y fija.
- Fecha límite nula o igual/posterior al inicio. Nulo significa sin vencimiento.
- `mode`: cantidad o hitos. `progress_source`: manual o hábito. Los discriminantes deben prohibir campos/filas ajenos a cada combinación, mediante restricciones y validación transaccional.
- Una meta de cantidad exige objetivo positivo hasta 999999999999 milésimas; una de hitos no recibe un objetivo cuantitativo independiente y requiere 1–30 hitos, posiciones únicas y contiguas.
- Fuente manual: sin hábito ni medida vinculada. Cantidad exige unidad recortada de 1–30; hitos manuales sin unidad ni umbrales.
- Fuente vinculada: hábito propio obligatorio y `linked_metric` igual a cantidad acumulada o días cumplidos. Un solo hábito por meta, sin unicidad global sobre el vínculo.
- Cantidad acumulada exige hábito cuantitativo y unidad idéntica a la almacenada en Hábitos, sin conversión ni equivalencias de etiquetas. La unidad se toma del hábito, no se acepta una distinta enviada por el cliente.
- Días cumplidos usa unidades enteras de días, representadas internamente en milésimas; objetivos/umbrales son múltiplos de 1000. La etiqueta se localiza al presentar, no se guarda como una traducción fija.
- Hitos vinculados: umbrales positivos, únicos y estrictamente crecientes según posición, en la misma medida. Los nombres no se interpretan como reglas.
- Modalidad, fuente, inicio, unidad, hábito, medida, lista/orden/umbrales de hitos no se editan inicialmente. Nombre, descripción, límite y objetivo cuantitativo generan una nueva versión inmediata bajo bloqueo; el historial anterior permanece.
- PK de totales por `(goal_id, occurrence_date)`. Solo cantidad manual, rango desde cero, fecha elegible y revisión positiva.
- PK de hito manual por `milestone_id`; FK compuesta al hito/propietario. Si completed=true, completion_date no nula; si false, completion_date nula. Al revertir se valida la fecha anterior antes de borrarla del estado, conservándola en el comprobante.
- Propuesta de ventana manual `[D−7,D]`, acotada por inicio; para hitos se validan la fecha previa y nueva. Esta ventana de Metas está por revisar y no fue aprobada al decidir «solo hoy» para Rutinas.
- Sin progreso manual para fuente vinculada ni escrituras manuales fuera de su modalidad. Archivo bloquea cambios y nuevas fechas; no elimina registros, no restaura inicialmente.
- La suma manual resultante no supera el máximo representable: la RPC bloquea la meta y valida el total acumulado con aritmética exacta antes de confirmar.

### Índices de metas

Unicidad `(goal_id, version)`, `(goal_id, position)` y claves compuestas de pertenencia. Listado por `(user_id, created_at, id)`; vínculos por `(user_id, habit_id)`; versiones por meta/versión descendente cubiertas por su índice único con lectura inversa; PK por meta/fecha y por hito para registros. Añadir un índice de filtro por archivo o límite solo si la consulta real lo requiere, ya que ambos viven en la versión vigente.

## Cálculo de progreso vinculado

La ventana incluye desde start_date hasta la fecha de cuenta actual, o hasta la fecha de archivo inclusive si existe. La fecha límite no corta aportes, porque una meta vencida puede continuar. Antes del inicio, acumulado cero con estado programada y sin escrituras.

- Cantidad acumulada suma los totales diarios confirmados de Hábitos, incluso parciales bajo el mínimo. No suma comprobantes, aportes originales ni apariciones en rutinas.
- Días cumplidos cuenta fechas distintas con cumplimiento según la definición histórica de Hábitos; máximo uno por fecha y sin trasladar excesos. Los días de hábitos flexibles no se convierten en obligaciones diarias.
- La evaluación histórica de elegibilidad y cumplimiento pertenece al contrato de Hábitos. Se diseñará un evaluador interno compartido del backend que consuman las proyecciones, con casos de paridad contra el contrato móvil; no habrá un algoritmo distinto dentro de cada proyección de rutinas/metas.
- Las correcciones de Hábitos recalculan el resultado al leer, sin actualizar tablas de progreso. Un hábito puede alimentar varias metas con ventanas distintas.
- La suma se realiza en un tipo exacto con capacidad suficiente. Si una meta vinculada excede el rango de transporte seguro, su progreso devuelve un error de límite explícito; nunca recorta ni redondea el valor. Las escrituras del hábito no fallan por un límite de una meta dependiente.
- Progreso de cantidad: valor/objetivo. Progreso de hitos: completados/total. Porcentaje entero truncado, barra limitada a 100 %, exceso real visible.
- Estado derivado, con prioridad: archivada, programada, lograda, vencida y en curso. El vencimiento ocurre al comenzar la fecha siguiente al límite, con calendario explícito.

El lector de progreso debe usar una única instantánea coherente para configuración, registros, calendario y resultado de cada lote, sin varias llamadas REST cuyos datos puedan mezclarse. Devuelve revisión/configuración observada, fecha y reloj de referencia junto con el resultado; no afirma consistencia frente a cambios posteriores.

## Operaciones previstas

Nombres propuestos para diseñar las firmas al implementar; no hay funciones disponibles todavía.

| Operación               | Entradas y resultado esenciales                                                                                                                 |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `create_routine`        | UUID estable de entidad/definición/pasos, nombre, programación y pasos. Creación atómica, inicio hoy y resultado autoritativo.                  |
| `rename_routine`        | operation_id, entidad, nombre y updated_at observado. Nombre inmediato.                                                                         |
| `edit_routine`          | operation_id, entidad, configuración completa e updated_at observado. Versión próxima semana y effective_from devuelto.                         |
| `record_routine_step`   | operation_id, rutina/paso propio, fecha, booleano y revisión observada. Solo hoy; comprobante original.                                         |
| `archive_routine`       | operation_id, entidad y updated_at observado. Archivo de servidor, sin cascadas.                                                                |
| `get_routine_window`    | IDs propios/rango acotado. Definiciones aplicables, pasos, registros propios y datos de hábitos necesarios; sin escribir resultados derivados.  |
| `create_goal`           | UUID estable de entidad/hitos, definición y origen. Creación atómica con versión inicial y calendario.                                          |
| `edit_goal`             | operation_id, entidad, campos editables completos y updated_at observado. Nueva versión inmediata y token actualizado.                          |
| `record_goal_amount`    | operation_id, meta, fecha, operación sumar o sustituir y cantidad. La sustitución exige revisión; sumar usa el último total bajo bloqueo.       |
| `record_goal_milestone` | operation_id, meta/hito, booleano, fecha cuando se confirma y revisión observada. Solo fuente manual.                                           |
| `archive_goal`          | operation_id, entidad y updated_at observado. Nueva versión con archived_at, ventana acotada y sin cascadas.                                    |
| `get_goal_progress`     | Hasta 20 IDs propios. Proyecciones actuales y contexto de una lectura coherente; no aceptar un user_id confiable ni fechas futuras del cliente. |
| Listados e historial    | Paginación estable por fecha/id; hasta 20 entidades por página. Historial de registros/configuraciones separado de progreso actual.             |

El lector de rutinas limita lotes a 10 rutinas para una fecha; el historial de una rutina a 28 fechas. Las membresías/versiones/estados vinculados se deduplican. Cada entidad admite hasta 30 pasos/hitos. No se usa la paginación REST por defecto como garantía de haber leído todos los datos.

Todos los comprobantes devuelven identidad de operación, entidad/fecha cuando aplique, token de revisión y datos del resultado original. Un comprobante no es el estado vigente si hubo operaciones posteriores; el cliente vuelve a leer.

## Atomicidad, concurrencia y reintentos

Cada escritura valida identidad autenticada y estructura básica; bloquea la identidad de operación, reconoce un comprobante previo y solo para una aceptación nueva valida propiedad, token, archivo, calendario, definición y ventana después de esperar bloqueos. Una identidad reutilizada con otro contenido falla sin mutar.

Se bloquea el padre de la entidad para serializar edición, archivo y registro. Operaciones que necesiten varios hábitos bloquean sus identidades en orden estable después de resolver la identidad de operación, y antes de bloquear la rutina/meta. El registro habitual de un hábito no necesita bloquear metas ni rutinas dependientes: sus resultados son derivados. Antes de implementar se comprobará el grafo completo de bloqueos para evitar inversión con las RPC existentes.

Las sustituciones exigen revisión observada; una fila ausente se identifica con revisión 0. Dos sustituciones concurrentes sobre la misma revisión no ganan ambas. Los aportes se suman exactamente una vez con identidad estable. Creación, estado y comprobante se confirman en una transacción; un error no deja hijos parciales.

No hay escritura masiva «completar rutina» ni transacción distribuida entre pasos propios y hábitos. Registrar un paso es una unidad de escritura; fallar otro paso no revierte uno ya confirmado ni permite comunicar que se completó todo.

Un reintento confirmado se reconoce antes del corte temporal, incluso al cambiar de fecha o archivar. Nunca reubicar una operación en otra fecha ni generar otro UUID automáticamente por fallo de respuesta.

## Matriz de autorización propuesta

| Objeto                                       | authenticated con propietario válido                                                     | anon / PUBLIC / identidad ausente                                               |
| -------------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Tablas públicas nuevas: SELECT               | Solo filas propias, por RLS y permiso explícito.                                         | Sin acceso.                                                                     |
| Tablas públicas nuevas: INSERT/UPDATE/DELETE | Denegado directo, incluidas propiedad y columnas de servidor.                            | Sin acceso.                                                                     |
| Comprobantes y helpers private               | Sin acceso directo ni EXECUTE.                                                           | Sin acceso.                                                                     |
| RPC de escritura                             | EXECUTE por firma; auth.uid no nulo, pertenencia y reglas verificadas dentro de función. | Sin EXECUTE; denegar también identidad ausente si se invoca como authenticated. |
| Lecturas públicas invocadoras                | SELECT propio/RLS, límites y validación de entradas.                                     | Sin EXECUTE.                                                                    |

RLS en la misma migración que crea cada tabla, incluidas las privadas como defensa adicional; revocar permisos de PUBLIC, anon, authenticated y service_role antes de conceder solo lo necesario. No ampliar defaults ni modificar esquemas administrados por Supabase.

RPC de escritura SECURITY DEFINER por ausencia deliberada de DML cliente, search_path vacío, nombres calificados y privilegios mínimos. Los lectores simples deben ser SECURITY INVOKER. Para get_goal_progress, si reutiliza el evaluador private sin conceder EXECUTE de ese helper, se propone un lector definer pequeño y explícitamente autorizado: seleccionar primero las metas propias mediante auth.uid y restringir todos sus vínculos antes de llamar al helper. Esta excepción se revisará con sus pruebas; no se debe otorgar acceso directo al helper ni confiar en RLS omitida por el propietario de la función. Una vista expuesta, si se necesita, será security_invoker y no otra vía de permisos.

No hay acceso colaborativo, público o anónimo, nuevas claves privilegiadas, Realtime ni Edge Functions por defecto. Un ID ajeno devuelve recurso no disponible sin confirmar su existencia.

## Migración e interoperabilidad, cuando se autorice implementar

1. Conservar historia de migraciones y datos de hábitos/perfiles. Crear una migración incremental en este repositorio, con RLS y permisos definidos antes de cualquier exposición.
2. Probar instalación limpia e incremento con registros previos, sin resetear la instancia de trabajo ni aplicar cambios remotos.
3. Implementar y probar evaluación compartida y RPC, incluyendo errores seguros y lectura paginada/coherente.
4. Generar types/database.types.ts desde PostgreSQL real aquí; el móvil importa ese artefacto con su pnpm db:types. No editar tipos a mano ni generarlos antes de tener esquema.
5. Mantener compatibles clientes anteriores y no habilitar navegación hasta disponer de contratos/recorridos completos.
6. Implementar primero Rutinas y verificar sus vínculos con Hábitos; después Metas y su progreso, y finalmente la integración completa de Hoy. Este orden no autoriza implementar durante la fase actual de definición.

## Evidencia requerida para implementación futura

- PostgreSQL real: roles A/B/anon y JWT ausente, permisos de tablas/columnas/RPC/helpers, intentos de vincular entidades ajenas y falsificar propietario/timestamps. Validar el lector definer con IDs de otro propietario.
- Restricciones de discriminantes, umbrales, rangos, posiciones, obligatoriedad y pertenencia; rechazo de cambios fuera de las operaciones admitidas.
- Hoy/ayer/mañana para Rutinas; [D−7,D] para Hábitos y ventana propuesta de Metas; medianoche, DST, cambios de semana, espera de bloqueos que cruza un corte y reintento ya confirmado fuera de ventana.
- Concurrencia de dos conexiones: duplicados de creación/aportes, revisiones obsoletas, edición/registro, archivo/registro y configuración futura reemplazada. Comprobar ausencia de interbloqueos y pérdida de actualización.
- Preservación de versiones aplicadas, registros de pasos retirados y datos previos de hábitos. No borrar pruebas de negocio ni datos personales.
- Meta vinculada por cantidad/días, parcial bajo mínimo, máximo un día por fecha, hitos por umbral, exceso, límite de transporte, archivo y correcciones que reabren el logro.
- Consistencia de lotes/paginación y de origen compartido en varias rutinas/metas; un fallo de lectura no equivale a cero.
- pnpm db:test, pruebas de reproducción/concurrencia pertinentes, lint SQL y generación/importación real de tipos. Sin nuevas pruebas SQL ni afirmaciones de seguridad verificada hasta implementar.

## Estado de esta entrega documental

No se ejecutaron migraciones, cambios de permisos, resets, generación de tipos ni despliegues. Las tablas, operaciones y pruebas descritas son un diseño para revisión. La seguridad y la corrección de las funcionalidades futuras todavía no están verificadas.

## Implementación posterior: Rutinas v1

El usuario autoriza implementar únicamente Rutinas el 27 de octubre de 2026. El [contrato v1](routines-v1.md) y [ADR-009](adr/009-routines-v1.md) documentan lo implementado y verificado localmente. Se utiliza un comprobante privado único y lectura compuesta desde móvil en lugar de dos tablas de comprobantes y get_routine_window. Las propuestas de Metas siguen sin implementar.
