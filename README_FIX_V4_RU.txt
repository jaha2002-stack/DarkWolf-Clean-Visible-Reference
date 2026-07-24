DarkWolf Experiment 19.1 Lite Workflow — Fix v4
================================================

ПРИЧИНА ОШИБКИ
---------------
Patch 271 был создан относительно укороченного тестового фрагмента
tr_scene.cpp. Поэтому первый hunk имел координаты:

  @@ -1,3 +1,78 @@

В полном исходном файле RE_AddLightToScene начинается примерно со строки 248.
GitHub runner не смог применить первый hunk и сообщил:

  patch failed: src/renderer/tr_scene.cpp:1

ЧТО ИСПРАВЛЕНО
---------------
В patch 271 исправлены координаты всех hunks для tr_scene.cpp:

  @@ -248,3 +248,78 @@
  @@ -259,12 +334,10 @@
  @@ -274,66 +347,107 @@

Содержимое логики Experiment 19.1 не изменялось.
Обновлён SHA-256 patch 271 в payload-sha256.txt.

ЧТО ЗАМЕНИТЬ В РЕПОЗИТОРИИ
--------------------------
Замените только два файла:

1. ci/exp19_1/payload/patches/
   271-d3d12-transient-muzzle-light-isolation-exp19_1.patch

2. ci/exp19_1/payload-sha256.txt

Workflow YAML и build-exp19_1.ps1 менять не требуется.

ПОСЛЕ ЗАМЕНЫ
------------
Создайте новый commit и push:

  Fix Experiment 19.1 tr_scene patch coordinates

Затем запустите новый Run workflow. Не используйте Re-run jobs старого
запуска, поскольку он привязан к предыдущему commit.

ПРОВЕРКИ
--------
- Patch 270 применён к состоянию Bloom 18.2: PASSED
- Исправленный patch 271 применён после patch 270: PASSED
- Reverse-check patch 271: PASSED
- Scope patch 271: ровно 5 ожидаемых файлов
- Patch 271 line endings: LF
