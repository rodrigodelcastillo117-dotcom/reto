# Verificación editorial independiente · THE PRIVATE EDITION Nº 01 (Noviembre 2026)

- **Fecha de la verificación:** 22-oct-2026 (UTC 19:00–19:40 aprox.).
- **Material revisado:** `data/prive/edition/issue-01.json` (16 piezas, 12 fotos, 34 fuentes) + `supabase/migrations/20261025110000_edition2_status_correcciones.sql`.
- **Método:** lectura de cada fuente por HTTP GET público (curl con UA de navegador) y, si bloqueaba, por WebFetch o búsqueda en otra fuente confiable. Las fotos se confirmaron en su página de Pexels (WebFetch), en el CDN `images.pexels.com` y viendo la imagen. También se leyó la licencia y los términos de servicio vigentes de Pexels (actualizados el 20-oct-2026).
- **No se modificó** ningún archivo del repo ni la base de datos, y no se tocó producción.
- **Criterio:** ante la duda, RETENER.

---

## 0. Resumen

| | Aprobar | Retener |
|---|---|---|
| Piezas (16) | 13 (9 de ellas con correcciones de texto que se hacen en el panel) | 3: **portada GP**, Art Basel, Delta–Aeroméxico |
| Fotos (12) | 9 | 3: `img_f1_circuito`, `img_desfile_muertos`, `img_miami_ocean_drive` |
| Fuentes (34) | 33 confiables; 1 de parte interesada, aceptable si se presenta como tal | 1 no confiable: `insideflyer_jv` (agregador automático) |

### Hallazgos que cambian las notas del equipo

1. **Una foto retenida bloquea la pieza: no «desaparece sin dejar hueco».**
   - `edition_article_checks` agrega `image_not_licensed:<key>` como **bloqueo** cuando una imagen de la pieza (hero o bloque `img` del cuerpo) no tiene licencia aprobada. Ver `supabase/migrations/20261025100100_edition_rpc.sql`, líneas 380–385.
   - El editor del panel (`src/pages/prive/edition/EditionAdminPage.tsx`, `ArticleEditor`) **no permite quitar la foto principal ni borrar un bloque `img`**: los bloques de imagen se muestran como texto de solo lectura.
   - La RPC `edition_admin_article_update` sí acepta `hero_image: null` y un `body` sin el bloque. Pero eso es una llamada técnica fuera del panel.
   - Por eso es falsa la nota del equipo sobre `img_f1_circuito` («si prefieres no arriesgar, bloquéala: la pieza queda con dos fotos»). Si se bloquea, **la portada no se puede aprobar**.
2. **La portada no se puede aprobar tal como está.**
   - Contiene dos fotos que retengo: `img_f1_circuito` y `img_desfile_muertos`.
   - Sin la portada aprobada, el número tampoco se aprueba (`cover_article_not_approved`).
   - La única forma de llegar al 2-nov es que un administrador, con autorización del dueño, llame a `edition_admin_article_update` con el cuerpo **sin esos dos bloques `img`** y con la corrección del §1. Después hay que aprobarla en el panel antes del **2-nov**, idealmente el 29-oct.
3. **La pieza de la IA en la UE ya está confirmada en fuente oficial.**
   - EUR-Lex devuelve 202 (página de verificación). Pero el repositorio oficial de la Oficina de Publicaciones de la UE (`publications.europa.eu/resource/celex/32026R1744`, CELLAR) entrega los metadatos y el texto oficial:
     - Reglamento (UE) 2026/1744, de 8-jul-2026;
     - DO L de **24-jul-2026**;
     - entrada en vigor el **27-jul-2026**;
     - fechas de aplicación **2-dic-2027** (Anexo III), **2-ago-2028** (Anexo I) y **2-dic-2026** (art. 50(2) para sistemas ya en el mercado).
   - El acuerdo provisional del **7-may-2026** está en el comunicado 299/26 del Consejo.
   - Se puede aprobar, con una corrección en la entradilla.
4. **Delta–Aeroméxico: el hecho es cierto, pero sus fuentes no sirven.**
   - `insideflyer_jv` es un agregador: dice «Originally reported by viewfromthewing.com · Powered by BoardingAI». La otra fuente es el comunicado de Delta, parte interesada.
   - El fallo sí está confirmado por Aviation Week (21-ago-2026) y DLA Piper: 11.º Circuito, 20-ago-2026, *Delta Air Lines v. DOT*, n.º 25-13546, 1,687 pares de ciudades.
   - Se retiene hasta sustituir la fuente.
5. **Foto del desfile mal descrita.**
   - Según Pexels, se tomó el **26-oct-2024**. El Gran Desfile de 2024 fue el **2-nov-2024**.
   - Por lo tanto no es «una edición anterior» del desfile. Probablemente es otro evento: la Mega Procesión de Catrinas, por ejemplo.
   - Además, una persona identificable es la protagonista y Pexels no garantiza permisos de modelo.
6. **El estado de los enlaces cambió desde el informe del equipo.**
   - michelin.com y miamilivingmagazine.com ahora responden **200**.
   - mexicodesconocido.com.mx (`md_tianguis2027`) ahora responde **403** a curl. Su contenido se leyó por WebFetch y Milenio lo corrobora.
7. **`img_ala_avion` no la usa ninguna pieza ni el número.**
   - La portada del PDF de vuelo sale de la foto principal de la primera pieza o de la portada del número (`src/lib/priveEditionPdf.ts`, líneas 146–148).
   - No es «la portada de la Flight Edition», como dicen las notas. Aprobar su licencia no tiene efecto ni riesgo.

