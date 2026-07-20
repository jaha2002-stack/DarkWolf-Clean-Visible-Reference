# DarkWolf RTCW DXR v2.2 — Image Cleanup / Quality Polish Fix

Это безопасный фикс поверх уже проверенной цепочки:

- patch 10 — Clean Visible Reference Rebase
- patch 20 — Stable Clear v2.1
- patch 30 — Stable Clear v2.2
- patch 70 — Effects Labs 3-6 Safe
- patch 71 — Image Cleanup / Quality Polish

## Что делает patch 71

Фикс специально направлен на визуальную очистку картинки:

- уменьшает структурное зерно и «рисованные» полосы/линии;
- делает паттерн семплирования менее регулярным в AO / Sky / Contact AO / GI / Reflections;
- чуть смягчает отражения, чтобы меньше было полос на полу и стенах;
- подавляет излишне «искрящийся» specular;
- добавляет готовые пресеты для аккуратного A/B теста.

## Что фикс НЕ делает

Этот фикс **не** добавляет:

- temporal accumulation;
- новые history textures;
- hybrid BLAS path;
- новую D3D12 resource model;
- тяжёлый post-process denoiser.

То есть он остаётся в безопасной архитектуре v2.2 safe chain.

## Рекомендуемый старт

Сначала запускай:

- `RUN_DXR_V22_CLEANUP_BALANCED.bat`

Если зерно/полоски ещё заметны:

- `RUN_DXR_V22_CLEANUP_MAXCLEAN.bat`

## Полезные A/B режимы

- `RUN_DXR_V22_CLEANUP_NO_GI.bat`
- `RUN_DXR_V22_CLEANUP_NO_REFLECTIONS.bat`
- `RUN_DXR_V22_CLEANUP_DEBUG_GI.bat`
- `RUN_DXR_V22_CLEANUP_DEBUG_REFLECTIONS.bat`

## Что сравнивать визуально

Смотри в первую очередь на:

1. Пол и стены под острым углом камеры.
2. Тёмные углы и коридоры.
3. Места, где раньше были горизонтальные/диагональные полоски.
4. Блики на оружии и мокрых/глянцевых поверхностях.
5. Насколько «спокойнее» стала картинка при движении.

## Ожидаемый эффект

По идее этот фикс должен дать:

- более чистую картинку;
- меньше зернистости;
- меньше полос на отдельных участках пола/стен;
- более спокойные reflections/specular;
- минимум риска по стабильности.
