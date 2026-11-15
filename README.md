# Rooftop Haven (루프톱 헤이븐, 가제)

무너진 도시의 옥상 거점에서 생존 도구와 음식, 의류를 만들고, 생존자를 폐허로 보내 재료를 구해 오게 하는 스팀용 생존 경영 게임의 Godot 프로젝트.

- 컨셉·개발 단계 노트: `D:\workspace\obsidian\rooftop-haven` (01-컨셉, 02-개발단계, 03-참고자료)

## 여는 방법

1. Godot 4.7 (Standard, GDScript 버전)을 설치한다.
2. Godot 프로젝트 매니저에서 **Import** → 이 폴더의 `project.godot`을 선택한다.
3. F5로 실행하면 회색 옥상과 실시간 게임 시계(DAY · 시각 · 시간대)가 뜬다.

## 프로젝트 설정

| 항목 | 값 | 이유 |
| --- | --- | --- |
| 기본 해상도 | 640×360 | 픽셀아트 기준 해상도. 16:9 |
| 창 크기 | 1280×720 (정수 배율 확대) | 1080p에서는 3배, 1440p에서는 4배로 픽셀이 반듯하게 커짐 |
| 텍스처 필터 | Nearest | 픽셀이 뭉개지지 않게 |
| 2D 픽셀 스냅 | 켬 | 움직일 때 픽셀이 흔들리지 않게 |
| 렌더러 | GL Compatibility | 2D 위주, 저사양 PC 호환 |
| 언어 | 영어(기본), 한국어 | `localization/translations.csv` |

## 폴더 구조

```
src/
  autoload/game_clock.gd   실시간 게임 시계 (일시정지 없음, 배속 변수만 있음)
  main/main.tscn, main.gd  시작 장면 (회색 박스 프로토타입)
assets/                    sprites, tiles, ui, fonts, audio (sfx, music)
data/                      레시피·장소·사건 데이터 (예정)
localization/              번역 CSV (keys, en, ko)
docs/                      기술 메모
```

## 게임 시계 규칙

- 게임 1분 = 실제 0.5초, 하루 = 실제 12분 (`seconds_per_game_minute`로 조정)
- 시작 시각: 1일차 06:00
- 시간대: 아침 06–12, 낮 12–18, 저녁 18–21, 밤 21–06
- 신호: `minute_changed`, `hour_changed`, `day_started`, `phase_changed`

## 다음 할 일

- 1단계 수치 설계: 생존 수치, 레시피, 원정 장소 데이터를 `data/`에 정리
- 2단계 회색 박스: 생존 수치 → 제작 5개 → 의뢰 1곳 → 무전 사건 3개 → 귀환 → 밤 습격
