DarkWolf EXP22.9 GitHub Kit
==========================

Dynamic BLAS Update Budgeting and View-Weapon Isolation поверх EXP22.8.

Ключевые изменения:
- view weapon определяется по RF_FIRST_PERSON/RF_DEPTHHACK и исключается до BLAS;
- бюджет 24 уже существующих динамических BLAS updates за build tick;
- новые BLAS не откладываются;
- PREFER_FAST_BUILD для обновляемых BLAS;
- TLAS update вместо rebuild для resident BLAS updates;
- ordered asynchronous submit в production profile;
- telemetry EXP22_9_PERF.

Patch SHA-256:
10B24C26D4A061AFD69EA307FCF369A5AFB92650A0B1141321EDF2AD0A092AC4
