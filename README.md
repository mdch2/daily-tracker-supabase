# Daily Tracker Supabase

Repositorio exclusivo del backend de Daily Tracker. La app móvil vive en [mdch2/daily-tracker](https://github.com/mdch2/daily-tracker).

Este repositorio posee PostgreSQL, migraciones, RLS, funciones, triggers, configuración Supabase y pruebas SQL. La configuración, migración inicial de perfiles y seed se trasladaron íntegros desde el móvil; la migración inicial conserva su contenido original. Los cambios posteriores son incrementales.

## Requisitos y comandos

Node.js 22 compatible, pnpm 10.28.2, Supabase CLI compatible y Docker con motor Linux. Verificación de seguridad realizada con CLI 2.121.0 y PostgreSQL 17.11.0.004.

```powershell
pnpm db:start
pnpm exec supabase migration up --local
pnpm db:test
pnpm db:test:auth
pnpm exec supabase db lint --local --level warning
pnpm db:types
```

`migration up --local` aplica migraciones pendientes sin resetear datos. `pnpm db:reset` destruye los datos locales: usarlo exclusivamente con una instancia desechable. Ningún comando de este flujo autoriza un despliegue remoto.

`db:types` genera `types/database.types.ts` desde PostgreSQL local y conserva el artefacto anterior si falla. No se admiten sustitutos escritos a mano. En el móvil, su propio `pnpm db:types` importa este artefacto sin administrar PostgreSQL; si los repositorios no son hermanos, se proporciona la ruta explícita al importador.

## Seguridad obligatoria

Leer [AGENTS.md](AGENTS.md), la [política y matriz de acceso](docs/security.md) y la [decisión de autorización](docs/adr/001-access-control.md) antes de cambiar el esquema o permisos.

- Acceso denegado por defecto, RLS en cada tabla de aplicación expuesta y permisos explícitos por rol, operación y columna.
- Perfiles privados por propietario autenticado; anon no puede acceder. Solo display_name admite UPDATE directo; el calendario se confirma por RPC y permanece fijo en hábitos v1. Auth crea los perfiles y administra la eliminación de cuentas.
- Las funciones internas no se exponen como RPC. Las funciones privilegiadas fijan search_path y requieren revisión de autorización.
- No usar claves privilegiadas en el móvil, metadatos editables como permisos ni datos personales en fixtures.
- Cada cambio de autorización requiere pruebas reales con roles cliente sobre PostgreSQL. Los mocks del móvil no prueban RLS.

Los permisos administrativos existentes no convierten service_role en un rol cliente. El acceso sin registro, los roles de producto y las futuras entidades de negocio siguen sin definirse.

## Verificación del 17 de octubre de 2026

- La migración incremental 20261017000100 se aplicó sobre la base local con la migración inicial ya registrada. También se reprodujo la cadena completa desde una base local vacía.
- **65 comprobaciones pgTAP correctas:** 34 de perfiles y 31 de permisos. Las nuevas pruebas de permisos detectaban 12 fallos antes del refuerzo.
- Las pruebas se ejecutaron directamente con psql y después mediante **`pnpm db:test`: PASS, 2 archivos y 65 pruebas**. La descarga inicial de pg_prove falló por DNS; un reintento posterior descargó correctamente `public.ecr.aws/supabase/pg_prove:3.36`, sin cambiar ajustes de red. El [procedimiento alternativo](docs/security.md#evidencia-requerida) sigue disponible si el runner no puede descargarse en otro entorno.
- Lint SQL local sin errores y tipos generados desde PostgreSQL. Creación y eliminación sintéticas con el rol real supabase_auth_admin verificadas en una transacción revertida.
- Sin fixtures residuales ni cambios remotos. La migración inicial conserva su SHA-256 original.

El entorno pudo iniciar la base con su imagen PostgreSQL 17.11.0.004 ya disponible, tras corregir una caché CLI local que apuntaba a 17.11.0.003. Esa caché se encuentra en supabase/.temp, ignorado por Git; no se cambió la configuración versionada para resolverlo.

El [modelo de datos](docs/data-model.md) describe el esquema actual y distingue las propuestas futuras que todavía no tienen DDL.

## Registro local y configuración de Auth

Auth exige un mínimo de **8 caracteres**, alineado con la validación de la app (8–128). Las confirmaciones por correo permanecen habilitadas. Después de modificar `supabase/config.toml`, ejecuta `pnpm db:restart`: detiene e inicia la instancia local con la nueva configuración, conservando los datos. `db:start` sobre servicios ya iniciados no aplica cambios de configuración.

No se necesita `db:fresh` para corregir el registro. El comando existente `pnpm db:reset` ya reconstruye la base local y destruye sus datos; resérvalo para instancias descartables. Estos comandos no cambian proyectos remotos.

`pnpm db:test:auth` usa exclusivamente las URLs locales devueltas por Supabase CLI. Comprueba rechazo con 7 caracteres, registro con 8, confirmación obligatoria, entrega de correo al buzón local, callback `dailytracker://callback`, intercambio PKCE S256 y lectura del perfil mediante REST con el token del propietario. Solo la limpieza del usuario sintético usa credenciales administrativas locales; la comprobación del perfil usa el rol autenticado. El usuario y su correo se eliminan al terminar. Los secretos y las sesiones permanecen en memoria y no se imprimen. Para elegir el correo: `pnpm db:test:auth --email user1-test@gmail.com`. Si la dirección ya existe, la prueba se detiene antes de modificarla; la limpieza solo elimina la cuenta nueva creada por la prueba.

Para Android, configura la app con `http://10.0.2.2:54321` o reenvía explícitamente `adb reverse tcp:54321 tcp:54321`. `127.0.0.1` dentro del emulador no apunta al equipo. Metro solo reenvía su propio puerto. Reinicia Expo y recarga la app tras editar su `.env`.

### Verificación del 21 de octubre de 2026

Se reprodujo el fallo de registro con 8 caracteres contra Auth local: `422 weak_password` al exigir todavía 12. Tras alinear la configuración y reiniciar sin resetear datos, la prueba de Auth completa pasó y eliminó su cuenta sintética. `pnpm db:test`: 65 comprobaciones pgTAP correctas. Lint SQL local sin errores. No hubo cambios de esquema, permisos ni despliegues remotos.

## Hábitos v1

Registro binario/cuantitativo con las tres frecuencias, calendario explícito y correcciones de siete días: [contrato implementado](docs/habits-v1.md), [ADR-007](docs/adr/007-first-habit-delivery.md). Verificación adicional: `pnpm db:test:habits:isolated`. El esquema se actualiza incrementalmente con `pnpm exec supabase migration up --local`. Sin despliegues remotos.

### Verificación de hábitos: 22 de octubre de 2026

Migración incremental local aplicada sin reset. `pnpm db:test`: 165 comprobaciones en tres archivos correctas; lint SQL sin errores. `pnpm db:test:habits:isolated`: migraciones de aplicación, conservación de perfil y concurrencia de dos conexiones correctas, con base temporal eliminada. `pnpm db:test:auth` correcto y usuario/perfil sintéticos eliminados. Tipos generados desde PostgreSQL e importados en el móvil; sin cambios remotos. El [contrato v1](docs/habits-v1.md) detalla el alcance del bootstrap Auth sintético de la prueba aislada.
