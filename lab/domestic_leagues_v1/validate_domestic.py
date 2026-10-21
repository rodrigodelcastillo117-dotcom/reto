#!/usr/bin/env python3
"""BLOQUE 2 — Validación de ligas domésticas no aprobadas (staged).
Dixon-Coles INTRA-LIGA (sin φ), temporalmente seguro (forma 540d < kickoff).
Por liga: temporal split, Brier, LogLoss, calibración, estabilidad, coverage,
leakage audit, floor sensitivity (val), decisión APPROVABLE/NOT_APPROVABLE.
Baseline = base-rate del train. NO usa odds/mercado."""
import math, json, numpy as np, collections
from scipy.optimize import minimize
from scipy.stats import poisson

NAMES={144:'Belgica/Jupiler',103:'Noruega/Eliteserien',197:'Grecia/SuperLeague',
       119:'Dinamarca/Superliga',179:'Escocia/Premiership'}

def load():
    rows=[]
    for ln in open('domestic_train.csv').read().strip().split('\n'):
        p=ln.split('|')
        if len(p)!=10: continue
        rows.append(dict(liga=int(p[0]),fecha=p[1][:10],hs=int(p[2]),as_=int(p[3]),
            h_n=int(p[4]),h_gf=float(p[5]),h_ga=float(p[6]),a_n=int(p[7]),a_gf=float(p[8]),a_ga=float(p[9])))
    return rows

def dc_tau(i,j,lh,la,rho):
    if i==0 and j==0: return 1-lh*la*rho
    if i==0 and j==1: return 1+lh*rho
    if i==1 and j==0: return 1+la*rho
    if i==1 and j==1: return 1-rho
    return 1.0
def nll(theta,X):
    a0,batt,bdef,g,rho=theta; t=0
    for (lhg,lhga,lag,laga,hs,as_) in X:
        lh=math.exp(min(a0+batt*lhg+bdef*laga+g,2.5)); la=math.exp(min(a0+batt*lag+bdef*lhga,2.5))
        t+=lh-hs*math.log(lh)+la-as_*math.log(la)
        tau=dc_tau(hs,as_,lh,la,rho); t+= -math.log(tau) if tau>0 else 10
    return t
def feats(rows):
    return [(math.log(max(r['h_gf'],.05)),math.log(max(r['h_ga'],.05)),
             math.log(max(r['a_gf'],.05)),math.log(max(r['a_ga'],.05)),r['hs'],r['as_']) for r in rows]
def fit(rows):
    r=minimize(nll,[0,.5,.5,.25,0],args=(feats(rows),),method='L-BFGS-B',options=dict(maxiter=400)); return r.x
def probs(theta,r):
    a0,batt,bdef,g,rho=theta
    lh=math.exp(min(a0+batt*math.log(max(r['h_gf'],.05))+bdef*math.log(max(r['a_ga'],.05))+g,2.5))
    la=math.exp(min(a0+batt*math.log(max(r['a_gf'],.05))+bdef*math.log(max(r['h_ga'],.05)),2.5))
    ph=poisson.pmf(range(11),lh); pa=poisson.pmf(range(11),la); M=np.outer(ph,pa)
    for i in range(2):
        for j in range(2): M[i,j]*=dc_tau(i,j,lh,la,rho)
    M/=M.sum()
    return np.array([np.tril(M,-1).sum(),np.trace(M),np.triu(M,1).sum()])
def y_of(r): return 0 if r['hs']>r['as_'] else (1 if r['hs']==r['as_'] else 2)
def met(P,ys):
    P=np.array(P);oh=np.eye(3)[np.array(ys)]
    return dict(n=len(ys),brier=round(float(np.mean(np.sum((P-oh)**2,1))),4),
        logloss=round(float(-np.mean(np.log(np.clip(P[np.arange(len(ys)),ys],1e-15,1)))),4),
        acc=round(float(np.mean(np.argmax(P,1)==ys)),3))
def base(train,n):
    ys=[y_of(r) for r in train];p=np.bincount(ys,3 if False else None,minlength=3)/len(ys);return [p]*n
