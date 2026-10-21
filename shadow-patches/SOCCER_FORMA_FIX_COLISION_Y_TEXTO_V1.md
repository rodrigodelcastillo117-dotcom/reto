# Fix: forma "últimos 8" de fútbol — colisión de nombres + texto confuso

Fecha: 2026-10-21. Gatillo: el usuario vio en Atlas vs América que (a) América mostraba
el récord del Atlas (38% ganó / 38% empató) y (b) el texto "Ganó 38% / Empató 38%" en
tarjetas sueltas se leía como si hubiera ganado Y empatado los 8.

## Causa raíz (medido)
- La forma por equipo se cruzaba por NOMBRE sobre todas las ligas. "América" existe en
  varios países (Club América MX, América-MG BR, América de Cali CO) → colisión. América
  real (Liga MX, últimos 8) es **5-2-1 (63% victorias)**, pero el cruce sin candado daba
  2-3-3, y el frontend además mostraba los números del local para el visitante.
- El texto mostraba cada stat como % suelto ("Ganó 38%", "Empató 38%"), confuso.

## Arreglo
- `public.v_reto_soccer_forma_v1` (CONTEXTO): por `espn_event_id` de próximos partidos,
  forma de los últimos 8 de cada equipo **fijada a la liga compartida del partido**
  (endpoint modal de sus enfrentamientos directos en `historico_partidos_espn`), lo que
  elimina la colisión de nombres entre países. Columnas: home/away `_n`, `_g`, `_e`, `_p`,
  `_btts_pct`, `_cs_pct`. Verificado: Atlas 3-3-2, América **5-2-1**, ambos BTTS 75%, CS 25%.
- Frontend: el bloque de forma lee esta vista y muestra un RÉCORD claro "Últimos 8: 3G 3E
  2P" (no porcentajes sueltos de ganó/empató), más 2 stats de contexto (ambos anotan %,
  portería a cero %). Estado honesto si no hay datos.

El bloque "Duelos previos" (H2H, `v_reto_soccer_h2h_v1`) es correcto: empareja por los dos
nombres a la vez, así que no sufre la colisión (Atlas no juega contra América-MG). Dinero OFF.
