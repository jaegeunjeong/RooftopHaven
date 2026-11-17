import collections, statistics as st
from r3 import T_of
from sim import World, run_many
orig=World.wishlist
PRE={'강화 바리케이드':[('강화 철판',3)], '전기 울타리':[], '감시탑':[('강화 철판',2)],
     '무전 중계기':[('무전 안테나',1),('축전지 팩',1),('회로판',2)], '정수 설비':[('필터 카트리지',2),('철판',3)],
     '온실':[('텃밭',1)], '연구대':[('의무실 침상',1),('회로판',1)]}
def make(target):
    def wl(self):
        W=orig(self)
        if ('기계 작업대',1) in W:
            i=W.index(('기계 작업대',1))+1
            ins=PRE[target]+[(target,1)]
            if target in ('정수 설비','온실','무전 중계기','연구대'):  # these don't need 기계 작업대; put them right after 계단 보강
                i=W.index(('계단 보강',1))+1
            W=W[:i]+ins+[x for x in W[i:] if x not in ins]
        return W
    return wl
T=T_of('late2+cap+pharm')
from sim import R
for tgt in PRE:
    World.wishlist=make(tgt)
    res=run_many(200,'smart',T=T)
    got=[r['first'][tgt] for r in res if tgt in r['first']]
    win=sum(r['result']=='승리' for r in res)/200
    print(f"{tgt}: built {len(got)/200:.0%} median day {st.median(got) if got else '-'}  win {win:.0%}")
World.wishlist=orig
