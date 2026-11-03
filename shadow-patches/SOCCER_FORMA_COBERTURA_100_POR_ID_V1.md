# Fútbol (P0): forma "últimos 8" al 100% de cobertura, por ID (anti-colisión)

Fecha: 2026-11-03. Gatillo: "déjame la mejor app del mundo" → palanca elegida: calidad/
cobertura de fútbol (P0). Diagnóstico de cobertura de contexto sobre los 187 partidos
próximos con pick canónico READY (de `v_futpro_publication_v3`):
- H2H: 128/187. Forma (últimos 8): **128/187 (68%)** → 59 partidos cubiertos sin forma.

## Causa raíz del hueco
La versión anterior de `v_reto_soccer_forma_v1` fijaba la liga de cada equipo a través
del **endpoint donde los dos equipos se habían enfrentado** (anti-colisión por el bug
"América" MX/BR/CO). Efecto colateral: los partidos **sin H2H previo** (debuts entre sí)
no tenían endpoint → no tenían forma. Los 59 sin forma eran:
- 37 de copas continentales (UCL/UEL/Conference): cruces de primera vez entre ligas.
- 22 de liga doméstica (Bundesliga, Süper Lig, Liga MX, PL, etc.) sin H2H en los datos.

## Arreglo (CONTEXTO, no toca modelo/pick/récord)
Se reescribió `v_reto_soccer_forma_v1` para fijar la forma a la **liga doméstica ACTUAL
de cada equipo, por `espn_id`** (no por nombre → sin colisión entre países):
1. IDs de equipo desde `agenda_espn` (home_espn_id/away_espn_id, deporte='soccer').
2. Liga actual = endpoint **modal de los últimos 15 juegos** del equipo (maneja ascensos/
   descensos: usa la liga donde juega hoy, no la histórica).
3. Últimos 8 juegos del equipo DENTRO de esa liga, por ID → G/E/P, BTTS%, CS%.

Mismas columnas de salida (el frontend no cambia). Todo soccer tiene `home_espn_id` en
historico (35,842/35,842) y la agenda trae los IDs.

## Resultado (verificado)
- Forma para ambos equipos: **187/187 READY (100%)**, antes 128.
- Integridad: 0 filas con G+E+P≠N; n máx = 8.
- Anti-colisión confirmada: "América" (Pumas vs América) da un récord limpio de Liga MX,
  no el 38/38 de la colisión vieja; Bayern Munich da 5-3-0 idéntico en sus dos partidos
  (determinista por ID). Cup/debuts ahora muestran la forma doméstica real de cada equipo.
- H2H sigue en 128/187 a propósito: dos equipos que nunca se enfrentaron no tienen duelo
  previo; mostrar "sin duelos previos" es lo honesto.

## Nota
Cobertura de PICKS de fútbol = 187/271 próximos (69%). El resto (84) queda sin pick por
razones honestas: FA Cup con equipos de división inferior (<15 juegos), copas con φ de
liga no servible a tiempo, y ligas sin φ sellada (Argentina, A-League). Ampliar a esas
ligas exige estimar su fuerza de liga (φ) con puentes internacionales y validarla OOS, y
la aprobación de competencia es decisión del dueño (`v2.competencia_autorizada_por_dueno`);
no se fuerza nada: sin φ el sistema falla cerrado por evento (correcto). Dinero OFF.
