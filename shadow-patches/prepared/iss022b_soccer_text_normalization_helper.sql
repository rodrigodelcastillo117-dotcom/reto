-- ISS-022b — SOCCER TEXT NORMALIZATION HELPER
-- *** STAGED — NO APLICADO A PROD ***
-- Required before ISS-023 because current production does not expose public.reto_norm_txt(text).
-- Uses the existing immutable public.sin_acentos(text) helper and conservative whitespace folding.

CREATE OR REPLACE FUNCTION public.reto_norm_txt(p_text text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path TO 'public'
AS $$
  SELECT regexp_replace(lower(public.sin_acentos(trim(coalesce(p_text,'')))), '\s+', ' ', 'g');
$$;

COMMENT ON FUNCTION public.reto_norm_txt(text)
IS 'Deterministic soccer text normalization for exact/static joins only; not a fuzzy identity resolver.';

-- ROLLBACK:
-- DROP FUNCTION IF EXISTS public.reto_norm_txt(text);
