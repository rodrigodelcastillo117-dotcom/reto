#!/usr/bin/env python3
"""Elo por superficie (blend global+superficie) vs Elo global, OOS.
Superficie mapeada por torneo (arcilla/pasto explícitos; resto dura; Stuttgart por tour).
Regla: publicar solo si mejora Brier/accuracy OOS sin empeorar calibración."""
import json, math, re
from collections import defaultdict
import numpy as np, pandas as pd

SC="/tmp/claude-0/-home-user-reto/46d9abc4-c29c-5c7a-91cd-791a32040095/scratchpad"
CUT=pd.Timestamp("2025-07-01", tz="UTC"); K=32.0

GRASS=["wimbledon","eastbourne","libema","libéma","hertogenbosch","rosmalen","halle","terra wortmann",
 "queen","cinch","hsbc championships","nottingham","birmingham","mallorca","bad homburg","newport",
 "surbiton","ilkley","berlin"]
CLAY=["roland garros","french open","madrid","rome","italia","internazionali","monte-carlo","monte carlo",
 "barcelona","bastad","båstad","nordea","kitzbuhel","kitzbühel","hamburg","umag","gstaad","bucharest",
 "estoril","munich","bmw open","geneva","genève","lyon","cordoba","córdoba","buenos aires","argentina open",
 "rio ","santiago","chile open","bogota","bogotá","colsanitas","charleston","parma","warsaw","palermo",
 "cluj","iasi","tunis","marrakech","houston","sao paulo","são paulo","florianopolis","guayaquil","quito",
 "oeiras","bahia","contrexeville","hamburgo","salvador","perugia","trieste","como","genova","rabat"]

def surface(torneo, tour):
    t=(torneo or "").lower()
    if "stuttgart" in t:                       # ATP pasto, WTA arcilla
        return "grass" if tour=="atp" else "clay"
    for k in GRASS:
        if k in t: return "grass"
    for k in CLAY:
        if k in t: return "clay"
    return "hard"

rows=[json.loads(l) for l in open(f"{SC}/matches.jsonl")]
df=pd.DataFrame(rows)
df["fecha"]=pd.to_datetime(df["fecha"],utc=True,format="ISO8601")
df=df.dropna(subset=["winner_id","loser_id"]).sort_values(["fecha","espn_match_id"]).reset_index(drop=True)
df["surf"]=[surface(t,to) for t,to in zip(df["torneo"],df["tour"])]
print("cobertura superficie (todos los partidos):")
print(df["surf"].value_counts(normalize=True).round(3).to_dict())
print("por mes (sanity: pasto en 6-7, arcilla en 4-6/verano):")
print(pd.crosstab(df["fecha"].dt.month, df["surf"]).to_string())

def run(df, w_surf):
    """w_surf = peso de la superficie en el blend (0 = solo global = vainilla)."""
    g=defaultdict(lambda:1500.0); s=defaultdict(lambda:1500.0); ng=defaultdict(int)
    rec=[]
    for r in df.itertuples(index=False):
        ww,ll=r.winner_id,r.loser_id; su=r.surf
        gw,gl=g[ww],g[ll]; sw,sl=s[(ww,su)],s[(ll,su)]
        # rating combinado (regresa a global por peso)
        rw=(1-w_surf)*gw + w_surf*sw
        rl=(1-w_surf)*gl + w_surf*sl
        exp_w=1.0/(1.0+10**((rl-rw)/400.0))
        fav=rw>=rl; p_fav=exp_w if fav else 1-exp_w
        rec.append((r.tour,r.fecha,min(ng[ww],ng[ll]),p_fav,1 if fav else 0))
        # actualizar global y superficie con su propio expected
        eg=1.0/(1.0+10**((gl-gw)/400.0)); es=1.0/(1.0+10**((sl-sw)/400.0))
        g[ww]=gw+K*(1-eg); g[ll]=gl-K*(1-eg)
        s[(ww,su)]=sw+K*(1-es); s[(ll,su)]=sl-K*(1-es)
        ng[ww]+=1; ng[ll]+=1
    return pd.DataFrame(rec,columns=["tour","fecha","nmin","p_fav","fav_won"])

def ece(p,y,bins=10):
    p=np.asarray(p);y=np.asarray(y);e=0.0
    for i in range(bins):
        lo,hi=i/bins,(i+1)/bins; m=(p>=lo)&(p<hi) if i<bins-1 else (p>=lo)&(p<=hi)
        if m.sum()>0: e+=m.mean()*abs(p[m].mean()-y[m].mean())
    return 100*e
def mtr(E,split):
    d=E[(E.fecha>=CUT if split=="test" else E.fecha<CUT)&(E.nmin>=10)]
    return dict(n=len(d),acc=round(100*d.fav_won.mean(),2),
               brier=round(float(np.mean((d.p_fav-d.fav_won)**2)),4),
               ece=round(ece(d.p_fav,d.fav_won),2))

van=run(df,0.0)
# elegir peso en TRAIN
best=None
for w in [0.2,0.3,0.4,0.5,0.6]:
    E=run(df,w); b=mtr(E,"train")["brier"]
    if best is None or b<best[1]: best=(w,b,E)
w_opt,_,surfE=best
print("\nw_surf óptimo (train):",w_opt)
print("VAINILLA (global) test:", mtr(van,"test"))
print("SUPERFICIE   test:", mtr(surfE,"test"))
v=mtr(van,"test"); s=mtr(surfE,"test")
print(f"\nDELTA: Brier {v['brier']}->{s['brier']} ({round(s['brier']-v['brier'],4)}; neg=mejor) | "
      f"Acc {v['acc']}->{s['acc']} ({round(s['acc']-v['acc'],2)}pp) | ECE {v['ece']}->{s['ece']}")
