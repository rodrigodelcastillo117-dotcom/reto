#!/usr/bin/env python3
"""
BLOQUE 1 — Modelo de fuerza entre ligas (cross-league) para Champions/Europa/etc.
STAGED · sin deploy · sólo validación offline con datos históricos reales.

Diseño (identificable + temporalmente seguro):
  - Fuerza de EQUIPO: tasas de gol domésticas (gf/ga por juego) en ventana móvil
    de 540 días ESTRICTAMENTE anteriores a cada partido continental (data_asof < kickoff).
  - Fuerza de LIGA φ_L: efecto fijo por liga, identificado SÓLO por los partidos
    cruzados (donde equipos de ligas distintas se enfrentan). Liga de referencia φ=0.
  - Ventaja de local γ: explícita.
  - Poisson bivariado independiente + corrección Dixon-Coles ρ para marcadores bajos.
  - Regularización ridge sobre φ (ligas con poca muestra cruzada se encogen a 0).

Validación:
  - Split TEMPORAL (nunca aleatorio). Train estrictamente antes que test.
  - Baseline A: mismo motor con φ≡0 (domestic naive, ignora calidad de liga).
  - Baseline B: prior de tasas base (home/draw/away marginal del train).
  - Métricas: multiclass Brier, log-loss, accuracy (secundaria), calibración por
    buckets, bootstrap CI, cobertura, estabilidad por temporada.
  - No se usan odds/mercado en ningún punto para fabricar P.
"""
import json, math, re, sys
import numpy as np
from scipy.optimize import minimize
from scipy.stats import poisson

RAW = "/root/.claude/projects/-home-user-reto/e3903dd5-0a68-5705-b176-b8fac308ee81/tool-results/mcp-Supabase-execute_sql-1788975218372.txt"
CROSS_LEAGUE_LIGAS = {2,3,848,13,11,15,16,17,20}
NO_PICK_LIGAS = {11}  # Sudamericana: puede entrenar, jamás pick (veto usuario)

def load():
    s = open(RAW).read()
    outer = json.loads(s)["result"]
    m = re.search(r'(\[\{.*\}\])', outer, re.S)
    arr = json.loads(m.group(1))
    csv = arr[0]["csv"]
    rows = []
    for ln in csv.strip().split("\n"):
        p = ln.split("|")
        if len(p) != 15: continue
        rows.append(dict(
            event_id=p[0], liga=int(p[1]), fecha=p[2][:10],
            hs=int(p[3]), as_=int(p[4]), home_id=p[5], away_id=p[6],
            h_n=int(p[7]), h_gf=float(p[8]), h_ga=float(p[9]), h_liga=int(p[10]),
            a_n=int(p[11]), a_gf=float(p[12]), a_ga=float(p[13]), a_liga=int(p[14]),
        ))
    return rows

def _addmonths(datestr, months):
    y,m,d=[int(x) for x in datestr.split("-")]
    m2=m+months; y+=(m2-1)//12; m2=(m2-1)%12+1
    return f"{y:04d}-{m2:02d}-{d:02d}"

def dc_tau(i, j, lh, la, rho):
    # Dixon-Coles low-score correction
    if i==0 and j==0: return 1 - lh*la*rho
    if i==0 and j==1: return 1 + lh*rho
    if i==1 and j==0: return 1 + la*rho
    if i==1 and j==1: return 1 - rho
    return 1.0

def score_matrix(lh, la, rho, kmax=10):
    ph = poisson.pmf(np.arange(kmax+1), lh)
    pa = poisson.pmf(np.arange(kmax+1), la)
    M = np.outer(ph, pa)
    for i in range(2):
        for j in range(2):
            M[i,j] *= dc_tau(i,j,lh,la,rho)
    M /= M.sum()
    return M

def outcome_probs(M):
    ph = np.tril(M,-1).sum()  # home>away
    pd = np.trace(M)
    pa = np.triu(M,1).sum()
    s = ph+pd+pa
    return np.array([ph/s, pd/s, pa/s])

