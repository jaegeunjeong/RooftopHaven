import sys, collections, statistics as st, json
from sim import run_many, drow
def summary(res):
    n=len(res); c=collections.Counter(r['result'] for r in res)
    L=collections.Counter()
    for r in res: L+=r['log']
    deaths=collections.Counter()
    for k,v in L.items():
        if k.startswith('death:'): deaths[k[6:]]+=v
    g=collections.Counter(r['grade'] for r in res)
    rd=collections.defaultdict(collections.Counter)
    for r in res:
        for d in r['daily']:
            for kind,stg,dfn,m in d['raids']:
                band='1~5' if d['day']<=5 else '6~19' if d['day']<=19 else '20~30'
                res_='완벽' if m>=2 else '막음' if m>=0 else '일부 뚫림' if m>=-2 else '크게 뚫림'
                rd[band][res_]+=1
    # daily averages
    curve={}
    for day in (1,3,5,7,10,15,20,25,30):
        rows=[d for r in res for d in r['daily'] if d['day']==day]
        if rows: curve[day]=dict(n=len(rows)/n, alive=st.mean(x['alive'] for x in rows), food=st.mean(x['food'] for x in rows),
            water=st.mean(x['water'] for x in rows), morale=st.mean(x['morale'] for x in rows), trace=st.mean(x['trace'] for x in rows),
            defense=st.mean(x['defense'] for x in rows))
    return dict(n=n, result={k:v/n for k,v in c.items()}, day_med=st.median(r['day'] for r in res),
        deaths=sum(r['deaths'] for r in res)/n, causes={k:v/n for k,v in deaths.items()},
        score_med=st.median(r['score'] for r in res), grades={k:v/n for k,v in g.items()},
        ev_rate=(L['ev_roll_ok']/max(1,L['ev_rolls'])), ev_per_run=L['ev_ok']/n+L['ev_fail']/n,
        raids={b:dict(v) for b,v in rd.items()}, curve=curve,
        exp={k[4:]:v/n for k,v in L.items() if k.startswith('exp:')},
        built={k[6:]:round(v/n,2) for k,v in L.items() if k.startswith('built:') and v/n>=.2},
        milestones={m:(sum(1 for r in res if m in r['first'])/n, st.median([r['first'][m] for r in res if m in r['first']] or [0])) for m in ('바리케이드','깡통 경보기','작업대 Lv2','증류기','재봉대','발전기','무전 안테나','계단 보강','방독 마스크','손전등','강화 철판','회로판','기계 작업대','강화 바리케이드','전기 울타리','감시탑','무전 중계기','온실','정수 설비','연구대')},
        bp={k[3:]:round(v/n,2) for k,v in L.items() if k.startswith('bp:')},
        joined=L['joined']/n, revive=L['revive']/n, starving_h=L['starving_h']/n, stolen=L['stolen']/n, broken=L['fac_broken']/n)
def show(name, s):
    print('=====',name); 
    for k,v in s.items():
        if k=='curve':
            for d,x in v.items(): print('   day',d,{a:round(b,1) for a,b in x.items()})
        else: print(' ',k,v if not isinstance(v,float) else round(v,3))
T1=dict(loot_add={'clothes':{'목재':(1,2),'고철':(0,1)},'hardware':{'통조림':(0,1)},
   'gas':{'통조림':(1,2),'생수':(1,2)},'down':{'통조림':(1,2),'생수':(0,1)},'subway':{'통조림':(1,2)},'hospital':{'생수':(1,2)}},
   regen=0.1, rain=6, rain_wet=12, filter=30, raider_first=(8,10), garden=(2,4))
T2=dict(T1); T2['decay']={'rest':(1.0,2.0,1.0),'work':(1.5,2.5,4.0),'exp':(2.0,3.0,5.0),'sleep':(0.8,1.5,0.0)}; T2['can']=(30,35)
PROPOSAL=dict(T2); PROPOSAL['can']=(25,30); PROPOSAL['inf_base']=0.15
PROPOSAL['decay']={'rest':(1.2,2.0,1.0),'work':(1.6,2.5,4.0),'exp':(2.2,3.2,5.0),'sleep':(1.0,1.5,0.0)}
NOFOOD=dict(PROPOSAL); NOFOOD['loot_add']={'clothes':{'목재':(1,2),'고철':(0,1)}}
CONSUME=dict(decay=T2['decay'], can=(30,35))
ROUND2=dict(PROPOSAL); ROUND2.update(late_start=20, down_mid=True, teams='size',
    rare_add={'down':[('BP기계 작업대',1,.25)],'hardware':[('전자 부품',1,.30)],'gas':[('정밀 부품',1,.25)]})
import copy as _c
ROUND2_FIX=_c.deepcopy(ROUND2); ROUND2_FIX['recipe_cost']={'계단 보강':{'철판':2,'목재':3}}
ROUND2_FIX['loot_add']['clothes']['목재']=(2,3); ROUND2_FIX['loot_add'].setdefault('hardware',{})['목재']=(2,3)
ROUND3=_c.deepcopy(ROUND2_FIX); ROUND3['guard_cap']=4
ROUND3['day_tbl']=[(1,5,2,None,0,None),(6,10,4,5,0,5),(11,15,5,6,.02,0),(16,20,8,9,.04,-5),(21,25,11,12,.06,-10),(26,30,13,14,.08,-10)]
ROUND3['loot_add']['pharmacy']={'화학품':(3,5),'천':(1,2)}
ROUND3['rare_set']={'pharmacy':[('BP증류기',1,.40),('희귀 의약품',1,.15),('소독약',1,.30)]}
SCENARIOS={'round3':ROUND3,'round2':ROUND2,'round2_fix':ROUND2_FIX,'current':None, 'consume':CONSUME, 'proposal':PROPOSAL, 'proposal_nofood':NOFOOD, 'generous':T2}

if __name__=='__main__':
    # usage: python3 exp.py <scenario> <smart|noanswer> <runs>
    which=sys.argv[1]; pol=sys.argv[2]; n=int(sys.argv[3])
    show(f'{which}/{pol}', summary(run_many(n,pol,T=SCENARIOS[which])))
