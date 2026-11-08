# Metas v1: diseño técnico listo para implementar

Fecha: 2026-10-30. Estado: contrato definido, sin migración ni RPC de Metas implementadas. Este documento prevalece sobre las propuestas de Metas de [routines-goals-plan.md](routines-goals-plan.md). La definición de producto está aprobada en el móvil, en docs/architecture/goals-v1.md y ADR-010; el contrato cliente está concretado en docs/architecture/goals-service-contract.md y ADR-011. No se importan fuentes de ese repositorio.

## Reglas conciliadas

- Descripción opcional hasta 400 caracteres; vacío normalizado a nulo. Nombres de 1–100, unidad de 1–30 y de 1 a 30 hitos. Longitudes por puntos de código Unicode después de recortar espacios exteriores, con paridad en móvil.
- Inicio explícito hoy o futuro, por calendario confirmado. Una meta vinculada creada hoy incluye todo el registro de hoy, aunque se guardase antes de crearla. Sin fechas anteriores al inicio ni saldo inicial sin fecha.
- Cantidad manual: aportes/sustituciones en [max(inicio,D−7),D]. Hitos manuales: confirmación, cambio de fecha o reversión entre inicio y hoy durante toda la meta sin archivar, sin corte de siete días, con historial.
- Una fuente por meta: manual o un hábito propio. Medida vinculada fija: cantidad acumulada (incluidos parciales bajo mínimo) o días cumplidos según definición histórica, como máximo uno por fecha. Hitos vinculados por umbrales crecientes, sin marcado manual ni conversiones.
- Nombre, descripción, límite y objetivo cuantitativo editables inmediatamente con historial. Modalidad, fuente, inicio, unidad, hábito, medida y estructura de hitos fijos.
- Archivo bloquea registro manual y configuración, sin restauración ni borrado definitivo. El vínculo incluye toda la fecha de archivo y conserva el efecto de correcciones permitidas y registros posteriores dentro de ese día; desde el siguiente no acumula.
- Prioridad de estado: archivada, programada, lograda, vencida, en curso. La fecha límite no corta la acumulación; lograr tampoco bloquea nuevos registros. Porcentaje truncado, presentación hasta 100 %, exceso real visible.
- Solo datos privados, sin guest, colaboración, Realtime, Edge Functions o dependencias nuevas. Idioma/tema son preferencias locales del móvil.

## Persistencia prevista

| Objeto                         | Responsabilidad                                                                                                                                                                                                           |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| public.goals                   | Identidad UUID, propietario, modalidad, fuente, inicio, zona fija, unidad de cantidad cuando aplique, vínculo y medida; created_at de servidor. No contiene progreso ni estado mutable.                                   |
| public.goal_versions           | Snapshots inmutables con goal_id, propietario, version positiva, effective_at, nombre, descripción, objetivo, límite y archived_at anulable. La mayor versión es la vigente; updated_at de transporte es su effective_at. |
| public.goal_milestones         | Identidad UUID, meta/propietario, posición desde 0, nombre y umbral anulable. Identidades/orden/umbrales se fijan al crear.                                                                                               |
| public.goal_amount_day_records | Un total manual por meta/fecha, propietario, cantidad exacta, revisión, recorded_at y updated_at.                                                                                                                         |
| public.goal_milestone_records  | Estado de un hito manual con meta/propietario, booleano, completion_date anulable, revisión y timestamps de servidor.                                                                                                     |
| private.goal_operations        | Un único almacén inmutable por usuario/UUID de operación, con meta, secuencia por meta, tipo, petición normalizada, before/after seguro, comprobante y accepted_at. Sirve a idempotencia e historial autorizado.          |

No crear goal_creation_requests adicional, contadores de progreso, banderas de logro ni copias de registros de Hábitos. El archivo se deriva de la versión vigente; archived_on se calcula en la zona fija.

PK, unicidad y FKs compuestas verifican pertenencia de meta, versión, hito, registro y hábito a la misma cuenta. Sin cascadas destructivas de negocio ni transferencia de propietario. Un hito manual completed=true exige fecha; false exige fecha nula. Solo su modalidad/fuente admite las filas correspondientes.

Los discriminantes validan las cuatro combinaciones: cantidad manual con unidad/objetivo y sin hitos/vínculo; hitos manuales sin unidad/objetivo/umbrales; cantidad vinculada con objetivo/hábito/medida; hitos vinculados con umbrales/hábito/medida y sin objetivo independiente. Unidad vinculada tomada del hábito, sin aceptar una alternativa del cliente; días cumplidos no persiste una traducción.

