# DarkWolf RTCW DXR Stable Clear v2.1

Цель этого набора — вернуться к подтверждённой картинке Clean Visible Reference,
убрать небезопасный async-путь v2 и дать чистый тестовый профиль без
низкосэмплового AO/sky-шума.

## Почему v2 вылетал

В v2 обычные профили ставили `r_dxrAsyncSubmit 1`. При этом следующий кадр мог
перезаписать upload-буферы или заменить BLAS/mesh resources, пока предыдущий
`DispatchRays` ещё использовал их. Ошибка `0x887A0005` обнаруживалась позднее в
другом D3D12-вызове, но первопричиной был небезопасный срок жизни ресурсов.

В v2.1 async и интервальное пропускание BLAS/TLAS принудительно отключены до
появления полноценного ring buffer/deferred destruction.

## Почему SAFE_SYNC был зернистым

SAFE_SYNC менял синхронизацию, но наследовал из Balanced:

- 2 shadow samples;
- 4 AO samples;
- 2 sky samples;
- contact shadows;
- alpha-shadow geometry как непрозрачную.

Без temporal accumulation/denoiser этого недостаточно: детерминированный
случайный рисунок остаётся на поверхности и не сходится со временем.

Основной v2.1 профиль использует один точный луч к центру источника, AO=0,
sky=0, contact=0 и alpha-shadow geometry=0. Это даёт жёсткие, но чистые тени.

## Чёткие текстуры

Лаунчер задаёт до инициализации renderer:

- `r_picmip 0`;
- `r_picmip2 0`;
- `r_roundImagesDown 0`;
- `r_simpleMipMaps 0`;
- `r_texturebits 32`;
- `r_textureMode GL_LINEAR_MIPMAP_LINEAR`.

## Установка

Загрузите содержимое `repo-overlay` в корень репозитория. Старые v2 файлы можно
не удалять: новый workflow их не использует.

Запустите в Actions:

`DarkWolf DXR Stable Clear v2.1` → `Release`

Artifact:

`DarkWolf-DXR-Stable-Clear-v2.1-Release`

Первый и главный тест:

`RUN_DXR_STABLE_CLEAR_V21.bat`

Не запускайте сначала FAST или Reference Quality.

## Важные ограничения

- Плоские решётки с alpha-cutout пока не могут дать корректный рисунок тени без
  any-hit alpha test. Поэтому они отключены в основном профиле.
- Один shadow ray даёт чистую жёсткую тень, а не мягкую.
- Этот набор статически проверен, но реальная работа на вашей GPU подтверждается
  только игровым тестом.
