# Motor de Probabilidad Real (mezcla modelo + momio de-vig, peso aprendido OOS)

Fecha: 2026-11-03. El usuario quiere la probabilidad REAL de cada partido usando TODO
(modelo + datos + momios), con la intuición correcta: "los momios dicen demasiado, solo
no sabemos leerlos". Se probó y es cierto.

## El experimento (medido, no opinión)
Sobre `evidencia_modelo_forward` (récord forward con prob_modelo y prob_mercado_novig y
resultado real), barrido del peso `w` de la mezcla p = w·modelo + (1−w)·mercado_devig,
minimizando Brier:
- **Fútbol ML (863):** óptimo w=0. El mercado le gana a nuestro modelo; cualquier peso al
  modelo EMPEORA. La mejor probabilidad = el momio sin comisión.
- **Football/NFL ML (123):** óptimo w≈0.72; la mezcla (≈70/30) le gana a mercado Y a modelo.
  Aquí el modelo sí aporta.
Conclusión: la mezcla correcta depende del segmento y se APRENDE de resultados.

## Construido (aditivo, dinero OFF, no toca modelos/gates)
- **`v_reto_blend_pesos_v1`**: por (deporte, mercado) calcula el peso óptimo en forma
  cerrada w* = Σ[(m−k)(y−k)] / Σ[(m−k)²], clamp [0,1], con **shrinkage hacia el mercado**
  por tamaño de muestra (λ=100: `w_usar = w*·n/(n+100)`), y marca si el modelo le gana al
  mercado. Hoy: soccer ML w=0.000, football ML w=0.395.
- **`v_reto_probabilidad_real_v1`** (soccer 1X2, próximos): de-vig del momio 1X2 (quita la
  comisión, normaliza a 100), mezcla con el modelo al peso aprendido, y entrega por partido:
  prob del mercado y prob REAL de cada resultado (home/empate/away), el más probable con su
  prob_real, la `ventaja_pp` (real − mercado del mejor lado) y un `veredicto`:
  "VALOR: …" solo si w>0, el modelo le gana al mercado y la ventaja ≥3pp; si no,
  "SIN VENTAJA — la prob real es la del mercado".
  Verificado: de-vig suma ~100; 116 partidos con prob real; **0 con valor** (correcto:
  en fútbol no le ganamos al mercado hoy, así que no hay ventaja — y la app lo dice).

## Qué resuelve
- Da la **probabilidad real de que pase** para cada partido con momio (la mejor estimación
  que existe = de-vig del mercado, ajustada por el modelo solo donde aporta).
- Ser buen apostador = apostar solo donde `veredicto='VALOR'` (hoy: ninguno en fútbol).
  La honestidad de decir "pasa" es el producto.

## Extensión (pendiente, mismo patrón)
- BTTS/O-U de fútbol: necesita momio de ese mercado (v3 trae 1X2 y O/U; BTTS no directo).
- NBA/NHL/Tenis: cuando fluya momio de moneyline en vivo, se agrega su rama (el peso de
  football ML ya está listo para cuando ese mercado tenga momios próximos).
- CLV tracker: registrar precio de entrada vs cierre para medir "¿le gano al cierre?".
Grants SELECT a anon/authenticated. Dinero OFF hasta que un segmento pruebe CLV+.
