DarkWolf Experiment 19.1 Lite - Fix v3

Причина ошибки:
Git/Windows преобразовал LF в CRLF у payload-файлов, поэтому SHA-256 не совпал.
Кроме того, patch 271 исходно имел смешанные LF/CRLF.

Замените/добавьте в корне репозитория ровно 4 файла:

1) .gitattributes
2) ci/exp19_1/build-exp19_1.ps1
3) ci/exp19_1/payload-sha256.txt
4) ci/exp19_1/payload/patches/271-d3d12-transient-muzzle-light-isolation-exp19_1.patch

Затем Commit to main и Push origin.
Запускайте новый workflow run, а не Re-run старого commit.

Исправление:
- проверка сначала использует точный SHA-256;
- при несовпадении пробует CRLF -> LF и повторно сверяет SHA-256;
- patch 271 приведён к чистому LF;
- .gitattributes принудительно сохраняет LF для всей папки ci/exp19_1.
