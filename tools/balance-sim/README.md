# balance-sim

Rooftop Haven 30일 균형 시뮬레이터 (1단계 수치 설계 검증용, Python 3 표준 라이브러리만 사용).

```
python3 exp.py <시나리오> <smart|noanswer> <판 수>
python3 exp.py current smart 400     # 노트의 현재 수치
python3 exp.py proposal smart 400    # 1차 조정안
python3 exp.py proposal noanswer 400 # 무전에 응답하지 않는 플레이어
```

- 시나리오: round4s (4차: 시설 내림 + 해체 작업), round4 (시설만 내림), round3 (3차: 후반 습격·약국), current, consume, proposal (1차 조정안), round2 (2차 변경 4개), round2_fix (2차 + 계단 보강·목재 보정), proposal_nofood, generous (`exp.py`의 SCENARIOS)
- 수치는 `sim.py` 위쪽 상수와 `BASE_T`, 시나리오 dict에서 바꾼다.
- 결과 해석과 가정은 Obsidian `05-시뮬레이션/05-01 1차 30일 시뮬레이션` 노트 참고.
- `prio.py`: 후반 시설 하나씩 우선해서 지을 때 몇 일째에 지어지는지 확인
- `fun.py <시나리오...>`: 단계별로 지은 시설 수, 새 시설이 생긴 날 수, 짓는 사람이 쉰 시간
