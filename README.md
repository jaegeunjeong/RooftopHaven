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
  autoload/game_data.gd    data/*.json을 읽고 서로 맞는지 검사 (GameData)
  autoload/game_state.gd   한 판의 상태: 생존자, 창고, 사기, 흔적, 날씨, 승패 (GameState)
  survivor/survivor.gd     생존자 한 명 (막대 4개와 상태)
  main/main.tscn, main.gd  시작 장면 (회색 박스 프로토타입 화면)
tests/                     헤드리스 검사 (tests/test_runner.tscn)
assets/                    sprites, tiles, ui, fonts, audio (sfx, music)
data/                      게임 숫자 전부 (재료, 시설, 레시피, 장소, 사건, 생존 수치, 밤, 점수)
localization/              번역 CSV (keys, en, ko)
docs/                      기술 메모
```

## 게임 시계 규칙

- 게임 1분 = 실제 0.5초, 게임 1시간 = 실제 30초, 하루 = 실제 12분 (`seconds_per_game_minute`로 조정)
- 시작 시각: 1일차 06:00
- 시간대: 아침 06–12, 낮 12–18, 저녁 18–21, 밤 21–06
- 신호: `minute_changed`, `hour_changed`, `day_started`, `phase_changed`

## 데이터 파일 (`data/`)

게임 숫자는 코드에 쓰지 않고 모두 `data/*.json`에 둔다. 숫자를 바꾸려면 JSON만 고치고 다시 실행하면 된다. 설계 근거는 Obsidian `04-수치설계` 노트에 있다.

| 파일 | 내용 |
| --- | --- |
| `config.json` | 프로토타입 길이(10일), 시작 생존자·자원, 생존 수치 감소량, 자동 행동, 사기, 건설 시간 |
| `items.json` | 재료, 음식, 물, 도구, 의류, 의료품 |
| `facilities.json` | 초반 시설 9개 (작업대, 빗물 집수기, 화덕, 침상, 창고 선반, 바리케이드, 못 판자, 깡통 경보기, 쥐덫) |
| `recipes.json` | 프로토타입 레시피 10개 + 보조 레시피 11개 |
| `locations.json` | 원정 규칙과 장소 2곳 (편의점, 의류 상가) |
| `events.json` | 무전 사건 규칙과 사건 3개 (감염체 무리, 숨은 창고, 날씨 급변) |
| `jobs.json`, `injuries.json`, `night.json`, `weather.json`, `score.json` | 직업, 부상, 밤 습격과 흔적, 날씨, 점수 |

실행할 때 `GameData`가 모든 파일을 읽고, 없는 아이템이나 시설을 가리키는 곳이 있으면 오류로 알려 준다.

## 테스트 실행

```
godot --headless --path . res://tests/test_runner.tscn
```

데이터 로드, 이틀 진행, 굶주림과 간호사 살리기, 10일 구조까지 검사하고 `TESTS: PASS`를 출력한다.

## 디버그 배속

개발용 빌드에서만 숫자 키로 시간 속도를 바꿀 수 있다: `1` 보통, `2` 4배, `3` 16배, `4` 60배. 게임 자체에는 일시정지가 없다.

## 진행 상황 (2단계 회색 박스)

- [x] 1. 데이터 파일
- [x] 2. 생존자와 수치 (막대 4개, 자동으로 먹고 마시고 자기, 쓰러짐과 간호사 살리기, 빗물, 음식 상함, 사기, 10일째 헬기)
- [ ] 3. 거점 화면 (시설, 창고, 제작 패널, 짓기)
- [ ] 4. 원정 (의뢰 게시판, 진행, 귀환 화면)
- [ ] 5. 밤과 습격
- [ ] 6. 무전 사건 3개
- [ ] 7. 승리·패배·점수 화면
- [ ] 8. 테스트 빌드
