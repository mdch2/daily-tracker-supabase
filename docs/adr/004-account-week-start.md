# ADR-004: inicio de semana y zona horaria elegidos por cuenta

- Estado: aceptada para inicio de semana, zona elegida por cuenta y preservación histórica; selección inicial y transición de cambios manuales pendientes.
- Fecha: 2026-10-21.

## Contexto

La frecuencia semanal de hábitos cuenta días distintos, según [ADR-003](003-habit-recurrence-modes.md). El usuario propone que cada persona pueda elegir si su semana comienza en lunes o domingo y acepta mantener esa preferencia en la cuenta y preservar los límites históricos de semanas cerradas.

El inicio de semana afecta el período evaluado, además del orden de columnas del calendario. Un domingo y el lunes siguiente pertenecen a semanas distintas cuando la semana empieza en lunes, y a la misma semana cuando empieza en domingo.

## Decisión

- Admitir lunes o domingo como inicio de semana elegido por la persona.
- Guardar la preferencia en Supabase como parte de la cuenta y compartirla entre sus dispositivos. No es una preferencia local independiente por dispositivo ni una configuración por hábito.
- Calcular días y semanas con una zona IANA elegida explícitamente para la cuenta, persistida en Supabase y compartida entre dispositivos. No cambiarla automáticamente al viajar ni cuando cambie la zona del teléfono. No inferirla del servidor, del idioma ni de la zona del equipo de desarrollo. La transición de un cambio manual sigue pendiente.
- Conservar los límites y el contexto temporal con los que se evaluó cada semana cerrada. Cambiar la preferencia actual no reagrupa sus fechas ni recalcula esas semanas bajo otra definición.
- Mantener los registros diarios asociados a su fecha de negocio. La preferencia semanal determina la agrupación, no modifica por sí sola las fechas originales.
- Usar la misma definición de período en hábitos, calendario, dashboard y estadísticas.

## Zona horaria elegida por cuenta

El 21 de octubre de 2026, el usuario acepta mantener una zona horaria elegida para la cuenta en vez de seguir automáticamente la zona del dispositivo.

- La misma zona de cuenta determina la fecha de negocio y los límites diarios/semanales en todos los dispositivos. La localización física o la preferencia horaria del teléfono no crean otra interpretación del mismo registro.
- Se conserva un identificador IANA, como `America/Bogota`, no solo un desplazamiento UTC. Es un ejemplo, no una zona por defecto. Mantener fija la elección no congela el offset: si la zona elegida tiene horario de verano, se usan sus reglas para la fecha correspondiente.
- `profiles.time_zone` ya existe, puede ser nulo y valida nombres IANA al actualizarse. Sin elección explícita, el contexto temporal no queda definido; el futuro flujo de hábitos no debe ocultarlo aplicando una zona del servidor o del teléfono.
- Conservar la fecha de negocio y el contexto temporal aplicados al guardar cada registro. No convertir de nuevo todos los instantes con la zona actual del perfil para reconstruir el historial.
- El usuario puede necesitar cambiar manualmente su zona; se debe definir su transición antes de implementar ese cambio con hábitos activos. Esta decisión no bloquea permanentemente la preferencia ni fija una fecha efectiva por omisión.

### Ejemplos de aceptación del diseño temporal

- Dos teléfonos de una cuenta, configurados con zonas de dispositivo diferentes, evalúan el mismo instante con la zona elegida para la cuenta.
- Viajar o cambiar la zona del sistema no mueve registros a otro día ni reinicia el progreso diario/semanal de la cuenta por sí solo.
- Un cambio manual posterior no reinterpreta las fechas de negocio ya guardadas ni los límites de semanas cerradas.
- Cuando `profiles.time_zone` es nulo, no se inventa una zona para registrar o evaluar hábitos.

Estos criterios no prueban una implementación de hábitos ni de cambios de zona: ambas continúan pendientes.

## Implicaciones para el diseño propuesto

