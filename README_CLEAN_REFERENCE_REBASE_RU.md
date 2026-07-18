# DarkWolf DXR Clean Visible Reference Rebase Kit

Этот kit создан специально по двум предоставленным архивам:

- `DarkWolf-Clean-Visible-Reference-main.zip` — текущий чистый репозиторий;
- `DarkWolfRTCW_DXR_Clean_Release_Build_Kit.zip` — старый kit, который не применялся к текущему исходнику.

Старые патчи были не просто переименованы. Их изменения перенесены на текущую структуру исходников и собраны в новый единый патч:

`patches/10-dxr-clean-reference-rebase-current-main.patch`

## Что переносится из старого Clean Release

- исходный видимый DXR composite `lerp(rtLitColor, baseAlbedo, legacyKeep)`;
- RT direct lighting, shadow rays и specular;
- ambient, exposure и legacy blend;
- camera-side fallback light с радиусом 900 и интенсивностью 6;
- debug modes 0–4 и периодический вывод состояния;
- нормали и texture coordinates для DXR meshes;
- безопасное ожидание DXR command lists;
- удаление прямого `CopyResource` в swapchain;
- x64 исправление `AAS_DecompressVis`.

Это контрольная визуальная сборка. В неё намеренно не добавлен код v6.x или v7.

## Установка

Загрузите **содержимое** папки `repo-overlay` в корень репозитория. Существующие старые файлы kit можно не удалять.

После коммита откройте Actions и запустите:

`DarkWolf DXR Clean Visible Reference Rebased`

Выберите `Release`.

Скачайте artifact:

`DarkWolf-DXR-Clean-Visible-Reference-Rebased-Release`

Распакуйте его в отдельную копию игры, не поверх v7.

Запускайте:

`RUN_DARKWOLF_DXR_CLEAN_REFERENCE.bat`

## Защита от неправильной базы

Apply-скрипт проверяет Git blob SHA семи исходных файлов из предоставленного ZIP. Проверка не зависит от преобразования LF/CRLF на Windows runner. Если исходник изменён, workflow остановится до применения патча, а не создаст неизвестную смесь кода.
