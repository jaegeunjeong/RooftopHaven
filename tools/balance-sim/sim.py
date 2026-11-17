"""Rooftop Haven 30-day Monte Carlo simulator (balance check for 04-수치설계 notes).

Hourly ticks. A scripted "competent player" policy builds, dispatches expeditions,
answers radio events and defends at night. Numbers come from the Obsidian notes;
anything the notes leave open is marked ASSUME.
"""
import random, math, collections, json, sys

# ---------------------------------------------------------------- constants
DAYS = 30
DECAY = {  # per game hour: (food, water, stamina)
    'rest': (1.5, 2.5, 1.0), 'work': (2.0, 3.0, 4.0), 'exp': (2.5, 4.0, 5.0), 'sleep': (1.5, 2.5, 0.0),
}
SLEEP_GAIN = {'floor': 5, 'bed': 7, 'bag': 8}

DAY_TABLE = [  # (from, to, infected base, raider str, injury add, event mod)
    (1, 5, 2, None, 0.00, None), (6, 10, 4, 5, 0.00, 5), (11, 15, 5, 6, 0.02, 0),
    (16, 20, 7, 8, 0.04, -5), (21, 25, 8, 9, 0.06, -10), (26, 30, 9, 10, 0.08, -10)]

CUR_TBL = [DAY_TABLE]
def drow(day):
    for r in CUR_TBL[0]:
        if r[0] <= day <= r[1]:
            return r
    return DAY_TABLE[-1]

STAGE2 = [16]
def stage(day):
    return 0 if day <= 5 else (1 if day < STAGE2[0] else 2)

WEATHER_P = [
    {'clear': 55, 'rain': 30, 'fog': 15},
    {'clear': 35, 'rain': 20, 'fog': 10, 'heat': 12, 'cold': 12, 'acid': 8, 'dust': 3},
    {'clear': 25, 'rain': 15, 'fog': 10, 'heat': 12, 'cold': 15, 'acid': 13, 'dust': 10}]
HARSH = {'heat', 'cold', 'acid', 'dust'}

def make_weather(rng):
    days = {}
    d = 1
    prev = None
    while d <= DAYS:
        p = WEATHER_P[stage(d)]
        while True:
            w = rng.choices(list(p), list(p.values()))[0]
            if prev == 'heat' and w == 'cold':
                continue
            break
        n = rng.randint(1, 3)
        for _ in range(n):
            if d > DAYS:
                break
            days[d] = w
            d += 1
        prev = w
    # first harsh weather guaranteed on day 6 or 7
    if not any(days[x] in HARSH for x in (6, 7)):
        days[rng.choice((6, 7))] = rng.choice(['heat', 'cold', 'acid'])
    # harsh weather never longer than 3 days in a row
    run = 0
    for x in range(1, DAYS + 1):
        run = run + 1 if days[x] in HARSH else 0
        if run > 3:
            days[x] = 'clear'; run = 0
    return days

# ---------------------------------------------------------------- locations
LOC = {
    'store':   dict(name='편의점', st=0, hrs=6, inj=.05,
                    main={'통조림': (2, 4), '생수': (1, 3), '식재료': (0, 2), '플라스틱': (1, 2)},
                    rare=[('연료', 1, .30), ('화학품', 1, .20), ('배터리', 1, .25)]),
    'clothes': dict(name='의류 상가', st=0, hrs=8, inj=.08,
                    main={'천': (3, 6), '플라스틱': (1, 2)},
                    rare=[('끈', 1, .30), ('방한 외투', 1, .10), ('BP재봉대', 1, .15), ('가죽', 1.5, .25, 'mid')]),
    'hardware':dict(name='철물점', st=1, hrs=8, inj=.10,
                    main={'고철': (3, 5), '부품': (1, 3), '목재': (1, 2)},
                    rare=[('BP작업대 Lv2', 1, .25), ('씨앗', 1.5, .30)]),
    'pharmacy':dict(name='약국', st=1, hrs=6, inj=.10, need=['쇠지렛대'],
                    main={'화학품': (2, 3), '유리': (1, 2), '천': (1, 1)},
                    rare=[('BP증류기', 1, .25), ('희귀 의약품', 1, .05)]),
    'gas':     dict(name='주유소', st=1, hrs=7, inj=.12,
                    main={'연료': (2, 4), '고무': (1, 2), '플라스틱': (1, 2)},
                    rare=[('배터리 셀', 1, .10)]),
    'down':    dict(name='아래층', st=2, hrs=4, inj=.15, needfac=['계단 보강'],
                    main={'고철': (2, 4), '정밀 부품': (1, 1), '태양광 셀': (0, 1)},
                    rare=[('SURVIVOR', 1, .10)]),
    'subway':  dict(name='지하철역', st=2, hrs=12, inj=.18, need=['손전등', '방독 마스크'],
                    main={'전자 부품': (1, 2), '배터리 셀': (1, 2), '부품': (1, 2)},
                    rare=[('BP기계 작업대', 1, .20), ('SURVIVOR', 1, .15)]),
    'hospital':dict(name='종합병원', st=2, hrs=14, inj=.25, need=['방호복'], team3=True,
                    main={'희귀 의약품': (1, 2), '화학품': (2, 3), '정밀 부품': (1, 1)},
                    rare=[('BP연구대', 1, .25)]),
}
TEAM_LOOT = {1: 1.0, 2: 1.8, 3: 2.5}
BASE_T = dict(loot_add={}, regen=0.0, rain=4, rain_wet=10, filter=20, raider_first=(6, 8),
              garden=(3, 3), start_extra={}, raider_tbl=None, decay=None, can=(25, 30), inf_base=0.0, late_start=16, down_mid=False, rare_add={},
              teams='antenna', recipe_cost={}, day_tbl=None, guard_cap=99, rare_set={}, recipe_needs={})
TEAM_INJ = {1: 1.0, 2: 0.8, 3: 0.6}

# ---------------------------------------------------------------- recipes
# kind: fac (facility, count), item (stockable), def (defense facility)
R = {}
def rec(name, cost, kind='item', needs=(), bp=False, hrs=1.0, **kw):
    R[name] = dict(cost=cost, kind=kind, needs=list(needs), bp=bp, hrs=hrs, **kw)

