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
