import sys, collections, statistics as st
from exp import SCENARIOS, summary
from sim import run_many, R
def fun(name, n=400):
    res=run_many(n,'smart',T=SCENARIOS[name])
    s=summary(res)
    by={5:[],19:[],30:[]}; types=[]; newdays=[]; idle=[]
    for r in res:
        fs={k:d for k,d in r['first'].items() if R[k]['kind'] in ('fac','def')}
        for lim in by: by[lim].append(sum(1 for d in fs.values() if d<=lim))
        types.append(len(fs)); newdays.append(len(set(fs.values()))); idle.append(r['log'].get('idle_h',0))
    print(f"== {name}: win {s['result'].get('승리',0):.0%}, deaths {s['deaths']:.2f}, score {s['score_med']:.0f}")
    print(f"   지은 시설 종류(누적): 5일 {st.mean(by[5]):.1f} / 19일 {st.mean(by[19]):.1f} / 30일 {st.mean(by[30]):.1f}")
    print(f"   새 시설이 생긴 날 수 {st.mean(newdays):.1f}일, 건설 담당 쉰 시간 {st.mean(idle):.0f}h")
    m=s['milestones']; print('  ',{k:(f"{v[0]:.0%}",v[1]) for k,v in m.items() if v[0]>0})
    L=collections.Counter()
    for r in res: L.update({k:v for k,v in r['first'].items()})
    return res
for nm in sys.argv[1:]: fun(nm)
