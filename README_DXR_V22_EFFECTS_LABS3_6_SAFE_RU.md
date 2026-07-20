# DarkWolf RTCW DXR v2.2 — Effects Labs 3–6 Safe

Этот вариант построен **не поверх QL1/QL2/QL3/QL3.1**, а непосредственно поверх доказанной стабильной цепочки:

```text
patch 10 → patch 20 Stable Clear v2.1 → patch 30 Stable Clear v2.2 → patch 70
```

## Главный принцип

Патч 70 не меняет подтверждённую D3D12-архитектуру v2.2:

- не создаёт history-текстуры;
- не добавляет UAV/SRV descriptors;
- не меняет root signature;
- не меняет BLAS/TLAS update path;
- не включает async submit;
- не переносит QL3 hybrid BLAS;
- не использует temporal accumulation;
- не использует отдельный post-process denoiser.

Все новые эффекты вычисляются внутри уже существующего ray-generation pass v2.2 и записываются в тот же единственный output UAV.

## Что означает Labs 3–6 в этой безопасной ветке

### Lab 3 — Specular/material response

Настраиваемый specular от существующих игровых источников:

```text
r_dxrSpecular
r_dxrSpecularStrength
r_dxrSpecularPower
```

### Lab 4 — RT AO и contact grounding

- регулируемый ray-traced ambient occlusion;
- короткий contact-AO для ног, трупов, мебели, решёток и стыков;
- регулируемая screen-space cavity-модуляция.

Это не длинные cast shadows.

### Lab 5 — Sky visibility

Лучевая проверка открытости неба регулирует уже существующий ambient/sky вклад Stable Clear v2.2. Закрытые помещения должны стать глубже, а открытые поверхности — естественнее.

### Lab 6 — Safe indirect diffuse и reflections

Добавлены консервативные visibility-based приближения:

- indirect diffuse/GI approximation;
- environment/Fresnel reflections;
- ограничение максимального вклада для защиты от пересветов.

Это не полноценный path tracing и не отражение полного цвета сцены: RTCW не предоставляет современный material hit-buffer с roughness/metalness/emissive. Отражения показывают реакцию окружения и видимость луча, а GI использует sky/ambient bounce approximation.

## Тени

Во всех игровых профилях:

```text
r_dxrCastShadows 0
r_dxrShadowStrength 0
r_dxrLegacyShadowStrength 0
```

Прямые shadow rays полностью пропускаются. Это оставляет эксперименты QL1–QL3 за пределами данного релиза.

## Первый запуск

```text
RUN_DXR_V22_FX_ALL_BALANCED.bat
```

Проверьте запуск, стабильность и FPS 10–15 минут. Затем:

```text
RUN_DXR_V22_FX_ALL_QUALITY.bat
```

При низком FPS:

```text
RUN_DXR_V22_FX_ALL_PERFORMANCE.bat
```

## Поэтапные профили

```text
RUN_DXR_V22_FX_L3_SPECULAR.bat
RUN_DXR_V22_FX_L4_AO.bat
RUN_DXR_V22_FX_L5_SKY.bat
RUN_DXR_V22_FX_L6_INDIRECT.bat
```

Каждый следующий профиль включает предыдущий и добавляет один класс эффектов.

## Диагностика

```text
RUN_DXR_V22_FX_DEBUG_AO.bat
RUN_DXR_V22_FX_DEBUG_CONTACT.bat
RUN_DXR_V22_FX_DEBUG_SKY.bat
RUN_DXR_V22_FX_DEBUG_GI.bat
RUN_DXR_V22_FX_DEBUG_REFLECTIONS.bat
RUN_DXR_V22_FX_DEBUG_SPECULAR.bat
```

Все BAT автоматически включают:

```text
developer 1
logfile 2
```

Ожидаемый маркер:

```text
DXR v2.2 Effects L3-L6 Safe:
```

## Установка через GitHub Web

1. Распаковать Upgrade Overlay.
2. Открыть `repo-overlay`.
3. Загрузить содержимое в корень репозитория.
4. Старые QL-патчи можно не удалять: новый workflow их не применяет.
5. Запустить Action:

```text
DarkWolf DXR v2.2 Effects Labs 3-6 Safe
```

6. Выбрать `Release`.
7. Скачать artifact:

```text
DarkWolf-DXR-v2.2-Effects-Labs3-6-Safe-Release
```

8. Установить в отдельную чистую копию игры.