def build_league_index(rows):
    ligs = sorted({r["h_liga"] for r in rows} | {r["a_liga"] for r in rows})
    # referencia = liga con más apariciones (más estable)
    from collections import Counter
    cnt = Counter()
    for r in rows: cnt[r["h_liga"]]+=1; cnt[r["a_liga"]]+=1
    ref = cnt.most_common(1)[0][0]
    idx = {L:i for i,L in enumerate(L for L in ligs if L!=ref)}
    return idx, ref

def make_features(rows):
    X=[]
    for r in rows:
        X.append((math.log(max(r["h_gf"],0.05)), math.log(max(r["h_ga"],0.05)),
                  math.log(max(r["a_gf"],0.05)), math.log(max(r["a_ga"],0.05)),
                  r["h_liga"], r["a_liga"], r["hs"], r["as_"]))
    return X

def nll_factory(rows, lidx, use_phi=True, ridge=5.0):
    X = make_features(rows)
    nL = len(lidx)
    def phi_of(L, phi):
        return 0.0 if (L not in lidx) else phi[lidx[L]]
    def nll(theta):
        a0, batt, bdef, gamma, rho = theta[:5]
        phi = theta[5:] if use_phi else np.zeros(nL)
        tot = 0.0
        for (lhgf, lhga, lagf, laga, hL, aL, hs, as_) in X:
            pdiff = (phi_of(hL,phi)-phi_of(aL,phi)) if use_phi else 0.0
            log_lh = a0 + batt*lhgf + bdef*laga + gamma + pdiff
            log_la = a0 + batt*lagf + bdef*lhga - pdiff
            lh, la = math.exp(min(log_lh,2.5)), math.exp(min(log_la,2.5))
            # Poisson NLL for both goal counts
            tot += lh - hs*math.log(lh) + la - as_*math.log(la)
            # DC correction contributes to likelihood of exact low scores
            tau = dc_tau(hs, as_, lh, la, rho)
            if tau>0: tot -= math.log(tau)
            else: tot += 10.0
        if use_phi: tot += ridge*np.sum(phi**2)
        return tot
    return nll, nL

def fit(rows, lidx, use_phi=True, ridge=5.0):
    nll, nL = nll_factory(rows, lidx, use_phi, ridge)
    x0 = np.array([0.0, 0.5, 0.5, 0.25, 0.0] + [0.0]*(nL if use_phi else 0))
    res = minimize(nll, x0, method="L-BFGS-B", options=dict(maxiter=500))
    return res.x

def predict(theta, r, lidx, use_phi=True):
    a0, batt, bdef, gamma, rho = theta[:5]
    phi = theta[5:]
    def phi_of(L):
        return 0.0 if (L not in lidx) else phi[lidx[L]]
    lhgf, lhga = math.log(max(r["h_gf"],0.05)), math.log(max(r["h_ga"],0.05))
    lagf, laga = math.log(max(r["a_gf"],0.05)), math.log(max(r["a_ga"],0.05))
    pdiff = (phi_of(r["h_liga"])-phi_of(r["a_liga"])) if use_phi else 0.0
    lh = math.exp(min(a0+batt*lhgf+bdef*laga+gamma+pdiff, 2.5))
    la = math.exp(min(a0+batt*lagf+bdef*lhga-pdiff, 2.5))
    M = score_matrix(lh, la, rho)
    return outcome_probs(M), lh, la, M

def y_of(r):
    return 0 if r["hs"]>r["as_"] else (1 if r["hs"]==r["as_"] else 2)

def metrics(probs, ys):
    probs=np.array(probs); ys=np.array(ys)
    onehot=np.eye(3)[ys]
    brier=float(np.mean(np.sum((probs-onehot)**2,axis=1)))
    eps=1e-15
    ll=float(-np.mean(np.log(np.clip(probs[np.arange(len(ys)),ys],eps,1))))
    acc=float(np.mean(np.argmax(probs,axis=1)==ys))
    return dict(brier=brier, logloss=ll, acc=acc, n=len(ys))

def calibration_buckets(probs, ys, nb=5):
    probs=np.array(probs); ys=np.array(ys)
    conf=probs.max(axis=1); pred=probs.argmax(axis=1); correct=(pred==ys).astype(float)
    out=[]
    for b in range(nb):
        lo,hi=b/nb,(b+1)/nb
        m=(conf>=lo)&(conf<(hi if b<nb-1 else 1.0001))
        if m.sum()>0:
            out.append(dict(bucket=f"{lo:.1f}-{hi:.1f}", n=int(m.sum()),
                            conf=round(float(conf[m].mean()),3), acc=round(float(correct[m].mean()),3)))
    return out

