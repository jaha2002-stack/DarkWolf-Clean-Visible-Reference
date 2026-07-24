DarkWolf Experiment 19.1 — облегчённый GitHub Actions workflow
================================================================

ЗАЧЕМ ЭТА ВЕРСИЯ
----------------
Старый workflow содержал около 500 КБ встроенных Base64-данных. В этой версии
YAML содержит только checkout, setup-msbuild, запуск внешнего PowerShell-скрипта
и upload-artifact. Все патчи и тестовые файлы хранятся отдельно в ci/exp19_1.

ЧТО СКОПИРОВАТЬ В РЕПОЗИТОРИЙ
-----------------------------
Скопируйте из этого комплекта с сохранением структуры:

.github/workflows/darkwolf-d3d12-game-dynamic-lights-exp19_1-lite.yml
ci/exp19_1/build-exp19_1.ps1
ci/exp19_1/payload-sha256.txt
ci/exp19_1/payload/ ... все файлы и подпапки ...

Проще всего скопировать целиком папки .github и ci в корень локального
DarkWolf-Clean-Visible-Reference, затем сделать Commit и Push через GitHub Desktop.

КАК ЗАПУСТИТЬ
-------------
1. Откройте GitHub -> Actions.
2. Выберите "DarkWolf Game Dynamic Lights Experiment 19.1 Lite".
3. Нажмите Run workflow.
4. Выберите Release.
5. Запустите только один экземпляр.

АРТЕФАКТ
--------
После успешной сборки скачайте:
DarkWolf-D3D12-Game-Dynamic-Lights-Exp19.1-Lite-Release

Внутри будут только WolfSP.exe, BAT/CFG/PowerShell для теста, README, manifest,
SHA256SUMS и два исследовательских patch-файла. Системные DLL не включаются.

ВАЖНО
-----
- Старый большой workflow больше не запускайте.
- Новая версия использует windows-latest, timeout 120 минут и concurrency.
- Каждый payload проверяется по SHA-256 до применения.
- Сборка выполняется на точном базовом commit
  229cd5d93b4c24ba705c9821a871cccf31b34b96.
- Этот комплект переносит те же payload и те же команды сборки, что и исходный
  Experiment 19.1; изменена только организация файлов и запуска.