def cal_ece(P,ys):
    P=np.array(P);conf=P.max(1);pred=P.argmax(1);corr=(pred==np.array(ys)).astype(float);e=[]
    for b in range(4):
        lo,hi=b/4,(b+1)/4;m=(conf>=lo)&(conf<(hi if b<3 else 1.01))
        if m.sum()>=5: e.append(abs(conf[m].mean()-corr[m].mean()))
    return round(float(np.mean(e)),3) if e else None

rows=load(); rows.sort(key=lambda r:r['fecha'])
by=collections.defaultdict(list)
for r in rows: by[r['liga']].append(r)
report={}
for lg in [144,103,197,119,179]:
    g=sorted(by[lg],key=lambda r:r['fecha'])
    # leakage audit
    live=[r for r in g if r['fecha']>='2026-09-09']
    # temporal split ~70/30
    cut=g[int(len(g)*0.7)]['fecha']
    tr=[r for r in g if r['fecha']<cut]; te=[r for r in g if r['fecha']>=cut]
    if len(tr)<120 or len(te)<40:
        report[NAMES[lg]]=dict(n=len(g),decision='NOT_APPROVABLE',motivo='muestra insuficiente');
        print(f"{NAMES[lg]}: n={len(g)} -> NOT_APPROVABLE (muestra)"); continue
    th=fit(tr); ys=[y_of(r) for r in te]
    P=[probs(th,r) for r in te]; PB=base(tr,len(te))
    m=met(P,ys); mb=met(PB,ys); ece=cal_ece(P,ys)
    # estabilidad por año
    est={}
    byy=collections.defaultdict(list)
    for r,p in zip(te,P): byy[r['fecha'][:4]].append((p,y_of(r)))
    for yr,it in sorted(byy.items()):
        if len(it)>=20: est[yr]=met([x[0] for x in it],[x[1] for x in it])['brier']
    dBrier=round(mb['brier']-m['brier'],4); dLL=round(mb['logloss']-m['logloss'],4)
    # floor sensitivity en validación interna del train
    itr=[r for r in tr if r['fecha']<tr[int(len(tr)*0.7)]['fecha']]; iva=[r for r in tr if r['fecha']>=tr[int(len(tr)*0.7)]['fecha']]
    floor_best=None
    if len(itr)>=100 and len(iva)>=30:
        bb=(None,1e9)
        for fl in [5,8,10,15]:
            itrf=[r for r in itr if r['h_n']>=fl and r['a_n']>=fl]; ivaf=[r for r in iva if r['h_n']>=fl and r['a_n']>=fl]
            if len(itrf)<80 or len(ivaf)<25: continue
            thf=fit(itrf); mm=met([probs(thf,r) for r in ivaf],[y_of(r) for r in ivaf])
            if mm['logloss']<bb[1]: bb=(fl,mm['logloss'])
        floor_best=bb[0]
    # decisión: mejora OOS vs base-rate en Brier Y logloss, calibración razonable
    approvable = (dBrier>0 and dLL>0 and (ece is None or ece<=0.08) and m['n']>=60 and len(tr)>=150)
    decision='APPROVABLE' if approvable else 'NOT_APPROVABLE'
    report[NAMES[lg]]=dict(liga_id=lg,n=len(g),n_train=len(tr),n_test=len(te),cut=cut,live_rows=len(live),
        brier=m['brier'],logloss=m['logloss'],acc=m['acc'],base_brier=mb['brier'],base_logloss=mb['logloss'],
        dBrier=dBrier,dLogLoss=dLL,ece=ece,estabilidad=est,floor_val=floor_best,decision=decision)
    print(f"{NAMES[lg]:22s} n={len(g):3d} tr={len(tr)} te={len(te)} live={len(live)} | "
          f"Brier={m['brier']:.4f} vs base {mb['brier']:.4f} (Δ{dBrier:+.4f}) | LogLoss={m['logloss']:.4f} (Δ{dLL:+.4f}) | "
          f"ECE={ece} est={est} floor*={floor_best} -> {decision}")

json.dump(report,open('domestic_result.json','w'),indent=2,default=str)
print('\n[saved] domestic_result.json  ·  leakage: live_rows debe ser 0 en todas')
