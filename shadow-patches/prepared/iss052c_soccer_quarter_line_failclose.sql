-- iss052c — SOCCER quarter-line fail-close · STAGED/RELEASE safety
-- Release contract supports WHOLE and HALF totals only. Quarter lines (x.25/x.75)
-- are intentionally unsupported until split-settlement semantics have their own validated
-- calibration/EV layer. Returning NULL here makes fn_dist_from_lambda expose
-- ou_supported=false with p_over/p_push/p_under=NULL, so event gate excludes it.
create or replace function v2.fn_total_weights(total integer, line numeric)
returns numeric[] language plpgsql immutable as $$
declare frac numeric;
begin
  if line is null then return null; end if;
  frac := line - floor(line);
  if frac = 0.5 then
    if total > line then return array[1,0,0]::numeric[];
    else return array[0,0,1]::numeric[];
    end if;
  elsif frac = 0 then
    if total > line then return array[1,0,0]::numeric[];
    elsif total = line then return array[0,1,0]::numeric[];
    else return array[0,0,1]::numeric[];
    end if;
  else
    -- x.25/x.75 and every non whole/half line fail closed for this release.
    return null;
  end if;
end $$;
