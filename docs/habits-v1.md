# Hábitos v1: contrato implementado

La migración 20261021000100 incorpora la primera entrega de registro. El [ADR-007](adr/007-first-habit-delivery.md) cierra su alcance sin modificar las decisiones aprobadas de ADR-002 a ADR-006.

## Calendario y definición

`initialize_habit_calendar(time_zone, week_start_day)` confirma explícitamente una zona IANA reconocida y lunes (1) o domingo (7). Ambos valores se comparten por cuenta. No hay predeterminados ni cambios posteriores en esta versión; repetir los mismos valores es idempotente. Un perfil previo puede conservar time_zone sin haber confirmado todavía su calendario: week_start_day nulo identifica ese estado. Solo display_name admite UPDATE directo del cliente.

`get_habit_context()` es invocadora y respeta RLS de perfiles. Devuelve una fila con server_time, business_date, time_zone, week_start_day, week_start_date y next_day_at. Fechas y límites son nulos hasta confirmar el calendario, aunque el generador CLI no refleje su nullabilidad. El móvil debe validarla en ejecución.

`create_habit` recibe UUID estable, nombre de 1–100 caracteres y discriminantes de medición/programación. El inicio es hoy según reloj servidor y zona de cuenta al aceptar la creación. Repetir UUID y contenido devuelve la identidad existente; cambiar contenido con ese UUID se rechaza.

- `habits`: identidad, propietario, nombre, start_date y timestamps de servidor.
- `habit_definitions`: una definición inicial inmutable por hábito; effective_from, zona, inicio de semana, modo y frecuencia. Se conserva el contexto para reconstruir períodos, sin transiciones ni versiones editables todavía.
- Binarios sin meta ni unidad. Cuantitativos con mínimo positivo y etiqueta libre recortada de 1–30 caracteres; sin conversiones.
- Cantidades enteras en milésimas de la unidad elegida, entre 0 y 999999999999 (999999999.999 unidades). Meta y aporte requieren al menos una milésima; fijar total admite cero. Así cliente y PostgreSQL evitan suma de coma flotante.
- Frecuencia `daily`, `weekdays` con máscara de bits lunes=1 a domingo=64 (1–127), o `weekly` con objetivo entero de 1–7 fechas distintas. Los campos ajenos al discriminante son nulos.

## Estado diario y operaciones

`habit_day_records`, PK (habit_id, occurrence_date), es el estado confirmado autoritativo: binary_value o amount_milliunits, definición aplicada, revisión y timestamps. No hay fila equivale a ausencia; no se convierte en cero ni en false. Un cuantitativo cumple cuando su valor confirmado alcanza o supera el mínimo. El exceso se conserva sin generar fechas extra.

`record_habit_day` admite `set_binary`, `add_amount` y `set_total`. La identidad de operación es UUID creado antes del envío y único por usuario. Los comprobantes en `private.habit_day_operations` conservan petición normalizada y resultado original; no son un segundo total mutable ni una cola offline.

La RPC bloquea la identidad de operación y la fila del hábito, valida pertenencia y guarda estado/comprobante en una transacción. Repetir la misma petición devuelve el comprobante original sin otra escritura; reutilizar su identidad con contenido distinto falla. Las sustituciones necesitan expected_revision (0 para ausencia); un aporte no recibe revisión y se suma al valor más reciente bajo bloqueo.

Para nuevas aceptaciones, D es la fecha del reloj servidor en la zona conservada: fecha dentro de [D−7,D], no anterior al inicio y elegible por frecuencia. El corte se comprueba después de esperar bloqueos. Un reintento ya confirmado se reconoce antes del corte y sigue disponible fuera de ventana. El comprobante puede ser anterior al estado vigente: el cliente vuelve a leer y no lo aplica como una proyección nueva.

Las FKs compuestas mantienen propietario, hábito y definición coherentes. No hay DELETE de cliente ni cascadas de negocio; eliminar administrativamente una cuenta con hábitos requiere una política posterior explícita.

## Lectura y evaluación

El móvil calcula estados desde definición inmutable y registros, con fecha de referencia obtenida del contexto servidor. Un día programado abierto está pendiente/parcial y, si termina sin mínimo, no cumplido. Una corrección admitida puede cambiar ese resultado.

Una frecuencia semanal cuenta fechas distintas, nunca aportes. No considera cada fecha una obligación diaria. Una semana completa abierta muestra progreso y puede cumplir anticipadamente; al cerrar bajo X, no cumplida. La primera semana parcial conserva X y solo informa progreso, sin resultado ni penalización. Los límites se reconstruyen con zona/inicio de semana históricos, no con idioma o zona del teléfono. No se persisten porcentajes ni rachas.

Las consultas del móvil pagan por rangos acotados: listado de 30 hábitos, días para hasta 30 hábitos y hasta 31 fechas, e historial por páginas de 14 fechas incluyendo los límites semanales necesarios.

## Errores y autorización

SQLSTATE estables: HT001 identidad ausente; HT002 calendario pendiente; HT003 entrada inválida; HT004 recurso no disponible; HT005 identidad de operación reutilizada; HT006 fuera de ventana; HT007 fecha no elegible; HT008 conflicto de revisión; HT009 calendario ya confirmado; HT010 límite de cantidad. El cliente traduce códigos en es/en y nunca presenta mensajes internos.

RLS y SELECT propio para las tres tablas públicas de hábitos. Sin DML directo, acceso anon ni acceso al esquema private. Las tres RPC de escritura son SECURITY DEFINER con search_path vacío y autorización por auth.uid(); no reciben propietario ni timestamps. EXECUTE se concede por firma solo a authenticated. El contexto es SECURITY INVOKER.

## Verificación local

`pnpm db:test`: pgTAP transaccional con rollback, A/B/anon/JWT ausente, integridad, permisos, operaciones, conflictos y fronteras temporales. `pnpm db:test:habits:isolated`: crea una base desechable en el contenedor LOCAL, reproduce todas las migraciones de aplicación con el contrato mínimo sintético Auth y la función auth.uid instalada, comprueba un perfil previo, ejecuta pgTAP y usa dos conexiones cliente concurrentes. No clona datos personales ni resetea la base de la app; elimina exclusivamente la base temporal creada por el script. Esta reproducción no sustituye pruebas de todo el servicio Auth; `pnpm db:test:auth` sigue comprobando ese servicio real.

Las pruebas aisladas necesitan commits de preparación para compartir fixtures entre conexiones; viven exclusivamente en la base desechable. Los archivos pgTAP revierten sus fixtures.

Pausas, rachas, porcentajes agregados, archivo, edición de definición y cambios de calendario permanecen aplazados. Los ADR existentes conservan sus decisiones y pendientes para esas entregas. Sin despliegues remotos.
