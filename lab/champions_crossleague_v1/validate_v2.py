#!/usr/bin/env python3
"""
BLOQUE 1 — VALIDACIÓN ENDURECIDA (gates del usuario). STAGED.
Estado objetivo: CROSS_LEAGUE_V1 = APPROVABLE_STAGED / FINAL_VALIDATION_PENDING.

Gates:
 (L) Leakage: sólo partidos FINAL con fecha < decision_time; excluye target y
     cualquier fila posterior. Asserts en código.
 (B) Baseline fuerte: MISMO Dixon-Coles, MISMAS features, MISMA regularización,
     SIN φ. Única diferencia = término de liga.
 (WF) Walk-forward por fold: n_train,n_val,n_test,Brier,LogLoss,ΔBrier,ΔLogLoss,CI.
 (C) Por competencia en test: n,Brier,LogLoss,calibración,Δ vs baseline.
 (ID) Identificabilidad φ: liga ref fija a 0; φ por fold.
 (FL) Sensibilidad sample floor 5/8/10/15, elegido por VALIDACIÓN (no test).
Sin resultados live como evidencia. Sólo OOS histórico.
"""
import json, math, numpy as np, collections
from fit_crossleague import (load, build_league_index, fit, predict, metrics,
                             calibration_buckets, base_rate_probs, y_of, make_features)

COMP={2:'UCL',3:'UEL',848:'Conference',13:'Libertadores',11:'Sudamericana',
      15:'FIFA CWC',16:'Concacaf',17:'AFC Elite',20:'AFC Two'}

def brier_vec(P,ys):
    P=np.array(P); oh=np.eye(3)[np.array(ys)]; return np.sum((P-oh)**2,axis=1)
def logloss_vec(P,ys):
    P=np.array(P); return -np.log(np.clip(P[np.arange(len(ys)),np.array(ys)],1e-15,1))
def boot_ci(delta, n=2000, seed=0):
    rng=np.random.default_rng(seed); d=np.array(delta)
    xs=[d[rng.integers(0,len(d),len(d))].mean() for _ in range(n)]
    return float(np.mean(xs)), float(np.percentile(xs,2.5)), float(np.percentile(xs,97.5))

def leakage_asserts(rows):
    # (L) Toda fila tiene marcador (FINAL) y features de fecha < fecha del target
    #     por construcción SQL (d.fecha < c.fecha). Verificamos invariantes de datos.
    assert all(r['hs'] is not None and r['as_'] is not None for r in rows), "score nulo (no-final) en fit"
    # ninguna fila fechada hoy/futuro (2026-09-09 son los LIVE); el histórico usable termina 09-08
    bad=[r for r in rows if r['fecha']>='2026-09-09']
    assert not bad, f"filas fechadas hoy/futuro en fit: {len(bad)}"
    return dict(n=len(rows), max_fecha=max(r['fecha'] for r in rows), live_rows=0)

def eval_split(train, test, floor=5, ridge=10.0):
    tr=[r for r in train if r['h_n']>=floor and r['a_n']>=floor]
    te=[r for r in test  if r['h_n']>=floor and r['a_n']>=floor]
    if len(tr)<80 or len(te)<30: return None
    lidx,ref=build_league_index(tr)
    thF=fit(tr,lidx,True,ridge); thN=fit(tr,lidx,False,0.0)  # baseline: idéntico sin φ
    ys=[y_of(r) for r in te]
    PF=[predict(thF,r,lidx,True)[0]  for r in te]
    PN=[predict(thN,r,lidx,False)[0] for r in te]
    return dict(tr=tr,te=te,lidx=lidx,ref=ref,thF=thF,thN=thN,ys=ys,PF=PF,PN=PN,
                mF=metrics(PF,ys),mN=metrics(PN,ys))

