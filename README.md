# Daily Tracker Supabase

Repositorio exclusivo del backend de Daily Tracker. La app móvil vive en [mdch2/daily-tracker](https://github.com/mdch2/daily-tracker).

Este repositorio posee PostgreSQL, migraciones, RLS, funciones, triggers, configuración Supabase y pruebas SQL. La configuración, migración inicial de perfiles y seed se trasladaron íntegros desde el móvil; la migración inicial conserva su contenido original. Los cambios posteriores son incrementales.

## Requisitos y comandos

Node.js 22 compatible, pnpm 10.28.2, Supabase CLI compatible y Docker con motor Linux. Verificación de seguridad realizada con CLI 2.121.0 y PostgreSQL 17.11.0.004.

```powershell
pnpm db:start
pnpm exec supabase migration up --local
pnpm db:test
pnpm exec supabase db lint --local --level warning
pnpm db:types
```

`migration up --local` aplica migraciones pendientes sin resetear datos. `pnpm db:reset` destruye los datos locales: usarlo exclusivamente con una instancia desechable. Ningún comando de este flujo autoriza un despliegue remoto.

`db:types` genera `types/database.types.ts` desde PostgreSQL local y conserva el artefacto anterior si falla. No se admiten sustitutos escritos a mano. En el móvil, su propio `pnpm db:types` importa este artefacto sin administrar PostgreSQL; si los repositorios no son hermanos, se proporciona la ruta explícita al importador.

## Seguridad obligatoria

Leer [AGENTS.md](AGENTS.md), la [política y matriz de acceso](docs/security.md) y la [decisión de autorización](docs/adr/001-access-control.md) antes de cambiar el esquema o permisos.

- Acceso denegado por defecto, RLS en cada tabla de aplicación expuesta y permisos explícitos por rol, operación y columna.
- Perfiles privados por propietario autenticado; anon no puede acceder. Solo se permite editar display_name y time_zone propios. Auth crea los perfiles y administra la eliminación de cuentas.
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
