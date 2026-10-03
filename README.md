# Planificador de menús

Webapp para organizar el menú semanal familiar, la lista de la compra y consultar recetas.

## Configuración de Supabase

El proyecto incluye una migración en `supabase/migrations/` y un `supabase/config.toml`. En el panel de Supabase, conecta el repositorio con el directorio de trabajo `.` y la rama `main`. Al activar el despliegue a producción, Supabase aplicará la migración a esa base de datos. La migración también puede ejecutarse manualmente desde el SQL Editor, pero no debe aplicarse por ambas vías al mismo tiempo.

Después, copia la URL del proyecto y su clave **publishable** en `supabase-config.js`. No uses la clave `secret` ni `service_role` en el navegador. La tabla no permite acceso directo y solo expone dos funciones RPC. El UUID aleatorio del enlace autoriza el acceso al menú; cualquier persona con el enlace puede consultarlo y editarlo.

La webapp consulta cambios nuevos cada cinco segundos. Los datos también se conservan en el navegador para mantenerlos disponibles si se interrumpe la conexión.

## Publicación

Publica el repositorio en Vercel como sitio estático. No necesita comando de compilación; la raíz del repositorio contiene `index.html`.
