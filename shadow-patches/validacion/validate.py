#!/usr/bin/env python3
"""Validacion OOS walk-forward de juegos totales O/U en tenis.
 - Elo secuencial causal (K=32) sobre los partidos con linescore.
 - Features de ritmo (games-per-set) rodantes por jugador.
 - Linea = mediana del periodo de entrenamiento por (tour, bo).
 - Modelo: regresion logistica P(total > linea) ajustada solo en train.
 - Holdout temporal; metricas por tramo de confianza + calibracion + Brier + baseline.
"""
import json, math
from collections import deque, defaultdict
import numpy as np
import pandas as pd

SC = "/tmp/claude-0/-home-user-reto/46d9abc4-c29c-5c7a-91cd-791a32040095/scratchpad"
CUTOFF = pd.Timestamp("2025-07-01", tz="UTC")
MIN_HIST = 5          # partidos previos minimos por jugador
ROLL = 20            # ventana rodante
K_ELO = 32.0

rows = [json.loads(l) for l in open(f"{SC}/matches.jsonl")]
df = pd.DataFrame(rows)
df["fecha"] = pd.to_datetime(df["fecha"], utc=True, format="ISO8601")
df = df.dropna(subset=["winner_id","loser_id","total_games","n_sets"])
df = df[df["n_sets"] >= 1]
df = df.sort_values(["fecha","espn_match_id"]).reset_index(drop=True)

# ---- Elo secuencial causal + ritmo rodante por jugador ----
elo = defaultdict(lambda: 1500.0)
ngames = defaultdict(int)
gps_hist = defaultdict(lambda: deque(maxlen=ROLL))   # games-per-set recientes
tot_hist = defaultdict(lambda: deque(maxlen=ROLL))   # total de juegos recientes

feat = []
for r in df.itertuples(index=False):
    w, l = r.winner_id, r.loser_id
    ew, el = elo[w], elo[l]
    nw, nl = ngames[w], ngames[l]
    gps_w = np.mean(gps_hist[w]) if gps_hist[w] else np.nan
    gps_l = np.mean(gps_hist[l]) if gps_hist[l] else np.nan
    tot_w = np.mean(tot_hist[w]) if tot_hist[w] else np.nan
    tot_l = np.mean(tot_hist[l]) if tot_hist[l] else np.nan
    p_fav = 1.0/(1.0+10**(-abs(ew-el)/400.0))  # closeness: 0.5=parejo, ->1 desparejo
    feat.append((nw, nl, p_fav, gps_w, gps_l, tot_w, tot_l))
    # update tras el partido
    exp_w = 1.0/(1.0+10**(-(ew-el)/400.0))
    elo[w] = ew + K_ELO*(1-exp_w)
    elo[l] = el - K_ELO*(1-exp_w)
    ngames[w]+=1; ngames[l]+=1
    g_per_set = r.total_games / r.n_sets
    gps_hist[w].append(g_per_set); gps_hist[l].append(g_per_set)
    tot_hist[w].append(r.total_games); tot_hist[l].append(r.total_games)

F = pd.DataFrame(feat, columns=["nw","nl","p_fav","gps_w","gps_l","tot_w","tot_l"])
df = pd.concat([df.reset_index(drop=True), F], axis=1)

# features simetricas
df["gps_sum"] = df["gps_w"] + df["gps_l"]
df["gps_min"] = df[["gps_w","gps_l"]].min(axis=1)
df["gps_max"] = df[["gps_w","gps_l"]].max(axis=1)
df["tot_sum"] = df["tot_w"] + df["tot_l"]

# filtro de cold-start
df = df[(df["nw"]>=MIN_HIST)&(df["nl"]>=MIN_HIST)].dropna(
    subset=["gps_sum","tot_sum","p_fav"]).reset_index(drop=True)

def sigmoid(z): return 1.0/(1.0+np.exp(-z))

