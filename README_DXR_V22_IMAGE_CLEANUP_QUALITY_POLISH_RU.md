# DarkWolf RTCW DXR v2.2 — Image Cleanup / Quality Polish Fix (исправленный patch 71)

Этот комплект заменяет ошибочный первый вариант patch 71.

Цепочка сборки:

```text
patch 10 → patch 20 → patch 30 → patch 70 → исправленный patch 71
```

## Что было неверно в первом patch 71

Первый вариант вызывал новую HLSL-функцию `StableCosineHemisphereSample` раньше её объявления. Embedded HLSL компилируется DXC уже при запуске игры, поэтому GitHub Actions мог собрать EXE, но игра закрывалась сразу при DXR initialization.

CFG-hotfix не мог это исправить: ошибка находилась в shader source.

## Что сделано теперь

- проблемные `Rotate2D` и `StableCosineHemisphereSample` полностью удалены;
- новый лёгкий `DecorrelateSample2D` объявлен до всех вызовов;
- pattern AO/Sky/Contact AO/GI/reflections декоррелируется по двум координатам;
- не используются дополнительные `sin/cos` для каждого ray sample;
- reflection cone и grazing contribution сделаны спокойнее;
- GI/reflection shaping стал консервативнее;
- specular получил простое anti-glint подавление;
- не добавляются history textures, temporal accumulation, extra UAV или hybrid BLAS.

## Первый запуск

Сначала обязательно:

```text
RUN_DXR_V22_CLEANUP_SAFE_START.bat
```

Этот режим оставляет DXR и исправленный shader включёнными, но отключает AO, Sky rays, GI и reflections. Его задача — подтвердить, что embedded HLSL теперь компилируется и DXR запускается.

Затем:

```text
RUN_DXR_V22_CLEANUP_SOFT.bat
RUN_DXR_V22_CLEANUP_BALANCED.bat
RUN_DXR_V22_CLEANUP_QUALITY.bat
RUN_DXR_V22_CLEANUP_MAXCLEAN.bat
```

Не переходите к следующему режиму, пока предыдущий не запускается стабильно.

## A/B режимы

```text
RUN_DXR_V22_CLEANUP_NO_GI.bat
RUN_DXR_V22_CLEANUP_NO_REFLECTIONS.bat
RUN_DXR_V22_CLEANUP_DEBUG_GI.bat
RUN_DXR_V22_CLEANUP_DEBUG_REFLECTIONS.bat
```

## Ограничение

Это не temporal denoiser и не полноценный edge-aware post-process. Исправленный patch 71 уменьшает регулярное зерно/полосы за счёт более правильного low-discrepancy sample pattern и консервативного shaping. Полностью убрать stochastic noise без temporal/spatial accumulation невозможно, но этот вариант не возвращает опасную QL3 history-архитектуру.
