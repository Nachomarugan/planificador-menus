# Planificador de menús

Webapp para organizar el menú semanal familiar, la lista de la compra y consultar recetas.

## Configuración de Supabase

1. En el SQL Editor del proyecto Supabase, ejecuta `supabase-schema.sql`.
2. Copia la URL del proyecto y su clave **publishable** en `supabase-config.js`.
3. Publica el repositorio en Vercel como sitio estático. No necesita comando de compilación; la raíz del repositorio contiene `index.html`.

No uses la clave `secret` ni `service_role` en el navegador. El esquema deja la tabla sin acceso directo y expone únicamente dos funciones RPC; el UUID aleatorio del enlace autoriza el acceso a ese menú. Cualquier persona con el enlace puede consultarlo y editarlo.

La webapp consulta cambios nuevos cada cinco segundos. Los datos también se conservan en el navegador para mantenerlos disponibles si se interrumpe la conexión.
