# ADR-003: programación por días y frecuencia semanal de hábitos

- Estado: aceptada para modalidades y conteo semanal por días distintos; límites temporales y cálculo completo pendientes.
- Fecha: 2026-10-21.

## Contexto

El MVP incluye hábitos binarios y cuantitativos con aportes y fijación de total, según [ADR-002](002-habit-measurement-modes.md). Durante la revisión, el usuario confirma programación diaria, días concretos y metas de X veces por semana sin días fijos. No hay tablas de hábitos aplicadas todavía.

## Decisión

Se incluyen las siguientes modalidades de programación:

| Modalidad                         | Intención                                                                             | Ejemplo                         |
| --------------------------------- | ------------------------------------------------------------------------------------- | ------------------------------- |
| Diaria                            | La actividad está programada todos los días de su vigencia.                           | Leer cada día.                  |
| Días concretos                    | La actividad está programada en los días de la semana elegidos.                       | Entrenar los lunes y viernes.   |
| Frecuencia semanal sin días fijos | Alcanzar una cantidad de cumplimientos en la semana sin asignar de antemano sus días. | Entrenar tres veces por semana. |

La programación diaria y por días concretos pertenece a la familia de días asignados. La frecuencia semanal sin días fijos es otra familia: no genera por omisión tres citas fijas ni considera cada día de la semana una obligación incumplida.

El usuario aclara que la frecuencia semanal cuenta días distintos con cumplimiento, con un máximo de uno por hábito y fecha de negocio. Tres veces por semana significa completar el hábito en tres días distintos; repetirlo tres veces el mismo día solo cuenta como un día. La razón es distribuir la práctica para formar el hábito, en lugar de concentrarla en una jornada. No equivale por sí sola a una cantidad semanal, como leer 100 páginas entre todos los días; esa agregación de cantidades no queda autorizada por esta decisión.

## Implicaciones para el diseño

- Distinguir el modo de medición (binario/cuantitativo) de la programación. Las cantidades no convierten automáticamente cada aporte en un cumplimiento adicional.
- Contemplar en la programación vigente un discriminante entre días asignados y frecuencia semanal, días elegidos cuando correspondan, y número objetivo de cumplimientos cuando corresponda. Los nombres y la estructura de columnas siguen propuestos.
- Identificar el cumplimiento diario por hábito y fecha de negocio. La futura representación del estado diario debe impedir duplicar ese cumplimiento; los aportes cuantitativos individuales sí pueden ser varios en la misma fecha y necesitan su propia identidad de operación.
- La meta semanal es un número entero entre 1 y 7 días distintos por semana completa, consecuencia del máximo de un cumplimiento por día. El tratamiento de semanas parciales sigue pendiente; no reducir ni prorratear la meta por omisión.
- En hábitos cuantitativos, agrupar los aportes por fecha para evaluar el mínimo diario: el valor confirmado alcanza o supera la meta vigente, según ADR-002. Una fecha que ya cumple no añade otro día al conteo semanal al recibir más aportes. El exceso de un día no cuenta como cumplimiento de otras fechas.
- Usar zona IANA explícita de la cuenta y su elección de inicio de semana en lunes o domingo, según [ADR-004](004-account-week-start.md). La preferencia se comparte entre dispositivos y no reagrupa semanas cerradas. El idioma, el reloj del servidor y la zona del equipo no fijan estos límites.
- Conservar la interpretación del pasado ante cambios de programación mediante vigencia explícita. Inicio, fin y edición de una semana parcial necesitan su propio contrato.
- Dashboard, calendario y estadísticas deben usar la misma programación. El calendario distingue días asignados de progreso semanal flexible.
- La evaluación de cumplimiento, el momento de cierre y la definición de rachas se resolverán por modalidad; el umbral de tres días para hábitos diarios no se extrapola a semanas.

## Ejemplos que distinguen modalidades

- Un hábito de lunes y viernes asigna esas fechas durante su vigencia. Completarlo el martes no sustituye automáticamente el lunes.
- En una frecuencia de tres veces por semana no se asignan lunes, miércoles y viernes por omisión.
- Tres realizaciones el lunes representan un día completado; no satisfacen una meta de tres días semanales.
- Cumplir lunes, miércoles y viernes representa tres días distintos dentro de la misma semana y alcanza una meta de tres días.
- Cumplir lunes y martes representa progreso de 2/3 días; la semana no se clasifica automáticamente como incumplida mientras siga abierta.
- Varios aportes cuantitativos en un día contribuyen al valor de ese día, pero como máximo generan un día de cumplimiento semanal. El criterio cuantitativo es alcanzar o superar la meta mínima con el valor guardado y confirmado, según ADR-002; los límites máximos quedan excluidos.

Estos son criterios de diseño; no se han ejecutado algoritmos ni pruebas sobre tablas de hábitos.

## Decisiones pendientes

1. Selección inicial y transición de cambios manuales de zona de negocio e inicio de semana, y tratamiento de semanas parciales. La zona elegida por cuenta, sin cambio automático al viajar, el inicio en lunes/domingo y la preservación histórica están aceptados en ADR-004.
2. Evaluación y cierre de días que no alcanzaron el mínimo, porcentajes de presentación y detalle del recálculo tras correcciones, ya aprobado en ADR-005. El mínimo cuantitativo y el progreso parcial ya están definidos en ADR-002.
3. Períodos abiertos, detalle de corrección histórica, contratos de pausa, archivo y fecha efectiva de cambios. Pausar/reanudar y la protección de racha hasta tres días calendario consecutivos están aceptados en [ADR-006](006-habit-pauses.md); se cuentan fechas en la zona de la cuenta. Se aprueban reanudación automática y máximo de tres fechas protegidas por hábito en treinta fechas móviles; el efecto semanal y los casos especiales siguen pendientes. Registrar y corregir los siete días anteriores, además del día actual, está aceptado en [ADR-005](005-habit-historical-records.md); la ventana se cuenta por fechas de la cuenta, sin depender del inicio de semana.
4. Rachas y métricas de cada modalidad, sin reinterpretar el umbral ya decidido para el caso diario.

## Alcance

Esta decisión documenta el alcance confirmado. No añade tablas, migraciones, RPC, algoritmos ni pantallas. El esquema se cerrará con las reglas anteriores antes de implementarse.

## Actualización de implementación: 22 de octubre de 2026

El [ADR-007](007-first-habit-delivery.md) y el [contrato v1](../habits-v1.md) cierran e implementan la primera entrega de registro. Las propuestas y pendientes anteriores describen el contexto original; los cambios de configuración, pausas y rachas siguen aplazados, conservando sus decisiones aprobadas.