# ASSUME: facility build time 2h (early) / 4h (mid) / 6h (late); notes have no build times.
rec('망치', {'고철': 2, '목재': 1}, hrs=.5)
rec('정수 필터', {'플라스틱': 2, '천': 1}, hrs=1)
rec('화덕', {'고철': 3, '목재': 2}, 'fac', ['망치'], hrs=2)
rec('침상', {'목재': 3, '천': 2}, 'fac', ['망치'], hrs=2)
rec('바리케이드', {'목재': 4, '고철': 2}, 'def', ['망치'], hrs=2, dfn=1, dur=5)
rec('깡통 경보기', {'고철': 2, '끈': 1}, 'fac', hrs=1)
rec('못 판자', {'목재': 2, '고철': 1}, 'def', hrs=1, dfn=1, minus=1, dur=3)
rec('끈', {'천': 2}, hrs=.25)
rec('붕대', {'천': 2}, hrs=.25)
rec('부목', {'목재': 1, '천': 1}, hrs=.5)
rec('소독약', {'화학품': 1, '정수된 물': 1}, needs=['화덕'], hrs=1)
rec('쇠지렛대', {'고철': 3}, hrs=.75)
rec('쇠파이프', {'고철': 2}, hrs=.5)
rec('손도끼', {'고철': 2, '목재': 1}, hrs=.5)
rec('방수 판초', {'플라스틱': 3, '끈': 1}, hrs=.75)
rec('방한 외투', {'천': 5, '끈': 1}, hrs=2)
rec('침낭', {'천': 4, '끈': 1}, hrs=1.5)
rec('덧댄 작업복', {'천': 3, '끈': 1}, hrs=1)
rec('깡통 미끼', {'고철': 1, '끈': 1}, hrs=.5)
# mid
rec('작업대 Lv2', {'고철': 6, '부품': 2}, 'fac', bp=True, hrs=4)
rec('재봉대', {'목재': 3, '고철': 2, '부품': 1}, 'fac', bp=True, hrs=4)
rec('증류기', {'고철': 4, '유리': 2}, 'fac', bp=True, hrs=4)
rec('쥐덫', {'목재': 2, '고철': 1, '끈': 1}, 'fac', ['망치'], hrs=2)
rec('텃밭', {'목재': 3, '플라스틱': 2, '씨앗': 2}, 'fac', ['망치'], hrs=4)
rec('훈연기', {'목재': 4, '고철': 2}, 'fac', ['화덕'], hrs=4)
rec('의무실 침상', {'침상': 1, '천': 2, '소독약': 1}, 'fac', ['침상'], hrs=4)
rec('발전기', {'고철': 5, '부품': 3}, 'fac', ['작업대 Lv2'], hrs=4)
rec('무전 안테나', {'고철': 4, '부품': 2}, 'fac', ['발전기'], hrs=4)
rec('철판', {'고철': 3}, needs=['작업대 Lv2'], hrs=.5)
rec('숯', {'목재': 2}, needs=['화덕'], hrs=1)
rec('알코올', {'화학품': 1}, needs=['증류기'], hrs=1, yields=2)
rec('방수포', {'플라스틱': 2, '천': 1}, needs=['작업대 Lv2'], hrs=.5)
rec('충전 배터리', {'배터리': 1}, needs=['발전기'], hrs=2)
rec('철조망', {'철판': 2, '고철': 2}, 'def', ['작업대 Lv2'], hrs=4, dfn=2, dur=5)
rec('보강 문', {'철판': 2, '목재': 2}, 'def', ['작업대 Lv2'], hrs=4, dfn=2, dur=5)
rec('가시 함정', {'목재': 3, '고철': 2}, needs=[], hrs=1)
rec('계단 보강', {'철판': 3, '목재': 6}, 'fac', ['작업대 Lv2'], hrs=6)
rec('연료통', {'플라스틱': 3}, hrs=.5)
rec('봉합 키트', {'끈': 1, '알코올': 1, '고철': 1}, needs=['의무실 침상'], hrs=1)
rec('방독 마스크', {'고무': 2, '플라스틱': 1, '숯': 1}, needs=['작업대 Lv2'], hrs=1)
rec('손전등', {'부품': 1, '플라스틱': 1, '충전 배터리': 1}, needs=['작업대 Lv2'], hrs=1)
rec('미끼 폭죽', {'화학품': 1, '천': 1}, needs=['증류기'], hrs=.5)
rec('연막탄', {'화학품': 1, '플라스틱': 1}, needs=['증류기'], hrs=.5)
rec('응급 키트', {'붕대': 2, '소독약': 1}, needs=['의무실 침상'], hrs=.5)
rec('갈고리 밧줄', {'끈': 3, '고철': 1}, hrs=1)
rec('큰 가방', {'천': 4, '가죽': 2, '끈': 2}, needs=['재봉대'], hrs=1.5)
rec('가죽 장화', {'가죽': 3, '끈': 1}, needs=['재봉대'], hrs=1.5)
rec('해체 공구 세트', {'부품': 2, '철판': 1}, needs=['작업대 Lv2'], hrs=1)
# late
rec('정밀 철판', {}, hrs=0)  # placeholder unused
rec('강화 철판', {'철판': 2, '정밀 부품': 1}, needs=['작업대 Lv2'], hrs=1)
rec('회로판', {'전자 부품': 2}, needs=['작업대 Lv2'], hrs=1)
rec('축전지 팩', {'배터리 셀': 2, '전자 부품': 1}, needs=['작업대 Lv2'], hrs=1)
rec('기계 작업대', {'강화 철판': 2, '회로판': 1, '정밀 부품': 1}, 'fac', ['계단 보강'], bp=True, hrs=6)
rec('강화 바리케이드', {'강화 철판': 3}, 'def', ['기계 작업대'], hrs=6, dfn=4, dur=10)
rec('전기 울타리', {'철판': 2, '전자 부품': 1}, 'def', ['기계 작업대'], hrs=6, dfn=3, minus=1, dur=99, power=True)
rec('감시탑', {'강화 철판': 2, '목재': 4}, 'fac', ['바리케이드'], hrs=6)
rec('경보 사이렌', {'회로판': 1, '부품': 2}, 'fac', ['기계 작업대'], hrs=4)
rec('무전 중계기', {'회로판': 2, '축전지 팩': 1}, 'fac', ['무전 안테나'], hrs=6)
rec('방호복', {'방수포': 2, '고무': 3, '가죽': 2}, needs=['재봉대', '기계 작업대'], hrs=2)
rec('석궁', {'정밀 부품': 1, '목재': 2, '끈': 2}, needs=['기계 작업대'], hrs=2)
rec('연구대', {'회로판': 1, '유리': 2}, 'fac', ['의무실 침상'], bp=True, hrs=6)
rec('항생제', {'희귀 의약품': 1, '알코올': 1}, needs=['연구대'], hrs=1)
rec('정수 설비', {'철판': 3, '필터 카트리지': 2}, 'fac', ['증류기'], hrs=6)
rec('온실', {'유리': 6, '철판': 2}, 'fac', ['텃밭', '계단 보강'], hrs=6)
rec('필터 카트리지', {'숯': 2, '천': 1, '플라스틱': 1}, needs=['작업대 Lv2'], hrs=1)
rec('휴대 식량', {'통조림': 1}, needs=['화덕'], hrs=.25)

R_DEFAULT = {k: dict(v['cost']) for k, v in R.items()}
R_NEEDS = {k: list(v['needs']) for k, v in R.items()}
R_BP = {k: v['bp'] for k, v in R.items()}
JOBS = ['정비공', '달리기 선수', '간호사', '요리사', '전직 경찰', '농부']

