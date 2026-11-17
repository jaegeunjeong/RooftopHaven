# balance-sim

Rooftop Haven 30일 균형 시뮬레이터 (1단계 수치 설계 검증용, Python 3 표준 라이브러리만 사용).

```
python3 exp.py <시나리오> <smart|noanswer> <판 수>
python3 exp.py current smart 400     # 노트의 현재 수치
python3 exp.py proposal smart 400    # 1차 조정안
python3 exp.py proposal noanswer 400 # 무전에 응답하지 않는 플레이어
```

- 시나리오: current, consume, proposal (1차 조정안), round2 (2차 변경 4개), round2_fix (2차 + 계단 보강·목재 보정), proposal_nofood, generous (`exp.py`의 SCENARIOS)
- 수치는 `sim.py` 위쪽 상수와 `BASE_T`, 시나리오 dict에서 바꾼다.
- 결과 해석과 가정은 Obsidian `05-시뮬레이션/05-01 1차 30일 시뮬레이션` 노트 참고.