def fit_logreg(X, y, l2=1.0, iters=300):
    # IRLS/Newton con regularizacion L2 (no penaliza intercepto)
    n,d = X.shape
    Xb = np.hstack([np.ones((n,1)), X])
    w = np.zeros(d+1)
    R = np.eye(d+1)*l2; R[0,0]=0.0
    for _ in range(iters):
        p = sigmoid(Xb@w)
        Wd = p*(1-p); Wd = np.clip(Wd,1e-6,None)
        grad = Xb.T@(p-y) + R@w
        H = (Xb*Wd[:,None]).T@Xb + R
        try:
            step = np.linalg.solve(H, grad)
        except np.linalg.LinAlgError:
            break
        w -= step
        if np.max(np.abs(step))<1e-7: break
    return w

def predict(w, X):
    Xb = np.hstack([np.ones((X.shape[0],1)), X])
    return sigmoid(Xb@w)

FEATURES = ["bo","p_fav","gps_sum","gps_min","gps_max","tot_sum"]

def run(sub, tour):
    tr = sub[sub["fecha"]<CUTOFF].copy()
    te = sub[sub["fecha"]>=CUTOFF].copy()
    out = {"tour":tour,"n_train":len(tr),"n_test":len(te)}
    if len(tr)<300 or len(te)<100:
        out["error"]="muestra insuficiente"; return out, None
    # linea = mediana del train por bo
    lines = tr.groupby("bo")["total_games"].median().to_dict()
    for d in (tr,te):
        d["linea"] = d["bo"].map(lines)
        d["push"] = d["total_games"]==d["linea"]
        d["y"] = (d["total_games"]>d["linea"]).astype(int)
    tr2 = tr[~tr["push"]]; te2 = te[~te["push"]]
    # estandarizar con stats del train
    mu = tr2[FEATURES].mean(); sd = tr2[FEATURES].std().replace(0,1)
    Xtr = ((tr2[FEATURES]-mu)/sd).values
    Xte = ((te2[FEATURES]-mu)/sd).values
    w = fit_logreg(Xtr, tr2["y"].values.astype(float), l2=2.0)
    p = predict(w, Xte)
    y = te2["y"].values
    # prob del pick (lado elegido) y acierto
    pick_over = p>=0.5
    conf = np.where(pick_over, p, 1-p)
    hit = (pick_over==(y==1)).astype(int)
    out["lines"]=lines
    out["base_over_rate_test"]=round(float(y.mean()),3)
    out["acc_all"]=round(float(hit.mean()),3)
    out["brier"]=round(float(np.mean((p-y)**2)),4)
    out["coef"]=dict(zip(["intercept"]+FEATURES, np.round(w,3).tolist()))
    # por tramo de confianza
    tiers=[("≥55",0.55),("≥60",0.60),("≥65",0.65),("≥70",0.70)]
    out["tiers"]={}
    for name,thr in tiers:
        msk=conf>=thr
        out["tiers"][name]={"n":int(msk.sum()),
            "acc":round(float(hit[msk].mean()),3) if msk.sum()>0 else None,
            "frac":round(float(msk.mean()),3)}
    # calibracion (bins de prob del pick)
    cal=[]
    for lo,hi in [(0.5,0.55),(0.55,0.60),(0.60,0.65),(0.65,0.70),(0.70,1.01)]:
        m=(conf>=lo)&(conf<hi)
        if m.sum()>0:
            cal.append({"bin":f"{lo:.2f}-{hi:.2f}","n":int(m.sum()),
                        "pred":round(float(conf[m].mean()),3),
                        "real":round(float(hit[m].mean()),3)})
    out["calibracion"]=cal
    return out, (te2.assign(p=p,hit=hit,conf=conf))

results={}
for tour in ["atp","wta"]:
    res,_=run(df[df["tour"]==tour].copy(), tour)
    results[tour]=res

print(json.dumps(results, indent=1, default=str))