---

## 1. Piezas

| slug | título | veredicto | por qué | fuentes comprobadas (URL + qué confirma) | correcciones necesarias (texto exacto) |
|---|---|---|---|---|---|
| `carta-del-editor-n01` | Una revista que se puede comprobar | **APROBAR** (con condición) | Texto editorial sin datos sensibles. Lo que afirma es verdad: el GP y el desfile caen el mismo fin de semana; Mérida y Guadalajara entraron a la guía en 2026; el Yacht Show fue la 35.ª edición. **Condición:** antes de aprobarla hay que aplicar la migración `20261025110000`. Sin ella, la firma en producción dice «borrador pendiente de firma». | Ninguna propia. Sus datos se confirman en las fuentes de las piezas 2–4. | Ninguna en el texto. Aplicar antes la migración `20261025110000` (firma «Dirección editorial de IATOS Privé»). |
| `cdmx-fin-de-semana-gran-premio` | La ciudad acelera (PORTADA, vence 2-nov) | **RETENER** | 1) Lleva en el cuerpo dos fotos que se retienen (`img_f1_circuito` e `img_desfile_muertos`, ver §2). La base bloquea aprobarla (`image_not_licensed`) y el panel no puede quitarlas. 2) Un dato dice algo distinto de la fuente: el promotor dice que el transporte gratuito «recorre el exterior del Autódromo», no «dentro del perímetro». **El resto del texto es correcto.** Se puede aprobar antes del 2-nov si un administrador autorizado quita los dos bloques `img` por RPC y aplica la corrección. La foto de portada (Ángel) se aprueba. | https://www.formula1.com/en/racing/2026 → ronda 19, 30 oct–1 nov; EE. UU. 23–25 oct; Brasil 6–8 nov · https://www.formula1.com/en/racing/2026/mexico → 4.304 km, 71 vueltas, 305.354 km, 1:17.774 Bottas 2021; sesiones en UTC **y en hora local con `gmtOffset -06:00`**: P1 12:30, P2 16:00, P3 11:30, Q 15:00, carrera 14:00 (la conversión de la redacción coincide con F1) · https://www.mercedesamgf1.com/races/mexico-city-grand-prix-2024 → «about 2,285 metres», «more than 2,200 metres … the highest venue we visit» · https://www.mexicogp.mx/como-llegar → Línea 9 (Velódromo, Ciudad Deportiva, Puebla), Metrobús L2; Ticket2Ride $350 viaje redondo por persona y por día, desde Condesa, Santa Fe, Interlomas…; transporte perimetral gratuito «que recorre el exterior», 7:00–20:00, «es necesario presentar tu boleto»; cita exacta «Recuerda que los accesos sólo serán permitidos en la sección de tu boleto»; «puede ser conveniente caminar algunas calles alejándote del Autódromo antes de solicitar el vehículo» · https://www.mexicogp.mx/ → canal de boletos (Ticketmaster), © 2026 CIE · https://politica.expansion.mx/cdmx/2026/10/14/… → sábado 31-oct, 14:00, Reforma a la altura de la Diana → 5 de Mayo → Plaza de la Constitución; Gobierno de la CDMX; 10 años (primera edición: 29-oct-2016); la SSC informará la ruta final · https://www.poresto.com/…/2026/10/17/… → 31-oct, 14:00, Diana → Zócalo, gratuito, con un post de @GobCDMX | **Cuerpo, párrafo «La guía oficial del promotor…»**: sustituir «Dentro del perímetro circulan autobuses gratuitos entre accesos, de 7:00 a 20:00, para quien muestra su boleto.» por «Alrededor del autódromo opera un transporte perimetral gratuito entre puertas, de 7:00 a 20:00, para quien presenta su boleto; el promotor advierte que el horario puede cambiar.» · **Quitar del `body`** los bloques `{"t":"img","image":"img_desfile_muertos","size":"half"}` y `{"t":"img","image":"img_f1_circuito","size":"full"}` (con RPC `edition_admin_article_update`, con autorización) |
| `merida-guadalajara-mesa-mexicana` | El sureste entra al mapa | **APROBAR** con corrección | Todo está respaldado. Michelin.com ya responde 200 y confirma las Llaves. Un error interno: del 20-may al 18-sep son cuatro meses, y el propio texto dice «Cuatro meses después». Fotos aprobadas. | https://www.adn40.mx/mexico/2026-03-25/… → gala el miércoles 20-may-2026 en Guadalajara; la guía amplía a Jalisco, Puebla y Yucatán · https://elrestaurante.com/news/7-new-michelin-stars-in-mexico/ → 7 primeras estrellas con chefs; Pujol y Quintonil con dos; Estrellas Verdes Damiana, Ixi'im, Xokol · https://www.rivieramayanews.mx/… → mismas 7, con Mérida, Chocholá, Guadalajara, CDMX · https://www.michelin.com/en/publications/products-and-services/michelin-guide-2026-michelin-key-selection → 18-sep-2026; 470 hoteles en 79 destinos; 2.832 (155/657/2.020); Hotel Sevilla (Mérida) con su primera Llave por la restauración de un edificio histórico; Nekajui, la única nueva con tres Llaves en América · https://www.outlooktraveller.com/… → corrobora | «Lectura editorial: en cinco meses, Mérida sumó» → «Lectura editorial: en cuatro meses, Mérida sumó». Recomendado: «En el continente, la única propiedad nueva» → «En América, la única propiedad nueva». |
| `monaco-yacht-show-2026` | Port Hercule, en septiembre | **APROBAR** con correcciones | Cifras, fechas, eslora y astilleros respaldados. Hay tres frases más fuertes que la fuente o sin atribución, y una afirmación comercial propia sin respaldo («verificadas»). Fotos aprobadas. | https://www.monacoyachtshow.com/en/ → «over 560 expert exhibitors», «exhibition of 120 superyachts», próxima edición 22–25 sep 2027 · https://www.yachtbuyer.com/en/news/… → 23–26 sep; 117 superyates; 70 a la venta; ~2,500 MDD; Leviathan 111 m (Oceanco) el mayor; Nixie 102.4 m Lürssen, debut mundial; Pangea, el primer Amels 80 mostrado en un salón; Silver Fox 72 m, el primer 74Steel; Amor à Vida 67.55 m, el primer híbrido de CRN; Baglietto T60, el mayor de la marca · https://monacolife.net/forty-three-world-premieres-set-for-monaco-yacht-show-2026/ → «35th edition»; 43 estrenos; turnos «committed through 2028 and 2029» (cita del Global Order Book de Boat International); cita «waiting until 2028 or beyond» | 1) «La pieza más esperada fue Nixie, de 102.4 metros, construida por Lürssen, en su debut mundial.» → «Entre los debuts mundiales estuvo Nixie, de 102.4 metros, construida por Lürssen, que ocupó el lugar principal del Quai Rainier Ier.» 2) «Los turnos de construcción de los grandes astilleros están comprometidos hasta 2028 y 2029.» → «Los turnos de construcción de los grandes astilleros están comprometidos hasta 2028 y 2029, según el Global Order Book 2026 de Boat International.» 3) «espera, según la misma fuente, hasta 2028 o más» → «espera hasta 2028 o más, según una declaración recogida por Monaco Life». 4) «la colección YACHT & SEA con experiencias náuticas verificadas por destino» → «la colección YACHT & SEA con experiencias náuticas por destino». |
| `watches-and-wonders-2027` | Ginebra ya marcó la hora | **APROBAR** con corrección | Fechas, 75 marcas (conté la lista oficial: 75), 13 nuevas, Palexpo, formato y nuevos expositores respaldados. «El más grande de Ginebra» no está en ninguna fuente. | https://www.watchesandwonders.com/ → 5–11 abr 2027; «13 new brands»; lista «Exhibiting brands» con 75 nombres; Breitling, Damiani, Gallet y Universal Genève anunciadas en junio · https://watchesbysjx.com/2026/06/watches-wonders-2027-dates.html → Palexpo; lunes a jueves profesionales, viernes a domingo público con boleto; trío de Georges Kern | «El salón relojero más grande de Ginebra ya tiene fecha:» → «Watches and Wonders, la principal feria de relojería de lujo según Watches by SJX, ya tiene fecha:» |
| `art-basel-miami-beach-2026` | Diciembre en Miami Beach | **RETENER** | 1) Su foto principal `img_miami_ocean_drive` se retiene (§2): la base bloquea aprobarla y el panel no puede quitarla. 2) El horario 11:00–18:00 solo lo da Miami Living; ArtRabbit da 10:00–18:00, y la página oficial no publica horario. **Las fechas sí están confirmadas.** Se puede aprobar sin foto, con hero en `null` por RPC autorizada, y con la corrección. | https://www.artbasel.com/miami-beach → «December 4 – 6, 2026, Miami Beach» · https://www.artbasel.com/miami-beach/at-the-show → «VIP Days (Wednesday, December 2, 2026 as of 4pm and Thursday, December 3)», «Public Days (Friday, December 4 – Sunday, December 6, 2026)» · https://www.miamilivingmagazine.com/post/art-basel-miami-beach-2026-ultimate-guide (ahora 200; `datePublished` 2026-10-17T00:57Z) → Miami Beach Convention Center; públicos 11–18 h | «Las jornadas públicas, de viernes a domingo, se celebran en el Miami Beach Convention Center, de 11:00 a 18:00, y los días por invitación comienzan el 2 de diciembre, según la guía publicada por Miami Living.» → «Las jornadas públicas, de viernes a domingo, se celebran en el Miami Beach Convention Center, según la guía publicada por Miami Living, y los días VIP comienzan el 2 de diciembre, según Art Basel. Consulte el horario en el sitio oficial.» · Quitar la foto principal (`hero_image: null`) |
| `pga-tour-los-cabos-2026` | El PGA Tour vuelve a Los Cabos | **APROBAR** con corrección | Datos confirmados en la ficha oficial. «Experiencias verificadas» es una afirmación comercial propia sin fuente. Fotos aprobadas. | https://www.pgatour.com/tournaments/2026/world-wide-technology-championship/R2026457/overview → El Cardonal at Diamante, Los Cabos, 5–8 nov 2026; bolsa de $6,000,000; 2025: Ben Griffin −29, 259 | «Los Cabos está en la sección de destinos de Privé, con experiencias verificadas y la colección SPORT & LEISURE.» → «Los Cabos está en la sección de destinos de Privé y en la colección SPORT & LEISURE.» |
| `banxico-pausa-6-50` | La tasa en 6.50%: cómo leer la pausa | **APROBAR** con corrección de vigencia | Decisiones de 2026 confirmadas en Banxico, incluido el comunicado oficial del 24-sep. Próximos anuncios (5-nov y 17-dic, 13:00) en el calendario de BBVA Research; las fechas pasadas coinciden con Banxico. Nobel confirmado en nobelprize.org. Sin consejo de inversión, con aviso explícito. Dos o más fuentes: cumple la regla de pieza sensible. El 5-nov a las 13:00 el texto queda desfasado, pero seguiría vigente todo ese día. | https://www.banxico.org.mx/…/anuncios-politica-monetaria-t.html → 05/02 sin cambio en 7.00; 26/03 −25 pb; 07/05 −25 pb; 25/06, 06/08 y 24/09 sin cambio en 6.50 · comunicado del 24-sep-2026 (PDF Banxico) → «decidió por unanimidad mantener … en 6.50%» · https://www.bbvaresearch.com/wp-content/uploads/2026/03/AgendaEconomica_2026.pdf → anuncios 5 nov y 17 dic; comunicado a las 13:00 · https://www.nobelprize.org/prizes/economic-sciences/2026/summary/ y /press-release/ → laureados y motivación; «models now used by central banks» · thesenior.com.au (AAP), en.apa.az (Reuters) → corroboran | Cambiar «Vigente hasta» de `2026-11-05` a `2026-11-04` en el panel. Recomendado: «según AAP y APA/Reuters» → «según la Real Academia Sueca de Ciencias». |
| `ue-ia-alto-riesgo-2027` | Bruselas mueve el reloj de la IA de alto riesgo | **APROBAR** con corrección | **Confirmado en fuente oficial** (ver §0.3): número, DO del 24-jul, vigor el 27-jul, 2-dic-2027 (Anexo III), 2-ago-2028 (Anexo I), gracia del art. 50(2) hasta el 2-dic-2026; acuerdo provisional del 7-may (Consejo). La entradilla generaliza de más: «a diciembre de 2027 las obligaciones para los sistemas de alto riesgo» y los del Anexo I van a agosto de 2028. | http://publications.europa.eu/resource/celex/32026R1744 (RDF oficial: date_document 2026-07-08; date_publication 2026-07-24; entry-into-force 2026-07-27) y su texto XHTML oficial (CELLAR `b459c07f-…`, `L_202601744EN`): «2 December 2027 … Annex III … 2 August 2028 … Annex I»; «placed on the market before 2 August 2026 shall … comply with Article 50(2) by 2 December 2026»; «third day following … publication»; Parlamento 16-jun-2026, Consejo 29-jun-2026 · https://www.consilium.europa.eu/en/press/press-releases/2026/05/07/artificial-intelligence-council-and-parliament-agree-to-simplify-and-streamline-rules/ → acuerdo provisional del 7-may-2026 · https://www.mondaq.com/…/1825722 (K&L Gates) · https://datamatters.sidley.com/2026/06/22/… | Entradilla: «aplazó a diciembre de 2027 las obligaciones para los sistemas de alto riesgo.» → «aplazó a diciembre de 2027 las obligaciones para los sistemas de alto riesgo del Anexo III, y a agosto de 2028 las de la IA integrada en productos regulados.» Recomendado, al final: «Las fechas provienen de análisis de despachos; el texto oficial está en EUR-Lex.» → «Las fechas coinciden con el texto oficial del Reglamento (UE) 2026/1744 (DO L de 24.7.2026), disponible en EUR-Lex.» |
| `brief-nobel-economia-2026` | Nobel de Economía para Robert E. Hall y Michael Woodford | **APROBAR** | Confirmado en la página oficial y en el comunicado: laureados, motivación textual («for microeconomic foundations of macroeconomic stabilisation»), 12-oct-2026, 12 millones de coronas suecas, ambos de EE. UU. La traducción de la cita es fiel. | https://www.nobelprize.org/prizes/economic-sciences/2026/summary/ · https://www.nobelprize.org/prizes/economic-sciences/2026/press-release/ → fecha, afiliaciones (Stanford, Columbia; nacidos en EE. UU.), monto · AAP y APA/Reuters lo corroboran | Ninguna. |
| `brief-lvmh-tercer-trimestre-2026` | LVMH crece 1% orgánico en el tercer trimestre; China pesa en la moda | **APROBAR** con corrección de vigencia | Todas las cifras están en el comunicado: 57.1 mil MDE; −2% reportado; +2% orgánico; T3 orgánico: Moda −5%, Relojes +6%, Vinos +6%, Distribución Selectiva +8%; «less buoyant environment in China». Con vigencia al 31-ene-2027, un hecho de 111 días seguiría visible como novedad, y LVMH publica sus resultados anuales a fines de enero. | https://www.lvmh.com/en/publications/continued-growth-in-the-third-quarter-of-2026 → tabla T3 y texto · https://fashionunited.uk/news/business/…/2026101390823 → corrobora; Moda T3 −5% por China | «Vigente hasta» `2027-01-31` → `2027-01-10` (fecha del hecho + 90 días). |
| `brief-inegi-viajeros-agosto-2026` | México recibió 7.99 millones de viajeros internacionales en agosto | **APROBAR** | Todas las cifras están en el boletín oficial 625/26. La Crónica solo corrobora el acumulado enero–agosto, no la cifra mensual; basta la fuente primaria. | https://www.inegi.org.mx/contenidos/saladeprensa/boletines/2026/ViajInternales/evi2026_10.pdf → 7 985 700 (+1.3%); 3 768 784 turistas (−0.5%); gasto +7.0%, gasto medio +5.6%; «Cifras preliminares»; próxima publicación 12-nov-2026 · https://www.cronica.com.mx/nacional/2026/10/14/… → 67.69 millones en enero–agosto | Ninguna. |
| `brief-banxico-24-septiembre` | Banxico mantiene su tasa en 6.50% por tercera reunión | **APROBAR** con corrección de vigencia | Confirmado en el listado y en el comunicado oficial del 24-sep. Siguiente anuncio confirmado en BBVA Research. | Mismas URL de Banxico y BBVA que el explicador | «Vigente hasta» `2026-11-05` → `2026-11-04`. |
| `brief-delta-aeromexico-tribunal` | Un tribunal de EE. UU. mantiene viva la alianza Delta–Aeroméxico | **RETENER** | El hecho es cierto, pero sus dos fuentes no lo respaldan como exige la revista: `delta_jv` es la parte interesada e `insideflyer_jv` es un **agregador automático** («Powered by BoardingAI», reposteo de View from the Wing). El texto dice «Según InsideFlyer…». La fecha del fallo es el 20-ago, no el 21. La vigencia (31-dic) es mayor que la regla de 90 días (19-nov). Cambiar la fuente requiere registrar una fuente nueva, que no se puede hacer desde el panel. Si no se corrige antes del 19-nov, ya no se puede aprobar. | https://news.delta.com/us-appeals-court-vacates-dot-order-unwind-deltaaeromexico-joint-venture → 11.º Circuito anula la orden; la JV continúa (comunicado de parte) · https://www.insideflyer.com/posts/… → agregador, **no confiable** · Comprobación independiente: https://aviationweek.com/air-transport/airlines-lessors/appeals-court-overturns-delta-aeromexico-jv-termination (21-ago-2026) → fallo del 20-ago; orden del DOT de sept. 2025; «1,687 individual city-pair markets»; el DOT «consider all available legal options» · https://www.dlapiper.com/insights/publications/2026/08/eleventh-circuit-vacates-dot-order-delta-aeromexico → 20-ago-2026, *Delta Air Lines v. DOT*, n.º 25-13546; vacatur; el DOT puede emitir una orden nueva con análisis completo | 1) Registrar como fuente Aviation Week (URL de arriba) y desvincular `insideflyer_jv`. 2) «Hecho: el Tribunal de Apelaciones del 11.º Circuito anuló» → «Hecho: el 20 de agosto, el Tribunal de Apelaciones del 11.º Circuito anuló». 3) «Según InsideFlyer, el tribunal señaló» → «Según Aviation Week, el tribunal señaló». 4) «Vigente hasta» → `2026-11-19`. Aprobar antes del 19-nov. |
| `brief-desfile-dia-de-muertos-2026` | Desfile de Día de Muertos: sábado 31 de octubre, 14:00 | **APROBAR** | Fecha, hora, ruta, gratuidad y los 10 años, respaldados por dos medios que citan al Gobierno de la CDMX (Por Esto incluye un post de @GobCDMX). Vence el 31-oct: hay que publicarla antes. | Expansión y Por Esto (URL arriba) | Ninguna. |
| `agenda-privada-n01` | Fechas para apartar | **APROBAR** | Las 9 fechas son futuras al 22-oct y cada una coincide con su fuente: GP 30-oct–1-nov; desfile 31-oct 14:00; Banxico 5-nov 13:00; WWT 5–8-nov; INEGI 12-nov; Art Basel 4–6-dic; Tianguis 9–12-mar-2027 en Puebla; W&W 5–11-abr-2027 en Palexpo; MYS 22–25-sep-2027. La fuente del Tianguis responde 403 a curl, pero se leyó por WebFetch y Milenio la confirma. | Fuentes de arriba + https://www.mexicodesconocido.com.mx/tianguis-turistico-mexico-2027.html (WebFetch: 51.ª edición, 9–12 mar 2027, Centro Expositor de Puebla, presentado el 3-ago-2026) · https://www.milenio.com/estados/armenta-sectur-anuncian-tianguis-turistico-puebla-2027 | Ninguna. |

