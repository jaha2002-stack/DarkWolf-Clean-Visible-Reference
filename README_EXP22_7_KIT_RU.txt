DarkWolf EXP22.7 GitHub Kit
===========================

Назначение:
Static/Dynamic Hit Table Split and Incremental Binding Updates поверх EXP22.6.

Содержимое:
- .github/workflows/darkwolf-d3d12-static-dynamic-hit-table-exp22_7.yml
- ci/exp22_7/360-d3d12-static-dynamic-hit-table-exp22_7.patch
- ci/exp22_7/apply_exp227.ps1
- ci/exp22_7/compile_exp227.ps1
- ci/exp22_7/package_exp227.ps1
- ci/exp22_7/runtime_tools/*
- входные/выходные SHA-256 контракты

Ключевые изменения:
- стабильные hit-table slots;
- статический диапазон 0..32767;
- динамический диапазон 32768..131071;
- dirty flags для descriptors и shader records;
- persistent CPU shadow и persistently mapped upload SBT;
- частичные обновления вместо полного прохода по 15 тысячам записей;
- повторное использование освобождённых slots;
- compaction при stale >= 256 и stale >= 5%;
- новая строка EXP22_7_PERF;
- полный Release x64 runtime и автоматический сбор тестов.

Patch SHA-256:
04998D9BA9717F6D1612B3A8F39B48F0E8F92AE3494F8C037F376B176DC22444