Valores exactos en milésimas: totales de 0 a 999999999999, objetivos/aportes positivos y umbrales crecientes dentro del rango. Días cumplidos exige múltiplos de 1000. Validar la suma manual completa bajo bloqueo antes de confirmar. Restricciones de filas, cardinalidad, posiciones consecutivas y compatibilidad interfilas deben proteger también escrituras de mantenimiento; usar constraints/triggers diferibles donde se requiera, además de RPC.

Índices iniciales justificados: listado por usuario/created_at/id; unicidad de versión por meta/version, hitos por meta/posición, total por meta/fecha, estado por hito, operación por usuario/operation_id y evento por meta/secuencia. FKs compuestas tienen sus claves únicas de destino. No duplicar índices cubiertos por esas claves; índices adicionales solo ante consultas reales.

## RPC definidas

Todas las nuevas RPC reciben exclusivamente p_input JSONB; payloads discriminados, claves conocidas, tipos estrictos, campos anulables explícitos y normalización estable. Transporte snake_case; el adaptador móvil valida y transforma. mode=amount/milestones, progress_source=manual/habit, linked_metric=amount/completed_days; state=archived/scheduled/achieved/overdue/in_progress en orden de prioridad. kind=create/edit/archive/amount_add/amount_set/milestone_set. En creación se prohíben campos de otra combinación incluso con nulo; description/deadline comunes sí reciben nulo explícito. Nunca se recibe user_id, reloj autoritativo, revisión nueva ni timestamps de servidor.

| RPC                    | Entrada principal                                                                                                                   | Respuesta                                                                                                    |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| create_goal            | operation_id, goal_id, nombre/descripción, inicio/límite, modalidad/fuente y medida discriminada; IDs de hitos anteriores al envío. | Comprobante de creación con versión 1.                                                                       |
| edit_goal              | operation_id, goal_id, expected_version y todos los campos editables, con nulos explícitos donde aplique.                           | Comprobante y nueva versión inmediata.                                                                       |
| archive_goal           | operation_id, goal_id, expected_version.                                                                                            | Comprobante, nueva versión, archived_at y archived_on.                                                       |
| record_goal_amount     | operation_id, goal_id, date, action add/set, amount_milliunits; expected_revision solo para set.                                    | Comprobante, fecha, total diario y revisión resultantes.                                                     |
| record_goal_milestone  | operation_id, goal_id, milestone_id, completed, completion_date y expected_revision.                                                | Comprobante, identidad, estado, fecha anulable y revisión.                                                   |
| get_goals              | status anulable y cursor anulable.                                                                                                  | Hasta 20 definiciones/progresos, next_cursor y cinco counts completos por estado, independientes del filtro. |
| get_goal               | goal_id.                                                                                                                            | Definición/progreso/hitos/origen o goal nulo si ajena o inexistente, incluidas archivadas.                   |
| get_goal_contributions | goal_id, from, to inclusivos, hasta 31 fechas.                                                                                      | Una fila por fecha, valores de origen y contribución según medida. No aplica a hitos manuales.               |
| get_goal_history       | goal_id, before_sequence/up_to_sequence anulables al inicio.                                                                        | Hasta 20 eventos seguros, up_to_sequence fijo y next_before_sequence.                                        |

Los comprobantes comunes contienen operation_id, goal_id, kind, accepted_at, goal_version y event_sequence. Son inmutables y no equivalen al estado vigente. Se vuelve a leer después de guardar.

Las definiciones transportan id, nombre/descripción, modalidad/fuente, fechas, zona, created_at, updated_at, version, archivo y configuración discriminada. Campos no aplicables explícitamente nulos, hitos como array ordenado. source es nulo o contiene habit_id, name, measurement_mode (binary/quantity), linked_metric y unit_label anulable para días localizados. Cantidad devuelve milestones vacío. El origen permite presentar/abrir el hábito sin otra lectura dependiente.

El detalle incluye estados manuales de hitos y sus revisiones; ausencia se proyecta pendiente/fecha nula/revisión 0. Hitos vinculados se evalúan desde su medida, sin revisión editable ni fecha de logro inventada. Cantidad manual no contiene estados de hitos.

