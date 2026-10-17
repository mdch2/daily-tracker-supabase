# Daily Tracker Supabase

Propietario exclusivo del backend de Daily Tracker. La aplicación móvil vive en [mdch2/daily-tracker](https://github.com/mdch2/daily-tracker).

Se trasladaron íntegramente desde el móvil la configuración Supabase, la migración inicial de profiles, el seed vacío y las pruebas pgTAP. Sus hashes se comprobaron antes de retirar las copias del móvil; no se alteró el esquema ni se aplicaron migraciones a un servidor.

## Requisitos y comandos

Node 22 compatible, pnpm 10.28.2, Supabase CLI 2.75.0 o compatible y Docker con motor Linux.

```powershell
pnpm db:start
pnpm db:reset
pnpm db:test
pnpm db:types
```

db:reset elimina los datos de la instancia local; usar solo con datos descartables.
db:types genera types/database.types.ts desde PostgreSQL local y conserva el archivo previo si falla. No se incluye un artefacto manual como sustituto.

En el repositorio móvil, pnpm db:types copia ese artefacto, sin administrar PostgreSQL.
Si ambos checkouts no son hermanos, indicar la ruta del artefacto al comando del móvil.

## Estado de verificación

Docker no expone su motor Linux en el entorno inspeccionado. No se pudieron ejecutar pruebas SQL ni generar tipos desde PostgreSQL. El snapshot histórico identificado como manual sigue en el cliente hasta sustituirlo por la primera generación real; no se considera un artefacto generado.

Las 14 aserciones de supabase/tests/database/profiles.test.sql prueban aislamiento de propietario, otro usuario y anónimo al disponer de PostgreSQL.
No se ha creado proyecto remoto ni configurado credenciales o despliegues.
