import sys, copy, collections
from exp import ROUND2_FIX, summary
from sim import run_many, DAY_TABLE
def T_of(v):
    T=copy.deepcopy(ROUND2_FIX)
    if 'cap' in v: T['guard_cap']=4
    if 'late' in v:
        T['day_tbl']=[(1,5,2,None,0,None),(6,10,4,5,0,5),(11,15,5,6,.02,0),(16,20,7,8,.04,-5),(21,25,10,11,.06,-10),(26,30,12,13,.08,-10)]
    if 'late2' in v:
        T['day_tbl']=[(1,5,2,None,0,None),(6,10,4,5,0,5),(11,15,5,6,.02,0),(16,20,8,9,.04,-5),(21,25,11,12,.06,-10),(26,30,13,14,.08,-10)]
    if 'pharm' in v:
        T['loot_add']['pharmacy']={'화학품':(3,5),'천':(1,2)}
        T.setdefault('rare_set',{})['pharmacy']=[('BP증류기',1,.40),('희귀 의약품',1,.15),('소독약',1,.30)]
    if 'lightmw' in v: T['recipe_cost']['기계 작업대']={'강화 철판':1,'회로판':1}
    if 'lv2late' in v:
        T['recipe_needs']={'전기 울타리':['작업대 Lv2','발전기'],'감시탑':['바리케이드','작업대 Lv2']}
    if 'cheaptower' in v: T['recipe_cost']['감시탑']={'철판':3,'목재':4}
    if 'mwnobp' in v: T['no_bp']=['기계 작업대']
    if 'relay' in v:
        T['recipe_cost']['무전 중계기']={'회로판':1,'배터리 셀':2}; T['recipe_needs']=dict(T.get('recipe_needs',{})); T['recipe_needs']['무전 중계기']=['발전기','기계 작업대']
    if 'elec' in v:
        T['rare_add']['hardware']=[('전자 부품',1,.5)]; T['loot_add']['subway']=dict(T['loot_add'].get('subway',{})); T['loot_add']['subway']['전자 부품']=(2,3)
    if 'midmove' in v:
        rc=T['recipe_cost']; rn=T.setdefault('recipe_needs',{})
        rc['온실']={'유리':4,'철판':2}; rn['온실']=['텃밭']
        rc['정수 설비']={'철판':2,'필터 카트리지':1}; rn['정수 설비']=['증류기']
        rc['연구대']={'회로판':1,'유리':2}; rn['연구대']=['의무실 침상','증류기']; T.setdefault('no_bp',[]); T['no_bp']=list(T['no_bp'])+['연구대']
        rc['무전 중계기']={'회로판':1,'배터리 셀':2}
    return T
if __name__=='__main__':
    for v in sys.argv[2:]:
        s=summary(run_many(int(sys.argv[1]),'smart',T=T_of(v)))
        r=s['raids'].get('20~30',{}); tot=sum(r.values()) or 1
        m=s['milestones']
        print(v, {k:round(x,3) for k,x in s['result'].items()}, 'deaths',round(s['deaths'],2),
              'late raids', {k:f'{x/tot:.0%}' for k,x in r.items()}, 'pharm',round(s['exp'].get('pharmacy',0),2),
              '증류기',m['증류기'], '기계',m['기계 작업대'], '울타리',m['전기 울타리'],'감시탑',m['감시탑'],'중계기',m['무전 중계기'],'강화바리',m['강화 바리케이드'],'score',s['score_med'],'온실',m.get('온실'),'정수',m.get('정수 설비'),'연구대',m.get('연구대'))
