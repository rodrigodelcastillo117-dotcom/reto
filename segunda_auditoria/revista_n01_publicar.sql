-- THE PRIVATE EDITION · Nº 01 · aprobar y publicar lo verificado (VERIFICACION_REVISTA_N01.md, 22-oct-2026).
--
-- Un solo bloque DO: o se aplica TODO o no se aplica NADA (cualquier RAISE revierte el bloque entero).
-- Usa solo las funciones del panel: edition_admin_image_license, edition_admin_article_update,
-- edition_admin_article_transition y edition_admin_issue_transition.
--
-- Requisitos previos (el bloque los comprueba y aborta si no se cumplen):
--   * migración 20261025110000_edition2_status_correcciones.sql ya aplicada (firma de la carta sin «borrador»);
--   * número n01-noviembre-2026 y sus 16 piezas en pending_review;
--   * el uuid 82c06fbd-… está en public.admins.
-- Actúa con la identidad de administrador de Rodrigo del Castillo: solo debe ejecutarlo él o alguien con su
-- autorización expresa.
--
-- Qué hace:
--   1. Licencias: aprueba 9 fotos; bloquea img_f1_circuito, img_desfile_muertos, img_miami_ocean_drive.
--   2. Correcciones (ES y EN) en 9 piezas, armadas desde el valor ACTUAL de cada fila. Cada texto viejo debe
--      aparecer exactamente una vez. Quita de la portada los bloques img de las 2 fotos bloqueadas.
--      Ajusta valid_until en 3 piezas.
--   3. Aprueba 14 piezas. Retiene art-basel-miami-beach-2026 y brief-delta-aeromexico-tribunal (no se tocan).
--   4. Aprueba y publica el número (publicar el número publica sus piezas aprobadas).
--
-- No se corrige el pie de img_monaco_puerto: ninguna función del panel edita depicts/alt de una imagen.

DO $edition_n01$
DECLARE
  c_issue   CONSTANT text := 'n01-noviembre-2026';
  c_label   CONSTANT text := 'Dirección editorial IATOS Privé';
  c_note    CONSTANT text := 'Verificación independiente 22-oct-2026 (VERIFICACION_REVISTA_N01.md); aprobado por Claude a petición de Rodrigo del Castillo';
  c_note_bl CONSTANT text := 'Verificación independiente 22-oct-2026 (VERIFICACION_REVISTA_N01.md); bloqueado por Claude a petición de Rodrigo del Castillo';
  c_imgs_ok CONSTANT text[] := ARRAY['img_cdmx_angel_noche','img_merida_catedral','img_chile_nogada','img_monaco_puerto',
                                     'img_yate_mar','img_reloj','img_golf','img_cabo_costa','img_ala_avion'];
  c_imgs_bl CONSTANT text[] := ARRAY['img_f1_circuito','img_desfile_muertos','img_miami_ocean_drive'];
  c_approve CONSTANT text[] := ARRAY['carta-del-editor-n01','cdmx-fin-de-semana-gran-premio','merida-guadalajara-mesa-mexicana',
    'monaco-yacht-show-2026','watches-and-wonders-2027','pga-tour-los-cabos-2026','banxico-pausa-6-50','ue-ia-alto-riesgo-2027',
    'brief-nobel-economia-2026','brief-lvmh-tercer-trimestre-2026','brief-inegi-viajeros-agosto-2026',
    'brief-banxico-24-septiembre','brief-desfile-dia-de-muertos-2026','agenda-privada-n01'];
  c_hold    CONSTANT text[] := ARRAY['art-basel-miami-beach-2026','brief-delta-aeromexico-tribunal'];
  v_issue_id uuid;
  a public.edition_articles;
  r record; s text; k text; n int;
  v_title text; v_dek text; v_body text; v_old text; v_new text; v_txt text;
  v_body_j jsonb; v_patch jsonb; v_valid date;
  v_pub int; v_pend int; v_ok int; v_bl int;
