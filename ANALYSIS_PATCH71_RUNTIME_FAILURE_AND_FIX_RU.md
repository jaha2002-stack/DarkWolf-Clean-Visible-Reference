# Анализ сбоя исходного patch 71 и исправление

## Найденная ошибка

Исходный `71-dxr-v2.2-image-cleanup-quality-polish.patch` добавлял HLSL-функцию:

```hlsl
float3 StableCosineHemisphereSample(float2 xi, float angle)
```

ниже функций `ComputeAmbientOcclusion`, `ComputeSkyVisibility` и `ComputeContactAO`, хотя эти функции уже вызывали `StableCosineHemisphereSample` раньше её объявления.

Embedded HLSL компилируется DXC не во время GitHub/MSVC-сборки, а при запуске DXR в игре. Поэтому:

- GitHub Actions мог завершиться успешно;
- `WolfSP.exe` открывался;
- DXC встречал вызов ещё не объявленной функции;
- DXR initialization завершался ошибкой, и игра сразу закрывалась.

CFG-hotfix не мог исправить эту проблему, потому что ошибка находилась в исходном HLSL, а не в количестве AO/Sky samples.

## Дополнительный вывод

Исходный patch 71 не содержал настоящего temporal/spatial denoiser. Он менял pattern семплирования, shaping GI/reflections и specular suppression. Поэтому прежнее описание как «полной очистки» было слишком сильным.

## Что изменено в исправленном patch 71

1. Удалены `Rotate2D` и `StableCosineHemisphereSample`.
2. Добавлен лёгкий `DecorrelateSample2D` сразу после `Hammersley2D`, до первого использования.
3. Вместо дополнительных `sin/cos` используется Cranley–Patterson shift сразу по двум координатам sample sequence.
4. AO, Sky, Contact AO, GI и reflections получают менее регулярный 2D pattern.
5. Reflection cone немного сужен, contribution на grazing angles ослаблен.
6. GI/reflection visibility проходит консервативный smoothstep.
7. Specular получает простое anti-glint подавление.
8. Не добавляются history textures, UAV ping-pong, temporal accumulation, hybrid BLAS или новый descriptor layout.

## Проверки

- исправленный patch применяется непосредственно после patch 70;
- reverse check проходит;
- `DecorrelateSample2D` объявлен до всех вызовов;
- старые проблемные `Rotate2D` и `StableCosineHemisphereSample` отсутствуют;
- баланс скобок embedded HLSL проверен;
- workflow YAML разобран;
- build-script references проверены;
- в Overlay оставлен только один workflow;
- добавлен `SAFE_START` профиль без AO/Sky/GI/reflections для первой проверки runtime HLSL compile.

Полная DXC-компиляция в Windows и GPU runtime всё ещё требуют GitHub Actions и вашего запуска.
