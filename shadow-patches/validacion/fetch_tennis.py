#!/usr/bin/env python3
"""Backfill de linescores de tenis desde ESPN scoreboard mensual.
Guarda:
 - matches.jsonl : una fila por partido singles completado con total de juegos
 - linescore_rows.jsonl : filas crudas por competidor/set para tenis_linescore
"""
import json, time, urllib.request, ssl, os, sys
from datetime import date

OUT = "/tmp/claude-0/-home-user-reto/46d9abc4-c29c-5c7a-91cd-791a32040095/scratchpad"
CA = "/root/.ccr/ca-bundle.crt"
ctx = ssl.create_default_context(cafile=CA) if os.path.exists(CA) else ssl.create_default_context()

def fetch(tour, ym):
    url = f"https://site.api.espn.com/apis/site/v2/sports/tennis/{tour}/scoreboard?dates={ym}"
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, headers={"User-Agent":"Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=40, context=ctx) as r:
                return json.load(r)
        except Exception as e:
            if attempt == 3:
                sys.stderr.write(f"FAIL {tour} {ym}: {e}\n")
                return None
            time.sleep(2*(attempt+1))
    return None

# meses 2021-09 .. 2026-10
months = []
y, m = 2021, 9
while (y, m) <= (2026, 10):
    months.append(f"{y:04d}{m:02d}")
    m += 1
    if m > 12:
        m = 1; y += 1

SLUG_TOUR = {"mens-singles":"atp", "womens-singles":"wta"}

matches = {}      # comp_id -> dict
ls_rows = {}      # (comp_id, competitor_id, period) -> row

req_count = 0
for ym in months:
    for feed in ("atp","wta"):
        d = fetch(feed, ym)
        req_count += 1
        time.sleep(0.25)
        if not d:
            continue
        for e in d.get("events", []):
            torneo = e.get("name") or ""
            for g in e.get("groupings", []):
                slug = (g.get("grouping") or {}).get("slug")
                if slug not in SLUG_TOUR:
                    continue
                tour = SLUG_TOUR[slug]
                for comp in g.get("competitions", []):
                    st = ((comp.get("status") or {}).get("type") or {})
                    if not st.get("completed"):
                        continue
                    cs = comp.get("competitors", [])
                    if len(cs) != 2:
                        continue
                    cid = comp.get("id")
                    # best-of-5 solo en individuales masculinos de los 4 Grand Slams.
                    # El campo format.regulation.periods de ESPN es ruidoso, no se usa.
                    tl = torneo.lower()
                    is_gs = any(k in tl for k in (
                        "australian open", "roland garros", "french open",
                        "wimbledon", "us open"))
                    bo = 5 if (tour == "atp" and is_gs) else 3
                    # datos por competidor
                    parsed = []
                    ok = True
                    for c in cs:
                        ath = c.get("athlete", {}) or {}
                        pid = c.get("id")
                        if pid is None:
                            ok = False; break
                        lss = c.get("linescores", []) or []
                        sets = []
                        for idx, it in enumerate(lss):
                            val = it.get("value")
                            if val is None:
                                continue
                            tb = it.get("tiebreak")
                            sets.append((idx+1, int(round(val)), (int(tb) if tb is not None else None)))
                        parsed.append({
                            "competitor_id": str(pid),
                            "order": c.get("order"),
                            "name": ath.get("displayName") or ath.get("fullName") or c.get("name"),
                            "winner": bool(c.get("winner")),
                            "sets": sets,
                        })
                    if not ok or len(parsed) != 2:
                        continue
                    # requiere linescores en ambos y mismo numero de sets
                    s0, s1 = parsed[0]["sets"], parsed[1]["sets"]
                    if len(s0) == 0 or len(s1) == 0:
                        continue
                    nsets = min(len(s0), len(s1))
                    total_games = 0
                    for p in range(nsets):
                        total_games += parsed[0]["sets"][p][1] + parsed[1]["sets"][p][1]
                    winner = next((p for p in parsed if p["winner"]), None)
                    loser = next((p for p in parsed if not p["winner"]), None)
                    matches[cid] = {
                        "espn_match_id": str(cid),
                        "tour": tour,
                        "torneo": torneo,
                        "fecha": comp.get("date"),
                        "bo": bo,
                        "n_sets": nsets,
                        "total_games": total_games,
                        "winner_id": winner["competitor_id"] if winner else None,
                        "loser_id": loser["competitor_id"] if loser else None,
                    }
                    for p in parsed:
                        for (period, juegos, tb) in p["sets"]:
                            ls_rows[(str(cid), p["competitor_id"], period)] = {
                                "espn_event_id": str(cid),
                                "competitor_id": p["competitor_id"],
                                "orden": p["order"],
                                "nombre": p["name"],
                                "period": period,
                                "juegos": juegos,
                                "tiebreak": tb,
                            }

with open(f"{OUT}/matches.jsonl","w") as f:
    for v in matches.values():
        f.write(json.dumps(v)+"\n")
with open(f"{OUT}/linescore_rows.jsonl","w") as f:
    for v in ls_rows.values():
        f.write(json.dumps(v)+"\n")

print(f"requests={req_count} matches={len(matches)} ls_rows={len(ls_rows)}")