Las filas de contribución contienen date, in_window, recorded, revision anulable, amount_milliunits/binary_value según origen, completed y contribution_milliunits anulable; vínculos incluyen source_definition_id. Ausencia no es cero/false confirmado. Fuera de ventana se devuelve in_window=false, recorded=false, valores/revisión/contribución nulos y completed=false, sin leer aportes de esas fechas. No hay ampliación de la ventana editable del hábito.

## Proyecciones y límites

Resolver el contexto de cuenta y una instantánea coherente de definiciones, registros, progreso, estado, conteos y página en una única sentencia de lectura, con helpers estables sin escrituras. Cada respuesta incluye context con read_at, today, time_zone y next_day_at. No componer lecturas REST independientes para fabricar ese resultado.

Extraer un evaluador privado de Hábitos con paridad frente a sus reglas vigentes: elegibilidad e isCompleted por definición histórica, incluidos hábitos flexibles y cantidades parciales. No cambiar RPC existentes ni duplicar algoritmos por cada proyección. La implementación actual de Rutinas móvil conserva su contrato; esta entrega no exige migrarla a otra lectura.

El acumulado usa aritmética exacta y resuelve estado/umbrales antes de transportar. Si una cantidad vinculada supera 999999999999 milésimas, progress devuelve available=false/error=amountLimit sin cantidad/porcentaje inventados; state y counts siguen siendo exactos. El resto de la página no es un fallo parcial: se trata de una variante conocida del dominio. Una lectura real fallida aborta la respuesta completa. No bloquear el escritor de Hábitos por límites de una meta.

Con progreso disponible, devolver accumulated_milliunits anulable en hitos manuales, completed_milestones/total_milestones anulables en cantidad y percentage entero truncado limitado a 100 para UI. El exceso cuantitativo real se conserva dentro del rango admitido.

Listado por created_at DESC, id DESC. Cursor de clave con versión de formato/filtro/última clave, validado como entrada no confiable y sin valor de autorización. Sin offset ni estado de paginación persistido. Cada página tiene su instantánea; no promete congelar estados entre peticiones. El móvil reinicia tras cambios, foreground, fecha o filtro para reflejar entradas/salidas de estados. Un cambio remoto entre páginas puede requerir refresco.

## Historial, revisiones y atomicidad

version cambia solo por configuración/archivo; revision cambia por escritura de un registro; event_sequence aumenta en cada operación nueva aceptada, incluida una confirmación explícita del mismo valor. Son enteros seguros para JavaScript, distintos de timestamps. Una operación repetida no genera otro evento/revisión.

El primer historial fija up_to_sequence al último evento comprometido; siguientes páginas usan ese límite y sequence < before_sequence, en orden descendente. Los números son enteros positivos seguros: before_sequence <= up_to_sequence y up_to_sequence no mayor que la secuencia comprometida de esa meta. Todo evento se filtra por meta/propietario, independientemente de los números recibidos; estos nunca autorizan acceso. Los eventos comprometidos son inmutables y el almacén se conserva durante la vida de la meta.

Proyectar solo sequence, operation_id, kind, accepted_at, fecha de negocio cuando aplique y before/after por tipo. Creación tiene before nulo. Mantener fecha anterior de hitos revertidos y total anterior de cantidades corregidas. No conceder SELECT al almacén privado ni exponer payloads internos.

El historial vinculado presenta contribuciones diarias actuales de Hábitos y cambios propios de configuración. No replica eventos de Hábitos ni promete el porcentaje histórico o la primera fecha en que se cruzó un umbral. No reconstruir avance sumando comprobantes.

Orden de bloqueo: identidad de operación por usuario/UUID; durante creación, identidad del hábito vinculado si aplica; después padre de meta. Creación inserta el padre y su definición/hitos/operación atómicamente; una meta propia ya existente con otra operación de creación falla como conflicto; un ID ajeno devuelve recurso no disponible, sin revelar su existencia. Registro, edición y archivo serializan por padre. Hábitos no adquiere bloqueos de metas dependientes; lectores no bloquean escritores.

Reconocer comprobante previo de petición normalizada antes de volver a exigir ventana, revisión o meta activa. Reutilización con otro contenido falla. Tras esperar bloqueos, capturar una sola vez el reloj autoritativo y revalidar inicio/fecha/calendario/archivo; nunca trasladar la fecha del borrador. Add usa el total vigente; set y los hitos exigen revisión observada (0 si ausencia). Dos sustituciones sobre la misma revisión no confirman ambas. Estado, historial y comprobante se confirman juntos.

