#!/bin/sh
# Разложить зарубежные сети по таблице маршрутизации и завернуть их в туннель.
#
#   apply-routes.sh [--flush] <интерфейс> <таблица>
#
# Зоны (Германия, ОАЭ, «весь мир кроме России») складываются в ОДНУ таблицу: разделение по
# файлам нужно не маршрутизатору, а человеку — чтобы зону можно было исключить, не пересобирая
# остальное.
#
# Почему `ip -batch`, а не цикл с `ip route add`: маршрутов больше трёхсот тысяч, и каждый
# отдельный вызов — это новый процесс и новый диалог с ядром. Поштучно это минуты, пакетом —
# секунды, и, что важнее, пакет применяется как одна транзакция: таблица не бывает «наполовину
# готовой», пока по ней уже идёт трафик.
set -eu

FLUSH=no
if [ "${1:-}" = "--flush" ]; then FLUSH=yes; shift; fi

IFACE="${1:-}"
TABLE="${2:-}"
[ -n "$IFACE" ] && [ -n "$TABLE" ] || {
  echo "usage: $0 [--flush] <интерфейс> <таблица>" >&2
  echo "       SRC_NETS=\"10.250.0.0/16 …\"  какие источники заворачивать (обязательно)" >&2
  echo "       SRC_PREF=100                 приоритет правил ip rule" >&2
  exit 2
}

LISTS="${LISTS:-$(CDPATH= cd -- "$(dirname -- "$0")/../lists" && pwd)}"
SRC_NETS="${SRC_NETS:-}"
#: Приоритет задаётся ЯВНО и не случайно: правило без pref получает «минимальный минус один»,
#: и тогда порядок между нашими правилами и чужими решает очерёдность старта, а не замысел.
#: Расследовать это потом приходится по трафику, который ушёл не туда молча.
SRC_PREF="${SRC_PREF:-100}"

flush() {
  ip route flush table "$TABLE" 2>/dev/null || true
  # Снимаем ТОЛЬКО свои правила — по таблице. Голый `ip rule flush` снёс бы и чужие,
  # включая те, что держат доступ к самой машине.
  while ip rule list | grep -q "lookup $TABLE"; do
    ip rule del table "$TABLE" || break
  done
}

if [ "$FLUSH" = yes ]; then
  flush
  echo "таблица $TABLE очищена, правила на неё сняты"
  exit 0
fi

for f in other_ips germany_ips uae_ips; do
  [ -r "$LISTS/$f.txt" ] || { echo "нет списка: $LISTS/$f.txt" >&2; exit 1; }
done

[ -n "$SRC_NETS" ] || {
  echo "SRC_NETS пуст: не задано, ЧЕЙ трафик заворачивать." >&2
  echo "Без источников таблица будет наполнена и не будет использована никем —" >&2
  echo "молчаливый холостой ход, который выглядит как рабочая настройка." >&2
  exit 2
}

flush

BATCH="$(mktemp)"
trap 'rm -f "$BATCH"' EXIT INT TERM

{
  echo "#begin;"
  for f in germany_ips uae_ips other_ips; do
    # Пустые строки и комментарии пропускаем здесь, а не в ядре: `ip -batch` на первой же
    # негодной строке прекращает работу, и таблица остаётся заполненной наполовину.
    sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$LISTS/$f.txt" \
      | while IFS= read -r net; do
          echo "route add $net dev $IFACE table $TABLE"
        done
  done
  echo "#commit;"
} > "$BATCH"

echo "маршрутов к добавлению: $(($(wc -l < "$BATCH") - 2))"
ip -batch "$BATCH"

for src in $SRC_NETS; do
  ip rule add from "$src" table "$TABLE" pref "$SRC_PREF"
  SRC_PREF=$((SRC_PREF + 1))
done

echo "готово: таблица $TABLE через $IFACE, источники: $SRC_NETS"
ip rule list | grep "lookup $TABLE" || true
