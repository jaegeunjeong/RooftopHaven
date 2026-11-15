# 코드·파일 규칙

- 스크립트: GDScript, 탭 들여쓰기, 정적 타입 표기 사용 (`var x: int`)
- 파일 이름: snake_case (`game_clock.gd`, `main.tscn`)
- 장면과 스크립트는 기능별 폴더에 함께 둔다 (`src/<기능>/`)
- 전역 시스템은 `src/autoload/`에 두고 project.godot의 [autoload]에 등록한다
- 화면에 보이는 글자는 직접 쓰지 않고 `tr("KEY")`로 번역 키를 쓴다
- 게임 데이터(레시피, 장소, 사건)는 코드가 아니라 `data/`의 JSON/CSV에 둔다
