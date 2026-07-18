# DarkWolf DXR Clean Release Build Kit

Этот kit исправляет упаковку GitHub Actions artifact.

Предыдущий workflow собирал игру, но загружал технические папки `src` и `bin_nt`, поэтому artifact выглядел как исходники/инструменты, а не как готовый runtime-релиз.

Новый workflow загружает только папку `dist`, где должны быть:

- `WolfSP.exe`
- `main/cgamex64.dll`
- `main/qagamex64.dll`
- `main/uix64.dll`
- `RUN_DARKWOLF_DXR.bat`
- `README_RUN_RU.txt`

Оригинальные `pak0.pk3`, `sp_pak*.pk3` не включаются, потому что это игровые данные RTCW. Их нужно брать из вашей установленной игры.

## Как использовать

1. Распакуйте архив.
2. Загрузите содержимое папки `dxr_clean_release_full_kit` в корень репозитория.
3. Нажмите `Commit changes`.
4. В GitHub Actions запустите workflow:
   `DarkWolf DXR Clean Release Build`
5. Скачайте artifact:
   `DarkWolf-DXR-Clean-Runtime-Release`
6. Содержимое artifact скопируйте поверх вашей установленной DarkWolf/RTCW папки.

## После запуска игры

В консоли:

```cfg
\seta r_dxr 1
\seta r_dxrFallbackLight 1
\seta r_dxrFallbackLightRadius 900
\seta r_dxrFallbackLightIntensity 6
\seta r_dxrAmbientIntensity 1.35
\seta r_dxrLegacyBlend 0.65
\seta r_dxrExposure 1.15
\seta r_dxrShadowBias 0.02
\seta r_dxrDebug 1
\seta r_dxrDebugMode 0
\vid_restart
\spdevmap escape1
```
