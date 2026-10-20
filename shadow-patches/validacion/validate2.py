#!/usr/bin/env python3
"""Pruebas de robustez: walk-forward multi-fold, estabilidad temporal,
desglose por bo, tasa de push y baseline sin features de ritmo."""
import json
from collections import deque, defaultdict
import numpy as np, pandas as pd

SC = "/tmp/claude-0/-home-user-reto/46d9abc4-c29c-5c7a-91cd-791a32040095/scratchpad"
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
def fit(X,y,l2=2.0,iters=300):
    n,d=X.shape; Xb=np.hstack([np.ones((n,1)),X]); w=np.zeros(d+1)
    R=np.eye(d+1)*l2; R[0,0]=0
    for _ in range(iters):
        p=sig(Xb@w); Wd=np.clip(p*(1-p),1e-6,None)
        g=Xb.T@(p-y)+R@w; H=(Xb*Wd[:,None]).T@Xb+R
        try: s=np.linalg.solve(H,g)
        except: break
        w-=s
        if np.max(np.abs(s))<1e-7: break
    return w
def pred(w,X): return sig(np.hstack([np.ones((X.shape[0],1)),X])@w)

def evaluate(tr,te,FEATURES):
    lines=tr.groupby("bo")["total_games"].median().to_dict()
    for d in (tr,te):
        d["linea"]=d["bo"].map(lines); d["push"]=d.total_games==d.linea
        d["y"]=(d.total_games>d.linea).astype(int)
    tr2=tr[~tr.push]; te2=te[~te.push]
    mu=tr2[FEATURES].mean(); sd=tr2[FEATURES].std().replace(0,1)
    w=fit(((tr2[FEATURES]-mu)/sd).values, tr2.y.values.astype(float))
    p=pred(w, ((te2[FEATURES]-mu)/sd).values); y=te2.y.values
    po=p>=0.5; conf=np.where(po,p,1-p); hit=(po==(y==1)).astype(int)
    return te2.assign(p=p,conf=conf,hit=hit), lines, len(te[te.push])/max(len(te),1)

FEATURES=["bo","p_fav","gps_sum","gps_min","gps_max","tot_sum"]
FEAT_BASE=["bo","p_fav"]  # baseline sin ritmo

print("="*70)
print("A) WALK-FORWARD POR TRIMESTRE (train=todo lo anterior, test=trimestre)")
print("="*70)
for tour in ["atp","wta"]:
    sub=df[df.tour==tour].copy()
    print(f"\n--- {tour.upper()} ---")
    folds=pd.date_range("2024-07-01","2026-10-01",freq="3MS",tz="UTC")
    agg=defaultdict(lambda:[0,0])  # tier -> [hits,n]
    for i in range(len(folds)-1):
        t0,t1=folds[i],folds[i+1]
        tr=sub[sub.fecha<t0].copy(); te=sub[(sub.fecha>=t0)&(sub.fecha<t1)].copy()
        if len(tr)<1000 or len(te)<80: continue
        res,lines,pushr=evaluate(tr,te,FEATURES)
        for thr,name in [(0.60,"≥60"),(0.55,"≥55")]:
            m=res.conf>=thr; agg[name][0]+=int(res.hit[m].sum()); agg[name][1]+=int(m.sum())
        m60=res.conf>=0.60
        a60=res.hit[m60].mean() if m60.sum()>0 else float("nan")
        print(f"  {str(t0.date())}→{str(t1.date())}: test={len(te):5d} push={pushr:.2f} "
              f"≥60 n={int(m60.sum()):3d} acc={a60:.3f} all_acc={res.hit.mean():.3f}")
    for name in ["≥55","≥60"]:
        h,n=agg[name]
        print(f"  TOTAL {name}: n={n} acc={h/n:.3f}" if n else f"  TOTAL {name}: sin picks")

print("\n"+"="*70)
print("B) HOLDOUT 2025-07-01: desglose por bo + baseline sin ritmo")
print("="*70)
CUT=pd.Timestamp("2025-07-01",tz="UTC")
for tour in ["atp","wta"]:
    sub=df[df.tour==tour].copy()
    tr=sub[sub.fecha<CUT].copy(); te=sub[sub.fecha>=CUT].copy()
    res,lines,pushr=evaluate(tr,te,FEATURES)
    resb,_,_=evaluate(sub[sub.fecha<CUT].copy(),sub[sub.fecha>=CUT].copy(),FEAT_BASE)
    print(f"\n--- {tour.upper()} (push rate test={pushr:.3f}, lines={lines}) ---")
    for thr,name in [(0.55,"≥55"),(0.60,"≥60")]:
        m=res.conf>=thr; mb=resb.conf>=thr
        print(f"  modelo {name}: n={int(m.sum()):4d} acc={res.hit[m].mean():.3f} | "
              f"baseline(bo,p_fav) {name}: n={int(mb.sum()):4d} acc={resb.hit[mb].mean() if mb.sum()>0 else float('nan'):.3f}")
    for bo in sorted(te.bo.unique()):
        m=(res.conf>=0.60)&(res.bo==bo)
        if m.sum()>0:
            print(f"  ≥60 solo bo{bo}: n={int(m.sum()):4d} acc={res.hit[m].mean():.3f}")
