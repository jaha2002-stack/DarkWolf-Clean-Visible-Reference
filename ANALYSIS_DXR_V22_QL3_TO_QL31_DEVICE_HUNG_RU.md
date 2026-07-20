# Технический анализ QL3 → QL3.1

## Доказательства

В аварийном логе профиль `NO_TEMPORAL` устанавливает:

- `r_dxrShadowTemporal 0`;
- `r_dxrShadowSpatialRadius 0`;
- runtime-поля `temporal=0` и `spatial=0`.

После первой диагностической строки возникает:

`Map failed 0x887A0005 ... removedReason=0x887A0006`.

`0x887A0005` — удалённое D3D12-устройство, а `0x887A0006` — зависание GPU. Строка `Map` лишь обнаруживает уже потерянное устройство при следующем обновлении upload-буфера.

## Почему CVar не помог

В исходном QL3 даже при `temporal=0` выполнялись:

1. создание двух `R16G16_FLOAT` history UAV-текстур;
2. расширение root table до `10 SRV + 2 UAV`;
3. привязка velocity, previous position, previous normal и history SRV;
4. безусловная запись `gShadowHistoryOut` из ray-generation shader;
5. переход history-текстуры в UAV;
6. UAV barrier и обратный переход;
7. swap ping-pong history.

CVar отключал только чтение и смешивание истории, но не сам GPU resource path. Поэтому тест локализовал сбой не в temporal-математике, а в инфраструктуре второго UAV/history bindings.

## Исправление QL3.1

QL3.1:

- удаляет `gShadowHistoryTex` и `gShadowHistoryOut`;
- удаляет velocity/previous G-buffer bindings из DXR shader;
- удаляет history texture allocation, transition, barrier и swap;
- возвращает heap `7 descriptors`;
- возвращает root table `6 SRV + 1 UAV`;
- возвращает output UAV в slot 6;
- жёстко фиксирует effective `temporal=0`, `spatial=0`;
- сохраняет source-size, QL2 composite, light selection, hybrid BLAS и frame normalization.

Это наиболее узкое изменение, которое полностью устраняет доказанный новый GPU-путь, не откатывая полезные независимые улучшения QL3.

## Почему temporal не исправлен внутри того же релиза

Лог доказывает, что текущая реализация history path небезопасна, но не различает окончательно:

- typed UAV store/format issue;
- descriptor/root-table mismatch на конкретном драйвере;
- неправильное состояние history resource;
- hazard между предыдущими G-buffer и DXR dispatch.

Повторное включение истории без PIX/RenderDoc capture было бы новым предположением. Поэтому QL3.1 сначала возвращает стабильный одно-кадровый путь. Следующий temporal prototype должен быть отдельным compute/post-process этапом с отдельной проверкой формата, barriers, first-frame clear и fallback-профилем.
