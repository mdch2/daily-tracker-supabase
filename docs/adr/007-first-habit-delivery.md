# ADR-007: primera entrega de registro de hábitos

- Estado: aceptada; implementación local.
- Decisiones confirmadas: 2026-10-21. Implementación y verificación: 2026-10-22.

## Decisión

Entregar creación, listado, detalle y registro de hábitos binarios/cuantitativos con las tres frecuencias ya aprobadas, aportes y fijación de total, reversión binaria y correcciones de los siete días anteriores. La zona IANA y lunes/domingo se confirman explícitamente antes del primer hábito y permanecen fijos en esta versión. El hábito comienza hoy al confirmar el servidor.

Unidad libre con hasta tres decimales; sin conversiones. Persistir milésimas enteras en rango seguro para JavaScript. Una semana inicial parcial conserva la meta X y es informativa, sin resultado ni penalización. Días programados y semanas completas que cierran sin alcanzar la meta muestran no cumplido; mientras están abiertos siguen pendientes/en progreso. Las correcciones recalculan los resultados derivados usando la definición histórica.

Elegir estado diario autoritativo con comprobantes inmutables, guardados atómicamente. Aportes aditivos se serializan; las sustituciones exigen revisión observada. La respuesta de una operación no se usa para sobrescribir un estado más nuevo.

## Alternativas y consecuencias

Un log de eventos completo no aporta una necesidad actual; los comprobantes preservan auditoría e idempotencia sin construir un motor de eventos. La ausencia de registro sigue siendo distinta de cero o false. Las RPC privilegiadas se justifican porque el cliente no recibe escrituras directas sobre estado ni calendario.

Aplazar cambios de definición/calendario evita introducir ahora reglas no aprobadas de transiciones. La definición inicial conserva contexto y vigencia para el historial. Pausas, rachas, porcentajes agregados, archivo y edición posterior quedan fuera de esta entrega, sin revocar ADR-002 a ADR-006 ni el umbral diario aprobado de tres días del móvil.

El [contrato v1](../habits-v1.md) describe esquema, RPC, cantidades, errores y verificación. Solo se aplica localmente; no autoriza despliegues remotos.
