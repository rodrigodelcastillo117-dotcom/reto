#!/usr/bin/env python3
"""Evidencia del modelo de tenis GANADOR (Elo secuencial) contra la vara del gate:
holdout temporal, accuracy con IC95, Brier vs naive (coin), skill con IC95, calibracion (ECE)."""
import json, math
from collections import defaultdict
import numpy as np, pandas as pd

SC="/tmp/claude-0/-home-user-reto/46d9abc4-c29c-5c7a-91cd-791a32040095/scratchpad"
CUT=pd.Timestamp("2025-07-01", tz="UTC"); K=32.0
rows=[json.loads(l) for l in open(f"{SC}/matches.jsonl")]
df=pd.DataFrame(rows)
df["fecha"]=pd.to_datetime(df["fecha"],utc=True,format="ISO8601")
df=df.dropna(subset=["winner_id","loser_id"]).sort_values(["fecha","espn_match_id"]).reset_index(drop=True)

elo=defaultdict(lambda:1500.0); ng=defaultdict(int)
recs=[]
for r in df.itertuples(index=False):
    w,l=r.winner_id,r.loser_id; ew,el=elo[w],elo[l]
    p_w=1.0/(1.0+10**((el-ew)/400.0))            # prob modelo de que gane el ganador real
    fav_is_w = ew>=el
    p_fav = p_w if fav_is_w else (1-p_w)          # prob del favorito (mayor Elo)
    fav_won = 1 if fav_is_w else 0                # el favorito fue el ganador real?
    recs.append((r.tour, r.fecha, min(ng[w],ng[l]), p_fav, fav_won, p_w))
    elo[w]=ew+K*(1-p_w); elo[l]=el-K*(1-p_w); ng[w]+=1; ng[l]+=1
E=pd.DataFrame(recs, columns=["tour","fecha","nmin","p_fav","fav_won","p_w"])
# holdout: ambos con >=10 partidos previos, test >= cutoff
te=E[(E.fecha>=CUT)&(E.nmin>=10)].copy()

def wilson(k,n):
    if n==0: return (None,None)
    p=k/n; z=1.96; d=1+z*z/n
    c=(p+z*z/(2*n))/d; h=z*math.sqrt(p*(1-p)/n+z*z/(4*n*n))/d
    return (round(100*(c-h),1), round(100*(c+h),1))

def ece(p,y,bins=10):
    p=np.asarray(p); y=np.asarray(y); e=0.0
    for i in range(bins):
        lo,hi=i/bins,(i+1)/bins; m=(p>=lo)&(p<hi) if i<bins-1 else (p>=lo)&(p<=hi)
        if m.sum()>0: e+=m.mean()*abs(p[m].mean()-y[m].mean())
    return round(100*e,2)

out={}
for tour in ["atp","wta","(ambos)"]:
    d = te if tour=="(ambos)" else te[te.tour==tour]
    n=len(d); acc=d.fav_won.mean()
    # Brier: prediccion = p_fav para el evento fav_won
    brier=np.mean((d.p_fav - d.fav_won)**2)
    naive=0.25  # coin (prob 0.5)
    # IC95 del skill (1 - brier/naive) por bootstrap
    rng=np.random.default_rng(0); sk=[]
    pv=d.p_fav.values; yv=d.fav_won.values
    for _ in range(2000):
        idx=rng.integers(0,n,n); b=np.mean((pv[idx]-yv[idx])**2); sk.append(1-b/naive)
    sk=np.array(sk)
    out[tour]={"n":n,"accuracy_pct":round(100*acc,1),"acc_IC95":wilson(int(d.fav_won.sum()),n),
               "brier":round(brier,4),"brier_naive":naive,
               "skill_pct":round(100*(1-brier/naive),2),
               "skill_IC95_pct":[round(100*np.percentile(sk,2.5),2),round(100*np.percentile(sk,97.5),2)],
               "cruza_neutral": bool(np.percentile(sk,2.5)<=0),
               "ECE_pct":ece(d.p_fav,d.fav_won)}
print(json.dumps(out,indent=1))
print("\nCalibracion (ambos), por bin de p_fav:")
d=te
for i in range(5,10):
    lo,hi=i/10,(i+1)/10; m=(d.p_fav>=lo)&(d.p_fav<hi) if i<9 else (d.p_fav>=lo)&(d.p_fav<=1.0)
    if m.sum()>0: print(f"  {lo:.1f}-{hi:.1f}: n={int(m.sum()):4d} pred={d.p_fav[m].mean():.3f} real={d.fav_won[m].mean():.3f}")