# ---------------------------------------------------------------- events (base probs, notes 04-13)
# effect keys: h hours, L light injuries, S serious, loot +mult, rare extra rolls, tr trace, mo morale,
# bag fraction lost, items gained, use consumable, rec recruit offer, chain, nohorde, half, wet, hp team
def EV():
    E = []
    def ev(key, cond, choices):
        E.append(dict(key=key, cond=cond, ch=choices))
    ev('horde', lambda c: True, [
        dict(n='숨기', d=True, p=.85, tag='hide', bon=[('위장 망토', 10)], s=dict(h=2), f=dict(L=1, h=2)),
        dict(n='돌파', p=.55, tag='fight', bon=[('쇠파이프', 20), ('석궁', 25)], s=dict(loot=.2), f=dict(S=1)),
        dict(n='깡통 미끼', need='깡통 미끼', use='깡통 미끼', p=.80, s=dict(), f=dict(h=1)),
        dict(n='미끼 폭죽', need='미끼 폭죽', use='미끼 폭죽', p=1, s=dict(nohorde=1), f={}),
    ])
    ev('ambush', lambda c: c['loc'] in ('hardware', 'gas', 'subway'), [
        dict(n='내준다', d=True, p=1, s=dict(bag=.3), f={}),
        dict(n='도망', p=.60, tag='flee', bon=[('달리기 선수', 20)], s={}, f=dict(L=1, bag=.15)),
        dict(n='협상', needjob='전직 경찰', p=.70, s=dict(info=1), f=dict(bag=.3)),
        dict(n='맞선다', p=.45, tag='fight', bon=[('석궁', 20), ('쇠파이프', 10)],
             s=dict(items={'연료': 2, '고철': 3, '통조림': 2}, delay=1), f=dict(S=1, bag=.3)),
        dict(n='연막탄', need='연막탄', use='연막탄', p=1, s={}, f={}),
    ])
    ev('cache', lambda c: True, [
        dict(n='지나친다', d=True, p=1, s={}, f={}),
        dict(n='쇠지렛대', need='쇠지렛대', p=.80, s=dict(rare=1), f=dict(h=1)),
        dict(n='부순다', p=.65, tag='search', bon=[('정비공', 15)], s=dict(rare=1, tr=2), f=dict(tr=2, chain=('horde', .3))),
    ])
    ev('storm', lambda c: c['w'] in ('rain', 'acid', 'dust'), [
        dict(n='피신', d=True, p=1, s=dict(h=2), f={}),
        dict(n='장비 강행', needany=['방수 판초', '방호복'], p=.85, s={}, f=dict(wet=1)),
        dict(n='맨몸 강행', p=.45, bon=[('달리기 선수', 15)], s={}, f=dict(hp=15, wet=1)),
    ])
    ev('survivor', lambda c: True, [
        dict(n='나눠 준다', d=True, p=1, needfood=True, s=dict(mo=3, food=-1), f={}),
        dict(n='데려온다', p=.70, bon=[('간호사', 15), ('붕대', 10)], s=dict(rec=1, h=2), f=dict(chain=('ambush', 1))),
        dict(n='무시', d2=True, p=1, s=dict(mo=-3), f={}),
    ])
    ev('bridge', lambda c: c['loc'] in ('hardware', 'gas', 'down'), [
        dict(n='우회', d=True, p=1, s=dict(h=4), f={}),
        dict(n='갈고리', need='갈고리 밧줄', p=.90, s={}, f=dict(L=1, h=1)),
        dict(n='끈', need='끈', use='끈', p=.75, s={}, f=dict(L=1, h=1)),
        dict(n='뛴다', p=.55, bon=[('달리기 선수', 20)], s={}, f=dict(S=1)),
    ])
    ev('car', lambda c: c['loc'] in ('gas', 'subway'), [
        dict(n='필요한 것만', d=True, p=1, s=dict(items={'배터리': 1}), f={}),
        dict(n='다 싣는다', p=.60, bon=[('큰 가방', 15)], s=dict(items={'배터리': 3, '부품': 2}), f=dict(h=3)),
        dict(n='해체', needjobor=('정비공', '해체 공구 세트'), p=.75, s=dict(items={'부품': 3, '배터리': 1}), f=dict(h=2)),
    ])
    ev('tired', lambda c: c['tired'], [
        dict(n='쉰다', d=True, p=1, s=dict(h=2, rest=10), f={}),
        dict(n='업고 간다', p=.65, s={}, f=dict(L=1)),
    ])
    ev('cabinet', lambda c: c['loc'] in ('pharmacy', 'hospital'), [
        dict(n='지나친다', d=True, p=1, s={}, f={}),
        dict(n='깨뜨린다', p=.70, tag='search', s=dict(items={'화학품': 2}, med=.2), f=dict(L=1, tr=1)),
        dict(n='쇠지렛대', need='쇠지렛대', p=.85, s=dict(items={'화학품': 2}, med=.2), f=dict(h=1)),
        dict(n='라벨', needjob='간호사', p=.90, s=dict(items={'희귀 의약품': 1, '화학품': 1}), f=dict(h=1)),
    ])
    ev('tank', lambda c: c['loc'] == 'gas', [
        dict(n='퍼낸다', d=True, p=1, s=dict(items={'연료': 1}, h=2), f={}),
        dict(n='펌프', needjobor=('정비공', '해체 공구 세트'), p=.75, s=dict(fuel=4), f=dict(h=1)),
        dict(n='비튼다', need='쇠지렛대', p=.60, s=dict(items={'연료': 3}), f=dict(tr=2, L=1)),
    ])
    ev('dark', lambda c: c['loc'] in ('subway', 'down') and c['day'] >= STAGE2[0], [
        dict(n='돌아 나온다', d=True, p=1, s=dict(half=1), f={}),
        dict(n='불 비추기', needany=['손전등'], p=.80, s={}, f=dict(L=1)),
        dict(n='따라간다', p=.50, tag='search', bon=[('전직 경찰', 15), ('석궁', 15)], s=dict(rec=.5, rare=1), f=dict(S=1)),
    ])
    ev('crate', lambda c: c['day'] >= STAGE2[0], [
        dict(n='지켜본 뒤', d=True, p=.80, s=dict(h=2, items={'통조림': 4, '생수': 4}, bp=.3), f=dict(h=2)),
        dict(n='바로 연다', p=.55, s=dict(items={'통조림': 4, '생수': 4}, bp=.3), f=dict(chain=('ambush', 1))),
        dict(n='위장 망토', need='위장 망토', p=.90, s=dict(items={'통조림': 4, '생수': 4}, bp=.3), f=dict(chain=('ambush', 1))),
    ])
    return {e['key']: e for e in E}
EVENTS = EV()

VAL = dict(h=-1.5, L=-10, S=-30, loot=25, rare=8, tr=-2.5, mo=1, bag=-30, rec=25, hp=-.4, wet=-3,
           half=-15, nohorde=5, info=6, delay=6, med=40, bp=20, fuel=3, rest=0.3, food=-4)

# ---------------------------------------------------------------- world
class S:  # survivor
    _id = 0
    def __init__(self, job, stat=80):
        S._id += 1; self.id = S._id
        self.job = job; self.hp = stat; self.food = stat; self.water = stat; self.st = stat
        self.where = 'home'; self.inj = None; self.inj_h = 0; self.splint = False; self.infect_h = 0
        self.disinf = 0; self.sick = 0; self.upset = 0; self.down_h = None; self.alive = True
        self.cause = None; self.exp = None; self.sleeping = False; self.forced_sleep = 0