---

## 2. Fotos

**Licencia vigente de Pexels** (https://www.pexels.com/license/ y https://www.pexels.com/terms-of-service/, «Last updated: October 20th, 2026»).

- **Lo que permite:**
  - usar, copiar y modificar, con o sin fines comerciales, sin atribución;
  - usos que la propia licencia menciona: apps, sitios, e-books, materiales impresos y revistas.
- **Lo que prohíbe:**
  - vender o distribuir la foto «on a Standalone basis», es decir, sin esfuerzo creativo y en sustancialmente la misma forma. Usarla combinada con texto no es *standalone*;
  - sugerir respaldo de personas o marcas;
  - usarla de forma inmoral o ilegal, «especially Content which features a recognisable person».
- **Marcas:** «If Content depicts any trademarks, logos or brands … you cannot use that Content for commercial purposes in relation to goods and services».
- **Responsabilidad:**
  - Pexels «do[es] not warrant that any consents or licenses have been obtained»;
  - «Responsibility for determining whether permissions are needed always rests solely and exclusively with you».
- **Conclusión para app, PDF y sin conexión:** una foto incrustada en un artículo de la revista, en la app, en el PDF personal o en la copia sin conexión es uso dentro de una obra, no redistribución suelta. **Se permite, con o sin crédito**, salvo los riesgos de marcas y personas.
- Las 12 páginas de Pexels responden 403 a curl, pero WebFetch las leyó. Las 12 imágenes del CDN responden 200, y se revisaron visualmente.

| key | autor | URL | existe | licencia permite app/PDF/offline | riesgos | veredicto |
|---|---|---|---|---|---|---|
| `img_cdmx_angel_noche` (portada del número) | Israyosoy S. (coincide) | https://www.pexels.com/photo/dynamic-night-view-of-angel-of-independence-in-mexico-city-36642849/ · CDN 36642849 | Sí: página leída (título, autor, «Ciudad de México», licencia «Free»); CDN 200 | Sí, con o sin crédito | Monumento público de noche. Logos al fondo diminutos, no protagonistas. Jacarandas en flor (primavera), pero se rotula como ilustrativa con «fecha no indicada». Bajo. | **APROBAR** |
| `img_f1_circuito` | Jenda Kubeš (coincide) | https://www.pexels.com/photo/formula-1-on-circuit-14079604/ · CDN 14079604 | Sí; CDN 200 | **No con seguridad.** Es un monoplaza Mercedes con logos **PETRONAS e INEOS** en primer plano; los términos prohíben el uso comercial de contenido con marcas «in relation to goods and services». La pieza invita a contratar servicios de IATOS (Iato, planear viaje) y cita a Mercedes como fuente, lo que puede sugerir una relación. | Marcas protagonistas; F1 y su equipo. La propia licencia lo señala. | **RETENER** |
| `img_desfile_muertos` | Mike The Fabrica (coincide) | https://www.pexels.com/photo/day-of-the-dead-parade-in-mexico-city-29560099/ · CDN 29560099 | Sí; CDN 200; Pexels: «Taken Oct 26, 2024» | Dudoso | **Persona identificable** como protagonista, sin permiso de modelo garantizado. **El pie es inexacto:** «desfile … de una edición anterior», pero el Gran Desfile 2024 fue el 2-nov-2024 y la foto es del 26-oct-2024. | **RETENER** (si se reconsiderara, el pie debería decir: «Participante caracterizada de Catrina en un evento de Día de Muertos en la Ciudad de México, 26 de octubre de 2024. No es el desfile de este año.») |
| `img_merida_catedral` | Edgar Rodrigo (coincide) | https://www.pexels.com/photo/cathedral-of-merida-yucatan-mexico-13688731/ · CDN 13688731 | Sí; «Mérida, Yuc.»; CDN 200 | Sí | Edificio público. Transeúntes pequeños, no identificables como protagonistas. Bajo. | **APROBAR** |
| `img_chile_nogada` | Luis Merlos Vega (coincide) | https://www.pexels.com/photo/chile-en-nogada-27989311/ · CDN 27989311 | Sí; «Lerma de Villada, Méx.»; CDN 200 | Sí | Platillo sin marca. Rotulada ilustrativa, «no es de los restaurantes mencionados». Bajo. | **APROBAR** |
| `img_monaco_puerto` | Reece t (coincide) | https://www.pexels.com/photo/stunning-view-of-port-hercules-in-monaco-32992932/ · CDN 32992932 | Sí; «Monaco»; tomada el 22-jun-2025; CDN 200 | Sí | Vista panorámica de ciudad y puerto. El pie dice «fecha no indicada», pero Pexels da 22-jun-2025; no engaña, porque ya aclara que no es del Yacht Show. Bajo. | **APROBAR** (recomendado en el pie: «tomada en junio de 2025; no corresponde al Yacht Show») |
| `img_yate_mar` | Oriana Polito (coincide) | https://www.pexels.com/photo/aerial-view-of-a-white-yacht-on-the-sea-9408818/ · CDN 9408818 | Sí; CDN 200 | Sí | Catamarán a motor, sin nombre ni marca legible. Rotulada ilustrativa. Bajo. | **APROBAR** |
| `img_reloj` | Mat Brown (coincide) | https://www.pexels.com/photo/close-up-photography-of-wristwatch-1034065/ · CDN 1034065 | Sí; CDN 200 | Sí | No se ve ninguna marca en la esfera. Bajo. | **APROBAR** |
| `img_miami_ocean_drive` | Luis Erives (coincide) | https://www.pexels.com/photo/landscape-photography-of-ocean-drive-miami-at-night-11457815/ · CDN 11457815 | Sí; «Miami Beach, FL»; CDN 200 | **No con seguridad.** Se ven en grande los logos **CVS**, **Colony Hotel** y **Boulevard Hotel**, en una pieza con acciones de servicio de IATOS. | Marcas y negocios protagonistas; transeúntes. | **RETENER** |
| `img_golf` | Kindel Media (coincide) | https://www.pexels.com/photo/photo-of-golf-course-under-blue-sky-6573665/ · CDN 6573665 | Sí; tomada el 4-ene-2021; CDN 200 | Sí | Campo no identificado; el pie aclara que no es El Cardonal. Bajo. | **APROBAR** |
| `img_cabo_costa` | Israel Torres (coincide) | https://www.pexels.com/photo/aerial-view-of-the-coastline-of-cabo-san-lucas-in-mexico-17415445/ · CDN 17415445 | Sí; «Cabo San Lucas, B.C.S.»; CDN 200 | Sí | Vista aérea; hoteles sin logos legibles. Bajo. | **APROBAR** |
| `img_ala_avion` | Anastasiya Vragova (coincide) | https://www.pexels.com/photo/wing-of-aircraft-flying-over-clouds-at-sundown-6791741/ · CDN 6791741 | Sí; tomada el 18-oct-2017; CDN 200 | Sí | Sin aerolínea identificable. **No la usa ninguna pieza ni el número.** | **APROBAR** (sin efecto) |

**Consecuencia para las piezas:** las tres fotos retenidas están en la portada (`img_f1_circuito`, `img_desfile_muertos`) y en Art Basel (`img_miami_ocean_drive`, foto principal). Esas piezas solo se pueden aprobar sin foto si antes se quita la referencia con la RPC `edition_admin_article_update` (`body` sin el bloque `img` / `hero_image: null`). El panel no lo permite, así que se **retienen**.

---

## 3. Fuentes (34)

Estado HTTP medido hoy con curl (GET con UA de navegador, siguiendo redirecciones).

| key | URL | estado HTTP | confiable | nota |
|---|---|---|---|---|
| `f1_calendar_2026` | https://www.formula1.com/en/racing/2026 | 200 | Sí (oficial) | Ronda 19, 30 oct–1 nov. |
| `f1_mexico_2026` | https://www.formula1.com/en/racing/2026/mexico | 200 | Sí (oficial) | Horario en UTC y en hora local (−06:00); ficha del circuito. |
| `mexicogp_home` | https://www.mexicogp.mx/ | 200 | Sí (promotor oficial, CIE) | Canal de boletos. |
| `mexicogp_como_llegar` | https://www.mexicogp.mx/como-llegar | 200 (redirige a `/como-llegar/`) | Sí (promotor oficial) | Transporte perimetral «recorre el exterior»; corrige el texto de la portada. |
| `mercedes_altitud` | https://www.mercedesamgf1.com/races/mexico-city-grand-prix-2024 | 200 | Sí, para el dato geográfico (equipo; página de 2024) | 2,285 m y «more than 2,200 m». |
| `expansion_desfile` | https://politica.expansion.mx/cdmx/2026/10/14/ruta-fecha-hora-tradicional-desfile-dia-de-muertos-cdmx | 200 | Sí (medio serio) | Cita al Gobierno de la CDMX. |
| `porEsto_desfile` | https://www.poresto.com/entretenimiento/ocio/2026/10/17/desfile-dia-muertos-cdmx-fecha-horario-ruta-confirmada-recorrido-zocalo.html | 200 | Sí (medio regional) | Incluye un post de @GobCDMX del 17-oct. |
| `elrestaurante_michelin` | https://elrestaurante.com/news/7-new-michelin-stars-in-mexico/ | 200 | Sí (medio especializado) | Lista y chefs. |
| `rivieramaya_michelin` | https://www.rivieramayanews.mx/michelin-guide-awards-first-stars-to-seven-restaurants-in-jalisco-yucatan-and-mexico-city/ | 200 | Sí (medio local) | Ubicaciones. Da un total de 26 que la pieza, con razón, no publica. |
| `adn40_ceremonia` | https://www.adn40.mx/mexico/2026-03-25/ceremonia-guia-michelin-mexico-2026-jalisco/ | 200 | Sí (medio nacional) | Gala el 20-may en Guadalajara; Jalisco, Puebla, Yucatán. |
| `michelin_keys_2026` | https://www.michelin.com/en/publications/products-and-services/michelin-guide-2026-michelin-key-selection | **200** (el equipo informó 403) | Sí (oficial) | Todas las cifras y Hotel Sevilla confirmados. |
| `outlook_keys` | https://www.outlooktraveller.com/News/michelin-reveals-its-2026-key-hotels-with-470-new-additions-worldwide | 200 | Sí (medio) | Corrobora. |
| `mys_oficial` | https://www.monacoyachtshow.com/en/ | 200 | Sí (organizador) | 560+, 120, 22–25 sep 2027. |
| `yachtbuyer_mys` | https://www.yachtbuyer.com/en/news/monaco-yacht-show-2026-opens-with-major-superyacht-debuts-and-a-high-value-fleet | 200 | Sí (medio especializado) | Flota y debuts. |
| `monacolife_mys` | https://monacolife.net/forty-three-world-premieres-set-for-monaco-yacht-show-2026/ | 200 | Sí (medio local) | 35.ª edición; el dato de 2028–2029 es del Global Order Book de Boat International. |
| `ww_oficial` | https://www.watchesandwonders.com/ | 200 | Sí (oficial) | 5–11 abr 2027; 13 nuevas; 75 en la lista. |
| `sjx_ww2027` | https://watchesbysjx.com/2026/06/watches-wonders-2027-dates.html | 200 | Sí (medio especializado) | Palexpo y formato. |
| `artbasel_mb` | https://www.artbasel.com/miami-beach | 200 | Sí (oficial) | 4–6 dic 2026. |
| `miamiliving_ab` | https://www.miamilivingmagazine.com/post/art-basel-miami-beach-2026-ultimate-guide | **200** (el equipo informó 429) | Parcial (revista de estilo de vida) | Fecha real 16/17-oct-2026. El horario 11–18 h no lo confirma la fuente oficial y ArtRabbit da 10–18 h. |
| `pgatour_wwt` | https://www.pgatour.com/tournaments/2026/world-wide-technology-championship/R2026457/overview | 200 | Sí (oficial) | Todo confirmado. |
| `banxico_anuncios` | https://www.banxico.org.mx/publicaciones-y-prensa/anuncios-de-las-decisiones-de-politica-monetaria/anuncios-politica-monetaria-t.html | 200 | Sí (oficial) | Decisiones de 2026 y comunicado del 24-sep. |
| `bbva_agenda_2026` | https://www.bbvaresearch.com/wp-content/uploads/2026/03/AgendaEconomica_2026.pdf | 200 (PDF) | Sí (análisis bancario serio; con datos de Banxico) | 5-nov y 17-dic, 13:00. Las fechas pasadas coinciden con Banxico. |
| `klgates_omnibus` | https://www.mondaq.com/eu-digital-omnibus-on-ai-enters-into-force/1825722 | 200 | Sí (despacho; ahora corroborado con el texto oficial) | 2026/1744, 24-jul y 27-jul, nuevas fechas. |
| `sidley_omnibus` | https://datamatters.sidley.com/2026/06/22/eu-lawmakers-reach-provisional-agreement-to-delay-key-eu-ai-act-obligations/ | 200 | Sí (despacho) | 7-may y 16-jun, nuevas fechas. |
| `inegi_evi_ago2026` | https://www.inegi.org.mx/contenidos/saladeprensa/boletines/2026/ViajInternales/evi2026_10.pdf | 200 (PDF) | Sí (oficial) | Boletín 625/26. |
| `cronica_inegi` | https://www.cronica.com.mx/nacional/2026/10/14/mexico-recibe-6769-millones-de-viajeros-internacionales-de-enero-a-agosto-de-2026/ | 200 | Sí (medio) | Solo corrobora el acumulado enero–agosto, no la cifra de agosto. |
| `lvmh_q3_2026` | https://www.lvmh.com/en/publications/continued-growth-in-the-third-quarter-of-2026 | 200 | Sí (comunicado del emisor) | Tabla del T3. |
| `fashionunited_lvmh` | https://fashionunited.uk/news/business/lvmh-q3-organic-revenue-growth-slows-amid-china-downturn/2026101390823 | 200 | Sí (medio especializado) | Corrobora. |
| `nobel_econ_2026` | https://www.nobelprize.org/prizes/economic-sciences/2026/summary/ | 200 | Sí (oficial) | Motivación textual confirmada. |
| `aap_nobel` | https://www.thesenior.com.au/story/9367197/americans-hall-and-woodford-win-nobel-economics-prize/ | 200 | Sí (AAP vía medio) | 12 millones de coronas. |
| `apa_nobel` | https://en.apa.az/europe/2026-nobel-prize-in-economics-laureates-announced-529516 | 200 | Sí (agencia que replica a Reuters) | Corrobora. |
| `delta_jv` | https://news.delta.com/us-appeals-court-vacates-dot-order-unwind-deltaaeromexico-joint-venture | 200 | Parte interesada (válida solo si se presenta como tal) | No basta como única fuente. |
| `insideflyer_jv` | https://www.insideflyer.com/posts/delta-and-aeromexico-joint-venture-survives-court-challenge/ | 200 | **No**: agregador automático («Powered by BoardingAI») que repostea un blog | Sustituir por Aviation Week (21-ago-2026) o DLA Piper. |
| `md_tianguis2027` | https://www.mexicodesconocido.com.mx/tianguis-turistico-mexico-2027.html | **403 a curl** (el equipo informó 200); legible por WebFetch | Sí (medio de viajes); Milenio corrobora | 51.ª edición, 9–12 mar 2027, Puebla. |

---

## 4. Lista en formato máquina

```yaml
fecha_verificacion: 2026-10-22
piezas_aprobar:            # 13
  - carta-del-editor-n01               # condición: aplicar antes 20261025110000 (firma sin «borrador»)
  - merida-guadalajara-mesa-mexicana   # con corrección de texto (§1)
  - monaco-yacht-show-2026             # con 4 correcciones de texto (§1)
  - watches-and-wonders-2027           # con corrección de texto (§1)
  - pga-tour-los-cabos-2026            # con corrección de texto (§1)
  - banxico-pausa-6-50                 # valid_until -> 2026-11-04
  - ue-ia-alto-riesgo-2027             # corrección de entradilla (§1); confirmado en texto oficial UE
  - brief-nobel-economia-2026
  - brief-lvmh-tercer-trimestre-2026   # valid_until -> 2027-01-10
  - brief-inegi-viajeros-agosto-2026
  - brief-banxico-24-septiembre        # valid_until -> 2026-11-04
  - brief-desfile-dia-de-muertos-2026  # publicar antes del 31-oct
  - agenda-privada-n01
piezas_retener:            # 3
  - slug: cdmx-fin-de-semana-gran-premio   # PORTADA, vence 2026-11-02
    motivo: contiene img_f1_circuito e img_desfile_muertos (retenidas); el panel no puede quitarlas; corregir el párrafo del transporte perimetral
    desbloqueo: RPC edition_admin_article_update autorizada (body sin los 2 bloques img + corrección), luego aprobar antes del 2026-11-02
  - slug: art-basel-miami-beach-2026
    motivo: hero img_miami_ocean_drive retenida; horario 11-18 h no confirmado por fuente oficial
    desbloqueo: hero_image null por RPC autorizada + corrección de horario
  - slug: brief-delta-aeromexico-tribunal
    motivo: fuentes = parte interesada + agregador automático (insideflyer_jv); fecha del fallo 20-ago; vigencia
    desbloqueo: registrar fuente Aviation Week, quitar insideflyer_jv, corregir texto, valid_until 2026-11-19; aprobar antes del 2026-11-19
fotos_aprobar:             # 9
  - img_cdmx_angel_noche
  - img_merida_catedral
  - img_chile_nogada
  - img_monaco_puerto
  - img_yate_mar
  - img_reloj
  - img_golf
  - img_cabo_costa
  - img_ala_avion          # no la usa ninguna pieza
fotos_retener:             # 3
  - img_f1_circuito        # logos PETRONAS/INEOS/Mercedes protagonistas; uso comercial de marcas restringido por los términos de Pexels
  - img_desfile_muertos    # persona identificable sin permiso de modelo; pie inexacto (26-oct-2024, no es el Gran Desfile)
  - img_miami_ocean_drive  # logos CVS / Colony Hotel / Boulevard Hotel protagonistas
fuentes_no_confiables:
  - insideflyer_jv
fuentes_parte_interesada:
  - delta_jv
numero_publicable_hoy_sin_cambios_tecnicos: false   # la portada no se puede aprobar desde el panel -> cover_article_not_approved
```