def base_rate_probs(train, n):
    ys=[y_of(r) for r in train]
    p=np.bincount(ys,minlength=3)/len(ys)
    return [p.tolist() for _ in range(n)]

def main():
    rows=load()
    rows.sort(key=lambda r:r["fecha"])
    print(f"[data] usable rows (n>=5 both): {len(rows)}  rango {rows[0]['fecha']}..{rows[-1]['fecha']}")
    # split temporal
    CUT="2025-02-01"
    train=[r for r in rows if r["fecha"]<CUT]
    test=[r for r in rows if r["fecha"]>=CUT]
    print(f"[split] train {len(train)} (<{CUT})  test {len(test)} (>= {CUT})")
    lidx,ref=build_league_index(train)
    print(f"[leagues] {len(lidx)+1} ligas en train, referencia liga_id={ref}")

    th_full=fit(train,lidx,use_phi=True,ridge=5.0)
    th_nophi=fit(train,lidx,use_phi=False,ridge=0.0)
    a0,batt,bdef,gamma,rho=th_full[:5]
    print(f"[fit] a0={a0:.3f} batt={batt:.3f} bdef={bdef:.3f} home_adv={gamma:.3f} rho={rho:.3f}")

    # test-set predictions
    P_full=[predict(th_full,r,lidx,True)[0] for r in test]
    P_nophi=[predict(th_nophi,r,lidx,False)[0] for r in test]
    P_base=base_rate_probs(train,len(test))
    ys=[y_of(r) for r in test]

    m_full=metrics(P_full,ys); m_nophi=metrics(P_nophi,ys); m_base=metrics(P_base,ys)
    print("\n=== OUT-OF-SAMPLE (test temporal) ===")
    for name,m in [("CROSS-LEAGUE (φ)",m_full),("DOMESTIC naive (φ=0)",m_nophi),("BASE-RATE prior",m_base)]:
        print(f"  {name:24s} n={m['n']:4d}  Brier={m['brier']:.4f}  LogLoss={m['logloss']:.4f}  Acc={m['acc']:.3f}")

    # bootstrap CI on Brier difference (full vs nophi)
    rng=np.random.default_rng(42)
    Pf=np.array(P_full); Pn=np.array(P_nophi); yy=np.array(ys); oh=np.eye(3)[yy]
    bf=np.sum((Pf-oh)**2,axis=1); bn=np.sum((Pn-oh)**2,axis=1)
    diffs=[]
    for _ in range(2000):
        idx=rng.integers(0,len(yy),len(yy))
        diffs.append(bn[idx].mean()-bf[idx].mean())  # >0 => full better
    lo,hi=np.percentile(diffs,[2.5,97.5])
    print(f"\n[bootstrap] Brier(domestic)-Brier(crossleague): mean={np.mean(diffs):+.4f} 95%CI=[{lo:+.4f},{hi:+.4f}]  (>0 favorece cross-league)")

    print("\n[calibration cross-league]")
    for b in calibration_buckets(P_full,ys): print("  ",b)

    # estabilidad por temporada (test partido por año-temporada de kickoff)
    print("\n[estabilidad por temporada de test]")
    import collections
    by=collections.defaultdict(list)
    for r,pf in zip(test,P_full): by[r["fecha"][:4]].append((pf,y_of(r)))
    for yr in sorted(by):
        ps=[x[0] for x in by[yr]]; yv=[x[1] for x in by[yr]]
        mm=metrics(ps,yv); print(f"  {yr}: n={mm['n']:3d} Brier={mm['brier']:.4f} LogLoss={mm['logloss']:.4f}")

    # cobertura por liga: nº de partidos CRUZADOS que identifican cada φ (piso de muestra)
    import collections as _c
    cov=_c.Counter()
    for r in rows:
        if r["h_liga"]!=r["a_liga"]:
            cov[r["h_liga"]]+=1; cov[r["a_liga"]]+=1
    print("\n[cobertura φ por liga] (partidos cruzados que la identifican; piso serving=20)")
    for L,n in cov.most_common():
        flag="SERVIBLE" if n>=20 else "FAIL-CLOSE(muestra)"
        print(f"  liga_id={L:4d}  n_cruzados={n:3d}  {flag}")

    # league strengths (top/bottom)
    phi=th_full[5:]
    inv={v:k for k,v in lidx.items()}
    order=np.argsort(phi)[::-1]
    print("\n[φ liga_strength] (ref=%d φ=0). Top5 y Bottom5:"%ref)
    for i in list(order[:5])+list(order[-5:]):
        print(f"  liga_id={inv[i]:4d}  φ={phi[i]:+.3f}")

    # ---- WALK-FORWARD multi-fold (robustez, no un solo split) ----
    print("\n=== WALK-FORWARD (folds temporales) ===")
    cuts=["2024-08-01","2025-02-01","2025-08-01"]
    wf=[]
    for cut in cuts:
        tr=[r for r in rows if r["fecha"]<cut]
        te=[r for r in rows if r["fecha"]>=cut and r["fecha"]<_addmonths(cut,6)]
        if len(tr)<120 or len(te)<40:
            print(f"  fold {cut}: muestra insuficiente (tr={len(tr)} te={len(te)}) -> skip"); continue
        li,_=build_league_index(tr)
        tf=fit(tr,li,True,5.0); tn=fit(tr,li,False,0.0)
        yv=[y_of(r) for r in te]
        mf=metrics([predict(tf,r,li,True)[0] for r in te],yv)
        mn=metrics([predict(tn,r,li,False)[0] for r in te],yv)
        wf.append(dict(cut=cut,n_test=len(te),brier_cross=mf["brier"],brier_dom=mn["brier"],
                       logloss_cross=mf["logloss"],logloss_dom=mn["logloss"]))
        print(f"  fold>={cut} n={len(te):3d}: Brier cross={mf['brier']:.4f} dom={mn['brier']:.4f} "
              f"(Δ={mn['brier']-mf['brier']:+.4f}) | LogLoss cross={mf['logloss']:.4f} dom={mn['logloss']:.4f}")
    if wf:
        gain=np.mean([w["brier_dom"]-w["brier_cross"] for w in wf])
        print(f"  >> Brier gain medio walk-forward: {gain:+.4f} ({'cross-league mejor' if gain>0 else 'sin ganancia'})")

    # ---- ridge sweep (seleccionado en validación interna del train, NO en test) ----
    print("\n=== RIDGE sweep (validación interna, sin tocar test) ===")
    vcut="2024-10-01"
    itr=[r for r in train if r["fecha"]<vcut]; ival=[r for r in train if r["fecha"]>=vcut]
    best=(None,1e9)
    if len(itr)>=100 and len(ival)>=40:
        li,_=build_league_index(itr); yv=[y_of(r) for r in ival]
        for rg in [0.5,1,2,5,10,20]:
            tt=fit(itr,li,True,rg)
            mm=metrics([predict(tt,r,li,True)[0] for r in ival],yv)
            print(f"  ridge={rg:4.1f}: val Brier={mm['brier']:.4f} LogLoss={mm['logloss']:.4f}")
            if mm["logloss"]<best[1]: best=(rg,mm["logloss"])
        print(f"  >> ridge óptimo (val logloss) = {best[0]}")

    out=dict(n_usable=len(rows), cut=CUT, n_train=len(train), n_test=len(test),
             walk_forward=wf, ridge_best=best[0],
             ref_league=ref, params=dict(a0=a0,batt=batt,bdef=bdef,home_adv=gamma,rho=rho),
             metrics=dict(crossleague=m_full,domestic_naive=m_nophi,base_rate=m_base),
             brier_gain_ci=[float(lo),float(hi)],brier_gain_mean=float(np.mean(diffs)),
             phi={int(inv[i]):float(phi[i]) for i in range(len(phi))})
    json.dump(out,open("crossleague_result.json","w"),indent=2)
    print("\n[saved] crossleague_result.json")

if __name__=="__main__":
    main()