class World:
    def __init__(self, seed, policy, T=None):
        self.rng = random.Random(seed); self.policy = policy
        self.T = dict(BASE_T); self.T.update(T or {})
        STAGE2[0] = self.T['late_start']
        for k, v in R_DEFAULT.items(): R[k]['cost'] = dict(v)
        for k, v in self.T['recipe_cost'].items(): R[k]['cost'] = dict(v)
        for k, v in R_NEEDS.items(): R[k]['needs'] = list(v)
        for k, v in self.T['recipe_needs'].items(): R[k]['needs'] = list(v)
        for k, v in R_BP.items(): R[k]['bp'] = v
        for k in self.T.get('no_bp', []): R[k]['bp'] = False
        CUR_TBL[0] = self.T['day_tbl'] or DAY_TABLE
        import copy
        self.LOC = copy.deepcopy(LOC)
        for k, extra in self.T['loot_add'].items():
            self.LOC[k]['main'].update(extra)
        for k, extra in self.T['rare_add'].items():
            self.LOC[k]['rare'] += extra
        for k, rares in self.T['rare_set'].items():
            self.LOC[k]['rare'] = list(rares)
        if self.T['down_mid']: self.LOC['down']['st'] = 1
        self.day = 1; self.hour = 6
        self.inv = collections.Counter({'통조림': 8, '생수': 8, '오염수': 4, '고철': 6, '목재': 6, '천': 4,
                                        '플라스틱': 3, '연료': 3})
        self.raw = []  # (day_acquired, '식재료'/'작은 고기')
        self.inv.update(self.T['start_extra'])
        self.fac = collections.Counter({'작업대': 1, '빗물 집수기': 1})
        self.dfn = []  # defense facilities: dict(name, dur)
        self.bp = set(); self.filter_dur = 0
        self.ppl = [S('정비공'), S('달리기 선수'), S('간호사')]
        self.morale = 60; self.morale0_h = 0
        self.trace = 0; self.weather = make_weather(self.rng)
        self.visits = collections.defaultdict(int); self.lastv = {}; self.stock = {}
        self.raider_day = self.rng.randint(*self.T['raider_first']); self.raid_known = False
        self.revives = {}  # nurse id -> used
        self.log = collections.Counter(); self.daily = []
        self.food_types_today = set(); self.food_types_prev = set()
        self.cooks_today = 0; self.builds_today = 0
        self.joined = 0; self.deaths = 0; self.left = 0; self.bp_count = 0
        self.result = None; self.end_day = None; self.block = collections.Counter()
        self.garden_t = 0; self.events_seen = collections.Counter()
        self.signal = False; self.missing = []
        self.hunger_zero_h = 0
        self.wip = None; self.first = {}

    # -------- helpers
    def alive(self):
        return [p for p in self.ppl if p.alive]
    def home(self):
        return [p for p in self.ppl if p.alive and p.where == 'home']
    def has(self, item, n=1):
        return self.inv[item] >= n or self.fac[item] >= n or self.dcount(item) >= n
    def jobs_home(self, job):
        return any(p.job == job for p in self.home())
    def cap(self):
        return 6 + (2 if self.fac['계단 보강'] else 0)
    def food_units(self):
        return self.inv['통조림'] + len(self.raw) / 2 + self.inv['휴대 식량'] + self.inv['훈제 육포']
    def water_units(self):
        return self.inv['생수'] + self.inv['정수된 물'] + min(self.inv['오염수'], self.filter_dur)
    def food_days(self):
        n = max(1, len(self.alive()))
        return self.food_units() * 27 / (40 * n)

    # -------- crafting
    def can_build(self, name, count_block=True):
        r = R[name]
        if r['bp'] and name not in self.bp:
            if count_block: self.block['설계도:' + name] += 1
            return False
        for n in r['needs']:
            if not self.has(n):
                if count_block: self.block['선행:' + n] += 1
                return False
        for k, v in r['cost'].items():
            if self.inv[k] + (self.fac[k] if R.get(k, {}).get('kind') == 'fac' else 0) < v:
                if count_block: self.block['재료:' + k] += 1
                return False
        return True
    def do_build(self, name):
        r = R[name]
        for k, v in r['cost'].items():
            if R.get(k, {}).get('kind') == 'fac' and self.inv[k] < v:
                self.fac[k] -= v
            else:
                self.inv[k] -= v
        if r['kind'] == 'fac':
            self.fac[name] += 1; self.builds_today += 1; self.trace += 1
        elif r['kind'] == 'def':
            self.dfn.append(dict(name=name, dur=r['dur'])); self.builds_today += 1; self.trace += 1
        elif name == '정수 필터':
            self.filter_dur += self.T['filter']
        else:
            self.inv[name] += r.get('yields', 1)
        self.log['built:' + name] += 1
        self.first.setdefault(name, self.day)

    def dcount(self, name):
        return sum(1 for d in self.dfn if d['name'] == name)

    def wishlist(self):
        """ordered build targets (name, desired count) for the competent policy."""
        d = self.day; n = len(self.alive())
        W = [('망치', 1)]
        if self.filter_dur < 4: W.append(('정수 필터', 1))
        W += [('화덕', 1), ('붕대', 2), ('바리케이드', 1), ('끈', 1), ('깡통 경보기', 1)]
        if d >= 3: W += [('쇠지렛대', 1), ('부목', 1), ('못 판자', 1)]
        W += [('작업대 Lv2', 1), ('철판', 2), ('철조망', 1), ('보강 문', 1)]
        if self.weather.get(d + 1) in ('rain', 'acid') or d >= 6: W += [('방수 판초', 2)]
        W += [('방한 외투', 2), ('쇠파이프', 2), ('침상', min(n, 3)), ('손도끼', 1)]
        W += [('쥐덫', 1), ('텃밭', 1), ('깡통 미끼', 1), ('연료통', 1), ('계단 보강', 1), ('발전기', 1),
              ('증류기', 1), ('소독약', 1), ('충전 배터리', 1), ('손전등', 2), ('숯', 1), ('방독 마스크', 2),
              ('강화 철판', 2), ('회로판', 1), ('기계 작업대', 1),
              ('강화 철판', 3), ('강화 바리케이드', 1), ('전기 울타리', 1), ('강화 철판', 2), ('감시탑', 1),
              ('온실', 1), ('필터 카트리지', 2), ('정수 설비', 1), ('의무실 침상', 1), ('무전 안테나', 1), ('축전지 팩', 1), ('회로판', 2), ('무전 중계기', 1),
              ('재봉대', 1), ('봉합 키트', 1), ('미끼 폭죽', 1), ('연막탄', 1), ('갈고리 밧줄', 1),
              ('침상', n), ('철조망', 2), ('바리케이드', 2),
              ('훈연기', 1), ('방호복', 1), ('석궁', 2), ('연구대', 1), ('항생제', 1)]
        return W

    def have_count(self, name):
        r = R[name]
        if r['kind'] == 'fac': return self.fac[name]
        if r['kind'] == 'def': return self.dcount(name)
        if name == '정수 필터': return 1 if self.filter_dur >= 4 else 0
        return self.inv[name]

    def craft_hours(self, hours, worker):
        speed = 1.0 / (0.75 if worker.job == '정비공' else 1.0)
        if self.morale >= 80: speed *= 1.1
        elif self.morale < 30: speed *= 0.75
        if worker.inj == 'light': speed *= .9
        if worker.inj == 'serious': speed *= .5
        budget = hours * speed
        # repairs first (1h each, half materials)
        for dd in self.dfn:
            if budget <= 0: break
            if dd['dur'] <= 2 and R[dd['name']]['dur'] < 50:
                cost = {k: math.ceil(v / 2) for k, v in R[dd['name']]['cost'].items()}
                if all(self.inv[k] >= v for k, v in cost.items()):
                    for k, v in cost.items(): self.inv[k] -= v
                    dd['dur'] = R[dd['name']]['dur']; budget -= 1; self.log['repair'] += 1
        first = True
        while budget > 1e-9:
            if self.wip is None:
                pick = None
                reserved = set()
                for name, want in self.wishlist():
                    if self.have_count(name) >= want: continue
                    if set(R[name]['cost']) & reserved: continue
                    if self.can_build(name, count_block=first):
                        pick = name; break
                    first = False
                    # keep scarce materials for the higher-priority target that is waiting on them
                    if len(reserved) < 6 and not (R[name]['bp'] and name not in self.bp):
                        reserved |= {k for k, v in R[name]['cost'].items() if self.inv[k] < v * 2}
                if pick is None:
                    self.log['idle_h'] += budget; return
                # reserve materials now
                r = R[pick]
                for k, v in r['cost'].items():
                    if R.get(k, {}).get('kind') == 'fac' and self.inv[k] < v: self.fac[k] -= v
                    else: self.inv[k] -= v
                self.wip = [pick, r['hrs']]
            use = min(budget, self.wip[1]); self.wip[1] -= use; budget -= use
            if self.wip[1] <= 1e-9:
                self.finish_build(self.wip[0]); self.wip = None

    def finish_build(self, name):
        r = R[name]
        if r['kind'] == 'fac':
            self.fac[name] += 1; self.builds_today += 1; self.trace += 1
        elif r['kind'] == 'def':
            self.dfn.append(dict(name=name, dur=r['dur'])); self.builds_today += 1; self.trace += 1
        elif name == '정수 필터':
            self.filter_dur += self.T['filter']
        else:
            self.inv[name] += r.get('yields', 1)
        self.log['built:' + name] += 1
        self.first.setdefault(name, self.day)

    # -------- eating / drinking
    def eat(self, p):
        cook = 1.25 if p.job == '요리사' else 1.0
        # soup from raw ingredients first (spoils)
        veg = [x for x in self.raw if x[1] == '식재료']
        meat = [x for x in self.raw if x[1] == '작은 고기']
        if self.fac['화덕'] and len(meat) >= 2 and self.inv['목재'] + self.inv['연료'] > 2:
            for x in meat[:2]: self.raw.remove(x)
            self.use_fuel(1); p.food = min(100, p.food + 35 * cook); self.food_types_today.add('꼬치'); self.cooks_today += 1; return True
        if self.fac['화덕'] and len(veg) >= 2 and self.inv['정수된 물'] + self.inv['생수'] > 0:
            for x in veg[:2]: self.raw.remove(x)
            self.take_water_item()
            p.food = min(100, p.food + 40 * cook); p.water = min(100, p.water + 10)
            self.food_types_today.add('수프'); self.cooks_today += 1; return True
        if self.inv['훈제 육포']:
            self.inv['훈제 육포'] -= 1; p.food = min(100, p.food + 35 * cook); self.food_types_today.add('육포'); return True
        if self.inv['통조림']:
            self.inv['통조림'] -= 1
            if self.fac['화덕'] and self.inv['연료'] + self.inv['목재'] > 4:
                self.use_fuel(1); p.food = min(100, p.food + self.T['can'][1] * cook); self.food_types_today.add('데운 통조림'); self.cooks_today += 1
            else:
                p.food = min(100, p.food + self.T['can'][0] * cook); self.food_types_today.add('찬 통조림')
            return True
        if self.inv['휴대 식량']:
            self.inv['휴대 식량'] -= 1; p.food = min(100, p.food + 30); self.food_types_today.add('찬 통조림'); return True
        return False

    def use_fuel(self, n):
        for _ in range(n):
            if self.inv['목재'] > 3: self.inv['목재'] -= 1
            elif self.inv['연료']: self.inv['연료'] -= 1
            elif self.inv['목재']: self.inv['목재'] -= 1

    def take_water_item(self):
        for k in ('정수된 물', '생수'):
            if self.inv[k]:
                self.inv[k] -= 1; return True
        return False

    def drink(self, p):
        if self.take_water_item():
            p.water = min(100, p.water + 30); return True
        if self.inv['오염수'] and self.filter_dur > 0:
            self.inv['오염수'] -= 1; self.filter_dur -= 1; p.water = min(100, p.water + 30); return True
        if self.inv['오염수'] and self.fac['화덕'] and self.inv['목재'] + self.inv['연료'] > 0:
            self.inv['오염수'] -= 1; self.use_fuel(1); p.water = min(100, p.water + 30); self.log['boil'] += 1; return True
        if self.inv['오염수']:
            self.inv['오염수'] -= 1; p.water = min(100, p.water + 30)
            if self.rng.random() < .4: p.upset = 12; self.log['upset'] += 1
            return True
        return False

    # -------- injuries
    def injure(self, p, kind):
        if not p.alive: return
        if p.inj == 'serious' and kind == 'light': kind = 'serious'
        p.inj = kind if p.inj != 'infect' else 'infect'
        p.inj_h = 0; p.splint = False
        self.morale -= 5; self.log['inj:' + kind] += 1
        self.treat(p)

    def treat(self, p):
        nurse = 1.5 if self.jobs_home('간호사') else 1.0
        if p.where != 'home': return
        if p.inj == 'light' and self.inv['붕대']:
            self.inv['붕대'] -= 1; p.inj = None; p.hp = min(100, p.hp + 15 * nurse)
        elif p.inj == 'light' and self.inv['천'] >= 2:
            self.inv['천'] -= 2; p.inj = None; p.hp = min(100, p.hp + 15 * nurse)
        elif p.inj == 'serious':
            if self.inv['봉합 키트'] and self.fac['의무실 침상']:
                self.inv['봉합 키트'] -= 1; p.inj = None; p.splint = False
            elif not p.splint and (self.inv['부목'] or (self.inv['목재'] >= 1 and self.inv['천'] >= 1)):
                if self.inv['부목']: self.inv['부목'] -= 1
                else: self.inv['목재'] -= 1; self.inv['천'] -= 1
                p.splint = True
        elif p.inj == 'infect':
            if self.inv['항생제']:
                self.inv['항생제'] -= 1; p.inj = None
            elif self.inv['소독약'] and p.disinf <= 0:
                self.inv['소독약'] -= 1; p.disinf = 24  # one dose per day, 3 days to cure

    def injury_tick(self, p):
        if p.inj is None: return
        p.inj_h += 1
        if p.inj == 'light':
            if p.inj_h % 24 == 0 and self.rng.random() < .15: p.inj = 'infect'; p.inj_h = 0; self.log['infect'] += 1
            elif p.inj_h >= 72: p.inj = None
        elif p.inj == 'serious':
            p.hp -= 0.5 if not p.splint else 0.0
            # ASSUME: with a splint a serious injury heals on its own in 5 days
            if p.splint and p.inj_h >= 120: p.inj = None
            if not p.splint and p.inj_h == 24 and self.rng.random() < .5: p.inj = 'infect'; p.inj_h = 0; self.log['infect'] += 1
        elif p.inj == 'infect':
            if p.disinf > 0:
                p.disinf -= 1
                p.infect_h = getattr(p, 'infect_cure', 0) + 1; p.infect_cure = p.infect_h
                if p.infect_cure >= 72: p.inj = None; p.infect_cure = 0
            else:
                p.hp -= 1
                if p.inj_h >= 72: p.hp = 0

    # -------- expeditions
    def gear_bonus(self, team, item):
        return self.inv[item] > 0

    def choose_loc(self, team):
        d = self.day; st = stage(d)
        opts = []
        for k, L in self.LOC.items():
            if L['st'] > st: continue
            if any(self.inv[x] <= 0 for x in L.get('need', [])): continue
            if any(self.fac[x] <= 0 for x in L.get('needfac', [])): continue
            if L.get('team3') and len(team) < 3: continue
            opts.append(k)
        fd = self.food_days(); wd = self.water_units() / max(1, 2.2 * len(self.alive()))
        self.short = collections.Counter()
        k = 0
        for name, want in self.wishlist():
            if self.have_count(name) >= want: continue
            if R[name]['bp'] and name not in self.bp: continue
            for m, v in R[name]['cost'].items():
                if self.inv[m] < v: self.short[m] += 1
            k += 1
            if k >= 6: break
        def score(k):
            L = self.LOC[k]
            mult = self.depl(k)
            s = 0
            for item, (a, b) in L['main'].items():
                need = self.need_weight(item, fd, wd)
                s += need * (a + b) / 2 * mult
            for r in L['rare']:
                item = r[0]
                if item.startswith('BP') and item[2:] not in self.bp: s += 12 * r[2]
                elif item == 'SURVIVOR': s += 8 * r[2]
                else: s += self.need_weight(item, fd, wd) * r[1] * r[2]
            s /= L['hrs'] ** 0.5
            s *= (1 - L['inj'] * 2)
            return s
        return max(opts, key=score) if opts else None

    def need_weight(self, item, fd, wd):
        base = {'통조림': 3.0, '생수': 2.0, '식재료': 1.2, '플라스틱': .8, '천': .6, '고철': 1.4, '목재': 2.2,
                '부품': 1.6, '연료': 1.0, '화학품': .7, '유리': .6, '고무': .6, '배터리': .7, '배터리 셀': 1,
                '전자 부품': 1.2, '정밀 부품': 1.6, '희귀 의약품': 1, '끈': .8, '가죽': .5, '씨앗': 1,
                '태양광 셀': .3, '방한 외투': 2}
        w = base.get(item, .5)
        if item in ('통조림', '식재료'): w *= 3 if fd < 2 else (1.5 if fd < 4 else .7)
        if item == '생수': w *= 3 if wd < 1.5 else (1.2 if wd < 3 else .4)
        if self.inv[item] > 25: w *= .3
        w += 1.5 * min(2, getattr(self, 'short', {}).get(item, 0))
        return w

    def depl(self, k):
        if self.T['regen']:
            # stock model: each visit -20% (min 30%), regrows by `regen` per day without visits
            if k not in self.lastv: return 1.0
            return min(1.0, self.stock[k] + self.T['regen'] * (self.day - self.lastv[k]))
        if k in self.lastv and self.day - self.lastv[k] >= 7: self.visits[k] = 0
        return max(.3, 1 - .2 * self.visits[k])

    def dispatch(self):
        d = self.day; w = self.weather[d]
        if d >= DAYS: return
        if self.T['teams'] == 'antenna':
            teams_max = 2 if self.fac['무전 안테나'] else 1
        else:
            na = len(self.alive())
            teams_max = 1 if na <= 3 else (3 if na >= 6 and self.fac['무전 안테나'] else 2)
        active = len({p.exp['tid'] for p in self.alive() if p.exp})
        if active >= teams_max: return
        desperate = self.food_days() < 1 or self.water_units() < len(self.alive())
        lim = 15 if desperate else 40
        avail = [p for p in self.home() if p.inj not in ('serious', 'infect') and p.hp >= (30 if desperate else 50)
                 and p.sick <= 0 and p.st >= (30 if desperate else 45) and p.food >= lim and p.water >= lim]
        if w == 'cold': avail = [p for p in avail][:self.inv['방한 외투']]
        if w == 'acid' and self.inv['방수 판초'] + self.inv['방호복'] < 1: return
        if w == 'dust' and self.inv['방독 마스크'] < 1: return
        n_home = len(self.home())
        keep = 1  # one person stays to build and guard
        size = min(3, len(avail), n_home - keep)
        if size < 1: return
        if size == 3 and n_home - 3 < 1: size = 2
        if size >= 2 or (size == 1 and len(self.alive()) <= 2):
            pass
        # prefer runner/able bodies; keep 정비공 at home if possible
        avail.sort(key=lambda p: (p.job == '정비공', p.inj is not None, -p.hp))
        team = avail[:size]
        loc = self.choose_loc(team)
        if not loc: return
        L = self.LOC[loc]
        hrs = L['hrs'] * (0.75 if any(p.job == '달리기 선수' for p in team) else 1)
        if self.inv['가죽 장화']: hrs *= .9
        if self.hour + hrs > 21 and self.hour > 7: return  # don't start a trip that returns after dark
        tid = self.rng.random()
        ex = dict(tid=tid, loc=loc, t=0, hrs=hrs, events=[], team=team, loot=collections.Counter(), mult=0,
                  rare_extra=0, bonus_items=collections.Counter(), half=False, nohorde=False, inj_add=0)
        n_ev = 0
        if d >= 6:
            n_ev = 1 + (1 if self.rng.random() < .3 else 0)
            ex['events'] = sorted(self.rng.uniform(1, hrs - .5) for _ in range(n_ev))
        for p in team:
            p.where = 'exp'; p.exp = ex
            # pack 1 ration + 1 water each when stock allows
            p.pack_food = 1 if self.inv['통조림'] > len(self.alive()) else 0
            self.inv['통조림'] -= p.pack_food
            p.pack_water = 1 if self.inv['생수'] + self.inv['정수된 물'] > len(self.alive()) else 0
            if p.pack_water: self.take_water_item()
        self.visits_pending = loc
        self.log['exp:' + loc] += 1

    def roll_loot(self, ex):
        L = self.LOC[ex['loc']]; team = [p for p in ex['team'] if p.alive]
        n = max(1, len(team))
        mult = TEAM_LOOT[min(3, n)] * self.depl(ex['loc']) * (1 + ex['mult'])
        if ex['half']: mult *= .5
        got = collections.Counter()
        for item, (a, b) in L['main'].items():
            x = self.rng.uniform(a, b + .999) // 1 * mult
            if item == '연료' and self.inv['연료통']: x *= 2
            if item == '식재료' and any(p.job == '농부' for p in team): x += 2
            got[item] += int(round(x))
        if self.inv['손도끼'] and n: got['목재'] += 2
        if any(p.job == '정비공' for p in team) and '부품' in L['main']: got['부품'] += 1
        for _ in range(1 + ex['rare_extra']):
            for r in L['rare']:
                if len(r) > 3 and r[3] == 'mid' and self.day < 6: continue
                if self.rng.random() < r[2]:
                    item = r[0]
                    if item.startswith('BP'):
                        name = item[2:]
                        if name in self.bp: got['부품'] += 2
                        else: self.bp.add(name); self.bp_count += 1; self.morale += 8; self.log['bp:' + name] += 1
                    elif item == 'SURVIVOR':
                        self.offer_recruit()
                    else:
                        got[item] += max(1, int(round(r[1])))
        got += ex['bonus_items']
        return got

    def offer_recruit(self):
        if len(self.alive()) >= self.cap(): return
        if self.food_days() < 2: self.log['recruit_declined'] += 1; return
        missing = [j for j in JOBS if not any(p.job == j and p.alive for p in self.ppl)]
        if self.rng.random() < .2: job = '일반인'
        else:
            weights = [2 if j in missing else 1 for j in JOBS]
            job = self.rng.choices(JOBS, weights)[0]
        p = S(job, 40)
        if job == '일반인': p.hp = p.food = p.water = p.st = 50
        if self.rng.random() < .3: p.inj = 'light'
        self.ppl.append(p); self.joined += 1; self.morale += 5; self.log['joined'] += 1

    def event_prob(self, ch, ex):
        if ch['p'] >= 1: return 1.0
        team = [p for p in ex['team'] if p.alive]
        p = ch['p'] * 100
        for item, b in ch.get('bon', []):
            if item in JOBS:
                if any(x.job == item for x in team): p += b
            elif self.inv[item] > 0: p += b
        p += {1: 0, 2: 5}.get(len(team), 10)
        p += drow(self.day)[5] or 0
        if any(x.hp <= 29 for x in team): p -= 10
        if self.weather[self.day] == 'fog':
            if ch.get('tag') in ('hide', 'flee'): p += 10
            if ch.get('tag') in ('fight', 'search'): p -= 10
        return max(35, min(95, p)) / 100

    def available(self, ch, ex):
        team = [p for p in ex['team'] if p.alive]
        if 'need' in ch and self.inv[ch['need']] <= 0: return False
        if 'needany' in ch and not any(self.inv[x] > 0 for x in ch['needany']): return False
        if 'needjob' in ch and not any(p.job == ch['needjob'] for p in team): return False
        if 'needjobor' in ch:
            j, it = ch['needjobor']
            if not (any(p.job == j for p in team) or self.inv[it] > 0): return False
        if ch.get('needfood') and self.inv['통조림'] < 1 and not any(getattr(p, 'pack_food', 0) for p in team): return False
        return True

    def value(self, eff):
        return sum(VAL.get(k, 0) * (v if not isinstance(v, (dict, tuple)) else 1) for k, v in eff.items()
                   if k not in ('items', 'chain')) + sum(v * 1.5 for v in eff.get('items', {}).values()) \
               + (-20 * eff['chain'][1] if 'chain' in eff else 0)

    def run_event(self, ex, key=None, depth=0):
        team = [p for p in ex['team'] if p.alive]
        if not team: return
        ctx = dict(loc=ex['loc'], w=self.weather[self.day], day=self.day,
                   tired=any(min(p.food, p.water, p.st) <= 29 for p in team))
        if key is None:
            pool = [k for k, e in EVENTS.items() if e['cond'](ctx) and not (k == 'horde' and ex['nohorde'])]
            key = self.rng.choice(pool)
        e = EVENTS[key]; self.events_seen[key] += 1
        chs = [c for c in e['ch'] if self.available(c, ex)]
        if not chs: return
        default = next((c for c in chs if c.get('d')), None) or next((c for c in chs if c.get('d2')), chs[0])
        if self.policy == 'noanswer':
            ch = default
        else:
            ch = max(chs, key=lambda c: self.event_prob(c, ex) * self.value(c['s'])
                     + (1 - self.event_prob(c, ex)) * self.value(c['f']))
        pr = self.event_prob(ch, ex)
        ok = self.rng.random() < pr
        self.log['ev_ok' if ok else 'ev_fail'] += 1
        if ch['p'] < 1: self.log['ev_rolls'] += 1; self.log['ev_roll_ok'] += ok
        if ch.get('use'): self.inv[ch['use']] -= 1
        eff = ch['s'] if ok else ch['f']
        self.apply_eff(ex, eff, depth)

    def apply_eff(self, ex, eff, depth):
        team = [p for p in ex['team'] if p.alive]
        ex['hrs'] += eff.get('h', 0)
        for _ in range(eff.get('L', 0)):
            p = self.rng.choice(team)
            if self.inv['붕대']: self.inv['붕대'] -= 1; self.morale -= 5; self.log['inj:light_auto'] += 1
            else: self.injure(p, 'light')
        for _ in range(eff.get('S', 0)):
            self.injure(self.rng.choice(team), 'serious')
        ex['mult'] += eff.get('loot', 0); ex['rare_extra'] += eff.get('rare', 0)
        self.trace += eff.get('tr', 0); self.morale += eff.get('mo', 0)
        if eff.get('bag'): ex['bagloss'] = max(ex.get('bagloss', 0), eff['bag'])
        for k, v in eff.get('items', {}).items(): ex['bonus_items'][k] += v
        if eff.get('fuel'): ex['bonus_items']['연료'] += eff['fuel'] * (2 if self.inv['연료통'] else 1)
        if eff.get('med') and self.rng.random() < eff['med']: ex['bonus_items']['희귀 의약품'] += 1
        if eff.get('bp') and self.rng.random() < eff['bp']:
            cand = [b for b in ('작업대 Lv2', '재봉대', '증류기', '기계 작업대', '연구대') if b not in self.bp]
            if cand: b = self.rng.choice(cand); self.bp.add(b); self.bp_count += 1; self.morale += 8
        if eff.get('rec') and self.rng.random() < eff['rec']: self.offer_recruit()
        if eff.get('half'): ex['half'] = True
        if eff.get('nohorde'): ex['nohorde'] = True
        if eff.get('delay'): self.raider_day += 1
        if eff.get('food'):
            if self.inv['통조림']: self.inv['통조림'] -= 1
        if eff.get('hp'):
            for p in team: p.hp -= eff['hp']
        if eff.get('rest'):
            for p in team: p.st = min(100, p.st + eff['rest'])
        if 'chain' in eff and depth < 2 and self.rng.random() < eff['chain'][1]:
            self.run_event(ex, eff['chain'][0], depth + 1)

    def exp_tick(self, ex):
        ex['t'] += 1
        while ex['events'] and ex['events'][0] <= ex['t']:
            ex['events'].pop(0); self.run_event(ex)
        team = [p for p in ex['team'] if p.alive]
        for p in team:
            if p.hp <= 0 and p.down_h is None:
                # collapse outside
                p.alive = False if not self.inv['진통 주사'] else True
                if not p.alive:
                    p.cause = '원정 중 실종'; self.missing.append((p, self.day)); p.where = 'missing'
                    self.log['missing'] += 1
        if ex['t'] >= ex['hrs'] or not [p for p in ex['team'] if p.alive]:
            self.finish_exp(ex)

    def finish_exp(self, ex):
        team = [p for p in ex['team'] if p.alive]
        loc = ex['loc']
        got = self.roll_loot(ex) if team else collections.Counter()
        if ex.get('bagloss'):
            for k in list(got): got[k] = int(got[k] * (1 - ex['bagloss']))
        for k, v in got.items():
            if k in ('식재료', '작은 고기'):
                self.raw += [(self.day, k)] * v
            else:
                self.inv[k] += v
        self.stock[loc] = max(.3, self.depl(loc) - .2)
        self.visits[loc] += 1; self.lastv[loc] = self.day
        # injury roll
        base = self.LOC[loc]['inj'] * TEAM_INJ[min(3, max(1, len(team)))] + drow(self.day)[4]
        for p in team:
            pr = base
            if any(x.job == '간호사' for x in team): pr *= .7
            if self.inv['덧댄 작업복']: pr *= .9
            if self.inv['가죽 장화']: pr *= .8
            if self.rng.random() < pr:
                if self.inv['붕대'] and self.rng.random() < .8:
                    self.inv['붕대'] -= 1; self.morale -= 5; self.log['inj:light_auto'] += 1
                else:
                    self.injure(p, 'light' if self.rng.random() < .8 else 'serious')
        if self.hour >= 21 or self.hour < 6: self.trace += 1
        for p in team:
            p.where = 'home'; p.exp = None
            if getattr(p, 'pack_food', 0): self.inv['통조림'] += 1; p.pack_food = 0
            if getattr(p, 'pack_water', 0): self.inv['생수'] += 1; p.pack_water = 0
            self.treat(p)
        self.log['loot_total'] += sum(got.values())

    # -------- night raid
    def night(self):
        d = self.day; w = self.weather[d]
        home = [p for p in self.home() if p.hp > 29]
        has_alarm = self.fac['깡통 경보기'] or self.fac['경보 사이렌']
        guards = len(home) if has_alarm else min(1, len(home))
        guards = min(guards, self.T['guard_cap'])
        gval = sum(2 if p.job == '전직 경찰' else 1 for p in home[:guards]) if home else 0
        weap = min(guards, self.inv['쇠파이프'] + 2 * self.inv['석궁'])
        dfn = sum(R[x['name']]['dfn'] for x in self.dfn if not (R[x['name']].get('power') and self.inv['연료'] < 1))
        if self.fac['감시탑']: gval = int(gval * 1.5)
        defense = dfn + gval + weap
        minus = sum(R[x['name']].get('minus', 0) for x in self.dfn if not (R[x['name']].get('power') and self.inv['연료'] < 1))
        if any(R[x['name']].get('power') for x in self.dfn) and self.inv['연료']:
            self.inv['연료'] -= 1  # ASSUME ~ one fuel powers the fence for a night
        raids = []
        # infected
        pch = min(.9, self.T['inf_base'] * (stage(d) > 0) + self.trace * .05)
        if w == 'rain': pch /= 2
        if d == DAYS - 1: pch = 1.0
        if self.rng.random() < pch:
            st = drow(d)[2] + self.trace // 5 + (1 if w == 'fog' else 0) - (2 if w == 'dust' else 0) - minus
            if d == DAYS - 1: st += 3
            raids.append(('inf', st))
        if d >= 6 and d == self.raider_day:
            st = drow(d)[3] if not self.T['raider_tbl'] else self.T['raider_tbl'](d)
            if self.fac['경보 사이렌']: st -= 1
            raids.append(('raid', st))
            self.raider_day = d + self.rng.randint(4, 6)
        for kind, st in raids:
            if self.inv['가시 함정']: self.inv['가시 함정'] -= 1; st -= 2
            m = defense - st
            self.log[f'raid_{kind}'] += 1
            self.daily_raid.append((kind, st, defense, m))
            if m >= 2:
                self.log['raid_perfect'] += 1
                if kind == 'inf': self.trace = max(0, self.trace - 2)
            elif m >= 0:
                self.log['raid_hold'] += 1
                if home and self.rng.random() < .3: self.injure(self.rng.choice(home), 'light')
                self.wear_def(1)
            elif m >= -2:
                self.log['raid_partial'] += 1
                for p in home[:max(1, guards)]:
                    if self.rng.random() < .6: self.injure(p, 'serious' if self.rng.random() < .25 else 'light')
                if kind == 'raid': self.steal(.10)
                else: self.break_fac(1)
            else:
                self.log['raid_breach'] += 1
                victims = self.rng.sample(self.home(), min(len(self.home()), self.rng.randint(1, 2))) if self.home() else []
                for p in victims: self.injure(p, 'serious')
                self.steal(.25); self.break_fac(self.rng.randint(1, 2)); self.morale -= 10
            for x in self.dfn:
                if x['name'] == '못 판자': x['dur'] -= 1
            self.dfn = [x for x in self.dfn if x['dur'] > 0]

    def wear_def(self, n):
        if self.dfn:
            self.rng.choice(self.dfn)['dur'] -= n
            self.dfn = [x for x in self.dfn if x['dur'] > 0]

    def steal(self, f):
        for k in list(self.inv):
            self.inv[k] -= int(self.inv[k] * f)
        self.raw = self.raw[int(len(self.raw) * f):]
        self.log['stolen'] += 1

    def break_fac(self, n):
        cands = [k for k, v in self.fac.items() if v > 0 and k not in ('작업대', '빗물 집수기')]
        cands += ['DEF'] * len(self.dfn)
        for _ in range(n):
            if not cands: return
            k = self.rng.choice(cands)
            if k == 'DEF' and self.dfn:
                self.dfn.pop(self.rng.randrange(len(self.dfn)))
            elif k != 'DEF':
                self.fac[k] -= 1
                self.log['fac_broken'] += 1
                # ASSUME: rebuilt later at half cost through wishlist (simplified: refund half the materials)
                for kk, v in R[k]['cost'].items():
                    if R.get(kk, {}).get('kind') != 'fac': self.inv[kk] += v // 2
            cands = [c for c in cands if c != k] if k != 'DEF' else cands

    # -------- main loop
    def morning(self):
        d = self.day; w = self.weather[d]
        # trace decay
        self.trace = max(0, self.trace - 3 - (2 if w == 'rain' else 0))
        # daily morale from food variety (yesterday)
        if len(self.food_types_today) >= 2: self.morale += 2
        elif self.food_types_today and self.food_types_today == self.food_types_prev and not self.jobs_home('요리사'):
            self.morale -= 3
        if self.cooks_today >= 3: self.trace += 1
        self.food_types_prev = self.food_types_today; self.food_types_today = set(); self.cooks_today = 0
        # rain water
        self.inv['오염수'] += self.T['rain_wet'] if w == 'rain' else self.T['rain']
        # spoilage
        keep = []
        for (dd, k) in self.raw:
            life = 3 if k == '식재료' else 1
            if w == 'heat': life /= 2
            if d - dd <= life: keep.append((dd, k))
            else: self.log['spoiled'] += 1
        self.raw = keep
        # garden / trap
        if self.fac['쥐덫']:
            self.raw += [(d, '작은 고기')] * self.rng.randint(0, 2) + ([(d, '작은 고기')] if self.jobs_home('농부') else [])
            self.trace += 1
        if self.fac['텃밭'] and w != 'acid':
            self.garden_t += 1
            if self.garden_t % self.T['garden'][0] == 0:
                g = self.T['garden'][1]
                self.raw += [(d, '식재료')] * (int(g * 1.5) if self.jobs_home('농부') else g)
        if self.fac['온실'] and d % 2 == 0:
            self.raw += [(d, '식재료')] * 4
        if self.fac['정수 설비']:
            self.inv['정수된 물'] += 10
        # visitors
        if d >= 6 and self.rng.random() < (.10 if self.fac['무전 안테나'] else .05):
            self.offer_recruit()
        # missing search: ASSUME a 6h search finds the missing person 60% of the time within 2 days
        still = []
        for p, dd in self.missing:
            if d - dd <= 2 and self.rng.random() < .6 * (1 if len(self.home()) >= 2 else .5):
                p.alive = True; p.where = 'home'; p.hp = 20; p.exp = None; self.log['found'] += 1
            elif d - dd > 2:
                p.cause = '원정 중 실종'; self.deaths += 1; self.morale -= 25; self.log['death:missing'] += 1
            else:
                still.append((p, dd))
        self.missing = still
        if self.fac['무전 중계기']: self.signal = True

    def tick(self):
        h = self.hour; d = self.day; w = self.weather[d]
        if h == 6: self.morning()
        if 7 <= h <= 15: self.dispatch()
        night = h >= 22 or h < 6
        self.cur_builder = self.builder()
        home = self.home()
        # workers: one builder during 8-20 if not resting
        has_alarm = self.fac['깡통 경보기'] or self.fac['경보 사이렌']
        for p in self.ppl:
            if not p.alive or p.where in ('missing',): continue
            if p.down_h is not None:
                p.down_h += 1
                nurse = next((x for x in self.home() if x.job == '간호사' and x is not p and not self.revives.get(x.id)), None)
                if nurse and p.where == 'home':
                    self.revives[nurse.id] = True; p.down_h = None
                    p.hp = 60 if self.inv['수술 도구 세트'] else 30; self.log['revive'] += 1
                elif p.down_h >= 6:
                    p.alive = False; self.deaths += 1; self.morale -= 25; self.log['death:' + (p.cause or '?')] += 1
                continue
            if p.where == 'exp':
                act = 'exp'
            elif night:
                act = 'sleep'
            elif 9 <= h < 17 and p.hp > 29 and p.st > 30 and p is self.cur_builder:
                act = 'work'
            else:
                act = 'rest'
            f, wa, st = (self.T['decay'] or DECAY)[act]
            if w == 'heat': wa *= 2
            if p.upset > 0: wa += 2; p.upset -= 1
            if p.job == '달리기 선수': st *= .8
            if act == 'exp' and self.inv['물통']: wa *= .75
            if act == 'exp' and w in ('rain',) and self.inv['방수 판초'] < 1: st *= 1.5
            p.food = max(0, p.food - f); p.water = max(0, p.water - wa); p.st = max(0, p.st - st)
            if act == 'sleep':
                gain = SLEEP_GAIN['bed'] if self.beds_for(p) else SLEEP_GAIN['floor']
                if self.inv['침낭'] and gain < 8: gain = 8
                if p.sick > 0: gain /= 2
                if p.inj == 'infect': gain /= 2
                p.st = min(100, p.st + gain)
            if act == 'work':
                self.craft_hours(1, p)
            # eat / drink
            if p.where == 'home':
                if p.food < 50: self.eat(p)
                if p.water < 50: self.drink(p)
            else:
                if p.food < 40 and getattr(p, 'pack_food', 0): p.pack_food = 0; p.food += 25
                if p.water < 40 and getattr(p, 'pack_water', 0): p.pack_water = 0; p.water += 30
            # health
            dmg = (2 if p.food <= 0 else 0) + (4 if p.water <= 0 else 0)
            if dmg:
                p.hp -= dmg; p.cause = '굶주림·갈증'
                if p.food <= 0 or p.water <= 0: self.log['starving_h'] += 1
            elif p.where == 'home' and act in ('rest', 'sleep') and p.food >= 50 and p.water >= 50 and p.inj is None:
                p.hp = min(100, p.hp + 1)
            if p.inj:
                before = p.inj
                self.injury_tick(p)
                if p.hp <= 0 and dmg == 0: p.cause = '부상·감염'
                if p.where == 'home' and p.inj: self.treat(p)
            if p.sick > 0: p.sick -= 1
            # cold weather at night without fire
            if w == 'cold' and night and p.where == 'home' and not self.fire_on:
                pr = .05 * (.5 if (self.inv['방한 외투'] or self.inv['침낭']) else 1)
                if p.sick <= 0 and self.rng.random() < pr: p.sick = 48; self.log['cold_sick'] += 1
            if p.st <= 0 and act != 'sleep':
                self.morale -= 2; p.st = 10
            if p.hp <= 0 and p.alive and p.down_h is None and p.where == 'home':
                p.down_h = 0
        # expeditions progress
        for ex in {id(p.exp): p.exp for p in self.ppl if p.alive and p.exp}.values():
            self.exp_tick(ex)
        # night fire in cold weather
        if h == 21:
            self.fire_on = False
            if w == 'cold' and self.fac['화덕'] and self.inv['목재'] + self.inv['연료'] >= 2:
                self.use_fuel(2); self.fire_on = True; self.trace += 1
            self.daily_raid = []
            self.night()
        # morale bounds & collapse
        self.morale = max(0, min(100, self.morale))
        if self.morale <= 0:
            self.morale0_h += 1
            if h == 6 and self.rng.random() < .2 and self.home():
                q = self.rng.choice(self.home()); q.alive = False; q.cause = '떠남'; self.left += 1; self.log['left'] += 1
        else:
            self.morale0_h = 0
        # advance
        self.hour += 1
        if self.hour == 24:
            self.hour = 0
            self.snapshot()
            self.day += 1

    def beds_for(self, p):
        sleepers = [x for x in self.home()]
        try: idx = sleepers.index(p)
        except ValueError: return False
        return idx < self.fac['침상'] + self.fac['의무실 침상']

    def builder(self):
        cands = [p for p in self.home() if p.hp > 29 and p.st > 30 and p.down_h is None]
        if not cands: return None
        cands.sort(key=lambda p: (p.job != '정비공', p.inj is not None))
        return cands[0]

    def snapshot(self):
        self.daily.append(dict(day=self.day, alive=len([p for p in self.ppl if p.alive]),
                               food=self.food_units(), water=self.water_units(), morale=self.morale,
                               trace=self.trace,
                               defense=sum(R[x['name']]['dfn'] for x in self.dfn),
                               wood=self.inv['목재'], scrap=self.inv['고철'], parts=self.inv['부품'],
                               raids=list(getattr(self, 'daily_raid', []))))

    def run(self):
        self.fire_on = False; self.daily_raid = []
        while self.day <= DAYS:
            if self.day == DAYS and self.hour == (6 if self.signal else 12):
                break
            self.tick()
            if not self.alive() and not self.missing:
                self.result = '전멸'; break
            if self.morale0_h >= 24:
                self.result = '거점 붕괴'; break
        if self.result is None:
            self.result = '승리' if self.home() else '전멸'
        self.end_day = min(self.day, DAYS)
        return self.score()

    def score(self):
        win = self.result == '승리'
        boarded = len(self.home()) if win else 0
        food = self.inv['통조림'] + self.inv['생수'] + self.inv['정수된 물'] + len(self.raw)
        mats = sum(v for k, v in self.inv.items() if k in ('고철', '목재', '천', '플라스틱', '화학품', '연료', '부품', '유리', '고무',
                                                             '가죽', '전자 부품', '정밀 부품', '배터리 셀', '배터리', '오염수'))
        proc = sum(v for k, v in self.inv.items() if k in ('끈', '철판', '숯', '알코올', '방수포', '강화 철판', '회로판', '축전지 팩'))
        sc = (self.end_day if not win else DAYS) * 100 + (3000 if win else 0) + (500 if (win and self.signal) else 0) \
             + boarded * 500 + self.joined * 200 - self.deaths * 300 + food * 5 + mats + proc * 3 + self.bp_count * 50
        grade = 'S' if sc >= 12000 else 'A' if sc >= 8000 else 'B' if sc >= 4000 else 'C'
        return dict(result=self.result, day=self.end_day, score=sc, grade=grade, boarded=boarded,
                    deaths=self.deaths, joined=self.joined, left=self.left, bp=self.bp_count)


def run_many(n, policy, seed0=0, T=None):
    out = []
    for i in range(n):
        w = World(seed0 + i, policy, T)
        r = w.run()
        r['log'] = w.log; r['daily'] = w.daily; r['block'] = w.block; r['events'] = w.events_seen
        r['first'] = w.first; r['fac'] = dict(w.fac); r['morale_end'] = w.morale; r['dfn'] = [x['name'] for x in w.dfn]; r['inv'] = dict(w.inv)
        out.append(r)
    return out

if __name__ == '__main__':
    pol = sys.argv[1] if len(sys.argv) > 1 else 'smart'
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 200
    res = run_many(n, pol)
    c = collections.Counter(r['result'] for r in res)
    print(pol, dict(c))
