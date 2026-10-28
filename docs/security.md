# Seguridad y autorización

## Política permanente

PostgreSQL decide el acceso mediante privilegios de objetos y RLS. Las validaciones del móvil, los filtros del cliente y la clave pública no sustituyen estos controles. Las normas obligatorias de desarrollo están en [AGENTS.md](../AGENTS.md#normas-obligatorias-de-autorización-y-rls).

El modelo es privado por propietario y deniega operaciones no autorizadas. No se definen todavía roles de producto, colaboración ni acceso público. La configuración mantiene deshabilitados los Anonymous Sign-Ins; no deben confundirse con el rol PostgreSQL anon, que representa peticiones sin sesión.

## Matriz de acceso vigente

| Objeto          | Rol                                | SELECT             | INSERT   | UPDATE                              | DELETE   |
| --------------- | ---------------------------------- | ------------------ | -------- | ----------------------------------- | -------- |
| public.profiles | anon                               | Denegado           | Denegado | Denegado                            | Denegado |
| public.profiles | authenticated con identidad válida | Solo perfil propio | Denegado | Solo display_name del perfil propio | Denegado |
| public.profiles | authenticated sin sub o sin perfil | Ninguna fila       | Denegado | Ninguna fila en columnas permitidas | Denegado |

El propietario es id = auth.uid(); USING protege las filas existentes y WITH CHECK valida el resultado del UPDATE. No hay transferencia de propiedad ni escritura cliente de timestamps. Los valores de user_metadata no conceden acceso. La PK ya indexa la columna de propiedad.

Auth crea perfiles mediante el trigger private.create_profile, que usa SECURITY DEFINER con search_path vacío y nombres calificados. private.prepare_profile_update ejecuta como invocador, valida la zona y mantiene updated_at. Ninguna función interna tiene EXECUTE para PUBLIC, anon, authenticated o service_role y private no está expuesto por la API. Los triggers invocan sus funciones sin necesitar conceder EXECUTE al cliente.

La eliminación administrativa de auth.users elimina su perfil por la FK ya existente. Esto no habilita el borrado desde el móvil ni define cascadas para futuros datos de negocio.

Los roles administrativos y service_role pertenecen al servidor y pueden omitir RLS; las políticas cliente no limitan por sí solas esas sesiones. Se conservan los permisos administrativos existentes de profiles y no se introduce ningún recorrido privilegiado nuevo.

## Migraciones y permisos por defecto

- 20261016000100_profiles.sql se conserva sin cambios: ya incorpora RLS, políticas por propietario y permisos de columnas.
- 20261017000100_security_baseline.sql refuerza esa base de forma incremental: revoca acceso de PUBLIC y clientes antes de restaurar únicamente SELECT y UPDATE de las dos columnas entonces autorizadas, explicita la identidad no nula en ambas políticas y restringe CREATE de clientes en public.
- Para objetos futuros creados por postgres, se eliminan permisos automáticos de tablas, secuencias y funciones en public/private, también para service_role. Cada necesidad de acceso se concede en la migración del objeto. Los defaults no activan RLS automáticamente: toda tabla nueva debe hacerlo explícitamente.
- EXECUTE de funciones se revoca también globalmente para objetos futuros de postgres. PostgreSQL suma defaults globales y de esquema: revocar solo en public no elimina el permiso global de PUBLIC. Esto afecta también funciones futuras en otros esquemas, incluidas extensiones creadas por ese rol, y requiere conceder su acceso deliberadamente. Las extensiones existentes y los defaults de roles administrados por Supabase no se modifican.
- No hay cambios de columnas ni datos, por lo que el contrato TypeScript de profiles permanece igual. La recuperación ante una incidencia se hace con otra migración revisada; no reabrir permisos globales ni deshabilitar RLS como solución rápida.

Aplicar localmente con `pnpm exec supabase migration up --local`; no requiere resetear los datos. Verificar también la cadena completa en una base local desechable. Nunca ejecutar db:reset sobre datos que deban conservarse. Ninguna de estas instrucciones autoriza despliegues remotos.

## Evidencia requerida

`supabase/tests/database/profiles.test.sql` comprueba el contrato del perfil con roles reales: lectura y actualización propias, aislamiento en ambos sentidos, identidad ausente/desconocida, metadatos editables sin privilegios, operaciones y columnas denegadas, validación y creación/borrado por Auth.

`supabase/tests/database/security.test.sql` comprueba RLS en tablas de aplicación expuestas, esquemas internos, funciones de trigger y denegación efectiva de acceso a tablas, secuencias y funciones creadas dentro de la prueba. Las pruebas revierten tanto fixtures como objetos y permisos auxiliares de pgTAP al terminar.

Comando normal: `pnpm db:test`. Si el runner no está disponible, ejecutar los mismos archivos con psql contra PostgreSQL real, comprobar el plan completo y que no aparezcan fallos TAP; documentar esa diferencia. Un lint o una revisión de SQL no sustituyen esta ejecución.

En PowerShell, desde este repositorio y con el contenedor local iniciado:

```powershell
foreach ($file in Get-ChildItem supabase/tests/database/*.test.sql) {
  $tap = Get-Content -LiteralPath $file.FullName -Raw |
    docker exec -i supabase_db_daily-tracker psql -U postgres -d postgres -X -A -t -v ON_ERROR_STOP=1
  $sqlExit = $LASTEXITCODE
  $plans = @($tap | Select-String '^1\.\.(\d+)$')
  $tap | Select-String '^(1\.\.|ok |not ok |#)'
  if ($sqlExit -ne 0 -or $plans.Count -ne 1) { throw "SQL o plan incompleto: $file" }
  $expected = [int]$plans[0].Matches.Groups[1].Value
  $passed = @($tap | Select-String '^ok ').Count
  if ($passed -ne $expected -or @($tap | Select-String '^not ok |^# Looks like').Count -gt 0) {
    throw "Fallo TAP: $file"
  }
}
```

Esta conexión administrativa prepara fixtures y comprueba el catálogo; las operaciones de aislamiento del perfil cambian explícitamente a authenticated/anon. La verificación adicional del rol de Auth requiere una conexión local con ese rol: postgres no puede asumir supabase_auth_admin mediante SET ROLE. No ampliar membresías administrativas para hacer pasar un test.

## Referencias

- [Supabase: RLS](https://supabase.com/docs/guides/database/postgres/row-level-security).
- [Supabase: protección de la API y grants](https://supabase.com/docs/guides/api/securing-your-api).
- [Supabase: funciones y privilegios](https://supabase.com/docs/guides/database/functions).
- [PostgreSQL 17: ALTER DEFAULT PRIVILEGES y límites de los defaults por esquema](https://www.postgresql.org/docs/17/sql-alterdefaultprivileges.html).

## Hábitos v1 — 22 de octubre de 2026

La migración 20261021000100 conserva SELECT propio de profiles y UPDATE directo solo de display_name. time_zone deja de ser editable directamente; week_start_day tampoco recibe UPDATE cliente. initialize_habit_calendar confirma ambos atómicamente y bloquea cambios posteriores.

| Objeto/operación                                                   | authenticated con identidad                                | anon / PUBLIC |
| ------------------------------------------------------------------ | ---------------------------------------------------------- | ------------- |
| habits, habit_definitions, habit_day_records: SELECT               | Solo propietario mediante RLS                              | Denegado      |
| Tablas de hábitos: INSERT/UPDATE/DELETE y columnas de servidor     | Denegado                                                   | Denegado      |
| get_habit_context: EXECUTE                                         | Permitido; invocadora y RLS de profiles                    | Denegado      |
| initialize_habit_calendar, create_habit, record_habit_day: EXECUTE | Permitido por firma, autorización explícita por auth.uid() | Denegado      |
| private.habit_day_operations y helpers internos                    | Sin acceso                                                 | Sin acceso    |

Las RPC de escritura necesitan privilegios definer por la ausencia deliberada de DML cliente. Fijan search_path vacío y califican objetos; validan propietario, modalidad, elegibilidad y calendario/ventana antes de aceptar nuevas escrituras. No confían en metadatos editables ni reciben user_id. service_role no recibe grants nuevos para estos objetos. Las FKs compuestas impiden relaciones privadas cruzadas. No se incorporan cascadas de negocio.

La suite de hábitos y la prueba aislada de concurrencia se describen en [hábitos v1](habits-v1.md). Los resultados de las secciones anteriores son evidencia histórica de la base previa.

## Edición de hábitos — 23 de octubre de 2026

`rename_habit` y `edit_habit` solo conceden EXECUTE a authenticated por sus firmas; las RPC exigen auth.uid(), propietario y token observado. No amplían grants ni políticas de las tablas públicas. `private.habit_creation_requests` y `private.habit_edit_operations` tienen RLS y deniegan acceso a PUBLIC, anon, authenticated y service_role. El servidor conserva los payloads y timestamps.

Las 216 comprobaciones pgTAP incluyen las nuevas funciones y conservación histórica. La prueba aislada añade conservación exacta durante migraciones y dos conexiones reales para duplicados y conflictos de metadatos/configuración. Véanse [ADR-008](adr/008-habit-editing.md) y [contrato de edición](habit-editing.md).

## Rutinas v1 — 27 de octubre de 2026

Las cinco tablas públicas de Rutinas conceden solo SELECT propio por RLS; sin DML directo, acceso anon, cambio de propietario o timestamps cliente. private.routine_operations y helpers no conceden acceso cliente. create_routine, edit_routine, archive_routine y record_routine_step son definer con search_path vacío y autorización por auth.uid; get_routines es invocadora con RLS. EXECUTE explícito por firma solo para authenticated. Sin grants nuevos a service_role ni cambios de defaults. Las FKs compuestas y validaciones transaccionales rechazan vínculos ajenos. Evidencia: 85 pruebas nuevas de Rutinas dentro de las 301 comprobaciones pgTAP y concurrencia real del [contrato v1](routines-v1.md).
