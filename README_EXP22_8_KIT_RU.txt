DarkWolf EXP22.8 GitHub Kit
==========================

Назначение:
Persistent Dynamic SBT Capacity and Transient Effect Isolation поверх EXP22.7.

Ключевые изменения:
- полная постоянная SBT capacity на 131072 slots;
- рост dynamic high-water не пересоздает buffer и не переписывает старые records;
- новый slot обновляется отдельно;
- capacity, monotonic high-water, active high-water, live records и dispatch span разделены;
- transient/additive/muzzle effects исключаются до BLAS/TLAS/SBT;
- transform/touch/visibility и animation с неизменным SRV не повышают bindingRev;
- telemetry EXP22_8_PERF: fullRebuildReason, highWaterGrowthEvents,
  newDynamicSlots, transientSkipped, muzzleInstances, sbtCapacity,
  sbtHighWater, sbtActiveHighWater, sbtLiveRecords, tlasMs, blasMs.

Patch SHA-256:
D9DAE13EA2DA365EFCFC11A9F42F5F78B1D0673516E589DEDB4F87287B660BE3
