# Fútbol: partidos sin análisis = CONTEXT_ONLY (copas), card parcial honesta (v1)

Supabase prod `wpiztubmmmzclhlprgpd`. 2026-10-28. Dinero OFF.

## Causa raíz de "no me salen los análisis de todos" (fútbol)

De 100 partidos de soccer programados en 48h, solo 45 tenían card. Los **55 faltantes son
exactamente Copa del Rey (38) + KNVB Beker (17)**. Todas las ligas tienen 100% de cobertura.

Verificado paso a paso:
- NO es falta de aprobación: el dueño ya autorizó ambas (`v2.competencia_autorizada_por_dueno`:
  "COPA DEL REY SI", "KNVB SI") y están `PROD_APPROVED` (`espn_143`, `espn_89`).
- NO es que no se ingieran: las 55 están en `v_futpro_analysis_v4`.
- **Sí es que salen `analysis_status='CONTEXT_ONLY'`**: el modelo tiene el contexto (forma,
  H2H) pero NO puede calcular probabilidad ni marcador, porque en esas rondas juegan equipos
  de **división inferior sin fuerza de liga medida** (forma 0-0-0 en ligas cubiertas). La
  publicación solo muestra partidos con probabilidad, así que estos desaparecían.

Es el sistema negándose a inventar un pronóstico Tercera-vs-Primera. Honestidad, no bug. Se
resuelve solo cuando las copas llegan a rondas de solo-primera.

## Fix elegido por el dueño: card parcial honesta

Nueva vista **`public.v_reto_soccer_contexto_v1`** (SELECT para anon): expone los partidos
`CONTEXT_ONLY` futuros no publicados, con identidad + forma real (temporada y últimos 5) +
H2H + resúmenes + `motivo_sin_prob`. SIN pick, SIN probabilidad inventada. No toca ninguna
vista crítica existente (es aditiva/nueva).

Frontend (Lovable "Remix of Reto 13M"): se instruyó renderizar estas filas como tarjetas de
**"Sin pronóstico · Solo contexto"**, claramente distintas de las que tienen pick, fuera de
Favoritos y de mejores picks, mostrando la forma/H2H que existe y la nota honesta.

## Resultado
El usuario ve TODOS los partidos de fútbol: los que tienen pick (con pronóstico) y los que
solo tienen contexto (copas con equipos de categoría inferior), con honestidad total sobre
cuáles no se pueden pronosticar y por qué.
