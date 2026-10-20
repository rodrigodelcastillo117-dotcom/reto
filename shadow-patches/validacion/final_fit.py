#!/usr/bin/env python3
"""Ajuste final de produccion sobre TODO el historico (el metodo ya se validó OOS).
Emite coeficientes, estandarizacion (mu/sd) y lineas por (tour,bo) para embeber en SQL."""
import json
from collections import deque, defaultdict
import numpy as np, pandas as pd

SC="/tmp/claude-0/-home-user-reto/46d9abc4-c29c-5c7a-91cd-791a32040095/scratchpad"
MIN_HIST=5; ROLL=20; K_ELO=32.0
rows=[json.loads(l) for l in open(f"{SC}/matches.jsonl")]
df=pd.DataFrame(rows)
df["fecha"]=pd.to_datetime(df["fecha"],utc=True,format="ISO8601")
df=df.dropna(subset=["winner_id","loser_id","total_games","n_sets"])
df=df[df["n_sets"]>=1].sort_values(["fecha","espn_match_id"]).reset_index(drop=True)

elo=defaultdict(lambda:1500.0); ng=defaultdict(int)
gpsh=defaultdict(lambda:deque(maxlen=ROLL)); toth=defaultdict(lambda:deque(maxlen=ROLL))
feat=[]
for r in df.itertuples(index=False):
    w,l=r.winner_id,r.loser_id; ew,el=elo[w],elo[l]
    gw=np.mean(gpsh[w]) if gpsh[w] else np.nan; gl=np.mean(gpsh[l]) if gpsh[l] else np.nan
    tw=np.mean(toth[w]) if toth[w] else np.nan; tl=np.mean(toth[l]) if toth[l] else np.nan
    pf=1.0/(1.0+10**(-abs(ew-el)/400.0))
    feat.append((ng[w],ng[l],pf,gw,gl,tw,tl))
    exp_w=1.0/(1.0+10**(-(ew-el)/400.0)); elo[w]=ew+K_ELO*(1-exp_w); elo[l]=el-K_ELO*(1-exp_w)
    ng[w]+=1; ng[l]+=1; gps=r.total_games/r.n_sets
    gpsh[w].append(gps); gpsh[l].append(gps); toth[w].append(r.total_games); toth[l].append(r.total_games)
F=pd.DataFrame(feat,columns=["nw","nl","p_fav","gps_w","gps_l","tot_w","tot_l"])
df=pd.concat([df.reset_index(drop=True),F],axis=1)
df["gps_sum"]=df.gps_w+df.gps_l; df["gps_min"]=df[["gps_w","gps_l"]].min(axis=1)
df["gps_max"]=df[["gps_w","gps_l"]].max(axis=1); df["tot_sum"]=df.tot_w+df.tot_l
df=df[(df.nw>=MIN_HIST)&(df.nl>=MIN_HIST)].dropna(subset=["gps_sum","tot_sum","p_fav"]).reset_index(drop=True)

def sig(z): return 1.0/(1.0+np.exp(-z))
def fit(X,y,l2=2.0,iters=400):
    n,d=X.shape; Xb=np.hstack([np.ones((n,1)),X]); w=np.zeros(d+1); R=np.eye(d+1)*l2; R[0,0]=0
    for _ in range(iters):
        p=sig(Xb@w); Wd=np.clip(p*(1-p),1e-6,None); g=Xb.T@(p-y)+R@w; H=(Xb*Wd[:,None]).T@Xb+R
        try: s=np.linalg.solve(H,g)
        except: break
        w-=s
        if np.max(np.abs(s))<1e-7: break
    return w

FEATURES=["bo","p_fav","gps_sum","gps_min","gps_max","tot_sum"]
out={}
for tour in ["atp","wta"]:
    sub=df[df.tour==tour].copy()
    lines=sub.groupby("bo")["total_games"].median().to_dict()
    sub["linea"]=sub["bo"].map(lines); sub=sub[sub.total_games!=sub.linea]
    sub["y"]=(sub.total_games>sub.linea).astype(int)
    mu=sub[FEATURES].mean(); sd=sub[FEATURES].std().replace(0,1)
    w=fit(((sub[FEATURES]-mu)/sd).values, sub.y.values.astype(float))
    out[tour]={"features":FEATURES,"lines":{int(k):float(v) for k,v in lines.items()},
               "mu":mu.round(6).to_dict(),"sd":sd.round(6).to_dict(),
               "coef_intercept":float(round(w[0],6)),
               "coef":{f:float(round(c,6)) for f,c in zip(FEATURES,w[1:])},
               "n_fit":int(len(sub))}
json.dump(out, open(f"{SC}/model_coef.json","w"), indent=1)
print(json.dumps(out,indent=1))