## Errores y autorización

SQLSTATE reservados para Metas: GL001 identidad ausente, GL002 calendario pendiente, GL003 entrada inválida, GL004 recurso no disponible, GL005 operación reutilizada, GL006 fuera de ventana manual de cantidad, GL007 fecha no elegible, GL008 conflicto, GL009 archivado y GL010 límite de cantidad manual. En lectura vinculada se usa la variante amountLimit descrita. No exponer existencia ajena ni detalles internos.

RLS desde la creación de cada tabla pública/privada y revocación explícita de privilegios de PUBLIC, anon, authenticated y service_role antes de grants mínimos, sin alterar defaults o esquemas administrados. Tablas públicas: solo SELECT de filas propias a authenticated; sin INSERT/UPDATE/DELETE directo. No hay grants cliente sobre comprobantes, secuencias o helpers privados.

Escritores SECURITY DEFINER por ausencia de DML cliente, search_path vacío y objetos calificados. Lectores con helpers privados y auditoría privada necesitan una excepción definer pequeña y revisada: auth.uid no nulo, selección inicial solo de metas propias y vínculos/filas restringidos antes de evaluar. EXECUTE explícito por firma solo a authenticated. No confiar en RLS omitida por el propietario ni conceder EXECUTE de helpers a clientes.

## Secuencia de implementación y evidencia requerida

1. Migración incremental de Metas, sin reescribir migraciones existentes ni resetear la base de trabajo. No activar clientes antes de contar con todas las RPC de su contrato.
2. PostgreSQL real: restricciones, A/B/anon/JWT ausente, accesos cruzados en cada lector definer, denegación de DML/helpers y validación de pertenencia. Casos de cuatro discriminantes, 400/401 caracteres, Unicode, rangos y posiciones.
3. Paridad del evaluador de Hábitos, progresos por cantidad/días, límite vinculado, umbrales y correcciones que reabren logro. Coherencia de página/conteos y paginación de historial bajo escrituras.
4. Dos conexiones para duplicados, revisiones obsoletas, add/set, edición/archivo/registro, reloj tras bloqueo y reintento fuera de ventana. Verificar recuperación de hito antiguo, inicio/archivo por fecha completa, DST y archivo anterior al inicio futuro.
5. Reproducción limpia y migración incremental con datos previos sintéticos, sin perder perfiles/hábitos/rutinas. Usar el runner aislado existente ampliado cuando corresponda; no crear otro framework.
6. Ejecutar pnpm db:test, runner aislado y lint SQL afectados; generar tipos con pnpm db:types desde PostgreSQL real. El móvil importa ese artefacto con su propio comando y prueba sus adaptadores/recorridos.

Esta entrega solo documenta. No se ejecutaron migraciones, permisos, SQL, generación de tipos, resets o despliegues de Metas, ni se presenta seguridad futura como probada.

## Recompensa personal y compatibilidad v2 (2026-11-07)

La migración `20261107000100_goal_rewards.sql` añade `reward` anulable a `goal_versions`, con texto recortado de 1–400 puntos de código Unicode cuando existe. Texto vacío se normaliza a nulo. Las metas anteriores quedan sin recompensa; no se modifican sus versiones ni comprobantes.

`create_goal_v2` y `edit_goal_v2` exigen la clave `reward` explícita (texto o nulo). `get_goal_v2` y `get_goals_v2` incluyen `definition.reward`. Las RPC v1 mantienen su forma de lectura y sus huellas de idempotencia. Una edición v1 conserva la recompensa actual. Archivo la copia a la nueva versión y bloquea su edición posterior. El historial reutiliza `before`/`after`; no hay una tabla adicional ni un estado de recompensa recibida.

Los cuatro wrappers v2 son `SECURITY DEFINER`, con `search_path` vacío, identidad de `auth.uid()` y propiedad verificada por los helpers privados existentes. Solo `authenticated` tiene EXECUTE; PUBLIC, anon y service_role no reciben permisos nuevos. Los helpers siguen inaccesibles desde clientes. Las políticas y permisos de tablas no se amplían.

Verificación: suite pgTAP `goal-rewards.test.sql`, cadena incremental y reintento de una operación v1 creada antes de la migración en `db:test:habits:isolated`. Generar tipos con `pnpm db:types` y después importarlos en el móvil. Esta extensión se aplica localmente; no constituye despliegue remoto.
