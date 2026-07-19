# Анализ v2.2 → v2.3: почему маска есть, а тени в цветном кадре почти нет

## Наблюдение из теста

- `RUN_DXR_V22_SHADOWS_STRONG` показывает только слабые тени.
- В режиме `RUN_DXR_V22_SHADOW_MASK_STRONG` прутья решетки и другие препятствия
  дают отчетливый темный рисунок.
- Тени больше не вращаются вместе с камерой.

Это разделяет проблему на два слоя:

1. TLAS/BLAS, геометрия двери и shadow rays работают.
2. Финальная цветная композиция ослабляет уже вычисленную маску.

## Формула v2.2

```hlsl
float3 rtLitColor = albedo * lightingAccum + specularAccum;
float3 finalColor = lerp(rtLitColor, baseAlbedo * legacyShadow, legacyKeep);
```

`legacyShadow` умножался только на raster/legacy-ветвь. RT diffuse содержал
camera fill, ambient и sky/direct lighting и оставался почти полностью
незатененным. При `legacyKeep=0.55` больше половины legacy-части имело тень, но
остальная яркая RT-составляющая визуально заполняла ее.

## Формула v2.3

```hlsl
float3 rtDiffuseColor = max(albedo * lightingAccum, baseAlbedo * 0.15);
float3 blendedDiffuse = lerp(rtDiffuseColor, baseAlbedo, legacyKeep);
float3 finalColor = blendedDiffuse * legacyShadow +
                    rtSpecularColor * lerp(1.0, legacyShadow, 0.35);
```

Теперь authored-light shadow применяется после смешивания ко всей diffuse-
составляющей. Specular затемняется частично, чтобы металлические поверхности
не становились полностью матовыми.

## Что не меняется

- async остается выключенным;
- `cpuSync=1`;
- fences и safe mode не меняются;
- camera fallback сохраняется, но `fallbackShadows=0`;
- full-precision position G-buffer и исправления v2.2 сохраняются;
- UV jitter не возвращается.

## Риск

Новый composite намеренно сильнее. В некоторых сценах профиль STRONG может
оказаться слишком темным. Поэтому в artifact предусмотрены два режима:

- основной умеренный `RUN_DXR_STABLE_SHADOWS_V23.bat`;
- усиленный `RUN_DXR_STABLE_SHADOWS_STRONG_V23.bat`.

Сборка MSVC/DXC и фактическая яркость на GPU должны быть подтверждены тестом.