def main():
    rows=load(); rows.sort(key=lambda r:r['fecha'])
    L=leakage_asserts(rows)
    print(f"[L leakage gate] PASS — {L['n']} filas final, max_fecha={L['max_fecha']}, live_rows={L['live_rows']}")
    print(f"                 baseline = MISMO modelo/features/ridge, único cambio = quitar φ de liga\n")

    # ── (WF) Walk-forward por fold (train/val/test temporales, sin solape) ──
    print("=== (WF) WALK-FORWARD por fold (floor=5, ridge=10) ===")
    folds=[("2024-08-01","2025-02-01"),("2025-02-01","2025-08-01"),("2025-08-01","2026-03-01")]
    wf=[]
    for (vstart,tstart) in folds:
        tr=[r for r in rows if r['fecha']<vstart]
        va=[r for r in rows if vstart<=r['fecha']<tstart]
        te=[r for r in rows if r['fecha']>=tstart]
        te=[r for r in te if r['fecha']< _add6(tstart)]
        R=eval_split(tr,te,5,10.0)
        if R is None: print(f"  fold t>={tstart}: muestra insuficiente"); continue
        bF=brier_vec(R['PF'],R['ys']); bN=brier_vec(R['PN'],R['ys'])
        lF=logloss_vec(R['PF'],R['ys']); lN=logloss_vec(R['PN'],R['ys'])
        m,lo,hi=boot_ci(bN-bF)
        wf.append(dict(test_desde=tstart,n_train=len(R['tr']),n_val=len(va),n_test=len(R['te']),
            brier=round(R['mF']['brier'],4),logloss=round(R['mF']['logloss'],4),
            dBrier=round(R['mN']['brier']-R['mF']['brier'],4),
            dLogLoss=round(R['mN']['logloss']-R['mF']['logloss'],4),
            ci=[round(lo,4),round(hi,4)]))
        print(f"  test>={tstart}: n_tr={len(R['tr'])} n_val={len(va)} n_te={len(R['te'])} | "
              f"Brier={R['mF']['brier']:.4f} LogLoss={R['mF']['logloss']:.4f} | "
              f"ΔBrier={R['mN']['brier']-R['mF']['brier']:+.4f} ΔLogLoss={R['mN']['logloss']-R['mF']['logloss']:+.4f} "
              f"CI_ΔBrier=[{lo:+.4f},{hi:+.4f}]")

    # ── split principal para breakdown por competencia + φ ──
    CUT="2025-02-01"
    tr=[r for r in rows if r['fecha']<CUT]; te=[r for r in rows if r['fecha']>=CUT]
    R=eval_split(tr,te,5,10.0)
    print(f"\n=== (C) POR COMPETENCIA en test (cut {CUT}, n_test={len(R['te'])}) ===")
    by=collections.defaultdict(list)
    for r,pf,pn in zip(R['te'],R['PF'],R['PN']):
        by[r['liga']].append((pf,pn,y_of(r)))
    comp_report={}
    for lg,items in sorted(by.items(), key=lambda kv:-len(kv[1])):
        ps=[x[0] for x in items]; pn=[x[1] for x in items]; yv=[x[2] for x in items]
        mF=metrics(ps,yv); mN=metrics(pn,yv)
        ece=np.mean([abs(b['conf']-b['acc']) for b in calibration_buckets(ps,yv,4)]) if len(yv)>=8 else None
        comp_report[COMP.get(lg,str(lg))]=dict(n=len(yv),brier=round(mF['brier'],4),logloss=round(mF['logloss'],4),
            dBrier_vs_base=round(mN['brier']-mF['brier'],4),ece=None if ece is None else round(float(ece),3))
        print(f"  {COMP.get(lg,str(lg)):12s} n={len(yv):3d} Brier={mF['brier']:.4f} LogLoss={mF['logloss']:.4f} "
              f"ΔBrier_vs_base={mN['brier']-mF['brier']:+.4f} ECE={'n/a' if ece is None else round(float(ece),3)}")

    # ── (ID) φ por fold (identificabilidad: ref fija =0) ──
    print(f"\n=== (ID) φ por fold (ref liga=0 fija; estabilidad) ===")
    inv={v:k for k,v in R['lidx'].items()}
    print(f"  ref liga (φ=0) = {R['ref']}")
    for (vstart,tstart) in folds:
        trf=[r for r in rows if r['fecha']<tstart]
        trf=[r for r in trf if r['h_n']>=5 and r['a_n']>=5]
        if len(trf)<80: continue
        li,rf=build_league_index(trf); th=fit(trf,li,True,10.0); phi=th[5:]; iv={v:k for k,v in li.items()}
        top=sorted(range(len(phi)),key=lambda i:phi[i])
        s=" ".join(f"{iv[i]}:{phi[i]:+.2f}" for i in top[:3]+top[-3:])
        print(f"  fold<{tstart} (ref {rf}): {s}")

    # ── (FL) sensibilidad sample floor, elegido por VALIDACIÓN (no test) ──
    print(f"\n=== (FL) SAMPLE FLOOR sweep (elegido por validación, no test) ===")
    itr=[r for r in tr if r['fecha']<"2024-10-01"]; ival=[r for r in tr if r['fecha']>="2024-10-01"]
    best=(None,1e9)
    for fl in [5,8,10,15]:
        Rf=eval_split(itr,ival,fl,10.0)
        if Rf is None: print(f"  floor={fl}: insuficiente"); continue
        print(f"  floor={fl}: n_tr={len(Rf['tr'])} n_val={len(Rf['te'])} val Brier={Rf['mF']['brier']:.4f} LogLoss={Rf['mF']['logloss']:.4f}")
        if Rf['mF']['logloss']<best[1]: best=(fl,Rf['mF']['logloss'])
    print(f"  >> floor óptimo (val logloss) = {best[0]}")

    out=dict(estado="APPROVABLE_STAGED / FINAL_VALIDATION_PENDING",
             leakage=L, walk_forward=wf, por_competencia=comp_report, floor_optimo=best[0])
    json.dump(out,open("validation_v2.json","w"),indent=2,default=str)
    print("\n[saved] validation_v2.json")

def _add6(datestr):
    y,m,d=[int(x) for x in datestr.split("-")]; m+=6; y+=(m-1)//12; m=(m-1)%12+1
    return f"{y:04d}-{m:02d}-{d:02d}"

if __name__=="__main__": main()
