#!/usr/bin/env python3
"""¿Aporta la fatiga/descanso skill OOS sobre el Elo (global+superficie) ya publicado?
Compara logística [elo] vs [elo + fatiga] fuera de muestra. Publicar solo si gana."""
import json, math
from collections import defaultdict, deque
import numpy as np, pandas as pd

SC="/tmp/claude-0/-home-user-reto/46d9abc4-c29c-5c7a-91cd-791a32040095/scratchpad"
CUT=pd.Timestamp("2025-07-01", tz="UTC"); K=32.0; WS=0.2  # peso superficie (como prod)
exec(open(f"{SC}/surface_elo.py").read().split("rows=")[0])  # trae GRASS/CLAY/surface()

rows=[json.loads(l) for l in open(f"{SC}/matches.jsonl")]
df=pd.DataFrame(rows)
df["fecha"]=pd.to_datetime(df["fecha"],utc=True,format="ISO8601")
df=df.dropna(subset=["winner_id","loser_id"]).sort_values(["fecha","espn_match_id"]).reset_index(drop=True)
df["surf"]=[surface(t,to) for t,to in zip(df["torneo"],df["tour"])]

g=defaultdict(lambda:1500.0); s=defaultdict(lambda:1500.0); ng=defaultdict(int)
last=defaultdict(lambda:None); hist=defaultdict(lambda:deque())  # fechas recientes por jugador
feat=[]
for r in df.itertuples(index=False):
    w,l=r.winner_id,r.loser_id; su=r.surf; d=r.fecha
    rw=(1-WS)*g[w]+WS*s[(w,su)]; rl=(1-WS)*g[l]+WS*s[(l,su)]
    fav_w = rw>=rl
    elo_diff = (rw-rl) if fav_w else (rl-rw)        # a favor del favorito (>=0)
    def load(pid, days):
        cut=d - pd.Timedelta(days=days)
        return sum(1 for x in hist[pid] if x>=cut)
    def rest(pid):
        return (d-last[pid]).days if last[pid] is not None else 60  # debutante: 60d
    fav,dog = (w,l) if fav_w else (l,w)
    rec=dict(tour=r.tour, fecha=d, nmin=min(ng[w],ng[l]), fav_won=1 if fav_w else 0,
             elo_diff=elo_diff,
             rest_diff=rest(fav)-rest(dog),
             load7_diff=load(fav,7)-load(dog,7),
             load14_diff=load(fav,14)-load(dog,14))
    feat.append(rec)
    # update
    eg=1.0/(1.0+10**((g[l]-g[w])/400.0)); es=1.0/(1.0+10**((s[(l,su)]-s[(w,su)])/400.0))
    g[w]+=K*(1-eg); g[l]-=K*(1-eg); s[(w,su)]+=K*(1-es); s[(l,su)]-=K*(1-es)
    ng[w]+=1; ng[l]+=1
    for pid in (w,l):
        last[pid]=d; hist[pid].append(d)
        while hist[pid] and hist[pid][0] < d - pd.Timedelta(days=21): hist[pid].popleft()

E=pd.DataFrame(feat)
E=E[E.nmin>=10]
tr=E[E.fecha<CUT].copy(); te=E[E.fecha>=CUT].copy()

def sig(z): return 1.0/(1.0+np.exp(-z))
def fit(X,y,l2=1.0,it=300):
    Xb=np.hstack([np.ones((len(X),1)),X]); w=np.zeros(Xb.shape[1]); R=np.eye(Xb.shape[1])*l2; R[0,0]=0
    for _ in range(it):
        p=sig(Xb@w); W=np.clip(p*(1-p),1e-6,None); grad=Xb.T@(p-y)+R@w; H=(Xb*W[:,None]).T@Xb+R
        try: st=np.linalg.solve(H,grad)
        except: break
        w-=st
        if np.max(np.abs(st))<1e-7: break
    return w
def pred(w,X): return sig(np.hstack([np.ones((len(X),1)),X])@w)
def ev(p,y):
    return dict(n=len(y), acc=round(100*np.mean((p>=0.5)==(y==1)),2),
                brier=round(float(np.mean((p-y)**2)),4))

y_tr=tr.fav_won.values.astype(float); y_te=te.fav_won.values.astype(float)
feats_base=["elo_diff"]; feats_fat=["elo_diff","rest_diff","load7_diff","load14_diff"]
mu=tr[feats_fat].mean(); sd=tr[feats_fat].std().replace(0,1)
def Z(d,cols): return ((d[cols]-mu[cols])/sd[cols]).values

wb=fit(Z(tr,feats_base), y_tr); wf=fit(Z(tr,feats_fat), y_fat:=y_tr)
pb=pred(wb, Z(te,feats_base)); pf=pred(wf, Z(te,feats_fat))
print("coef fatiga (estand.):", dict(zip(["int"]+feats_fat, np.round(wf,3))))
print("BASE  [elo]        test:", ev(pb,y_te))
print("FATIGA[elo+fatiga] test:", ev(pf,y_te))
b=ev(pb,y_te); f=ev(pf,y_te)
print(f"\nDELTA: Brier {b['brier']}->{f['brier']} ({round(f['brier']-b['brier'],4)}; neg=mejor) | "
      f"Acc {b['acc']}->{f['acc']} ({round(f['acc']-b['acc'],2)}pp)")
