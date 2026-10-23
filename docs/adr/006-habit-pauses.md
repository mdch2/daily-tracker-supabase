# ADR-006: pausas de hábitos con protección de racha limitada

- Estado: aceptada para duración, presupuesto móvil, reanudación y continuidad; efectos semanales y casos especiales pendientes.
- Fecha: 2026-10-21.

## Contexto

El usuario acepta pausar y reanudar conservando historial, pero limita el descanso protegido para mantener la constancia. Delega la elección de la unidad de conteo: se eligen días calendario consecutivos. Después aprueba pausas de uno a tres días, reanudación automática y un presupuesto de tres días protegidos por hábito en los últimos treinta días.

Las modalidades diaria, por días concretos y frecuencia semanal por días distintos se conservan, según [ADR-003](003-habit-recurrence-modes.md). Una pausa no convierte todos los hábitos en diarios.

## Decisión

- La persona elige una duración entera de uno, dos o tres días calendario consecutivos.
- La fecha de inicio cuenta como el primer día. La pausa termina al comenzar la fecha posterior al último día elegido, en la zona IANA de la cuenta. Se representa conceptualmente como `[start_date, end_date)`, con fin excluido.
- Al terminar, el hábito vuelve automáticamente a su programación habitual. Se permite reanudar antes.
- Cada hábito dispone de un máximo de tres fechas de pausa protegida en cualquier ventana móvil de treinta fechas calendario. Pueden usarse juntas o separadas; no es una cuota por mes del calendario ni una cuota compartida entre hábitos.
- Cada fecha consumida deja de contar contra el presupuesto al salir de la ventana móvil. Cerrar/reabrir una pausa no reinicia el presupuesto.
- La pausa conserva una racha previa válida sin aumentarla ni generar días completados o cantidades ficticias. No crea una racha inexistente, no recupera un incumplimiento anterior y no completa el umbral de activación por sí sola.
- Terminar la pausa no rompe la racha a medianoche. La persona tiene oportunidad de cumplir el siguiente día exigible según su programación; si lo incumple, se interrumpe la continuidad conforme a las reglas de esa modalidad.
- Conservar historial es independiente de conservar continuidad: no se borran registros ni rachas históricas al interrumpirse una racha actual.

## Conteo y presupuesto

Se cuentan todas las fechas de la pausa explícita, incluso si alguna no tenía actividad programada. Fuera de una pausa explícita, los días no programados siguen siendo descanso normal: no consumen presupuesto ni constituyen incumplimiento.

Contar solo días programados podría prolongar una pausa durante semanas en un hábito poco frecuente. Por eso el máximo se expresa en fechas consecutivas de la zona de cuenta, no en días elegibles ni en 72 horas exactas.

Para cualquier fecha `D`, el intervalo móvil de treinta fechas es `[D - 29 días, D]`. El número de fechas distintas de pausa protegida de ese hábito dentro del intervalo no puede superar tres. El presupuesto no se reinicia al cambiar de semana, mes o año.

La futura escritura debe validar la duración y disponibilidad en el servidor de forma atómica, coordinando solicitudes concurrentes y pausas ya reservadas. Una pausa programada solo puede confirmarse si sus fechas, junto con las demás confirmadas, respetan el máximo en todas las ventanas afectadas. No guardar una cartera de créditos independiente del historial que pueda desincronizarse.

Reanudar antes deja de reservar/consumir las fechas futuras que ya no estén pausadas; no devuelve por sí solo las fechas ya consumidas. Una pausa que comienza a mitad de una fecha, cuando el contrato permita ese caso, cuenta esa fecha como primer día. El tratamiento de actividad ya registrada en esa fecha sigue pendiente.

## Reanudación

El estado efectivo se determina por el intervalo confirmado y el reloj del servidor en la zona aplicable. Volver a la programación no debe depender de que el móvil esté abierto ni de que la persona pulse un botón de reanudación.

Ejemplo: una pausa de viernes a domingo termina al empezar el lunes. El lunes vuelve a ser exigible si corresponde al hábito; no se pierde la racha solo por llegar la medianoche. Si el siguiente día programado fuera el martes, el descanso normal del lunes no crea un incumplimiento.

Una solicitud de cuatro días consecutivos o que exceda el presupuesto disponible se rechaza. No se permite ampliar indefinidamente la pausa manteniendo protección. Dividir una ausencia en varias solicitudes no elude ni la duración máxima continua ni el presupuesto móvil.

## Criterios para el diseño

- Conservar intervalos y contexto temporal que permitan reconstruir pausas históricas. Un booleano de pausa actual no basta.
- Mantener identidades de operación y reintentos sin duplicación. No volver a consumir presupuesto al reintentar una confirmación ya guardada.
- Resolver intervalos adyacentes o superpuestos como un mismo descanso continuo para verificar el máximo, sin contar dos veces la misma fecha.
- Los días pausados no aportan cumplimiento a la meta semanal. Su efecto en semanas parciales, denominadores y rachas no diarias sigue pendiente; no reducir la meta por omisión.
- Las correcciones de cumplimiento de los siete días anteriores siguen [ADR-005](005-habit-historical-records.md). Editar pausas retroactivamente o registrar actividad dentro de ellas requiere reglas propias.
- Dashboard, calendario, detalle y estadísticas deben compartir la misma interpretación y distinguir pausa, realización e incumplimiento.

## Ejemplos de aceptación

Se supone una racha previa válida, disponibilidad y fechas elegibles salvo indicación contraria. Son criterios de diseño, no pruebas ejecutadas.

| Situación                                                                         | Resultado esperado                                                                               |
| --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Pausa viernes, sábado y domingo                                                   | Consume tres fechas; el lunes vuelve la programación sin romper la racha a medianoche.           |
| Solicitar una pausa de cuatro fechas consecutivas                                 | Solicitud rechazada.                                                                             |
| Usar un día protegido                                                             | Quedan como máximo dos fechas adicionales disponibles mientras ese día siga en la ventana móvil. |
| Usar tres fechas protegidas y solicitar otra antes de que alguna salga de ventana | Solicitud rechazada.                                                                             |
| Una fecha consumida es exactamente `D - 29`                                       | Sigue dentro de la ventana y consume presupuesto.                                                |
| Una fecha consumida es `D - 30`                                                   | Ya está fuera de ventana y no consume presupuesto.                                               |
| Cerrar y reabrir una pausa                                                        | No restituye fechas consumidas ni renueva el presupuesto.                                        |
| Reintentar una solicitud ya confirmada                                            | No crea otro intervalo ni duplica el consumo.                                                    |
| Día no programado fuera de pausa                                                  | Descanso normal, sin consumo ni incumplimiento.                                                  |

## Decisiones pendientes

1. Metas semanales, semanas parciales y denominadores; fórmulas de rachas por modalidad no diaria.
2. Protección de la fase previa a la activación de una racha, sin sumar días realizados.
3. Inicio sobre fechas con registros previos, actividad durante una pausa y edición retroactiva de pausas.
4. Fechas de inicio permitidas, detalle de reanudación anticipada dentro del día y transición al cambiar manualmente la zona de cuenta con una pausa activa.

## Alcance

Documentación de las reglas aprobadas y criterios de aceptación. No crea tablas, migraciones, RPC, algoritmos ni pantallas. La implementación futura debe probar presupuesto, concurrencia, cortes temporales y los contratos especiales que todavía están pendientes.
