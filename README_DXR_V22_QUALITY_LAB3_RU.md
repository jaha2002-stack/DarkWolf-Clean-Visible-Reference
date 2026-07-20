# DarkWolf RTCW DXR v2.2 Quality Lab 3

## Назначение

Quality Lab 3 строится строго поверх подтверждённой цепочки:

`patch 10 → patch 20 → patch 30 v2.2 → patch 40 QL1 → patch 50 QL2 → patch 60 QL3`

Он не возвращает экспериментальный v2.3 и не меняет стабильную синхронизацию.

Реализовано:

- source-size для мягкой полутени point-light;
- temporal accumulation по motion vectors;
- edge-aware history filtering по position/normal;
- локальный резерв и новый рейтинг источников света;
- гибридный BLAS auto/refit/full;
- общая нормализация кадров MD3/MDC.

## Установка Upgrade Overlay

1. Распакуйте `DarkWolfRTCW_DXR_v2.2_Quality_Lab_3_Upgrade_Overlay.zip`.
2. Откройте папку `repo-overlay`.
3. Загрузите её содержимое в корень существующего GitHub-репозитория с QL2.
4. Патчи `10`, `20`, `30`, `40` и `50` не удаляйте.
5. Выполните commit, например:

   `Add DXR v2.2 Quality Lab 3 shadow quality pipeline`

6. Откройте **Actions**.
7. Запустите workflow:

   `DarkWolf DXR v2.2 Quality Lab 3`

8. Выберите `Release`.
9. Скачайте artifact:

   `DarkWolf-DXR-v2.2-Quality-Lab3-Release`

10. Установите его в отдельную чистую копию игры, не поверх контрольной QL2.

## Первый порядок запуска

### 1. Основной кандидат

`RUN_DXR_V22_QL3_BALANCED.bat`

Проверить:

- факел и его кронштейн;
- решётчатую дверь до/после открытия;
- живого персонажа и труп;
- движущуюся потолочную клетку;
- прежние места белых кругов;
- поворот камеры возле источников;
- стабильность и FPS не менее нескольких минут.

Ожидаемая строка:

`DXR v2.2 Quality Lab 3:`

Ключевые параметры:

`async=0 cpuSync=1 fallbackShadows=0 temporal=1/0.82 spatial=1 blasMode=0`

### 2. Quality

После подтверждения Balanced:

`RUN_DXR_V22_QL3_QUALITY.bat`

Он использует 8 rays, 96 lights, более широкий source-size и 5×5 history gather.

### 3. Performance

При заметном падении FPS:

`RUN_DXR_V22_QL3_PERFORMANCE.bat`

Он оставляет temporal filter, но снижает rays и лимит lights.

## Контрольные A/B-профили

- `RUN_DXR_V22_QL3_REAL_LIGHTS.bat` — без camera fill.
- `RUN_DXR_V22_QL3_NO_TEMPORAL.bat` — source-size без history.
- `RUN_DXR_V22_QL3_SHARP_AB.bat` — почти точечные жёсткие тени.
- `RUN_DXR_V22_QL3_BLAS_REFIT.bat` — принудительный refit.
- `RUN_DXR_V22_QL3_BLAS_FULL.bat` — полный QL2-style rebuild.

## Диагностика temporal filter

- `RUN_DXR_V22_QL3_DEBUG_RAW_VISIBILITY.bat` — текущий сырой кадр.
- `RUN_DXR_V22_QL3_DEBUG_FILTERED_VISIBILITY.bat` — итог после history filter.
- `RUN_DXR_V22_QL3_DEBUG_TEMPORAL_CONFIDENCE.bat` — доверие к истории.
- `RUN_DXR_V22_QL3_DUMP_LIGHTS.bat` — обычная картинка и расширенный лог.

В confidence белый/серый означает принятую историю, чёрный — её отбрасывание.
На движущихся границах тени чёрные области ожидаемы и полезны: они предотвращают
шлейф.

## Что прислать после первого теста

Минимальный комплект:

1. `rtcwconsole.log` от `QL3_BALANCED`.
2. Скриншоты персонажа, трупа, решётки, факела и клетки.
3. Короткое видео качающейся клетки в Balanced.
4. Одно сравнение Balanced и Quality в одной сцене.
5. При шлейфе — видео Raw/Filtered/Temporal Confidence.

## Статус проверки

Проверено статически:

- patch 60 применяется после QL2 и снимается обратным patch-check;
- `git diff --check`;
- побайтовое совпадение восьми изменённых исходных файлов;
- C++/HLSL constant layout marker;
- descriptor/root-table counts;
- HLSL разбит на блоки менее 8000 байт против MSVC C2026;
- CFG/BAT-ссылки;
- workflow YAML и структура ZIP.

Не выполнено в среде подготовки:

- MSVC-компиляция;
- DXC-компиляция embedded HLSL;
- запуск на DXR GPU.

Поэтому результат является **Quality Lab 3 release candidate**, пока GitHub Actions
и ваш GPU-тест не подтвердят сборку и runtime.
