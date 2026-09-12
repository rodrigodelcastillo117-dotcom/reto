#!/usr/bin/env python3
"""BLOQUE 1 — Prueba explícita de los 3 partidos cruzados del usuario.
Reentrena en TODO el histórico usable y predice, aplicando fail-close por cobertura."""
import math, numpy as np
from fit_crossleague import load, build_league_index, fit, predict, score_matrix
from scipy.stats import poisson
import collections

rows=load(); rows.sort(key=lambda r:r["fecha"])
lidx,ref=build_league_index(rows)
# cobertura por liga (piso serving 20 juegos cruzados)
cov=collections.Counter()
for r in rows:
    if r["h_liga"]!=r["a_liga"]: cov[r["h_liga"]]+=1; cov[r["a_liga"]]+=1
SERVIBLE={L for L,n in cov.items() if n>=20}
theta=fit(rows,lidx,use_phi=True,ridge=10.0)

MATCHES=[
 ("Barcelona (LaLiga)","Feyenoord (Eredivisie)", dict(h_gf=2.6727,h_ga=0.9455,h_liga=140,a_gf=2.1837,a_ga=1.2857,a_liga=88), "UEFA Champions League"),
 ("Liverpool (Premier)","Atlético Madrid (LaLiga)", dict(h_gf=1.7255,h_ga=1.4314,h_liga=39,a_gf=1.7358,a_ga=1.1321,a_liga=140), "UEFA Champions League"),
 ("VfB Stuttgart (Bundesliga)","Viking (Eliteserien)", dict(h_gf=2.0889,h_ga=1.4889,h_liga=78,a_gf=2.4490,a_ga=1.1224,a_liga=103), "UEFA Europa League"),
]

def ou_btts(M):
    kmax=M.shape[0]-1
    over=sum(M[i,j] for i in range(kmax+1) for j in range(kmax+1) if i+j>=3)  # O/U 2.5
    btts=sum(M[i,j] for i in range(1,kmax+1) for j in range(1,kmax+1))
    return over, btts

print(f"modelo: ref liga={ref}, ridge=10, ligas servibles={sorted(SERVIBLE)}\n")
for home,away,f,comp in MATCHES:
    if f["h_liga"] not in SERVIBLE or f["a_liga"] not in SERVIBLE:
        print(f"{home} vs {away} [{comp}] -> FAIL-CLOSE (liga sin cobertura φ)\n"); continue
    r=dict(h_gf=f["h_gf"],h_ga=f["h_ga"],h_liga=f["h_liga"],a_gf=f["a_gf"],a_ga=f["a_ga"],a_liga=f["a_liga"])
    p,lh,la,M=predict(theta,r,lidx,True)
    over,btts=ou_btts(M)
    # marcador más probable
    idx=np.unravel_index(np.argmax(M),M.shape)
    print(f"{home} vs {away}  [{comp}]")
    print(f"  λ_home={lh:.2f} λ_away={la:.2f}  marcador más probable {idx[0]}-{idx[1]}")
    print(f"  P_RETO 1X2:  Local {p[0]*100:5.1f}%  Empate {p[1]*100:5.1f}%  Visita {p[2]*100:5.1f}%")
    print(f"  Over2.5 {over*100:5.1f}%  Under2.5 {(1-over)*100:5.1f}%  BTTS_sí {btts*100:5.1f}%\n")
