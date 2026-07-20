# DarkWolf RTCW DXR v2.2 Quality Lab 3.1 — Startup Safe

## Причина выпуска

Первый Quality Lab 3 успешно компилировался, однако сразу после первого DXR-dispatch видеодрайвер переводил устройство в состояние `DXGI_ERROR_DEVICE_HUNG` (`removedReason=0x887A0006`).

Контрольные тесты доказали:

- при `r_dxr 0` игра запускается;
- профиль `NO_TEMPORAL` действительно устанавливает `temporal=0` и `spatial=0`;
- несмотря на это, исходный QL3 всё равно создаёт, привязывает и записывает две history UAV-текстуры;
- потеря устройства обнаруживается на следующем `Map` upload-буфера, но возникает раньше — во время первого DXR-прохода.

Поэтому QL3.1 полностью удаляет опасный межкадровый history SRV/UAV-путь, а не только отключает его формулу через CVar.

## Что сохранено

- source-size для point-light и более естественной полутени;
- улучшенный выбор ближайших и значимых источников;
- гибридный BLAS `auto/refit/full`;
- универсальная нормализация кадров MD3/MDC;
- QL2 shadow authority и многосветовой composite;
- исправление белых кругов;
- `async=0`, `cpuSync=1`, `buildInterval=1`, `dispatchInterval=1`;
- `fallbackShadows=0`.

## Что временно отключено

- temporal accumulation теневой маски;
- edge-aware history filtering;
- velocity/previous-position/previous-normal SRV в DXR root table;
- две history-текстуры и второй UAV.

QL3.1 возвращает проверенную структуру QL2: **6 SRV + 1 UAV**. Temporal будет возвращён только отдельным экспериментальным проходом после подтверждения запуска QL3.1.

## Установка Upgrade Overlay

1. Распакуйте `DarkWolfRTCW_DXR_v2.2_Quality_Lab_3.1_Startup_Safe_Upgrade_Overlay.zip`.
2. Откройте папку `repo-overlay`.
3. Загрузите её содержимое в корень репозитория, где уже находится QL3.
4. Не удаляйте патчи `10`, `20`, `30`, `40`, `50`, `60`.
5. Выполните commit.
6. В Actions запустите:

   `DarkWolf DXR v2.2 Quality Lab 3.1 Startup Safe`

7. Выберите `Release`.
8. Скачайте artifact:

   `DarkWolf-DXR-v2.2-Quality-Lab3.1-Startup-Safe-Release`

9. Распакуйте в отдельную чистую копию игры.

## Первый тест

Запустите только:

`RUN_DXR_V22_QL31_BALANCED.bat`

Ожидаемая строка:

`DXR v2.2 Quality Lab 3.1 Startup Safe:`

Обязательные поля:

`temporal=0 spatial=0 async=0 cpuSync=1 fallbackShadows=0`

Сначала проверьте запуск и 5–10 минут стабильности. Только затем запускайте:

`RUN_DXR_V22_QL31_QUALITY.bat`

## Честное ограничение

QL3.1 — аварийный release candidate, устраняющий доказанный startup/device-hung путь. Он сохраняет source-size, light selection и hybrid BLAS, но пока не содержит temporal denoiser. Полная MSVC/DXC-компиляция и GPU runtime подтверждаются только вашей сборкой GitHub Actions и тестом на видеокарте.
