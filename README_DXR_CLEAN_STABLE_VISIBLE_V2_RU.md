# DarkWolf RTCW DXR Clean Stable Visible v2

Этот kit построен по правильной схеме:

```text
чистый DarkWolf из DarkWolf-Clean-Visible-Reference-main.zip
+ 10-dxr-clean-reference-rebase-current-main.patch
= подтверждённая пользователем красивая Clean Visible Reference

Clean Visible Reference
+ 20-dxr-clean-stable-visible-v2.patch
= кандидат Clean Stable Visible v2
```

Код v6, v6.1, v6.2, v6.3 и v7 сюда не переносился.

## Задачи v2

1. Сохранить подтверждённый пользователем Clean Release composite и внешний вид.
2. Убрать самые тяжёлые причины лагов и рывков.
3. Сделать RT-тени заметнее в обычной игровой картинке.
4. Добавить в DXR-геометрию решётки/двери с `SURF_ALPHASHADOW`.
5. Не допускать зависания процесса на бесконечном fence wait при ошибке драйвера.

## Основные изменения

### Производительность

- Удалён обязательный `glFinish()` на каждом RT-кадре. Он остаётся только при `r_dxrCpuSync 1`.
- DXR command lists по умолчанию отправляются упорядоченно в общую D3D12 queue без немедленного CPU wait (`r_dxrAsyncSubmit 1`).
- Повторное использование command allocator по-прежнему защищено fence wait перед его следующим reset.
- Введён отбор наиболее важных источников света относительно камеры (`r_dxrMaxLights`).
- Уменьшено и сделано настраиваемым число shadow/AO/sky rays.
- Для неподвижной локальной геометрии движущихся дверей, ворот и лифтов добавлен geometry hash: при движении обновляется transform/TLAS, но BLAS не пересоздаётся каждый кадр.
- При одинаковом размере обновляемого mesh повторно используются upload/BLAS allocations.
- Неизменившиеся transforms больше не помечают TLAS dirty.

### Тени

- Тени точечных и прямоугольных источников получили настраиваемое число samples.
- Добавлены короткие contact-shadow rays.
- Сильнейшая релевантная RT-тень теперь модулирует также сохраняемую оригинальную RTCW-составляющую; раньше `r_dxrLegacyBlend 0.65` визуально смывал большую часть тени.
- Добавлен debug mode 5 — чистая grayscale shadow mask.
- `SURF_ALPHASHADOW` больше не исключается целиком из DXR geometry при `r_dxrAlphaShadowGeometry 1`.

Важно: пока нет alpha-tested any-hit shader. Если решётка сделана плоским alpha-текстурированным полигоном, она будет давать непрозрачную тень. Если решётка состоит из реальных металлических прутьев/полигонов, тень будет соответствовать геометрии.

### Стабильность

- Ошибки DXR больше не вызывают `MessageBox + DebugBreak`.
- Добавлен safe mode и ограниченный fence timeout.
- При `DEVICE_REMOVED`, `DEVICE_RESET`, `DEVICE_HUNG` или timeout DXR отключается до `vid_restart`, вместо бесконечного зависания/серии аварий.
- При `vid_restart` состояние device-lost сбрасывается при новом создании DXR context.
- Добавлена compile-time проверка размера C++/HLSL constant buffer (`256` байт).

## Установка

Распакуйте архив и загрузите **содержимое** папки `repo-overlay` в корень репозитория `DarkWolf-Clean-Visible-Reference`.

Новый workflow:

```text
DarkWolf DXR Clean Stable Visible v2
```

Запускайте `Release`.

Artifact:

```text
DarkWolf-DXR-Clean-Stable-Visible-v2-Release
```

Распакуйте artifact в отдельную копию игры, заменив старый `WolfSP.exe` и DLL в `main`.

## Порядок тестирования

1. `RUN_RT_CLEAN_V2_BALANCED.bat` — главный профиль.
2. `RUN_RT_CLEAN_V2_PERFORMANCE.bat` — если Balanced всё ещё медленный.
3. `RUN_RT_CLEAN_V2_QUALITY.bat` — только после проверки стабильности Balanced.
4. `RUN_RT_CLEAN_V2_REAL_LIGHTS.bat` — проверка реальных факелов без camera fallback light.
5. `RUN_RT_CLEAN_V2_SAFE_SYNC.bat` — медленный диагностический режим, если async нестабилен.
6. `RUN_RT_CLEAN_V2_SHADOW_MASK.bat` — проверка самой маски теней.

Не смешивайте runtime-файлы v2 с v7 в одной тестовой папке.

## Что собрать после теста

- скриншоты одинаковых сцен Balanced/Performance/Real Lights;
- FPS в этих сценах;
- время игры до сбоя;
- результат открытия/закрытия решётчатой двери;
- `rtcwconsole.log` после команд:

```text
developer 1
logfile 2
r_dxrDebug 1
```

В логе должен появляться маркер:

```text
DXR v2:
```

## Честные ограничения

- Этот kit статически проверен и воспроизводимо применяется к подтверждённой Clean Visible Reference базе.
- Реальная MSVC/DXC-компиляция выполняется GitHub Actions.
- Реальный FPS, качество теней и длительная стабильность могут быть доказаны только запуском на вашей видеокарте.
- Полноценные GI/reflections из экспериментальной v6-ветки намеренно не переносились: сначала нужно стабилизировать доказанный direct-light/shadow/specular baseline.