BEGIN
  -- 1) Identidad: cuenta admin del dueño. request.jwt.claims es lo que lee auth.uid() en Supabase;
  --    request.jwt.claim.sub/role cubre la variante antigua (la usa el stub local de pruebas).
  PERFORM set_config('request.jwt.claims', '{"sub":"82c06fbd-02d7-4a7b-bff7-4159d0916dad","role":"authenticated"}', true);
  PERFORM set_config('request.jwt.claim.sub', '82c06fbd-02d7-4a7b-bff7-4159d0916dad', true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);

  -- 0) Comprobaciones previas: si algo no está como se verificó, no se toca nada.
  SELECT id INTO v_issue_id FROM public.edition_issues WHERE slug = c_issue AND status = 'pending_review';
  IF v_issue_id IS NULL THEN
    RAISE EXCEPTION 'N01: el número % no está en pending_review (¿ya se aprobó o publicó?). No se aplicó nada.', c_issue;
  END IF;
  SELECT count(*) INTO n FROM public.edition_articles
   WHERE issue_id = v_issue_id AND slug = ANY (c_approve || c_hold) AND status = 'pending_review';
  IF n <> 16 THEN
    RAISE EXCEPTION 'N01: se esperaban 16 piezas en pending_review y hay %. No se aplicó nada.', n;
  END IF;
  IF EXISTS (SELECT 1 FROM public.edition_articles WHERE slug = 'carta-del-editor-n01'
              AND (byline->>'es' ILIKE '%borrador%' OR byline->>'en' ILIKE '%draft%')) THEN
    RAISE EXCEPTION 'N01: la firma de la carta todavía dice «borrador»: aplica antes 20261025110000_edition2_status_correcciones.sql.';
  END IF;
  SELECT count(*) INTO n FROM public.edition_images WHERE key = ANY (c_imgs_ok || c_imgs_bl);
  IF n <> 12 THEN RAISE EXCEPTION 'N01: se esperaban 12 imágenes y hay %.', n; END IF;

  -- 2) Licencias de fotos.
  FOREACH k IN ARRAY c_imgs_ok LOOP
    PERFORM public.edition_admin_image_license(k, 'approve', c_note);
  END LOOP;
  FOR r IN SELECT * FROM (VALUES
      ('img_f1_circuito',       'Motivo: logos PETRONAS, INEOS y Mercedes protagonistas; los términos de Pexels restringen el uso comercial de contenido con marcas.'),
      ('img_desfile_muertos',   'Motivo: persona identificable sin permiso de modelo; tomada el 26-oct-2024, no corresponde al Gran Desfile (pie inexacto).'),
      ('img_miami_ocean_drive', 'Motivo: logos de CVS, Colony Hotel y Boulevard Hotel protagonistas.')
    ) v(key, motivo) LOOP
    PERFORM public.edition_admin_image_license(r.key, 'block', c_note_bl || ' · ' || r.motivo);
  END LOOP;

  -- 3) Correcciones. field: title | dek | body (reemplazo de texto exacto, 1 ocurrencia),
  --    remove_img (quita del body el bloque img de esa foto; debe existir 1 vez),
  --    valid_until (old_txt = valor actual esperado, new_txt = nuevo valor).
  CREATE TEMP TABLE _n01_corr (ord int, slug text, field text, old_txt text, new_txt text) ON COMMIT DROP;
  INSERT INTO _n01_corr VALUES
    -- Portada
    (10, 'cdmx-fin-de-semana-gran-premio', 'body',
       $t$Dentro del perímetro circulan autobuses gratuitos entre accesos, de 7:00 a 20:00, para quien muestra su boleto.$t$,
       $t$Alrededor del autódromo opera un transporte perimetral gratuito entre puertas, de 7:00 a 20:00, para quien presenta su boleto; el promotor advierte que el horario puede cambiar.$t$),
    (11, 'cdmx-fin-de-semana-gran-premio', 'body',
       $t$Inside the perimeter, free buses run between gates from 7:00 to 20:00 for ticket holders.$t$,
       $t$Around the circuit, a free perimeter shuttle runs between gates from 7:00 to 20:00 for those who show their ticket; the promoter warns that the schedule may change.$t$),
    (12, 'cdmx-fin-de-semana-gran-premio', 'remove_img', 'img_desfile_muertos', NULL),
    (13, 'cdmx-fin-de-semana-gran-premio', 'remove_img', 'img_f1_circuito', NULL),
    -- Mérida (el EN ya decía «In the Americas»)
    (20, 'merida-guadalajara-mesa-mexicana', 'body',
       $t$Lectura editorial: en cinco meses, Mérida sumó$t$, $t$Lectura editorial: en cuatro meses, Mérida sumó$t$),
    (21, 'merida-guadalajara-mesa-mexicana', 'body',
       $t$Editorial reading: in five months, Mérida gained$t$, $t$Editorial reading: in four months, Mérida gained$t$),
    (22, 'merida-guadalajara-mesa-mexicana', 'body',
       $t$En el continente, la única propiedad nueva$t$, $t$En América, la única propiedad nueva$t$),
    -- Mónaco
    (30, 'monaco-yacht-show-2026', 'body',
       $t$La pieza más esperada fue Nixie, de 102.4 metros, construida por Lürssen, en su debut mundial.$t$,
       $t$Entre los debuts mundiales estuvo Nixie, de 102.4 metros, construida por Lürssen, que ocupó el lugar principal del Quai Rainier Ier.$t$),
    (31, 'monaco-yacht-show-2026', 'body',
       $t$The most anticipated arrival was Nixie, 102.4 metres, built by Lürssen, on her world debut.$t$,
       $t$Among the world debuts was Nixie, 102.4 metres, built by Lürssen, which took pride of place at Quai Rainier Ier.$t$),
    (32, 'monaco-yacht-show-2026', 'body',
       $t$Los turnos de construcción de los grandes astilleros están comprometidos hasta 2028 y 2029.$t$,
       $t$Los turnos de construcción de los grandes astilleros están comprometidos hasta 2028 y 2029, según el Global Order Book 2026 de Boat International.$t$),
    (33, 'monaco-yacht-show-2026', 'body',
       $t$Build slots at the leading shipyards are committed through 2028 and 2029.$t$,
       $t$Build slots at the leading shipyards are committed through 2028 and 2029, according to Boat International's Global Order Book 2026.$t$),
    (34, 'monaco-yacht-show-2026', 'body',
       $t$espera, según la misma fuente, hasta 2028 o más.$t$,
       $t$espera hasta 2028 o más, según una declaración recogida por Monaco Life.$t$),
    (35, 'monaco-yacht-show-2026', 'body',
       $t$means waiting, according to the same source, until 2028 or beyond.$t$,
       $t$means waiting until 2028 or beyond, according to a statement quoted by Monaco Life.$t$),
    (36, 'monaco-yacht-show-2026', 'body',
       $t$con experiencias náuticas verificadas por destino.$t$, $t$con experiencias náuticas por destino.$t$),
    (37, 'monaco-yacht-show-2026', 'body',
       $t$lists verified nautical experiences by destination.$t$, $t$lists nautical experiences by destination.$t$),
    -- Watches and Wonders
    (40, 'watches-and-wonders-2027', 'body',
       $t$El salón relojero más grande de Ginebra ya tiene fecha:$t$,
       $t$Watches and Wonders, la principal feria de relojería de lujo según Watches by SJX, ya tiene fecha:$t$),
    (41, 'watches-and-wonders-2027', 'body',
       $t$Geneva's largest watch fair has its dates:$t$,
       $t$Watches and Wonders, the leading luxury watch fair according to Watches by SJX, has its dates:$t$),
    -- PGA Tour
    (50, 'pga-tour-los-cabos-2026', 'body',
       $t$Los Cabos está en la sección de destinos de Privé, con experiencias verificadas y la colección SPORT & LEISURE.$t$,
       $t$Los Cabos está en la sección de destinos de Privé y en la colección SPORT & LEISURE.$t$),
    (51, 'pga-tour-los-cabos-2026', 'body',
       $t$Los Cabos is in Privé's destinations, with verified experiences and the SPORT & LEISURE collection.$t$,
       $t$Los Cabos is in Privé's destinations and in the SPORT & LEISURE collection.$t$),
    -- Banxico (explicador)
    (60, 'banxico-pausa-6-50', 'body',
       $t$, según AAP y APA/Reuters.$t$, $t$, según la Real Academia Sueca de Ciencias.$t$),
    (61, 'banxico-pausa-6-50', 'body',
       $t$, according to AAP and APA/Reuters.$t$, $t$, according to the Royal Swedish Academy of Sciences.$t$),
    (62, 'banxico-pausa-6-50', 'valid_until', '2026-11-05', '2026-11-04'),
    -- IA en la UE
    (70, 'ue-ia-alto-riesgo-2027', 'dek',
       $t$aplazó a diciembre de 2027 las obligaciones para los sistemas de alto riesgo.$t$,
       $t$aplazó a diciembre de 2027 las obligaciones para los sistemas de alto riesgo del Anexo III, y a agosto de 2028 las de la IA integrada en productos regulados.$t$),
    (71, 'ue-ia-alto-riesgo-2027', 'dek',
       $t$pushed obligations for high-risk systems to December 2027.$t$,
       $t$pushed obligations for Annex III high-risk systems to December 2027, and those for AI embedded in regulated products to August 2028.$t$),
    (72, 'ue-ia-alto-riesgo-2027', 'body',
       $t$Las fechas provienen de análisis de despachos; el texto oficial está en EUR-Lex.$t$,
       $t$Las fechas coinciden con el texto oficial del Reglamento (UE) 2026/1744 (DO L de 24.7.2026), disponible en EUR-Lex.$t$),
    (73, 'ue-ia-alto-riesgo-2027', 'body',
       $t$Dates come from law-firm analyses; the official text is on EUR-Lex.$t$,
       $t$The dates match the official text of Regulation (EU) 2026/1744 (OJ L of 24.7.2026), available on EUR-Lex.$t$),
    -- Vigencias
    (80, 'brief-lvmh-tercer-trimestre-2026', 'valid_until', '2027-01-31', '2027-01-10'),
    (90, 'brief-banxico-24-septiembre',      'valid_until', '2026-11-05', '2026-11-04');

  FOR s IN SELECT c.slug FROM _n01_corr c GROUP BY c.slug ORDER BY min(c.ord) LOOP
    SELECT * INTO a FROM public.edition_articles WHERE slug = s;
    IF NOT FOUND THEN RAISE EXCEPTION 'N01: no existe la pieza %', s; END IF;
    v_title := a.title::text; v_dek := a.dek::text; v_body := a.body::text; v_valid := NULL;

    -- 3a) Reemplazos de texto sobre el JSON actual (el texto se busca ya escapado como JSON).
    FOR r IN SELECT * FROM _n01_corr c WHERE c.slug = s AND c.field IN ('title','dek','body') ORDER BY c.ord LOOP
      v_old := to_jsonb(r.old_txt)::text; v_old := substr(v_old, 2, length(v_old) - 2);
      v_new := to_jsonb(r.new_txt)::text; v_new := substr(v_new, 2, length(v_new) - 2);
      v_txt := CASE r.field WHEN 'title' THEN v_title WHEN 'dek' THEN v_dek ELSE v_body END;
      n := (length(v_txt) - length(replace(v_txt, v_old, ''))) / length(v_old);
      IF n <> 1 THEN
        RAISE EXCEPTION 'N01: corrección % de % (%): el texto viejo aparece % veces (se esperaba 1): «%»', r.ord, s, r.field, n, r.old_txt;
      END IF;
      v_txt := replace(v_txt, v_old, v_new);
      CASE r.field WHEN 'title' THEN v_title := v_txt; WHEN 'dek' THEN v_dek := v_txt; ELSE v_body := v_txt; END CASE;
    END LOOP;

    -- 3b) Quitar bloques de imagen de fotos bloqueadas.
    v_body_j := v_body::jsonb;
    FOR r IN SELECT * FROM _n01_corr c WHERE c.slug = s AND c.field = 'remove_img' ORDER BY c.ord LOOP
      SELECT count(*) INTO n FROM jsonb_array_elements(v_body_j) b WHERE b->>'t' = 'img' AND b->>'image' = r.old_txt;
      IF n <> 1 THEN
        RAISE EXCEPTION 'N01: % — el bloque img «%» aparece % veces (se esperaba 1)', s, r.old_txt, n;
      END IF;
      SELECT coalesce(jsonb_agg(b ORDER BY ord), '[]'::jsonb) INTO v_body_j
        FROM jsonb_array_elements(v_body_j) WITH ORDINALITY x(b, ord)
       WHERE NOT (b->>'t' = 'img' AND b->>'image' = r.old_txt);
    END LOOP;

    -- 3c) Vigencia: el valor actual debe ser el verificado.
    FOR r IN SELECT * FROM _n01_corr c WHERE c.slug = s AND c.field = 'valid_until' LOOP
      IF a.valid_until IS DISTINCT FROM r.old_txt::date THEN
        RAISE EXCEPTION 'N01: % — valid_until actual % (se esperaba %)', s, a.valid_until, r.old_txt;
      END IF;
      v_valid := r.new_txt::date;
    END LOOP;

    v_patch := '{}'::jsonb;
    IF v_title <> a.title::text THEN v_patch := v_patch || jsonb_build_object('title', v_title::jsonb); END IF;
    IF v_dek   <> a.dek::text   THEN v_patch := v_patch || jsonb_build_object('dek',   v_dek::jsonb);   END IF;
    IF v_body_j <> a.body       THEN v_patch := v_patch || jsonb_build_object('body',  v_body_j);       END IF;
    IF v_valid IS NOT NULL      THEN v_patch := v_patch || jsonb_build_object('valid_until', v_valid);  END IF;
    IF v_patch = '{}'::jsonb THEN RAISE EXCEPTION 'N01: % — el patch quedó vacío', s; END IF;
    PERFORM public.edition_admin_article_update(s, v_patch, c_note);
  END LOOP;

  -- 3d) Ninguna pieza a aprobar puede llevar una foto bloqueada (hero o cuerpo).
  FOREACH s IN ARRAY c_approve LOOP
    SELECT * INTO a FROM public.edition_articles WHERE slug = s;
    IF EXISTS (SELECT 1 FROM unnest(public.edition_article_image_keys(a.hero_image_id, a.body)) AS ik(img_key)
                WHERE ik.img_key = ANY (c_imgs_bl)) THEN
      RAISE EXCEPTION 'N01: % todavía lleva una foto bloqueada', s;
    END IF;
  END LOOP;

  -- 4) Aprobación de las 14 piezas (la base vuelve a correr todos sus bloqueos).
  FOREACH s IN ARRAY c_approve LOOP
    PERFORM public.edition_admin_article_transition(s, 'approve', c_note, NULL, c_label);
  END LOOP;

  -- 5) Número: aprobar y publicar (publica las 14 aprobadas; las 2 retenidas siguen en pending_review).
  PERFORM public.edition_admin_issue_transition(c_issue, 'approve', c_note, NULL, c_label);
  PERFORM public.edition_admin_issue_transition(c_issue, 'publish', c_note, NULL, c_label);

  -- 6) Comprobación final y resumen.
  SELECT count(*) FILTER (WHERE status = 'published'), count(*) FILTER (WHERE status = 'pending_review' AND slug = ANY (c_hold))
    INTO v_pub, v_pend FROM public.edition_articles WHERE issue_id = v_issue_id;
  SELECT count(*) FILTER (WHERE license_status = 'approved' AND key = ANY (c_imgs_ok)),
         count(*) FILTER (WHERE license_status = 'blocked'  AND key = ANY (c_imgs_bl))
    INTO v_ok, v_bl FROM public.edition_images;
  IF v_pub <> 14 OR v_pend <> 2 OR v_ok <> 9 OR v_bl <> 3
     OR NOT EXISTS (SELECT 1 FROM public.edition_issues WHERE id = v_issue_id AND status = 'published') THEN
    RAISE EXCEPTION 'N01: resultado inesperado (publicadas %, retenidas %, fotos ok %, bloqueadas %)', v_pub, v_pend, v_ok, v_bl;
  END IF;
  RAISE NOTICE 'N01 publicado: número % published; % piezas publicadas; % retenidas en pending_review (%); fotos: % aprobadas, % bloqueadas (%); % piezas corregidas.',
    c_issue, v_pub, v_pend, array_to_string(c_hold, ', '), v_ok, v_bl, array_to_string(c_imgs_bl, ', '),
    (SELECT count(DISTINCT slug) FROM _n01_corr);
END
$edition_n01$;