La preferencia es dato remoto de la cuenta, separado de idioma y tema de dispositivo. El diseño podría añadir un campo como `week_start_day` al perfil o a un contrato equivalente; el nombre y su representación se cerrarán antes de migrar. La columna todavía no existe y la matriz actual de permisos de perfiles no se amplía con esta decisión.

Una semana histórica necesita identidad y límites estables, zona aplicada e información suficiente para identificar la regla vigente. Se pueden preservar mediante períodos explícitos o configuración temporal versionada; no se elige todavía una estructura de tablas.

Un único valor mutable en el perfil no basta para reconstruir todas las semanas pasadas. Las consultas de historial no deben reagrupar cada fecha con la preferencia más reciente. La visualización puede ordenar columnas según la preferencia aplicable, conservando la identidad y la evaluación de los períodos históricos.

El diseño de períodos debe impedir superposición y fechas sin período asignado. Sus límites son fechas locales con inicio incluido y fin excluido; los instantes se interpretan con la zona IANA correspondiente. No sustituir una semana local por una duración fija de 168 horas.

## Ejemplos de aceptación del diseño

| Configuración     | Domingo y lunes siguiente, dentro de la vigencia de esa configuración |
| ----------------- | --------------------------------------------------------------------- |
| Inicio en lunes   | Pertenecen a semanas distintas.                                       |
| Inicio en domingo | Pertenecen a la misma semana.                                         |

- Dos dispositivos de una misma cuenta consumen la misma preferencia confirmada.
- Una semana cerrada mantiene sus límites al cambiar la preferencia actual.
- El cambio no edita las fechas de los registros diarios ya guardados.

Estos ejemplos son criterios para la futura implementación; no son pruebas ejecutadas sobre un esquema nuevo.

Preservar los límites de una semana cerrada no prohíbe registrar o corregir datos de sus fechas. El registro/corrección histórica y el recálculo de estadísticas y rachas afectadas están aceptados en [ADR-005](005-habit-historical-records.md). La ventana permite los siete días anteriores, además del día actual; las fórmulas completas siguen pendientes; conservar límites no significa congelar los resultados frente a una corrección.

## Transición pendiente

Permitir elegir inicio de semana no cierra cómo cambiarlo durante una semana activa. Debe decidirse fecha efectiva, tratamiento de la semana en curso y posibles períodos parciales, sin días duplicados ni omitidos y sin penalizaciones inferidas por el cambio.

Aplicar el nuevo valor a una supuesta semana siguiente tampoco resuelve por sí solo la transición: los límites de domingo y lunes no coinciden. Por ejemplo, si la semana activa termina un lunes, el domingo que iniciaría una semana con la nueva regla puede estar antes o después de ese límite. No ejecutar un cambio global ni crear intervalos superpuestos como atajo.

## Otras decisiones pendientes

- Selección inicial o valor por defecto del inicio de semana; no inferirlo del idioma o de la región del dispositivo por omisión.
- Flujo de selección inicial de la zona horaria y transición al cambiarla manualmente: fecha efectiva, día/semana en curso y preservación de fechas. Viajar o cambiar la zona del teléfono no modifica la zona elegida.
- Semanas parciales al crear o editar un hábito y su efecto en metas, rachas y estadísticas.
- Contrato de actualización, permisos de columnas y pruebas de aislamiento antes de implementar.

## Alcance

Solo documentación de la decisión y sus consecuencias. No se crean columnas, tablas, migraciones, RPC, pantallas ni tipos generados. La transición temporal debe resolverse antes de implementar el cambio de preferencia con hábitos activos.

## Actualización de implementación: 22 de octubre de 2026

El [ADR-007](007-first-habit-delivery.md) y el [contrato v1](../habits-v1.md) cierran e implementan la primera entrega de registro. Las propuestas y pendientes anteriores describen el contexto original; los cambios de configuración, pausas y rachas siguen aplazados, conservando sus decisiones aprobadas.
