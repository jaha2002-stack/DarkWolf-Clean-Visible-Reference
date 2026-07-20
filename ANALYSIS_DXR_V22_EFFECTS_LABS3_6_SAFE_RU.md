# Технический анализ: безопасное расширение эффектов Stable Clear v2.2

## Почему ветка начинается заново от v2.2

QL3 и QL3.1 вызывали `DXGI_ERROR_DEVICE_REMOVED / DEVICE_HUNG` даже при выключенной temporal-математике. Поэтому новый вариант не пытается чинить ту цепочку. Он не применяет патчи 40/50/60/61 и не использует их изменения.

## Что не меняется

Сохраняется доказанная модель v2.2:

```text
6 SRV + 1 UAV
7 descriptors
один lighting output UAV
старые fences/order
async=0
cpuSync=1
старый BLAS/TLAS path
```

Патч расширяет только constant buffer и embedded HLSL. Размер CB автоматически выравнивается до 512 байт существующей функцией `glRaytracingAlignUp`; root CBV descriptor остаётся тем же.

## Отсутствие теневых экспериментов

Новый `r_dxrCastShadows` проверяется до `TraceSoftShadow` и `RectLightShadow`. При нуле direct cast-shadow rays вообще не запускаются. Legacy shadow multiplier также остаётся единицей.

AO, sky, GI и reflections используют visibility rays независимо и не участвуют в старом shadow composite.

## AO/contact

AO использует настраиваемые radius/strength и существующий BVH. Contact AO — четыре коротких hemisphere rays. Его радиус ограничен 64 игровыми единицами, чтобы он не превращался в длинные ложные тени.

## Sky visibility

Сохраняется исходный цвет/стиль Stable Clear v2.2, но sky contribution умножается на visibility. Дальность ограничивается CVar вместо бесконечного луча.

## GI

Полноценный colored hit невозможен без дополнительных hit attributes/material buffers. Поэтому используется visibility-based bounce approximation:

- открытый луч получает смесь sky и ambient;
- перекрытый луч получает слабый ambient bounce;
- результат умножается на albedo;
- вклад ограничивается `r_dxrIndirectClamp`.

## Reflections

Reflection ray определяет, видит ли направление окружение или сценовую геометрию. Затем применяется Fresnel и roughness jitter. Полный цвет объекта в отражении не доступен без нового material hit pipeline, поэтому используется environment/scene tint approximation. Вклад ограничивается `r_dxrReflectionClamp`.

## Почему нет temporal/denoiser

Любой межкадровый history path потребовал бы новых ресурсов, descriptor bindings и resource-state lifetime. Именно эта область стала источником GPU hang в QL3. В данном релизе качество достигается детерминированными low-discrepancy samples и консервативными значениями, а не history accumulation.

## Ожидаемые риски

- дополнительные rays могут снизить FPS;
- 2-sample GI/reflection quality profile значительно дороже Balanced;
- visibility-based GI/reflections являются приближениями;
- без temporal возможна мелкая зернистость при высоком roughness;
- реальная GPU-стабильность подтверждается только пользовательским запуском.
