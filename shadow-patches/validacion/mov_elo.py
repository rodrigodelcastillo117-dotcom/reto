#!/usr/bin/env python3
"""Compara Elo vainilla vs Elo ponderado por margen de victoria (MOV), OOS.
MOV usa los juegos ganados/cedidos (dato del backfill de linescores).
Regla: publicar solo si MOV mejora Brier/accuracy fuera de muestra sin empeorar calibración."""
import json, math
from collections import defaultdict
import numpy as np, pandas as pd

SC="/tmp/claude-0/-home-user-reto/46d9abc4-c29c-5c7a-91cd-791a32040095/scratchpad"
CUT=pd.Timestamp("2025-07-01", tz="UTC"); K=32.0
rows=[json.loads(l) for l in open(f"{SC}/matches.jsonl")]
df=pd.DataFrame(rows)
df["fecha"]=pd.to_datetime(df["fecha"],utc=True,format="ISO8601")
df=df.dropna(subset=["winner_id","loser_id","w_games","l_games"])
df=df[(df.w_games+df.l_games)>0].sort_values(["fecha","espn_match_id"]).reset_index(drop=True)

def run_elo(df, mov=False, C=2.2):
    elo=defaultdict(lambda:1500.0); ng=defaultdict(int); rec=[]
    for r in df.itertuples(index=False):
        w,l=r.winner_id,r.loser_id; ew,el=elo[w],elo[l]
        exp_w=1.0/(1.0+10**((el-ew)/400.0))
        fav_is_w = ew>=el
        p_fav = exp_w if fav_is_w else (1-exp_w)
        rec.append((r.tour, r.fecha, min(ng[w],ng[l]), p_fav, 1 if fav_is_w else 0))
        if mov:
            margin = abs(r.w_games - r.l_games)            # diferencia de juegos
            elo_diff_w = ew - el                            # a favor del ganador
            mult = math.log(margin+1.0) * (C/((elo_diff_w)*0.001 + C))
        else:
            mult = 1.0
        delta = K*mult*(1-exp_w)
        elo[w]=ew+delta; elo[l]=el-delta; ng[w]+=1; ng[l]+=1
    E=pd.DataFrame(rec, columns=["tour","fecha","nmin","p_fav","fav_won"])
    return E

def ece(p,y,bins=10):
    p=np.asarray(p); y=np.asarray(y); e=0.0
    for i in range(bins):
        lo,hi=i/bins,(i+1)/bins; m=(p>=lo)&(p<hi) if i<bins-1 else (p>=lo)&(p<=hi)
        if m.sum()>0: e+=m.mean()*abs(p[m].mean()-y[m].mean())
    return 100*e

def metrics(E):
    te=E[(E.fecha>=CUT)&(E.nmin>=10)]
    out={}
    for tour in ["atp","wta","(ambos)"]:
        d = te if tour=="(ambos)" else te[te.tour==tour]
        out[tour]=dict(n=len(d), acc=round(100*d.fav_won.mean(),2),
                       brier=round(float(np.mean((d.p_fav-d.fav_won)**2)),4),
                       ece=round(ece(d.p_fav,d.fav_won),2))
    return out

van=run_elo(df, mov=False)
# elegir C en TRAIN (minimiza Brier en train) para no sobreajustar al test
best=None
for C in [1.0,1.6,2.2,3.0,5.0,8.0]:
    E=run_elo(df, mov=True, C=C)
    tr=E[(E.fecha<CUT)&(E.nmin>=10)]
    b=float(np.mean((tr.p_fav-tr.fav_won)**2))
    if best is None or b<best[1]: best=(C,b,E)
C_opt, _, mov = best

print("C_opt (elegido en train):", C_opt)
print("\n=== VAINILLA (Elo actual) — TEST ===")
print(json.dumps(metrics(van), indent=1))
print("\n=== MOV (margen de victoria) — TEST ===")
print(json.dumps(metrics(mov), indent=1))

print("\n=== DELTA (MOV - vainilla), TEST, ambos ===")
mv=metrics(mov)["(ambos)"]; vn=metrics(van)["(ambos)"]
print(f"  Brier: {vn['brier']} -> {mv['brier']}  (delta {round(mv['brier']-vn['brier'],4)}; negativo = mejor)")
print(f"  Acc:   {vn['acc']}% -> {mv['acc']}%  (delta {round(mv['acc']-vn['acc'],2)}pp)")
print(f"  ECE:   {vn['ece']} -> {mv['ece']}  (delta {round(mv['ece']-vn['ece'],2)}; cerca de 0 mejor)")
