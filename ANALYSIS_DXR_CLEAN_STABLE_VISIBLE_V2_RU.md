# Технический анализ Clean Visible Reference → Stable Visible v2

## Подтверждённая база

Пользователь подтвердил, что Clean Reference v1.1 воспроизводит исходную красивую RT-картинку. Поэтому v2 не заменяет её shader/composite поздними экспериментами, а является отдельным incremental diff поверх этой базы.

## Найденные причины низкого FPS и лагов

### 1. Двойная/тройная синхронизация CPU-GPU

Clean Reference выполнял глобальный `glFinish()` перед `glLightScene()`. Затем shim отправлял основной command list с ожиданием, а DXR command list также ждал fence сразу после `DispatchRays`.

`glFinish()` убран из обычного режима. Immediate waits после DXR/BLAS/TLAS submit отключены при `r_dxrAsyncSubmit 1`. Очередь остаётся одна и сохраняет порядок GPU-команд. Перед повторным использованием каждого command allocator по-прежнему выполняется fence wait.

Главный shim wait перед передачей scene textures внешнему DXR command list пока сохранён. Его удаление требует переработки владения main command allocator и несёт больший риск нестабильности.

### 2. Чрезмерное число rays на пиксель

В эталонном shader были жёстко зашиты:

- 12 point-shadow samples на каждый влияющий point light;
- 24 AO rays;
- 8 sky rays;
- до 66 lights на сцене со скриншота.

Теоретический верхний предел только для этих rays мог составлять около:

```text
66 × 12 + 24 + 8 = 824 rays/pixel
```

Не каждый light влияет на каждый pixel, но цикл и проверки всё равно выполнялись.

Профили v2:

```text
Balanced:    до 24 × 2 + 4 + 2 = 54 rays/pixel
Performance: до 16 × 1 + 2 + 1 = 19 rays/pixel
Quality:     до 32 × 4 + 8 + 4 = 140 rays/pixel
```

Это теоретические верхние оценки, не обещание конкретного ускорения FPS.

### 3. Все источники света отправлялись в shader

Добавлен CPU importance selection. Оценка учитывает интенсивность, радиус, расстояние от камеры, нахождение камеры внутри радиуса и тип rect/point. Camera fallback light, если явно включён, получает приоритет и не теряется.

### 4. Динамические двери пересоздавали геометрию

Ранее brush entity мог повторно формировать vectors, загружать vertex/index data и инициировать BLAS update каждый кадр, даже когда дверь только меняла transform.

Добавлено:

- FNV hash локальной геометрии;
- transform cache;
- повторное использование upload buffers;
- повторное использование BLAS scratch/result allocations при совпадающем размере;
- пропуск TLAS update при неизменном transform.

## Почему тени были слабыми

Clean composite сохраняет 65% оригинального изображения:

```hlsl
lerp(rtLitColor, baseAlbedo, legacyBlend)
```

RT shadow затемнял RT-light contribution, но оригинальный `baseAlbedo` оставался незатенённым и визуально заполнял тень.

В v2 сохраняется Clean Reference relighting, но original contribution умножается на маску наиболее значимого прямого RT-источника:

```hlsl
lerp(rtLitColor, baseAlbedo * legacyShadow, legacyBlend)
```

Сила регулируется `r_dxrLegacyShadowStrength`.

## Почему решётчатые двери не давали тень

World mesh builder полностью исключал поверхности с `SURF_ALPHASHADOW`. В v2 они включены при `r_dxrAlphaShadowGeometry 1`.

Ограничение: any-hit alpha test пока отсутствует. Реальная полигональная решётка даст геометрически правильную тень; плоский alpha-cutout polygon даст сплошную непрозрачную тень.

## Стабильность

- bounded fence wait;
- safe disable вместо `MessageBox/DebugBreak`;
- обработка `DEVICE_REMOVED/RESET/HUNG`;
- повторная попытка через `vid_restart`;
- сохранение упорядоченной единой D3D12 queue;
- compile-time C++/HLSL constant-buffer size check.

## Что намеренно не добавлено

- gameplay composite из v6.2;
- `authoredHeadroom` и скрытые caps;
- экспериментальные GI/reflections из v6.x;
- temporal accumulation без доказанных motion vectors;
- рискованное удаление main command-list wait.

Сначала должен быть подтверждён стабильный direct-light/shadow/specular baseline.
