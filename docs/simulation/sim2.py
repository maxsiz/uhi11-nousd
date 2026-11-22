"""noUSD v3: fee-split schemes on-chain-realistic.
Honest users: generator from nousd_monte_carlo.py (10 users, cap 100k, 30 days).
Fees: pool with fixed volume; vault earns share deployed/(deployed+OTHER). Idle earns 0.
Deploy of idle every DEPLOY days. Service 10%.
Schemes (all mint 1:1 to stable):
  A  fees compounded into body, burn x/supply of body (naive v3)
  B  separate ledger, daily snapshot of opening balances (user's 'snap')
  C  accumulator checkpointed on every event, by noUSD balance (user's 'fair')
  C2 accumulator, entitlement only for deployed (active) balance
Ideal = C2 (fees follow capital that actually sits in the pool).
"""
import random, statistics, sys, json
DAYS=30; USERS=10; CAP=100_000.0; SERVICE=.10
OTHER=2_000_000.0; VOLUME=5_000_000.0; FEE=0.0001   # pool: $500/day of fees
POOL_DAILY=VOLUME*FEE
SCHEMES=('A','B','C','C2')

def honest(rng):
    arr=[0.0]+sorted(rng.uniform(.01,25.99) for _ in range(USERS-1))
    w=[rng.uniform(.7,1.5) for _ in range(USERS)]
    amt=[CAP*x/sum(w) for x in w]; ev=[]
    for i,a in enumerate(arr):
        ev.append((a,'mint',i,amt[i]))
        if rng.random()<.75: ev.append((min(29.999,a+rng.uniform(.15,18)),'burnf',i,rng.uniform(.3,1.0)))
        if rng.random()<.4: ev.append((min(29.999,a+rng.uniform(1,22)),'burnf',i,1.0))
    return ev

def run(rng, attack=None, deploy=1.0, M=50_000.0):
    ev=honest(rng); A=USERS  # attacker index
    n=USERS+1
    # schedule
    t=deploy
    while t<DAYS: ev.append((t,'deploy',-1,0)); t+=deploy
    for d in range(1,DAYS): ev.append((d,'snap',-1,0))
    if attack=='flash':
        for d in range(DAYS): ev.append((d+0.5,'flash',A,M))
    elif attack=='snapshot':          # in just before day boundary, out just after
        for d in range(1,DAYS): ev.append((d-1e-6,'mintA',A,M)); ev.append((d+1e-6,'burnA',A,1.0))
    elif attack=='idle':              # in right after each deploy, out right before next
        t=0.0
        while t+deploy<=DAYS:
            ev.append((t+1e-6,'mintA',A,M)); ev.append((t+deploy-2e-6,'burnA',A,1.0)); t+=deploy
    order={'snap':0,'burnA':1,'deploy':2,'mintA':3,'mint':4,'burnf':4,'flash':4}
    ev.sort(key=lambda e:(e[0],order[e[1]]))
    bal=[0.0]*n; active=[0.0]*n; dep=[0.0]*n; got=[0.0]*n
    idle=0.0; deployed=0.0
    body=0.0   # scheme A: NAV of body incl. compounded fees (deployed+idle+fees)
    ledger={s:[0.0]*n for s in ('B','C','C2')}
    snap_open=bal[:]; day_fees=0.0; t=0.0; total_fees=0.0
    def supply(): return sum(bal)
    for (te,kind,j,q) in ev:
        dt=te-t
        if dt>0:
            f=POOL_DAILY*deployed/(deployed+OTHER)*(1-SERVICE)*dt
            total_fees+=f; body+=f; day_fees+=f
            s=supply(); sa=sum(active)
            if s>0:
                for k in range(n): ledger['C'][k]+=f*bal[k]/s
            if sa>0:
                for k in range(n): ledger['C2'][k]+=f*active[k]/sa
            t=te
        if kind=='snap':
            so=sum(snap_open)
            if so>0:
                for k in range(n): ledger['B'][k]+=day_fees*snap_open[k]/so
            day_fees=0.0; snap_open=bal[:]
        elif kind=='deploy':
            deployed+=idle; idle=0.0; active=bal[:]
        elif kind in('mint','mintA','flash'):
            x=min(q,max(0.0,CAP-supply()))
            if x<=0: continue
            bal[j]+=x; dep[j]+=x; idle+=x; body+=x
            if kind=='flash':   # burn same instant
                s=supply(); out=x*body/s   # scheme A payout
                got[j]+=out; body-=out
                bal[j]-=x; idle-=x   # B/C/C2: principal back exactly x
        else:  # burn fraction q of own balance
            x=bal[j]*q
            if x<=0: continue
            s=supply(); out=x*body/s
            got[j]+=out; body-=out
            bal[j]-=x
            pend=bal[j]+x-active[j]          # pending part of balance before burn
            fromp=min(x,max(0.0,pend)); froma=x-fromp
            active[j]-=froma
            fr=x/s; idle-=idle*fr; deployed-=deployed*fr   # burn takes pro-rata from idle and positions
    # close day leftovers for B (last day)
    so=sum(snap_open)
    if so>0:
        for k in range(n): ledger['B'][k]+=day_fees*snap_open[k]/so
    s=supply()
    res={'total':total_fees}
    # scheme A earnings per user = got + final value - deposits
    earnA=[got[k]+(bal[k]*body/s if s>0 else 0)-dep[k] for k in range(n)]
    res['A']=earnA
    for sc in ('B','C','C2'): res[sc]=ledger[sc]
    return res

def summarize(attack=None, deploy=1.0, trials=2000, seed=20261120):
    rng=random.Random(seed); out={s:{'mis':[], 'att':[]} for s in SCHEMES}; tot=[]
    for _ in range(trials):
        r=run(rng,attack,deploy); tot.append(r['total'])
        ideal=r['C2'][:USERS]
        for s in SCHEMES:
            e=r[s]; honest_err=sum(abs(e[k]-ideal[k]) for k in range(USERS))/2
            out[s]['mis'].append(honest_err); out[s]['att'].append(e[USERS])
    m=lambda v: round(statistics.mean(v),2)
    return {'fees':m(tot), **{s:{'mis':m(out[s]['mis']),'att':m(out[s]['att'])} for s in SCHEMES}}

if __name__=='__main__':
    R={}
    for name,att,dep in [('honest_d1',None,1.0),('honest_h1',None,1/24),('flash',  'flash',1.0),
                         ('snapshot','snapshot',1.0),('idle_d1','idle',1.0),('idle_h1','idle',1/24)]:
        R[name]=summarize(att,dep); print(name,R[name]); sys.stdout.flush()
    json.dump(R,open(sys.argv[1] if len(sys.argv)>1 else 'sim2.json','w'),ensure_ascii=False,indent=1)
