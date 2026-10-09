#!/usr/bin/env bash
# replay_ceiling.sh -- reproducible demonstration of the WAL replay ceiling of a
# streaming standby, and of how WAL generation on the primary scales past it.
#
# It builds a throwaway primary + one streaming standby from the PostgreSQL build
# that PG_CONFIG points at, bulk-loads ROWS rows (primary key + a secondary btree on
# a random int) and, per round:
#
#   1 session  : WAL generation rate with a single loading session
#   K sessions : WAL generation rate with SESSIONS concurrent sessions
#
# In both, replay on the standby is PAUSED during the load (pg_wal_replay_pause), so
# the walreceiver alone is measured against generation. Once all WAL is on the
# standby, replay is resumed and timed from local WAL: that is the replay ceiling,
# with the network and the primary out of the way.
#
# A final streaming round (replay NOT paused) records the lag curve to lag.csv.
#
# Linux only (uses /proc and GNU date). Needs: bash, awk, psql/initdb/pg_ctl/
# pg_basebackup from the same build. python3 is optional (draws lag.svg).
#
# Environment (all optional):
#   PG_CONFIG       pg_config of the build to test        (default: pg_config in PATH)
#   ROWS            rows per load                         (default: 10000000)
#   SESSIONS        concurrent loading sessions, K        (default: 4)
#   ROUNDS          paused rounds per mode                (default: 5)
#   WORKDIR         scratch directory, wiped at start     (default: ./replay-ceiling-work)
#   PRIMARY_PORT    / STANDBY_PORT                        (default: 5601 / 5602)
#   SHARED_BUFFERS  for both servers                      (default: 2GB)
#   PRIMARY_CPUS    taskset CPU list for the primary and the load clients (default: none)
#   STANDBY_CPUS    taskset CPU list for the standby       (default: none)
#   COOLDOWN        seconds to let the disk settle before each load (default: 20)
#   STREAM          1 = also run the streaming lag-curve round (default: 1)
#   KEEP            1 = keep WORKDIR and leave the servers stopped (default: 0)
#   ALLOW_ASSERTS   1 = run even on a build with assertions enabled (default: 0)
set -euo pipefail

PG_CONFIG=${PG_CONFIG:-pg_config}
ROWS=${ROWS:-10000000}
SESSIONS=${SESSIONS:-4}
ROUNDS=${ROUNDS:-5}
WORKDIR=${WORKDIR:-$PWD/replay-ceiling-work}
PRIMARY_PORT=${PRIMARY_PORT:-5601}
STANDBY_PORT=${STANDBY_PORT:-5602}
SHARED_BUFFERS=${SHARED_BUFFERS:-2GB}
PRIMARY_CPUS=${PRIMARY_CPUS:-}
STANDBY_CPUS=${STANDBY_CPUS:-}
COOLDOWN=${COOLDOWN:-20}
STREAM=${STREAM:-1}
KEEP=${KEEP:-0}
BATCH=100000

HERE=$(dirname "$(readlink -f "$0")")
BIN=$("$PG_CONFIG" --bindir)
PRIM=$WORKDIR/primary
STBY=$WORKDIR/standby
# Unix socket paths are limited to ~107 bytes, so the sockets live in a short temporary
# directory instead of under WORKDIR (which may be long). SOCKET_DIR overrides it.
SOCK=${SOCKET_DIR:-$(mktemp -d /tmp/rc.XXXXXX)}
CLK=$(getconf CLK_TCK)
export PGHOST=$SOCK PGUSER=postgres PGDATABASE=postgres PGOPTIONS="-c client_min_messages=warning"

pp() { "$BIN/psql" -X -q -At -p "$PRIMARY_PORT" -v ON_ERROR_STOP=1 -c "$1"; }
sp() { "$BIN/psql" -X -q -At -p "$STANDBY_PORT" -v ON_ERROR_STOP=1 -c "$1"; }
now() { date +%s.%N; }
calc() { awk "BEGIN { printf \"%.1f\", $1 }"; }
ratio() { awk "BEGIN { printf \"%.2f\", $1 }"; }
pin() {  # <cpu list or empty> command...
  local cpus=$1; shift
  if [ -n "$cpus" ] && command -v taskset >/dev/null; then taskset -c "$cpus" "$@"; else "$@"; fi
}
ticks() { [ -r "/proc/$1/stat" ] && awk '{print $14 + $15}' "/proc/$1/stat" || echo 0; }
median() { sort -n | awk '{a[NR] = $1} END {if (NR == 0) print "n/a"; else if (NR % 2) print a[(NR + 1) / 2]; else printf "%.1f\n", (a[NR / 2] + a[NR / 2 + 1]) / 2}'; }
range() { sort -n | awk 'NR == 1 {lo = $1} {hi = $1} END {print lo ".." hi}'; }

cleanup() {
  "$BIN/pg_ctl" -D "$STBY" -m fast -w stop >/dev/null 2>&1 || true
  "$BIN/pg_ctl" -D "$PRIM" -m fast -w stop >/dev/null 2>&1 || true
  [ "$KEEP" = 1 ] || rm -rf "$PRIM" "$STBY"
  [ -n "${SOCKET_DIR:-}" ] || rm -rf "$SOCK"   # our own temporary socket directory
}
trap cleanup EXIT

if "$PG_CONFIG" --configure 2>/dev/null | grep -q -- '--enable-cassert'; then
  echo "This build has assertions enabled (--enable-cassert): rates will be far lower than a production build." >&2
  [ "${ALLOW_ASSERTS:-0}" = 1 ] || { echo "Set ALLOW_ASSERTS=1 to run anyway." >&2; exit 2; }
fi

# ---------------------------------------------------------------- setup
rm -rf "$WORKDIR"
mkdir -p "$SOCK" "$WORKDIR/rounds"
echo "sockets: $SOCK" > "$WORKDIR/sockets.txt"
"$BIN/initdb" -D "$PRIM" -U postgres -A trust -E UTF8 >/dev/null
cat >> "$PRIM/postgresql.conf" <<CONF
port = $PRIMARY_PORT
listen_addresses = ''
unix_socket_directories = '$SOCK'
shared_buffers = $SHARED_BUFFERS
wal_level = replica
max_wal_senders = 4
max_replication_slots = 4
max_wal_size = 32GB
min_wal_size = 32GB
checkpoint_timeout = 30min
autovacuum = off
CONF
pin "$PRIMARY_CPUS" "$BIN/pg_ctl" -D "$PRIM" -l "$WORKDIR/primary.log" -w start >/dev/null
if [ "$(pp 'show debug_assertions')" = on ] && [ "${ALLOW_ASSERTS:-0}" != 1 ]; then
  echo "debug_assertions = on: rates will be far lower than a production build. Set ALLOW_ASSERTS=1 to run anyway." >&2
  exit 2
fi
pp "select pg_create_physical_replication_slot('standby')" >/dev/null
"$BIN/pg_basebackup" -D "$STBY" -h "$SOCK" -p "$PRIMARY_PORT" -U postgres -X stream -S standby -R -c fast >/dev/null
cat >> "$STBY/postgresql.conf" <<CONF
port = $STANDBY_PORT
hot_standby = on
CONF
pin "$STANDBY_CPUS" "$BIN/pg_ctl" -D "$STBY" -l "$WORKDIR/standby.log" -w start >/dev/null
until [ "$(pp "select count(*) from pg_stat_replication where state = 'streaming'")" = 1 ]; do sleep 0.2; done

caught_up() {  # standby has replayed everything the primary has written so far
  local target; target=$(pp "select pg_current_wal_lsn()")
  until [ "$(sp "select pg_last_wal_replay_lsn() >= '$target'::pg_lsn")" = t ]; do sleep 0.2; done
}
lsn_bytes() { pp "select pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')"; }

prepare() {  # <sessions>: same starting state every round
  local k=$1 i
  pp "do \$\$ declare r record; begin for r in select tablename from pg_tables where schemaname = 'public' loop execute format('drop table %I', r.tablename); end loop; end \$\$"
  pp "checkpoint"; caught_up; sp "checkpoint"
  sleep "$COOLDOWN"
  for i in $(seq 1 "$k"); do
    pp "create table load_$i (id bigint primary key, a int not null, b text not null, c timestamptz not null)"
    pp "create index load_${i}_a on load_$i (a)"
  done
  caught_up
}

load() {  # <sessions> <dir>: ROWS rows split over the sessions, one table each
  local k=$1 dir=$2 per i lo hi
  per=$(( ROWS / k ))
  for i in $(seq 1 "$k"); do
    : > "$dir/load_$i.sql"
    for (( lo = 1; lo <= per; lo += BATCH )); do
      hi=$(( lo + BATCH - 1 )); (( hi > per )) && hi=$per
      echo "insert into load_$i select g, (random() * 2147483646)::int, md5(g::text), now() from generate_series($lo, $hi) g;" >> "$dir/load_$i.sql"
    done
  done
  local pids=()
  for i in $(seq 1 "$k"); do
    pin "$PRIMARY_CPUS" "$BIN/psql" -X -q -p "$PRIMARY_PORT" -v ON_ERROR_STOP=1 -f "$dir/load_$i.sql" &
    pids+=($!)
  done
  wait "${pids[@]}"   # only the load clients, not the lag sampler
}

paused_round() {  # <sessions> -> "gen_MBps recv_MBps replay_MBps startup_cpu_pct"
  local k=$1 dir t0 t1 tr tres t2 l0 l1 end pid c0 c1
  dir=$WORKDIR/rounds/$(date +%H%M%S)-k$k; mkdir -p "$dir"
  prepare "$k"
  pid=$(sp "select pid from pg_stat_activity where backend_type = 'startup'")
  sp "select pg_wal_replay_pause()" >/dev/null
  t0=$(now); l0=$(lsn_bytes)
  load "$k" "$dir"
  t1=$(now); l1=$(lsn_bytes); end=$(pp "select pg_current_wal_lsn()")
  until [ "$(sp "select pg_last_wal_receive_lsn() >= '$end'::pg_lsn")" = t ]; do sleep 0.05; done
  tr=$(now)
  c0=$(ticks "$pid"); tres=$(now)
  sp "select pg_wal_replay_resume()" >/dev/null
  until [ "$(sp "select pg_last_wal_replay_lsn() >= '$end'::pg_lsn")" = t ]; do sleep 0.05; done
  t2=$(now); c1=$(ticks "$pid")
  echo "$(calc "($l1 - $l0) / ($t1 - $t0) / 1e6") $(calc "($l1 - $l0) / ($tr - $t0) / 1e6") $(calc "($l1 - $l0) / ($t2 - $tres) / 1e6") $(calc "100 * ($c1 - $c0) / $CLK / ($t2 - $tres)")"
}

streaming_round() {  # <sessions>: replay NOT paused; lag sampled every 0.25 s into lag.csv
  local k=$1 dir t0 t1 t2 l0 l1 end spid
  dir=$WORKDIR/rounds/$(date +%H%M%S)-k$k-streaming; mkdir -p "$dir"
  prepare "$k"
  l0=$(lsn_bytes); t0=$(now)
  (
    echo "seconds,generated_mb,receive_lag_mb,replay_lag_mb"
    while :; do
      t=$(now); g=$(lsn_bytes)
      s=$(sp "select pg_wal_lsn_diff(pg_last_wal_receive_lsn(), '0/0') || ',' || pg_wal_lsn_diff(pg_last_wal_replay_lsn(), '0/0')")
      awk -v t="$t" -v t0="$t0" -v g="$g" -v l0="$l0" -v s="$s" 'BEGIN {
        split(s, r, ","); printf "%.2f,%.1f,%.1f,%.1f\n", t - t0, (g - l0) / 1e6, (g - r[1]) / 1e6, (g - r[2]) / 1e6 }'
      sleep 0.25
    done
  ) > "$WORKDIR/lag.csv" &
  spid=$!
  load "$k" "$dir"
  t1=$(now); l1=$(lsn_bytes); end=$(pp "select pg_current_wal_lsn()")
  until [ "$(sp "select pg_last_wal_replay_lsn() >= '$end'::pg_lsn")" = t ]; do sleep 0.05; done
  t2=$(now)
  sleep 0.5; kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null || true
  STREAM_GEN=$(calc "($l1 - $l0) / ($t1 - $t0) / 1e6")
  STREAM_LOAD_S=$(calc "$t1 - $t0")
  STREAM_CATCHUP_S=$(calc "$t2 - $t1")
  STREAM_REPLAY=$(calc "($l1 - $l0) / ($t2 - $t0) / 1e6")
  STREAM_MAX_REPLAY_LAG=$(awk -F, 'NR > 1 && $4 > m {m = $4} END {printf "%.0f", m}' "$WORKDIR/lag.csv")
  STREAM_MAX_RECV_LAG=$(awk -F, 'NR > 1 && $3 > m {m = $3} END {printf "%.0f", m}' "$WORKDIR/lag.csv")
}

# ---------------------------------------------------------------- measure
echo "PostgreSQL: $(pp 'select version()' | cut -d, -f1)"
echo "rows per load: $ROWS, sessions: 1 and $SESSIONS, rounds: $ROUNDS, shared_buffers: $SHARED_BUFFERS"
echo "primary CPUs: ${PRIMARY_CPUS:-any}, standby CPUs: ${STANDBY_CPUS:-any}, workdir: $WORKDIR"
echo
printf "%-6s %-9s %12s %12s %14s %13s\n" round sessions "gen MB/s" "recv MB/s" "replay MB/s" "startup CPU%"
: > "$WORKDIR/results.txt"
for r in $(seq 1 "$ROUNDS"); do
  for k in 1 "$SESSIONS"; do
    read -r g rc rp cpu < <(paused_round "$k")
    printf "%-6s %-9s %12s %12s %14s %13s\n" "$r" "$k" "$g" "$rc" "$rp" "$cpu"
    echo "$k $g $rc $rp $cpu" >> "$WORKDIR/results.txt"
  done
done

col() { awk -v k="$1" -v c="$2" '$1 == k {print $c}' "$WORKDIR/results.txt"; }
REPLAY=$( { col 1 4; col "$SESSIONS" 4; } | median)
REPLAY_RANGE=$( { col 1 4; col "$SESSIONS" 4; } | range)
CPU=$( { col 1 5; col "$SESSIONS" 5; } | median)
GEN1=$(col 1 2 | median); GEN1_RANGE=$(col 1 2 | range)
GENK=$(col "$SESSIONS" 2 | median); GENK_RANGE=$(col "$SESSIONS" 2 | range)
RECVK=$(col "$SESSIONS" 3 | median)

echo
echo "Summary (medians over $ROUNDS rounds; MB = 10^6 bytes)"
echo "  replay ceiling (paused replay, local WAL): $REPLAY MB/s  [$REPLAY_RANGE]   startup process CPU: $CPU%"
echo "  WAL generation, 1 session:                 $GEN1 MB/s  [$GEN1_RANGE]   = $(ratio "$GEN1 / $REPLAY") x replay ceiling"
echo "  WAL generation, $SESSIONS sessions:                $GENK MB/s  [$GENK_RANGE]   = $(ratio "$GENK / $REPLAY") x replay ceiling"
echo "  walreceiver vs generation, $SESSIONS sessions:     $RECVK MB/s received (receive keeps up if close to generation)"
if awk "BEGIN {exit !($GENK > $REPLAY)}"; then
  echo "  -> median generation with $SESSIONS sessions is above the median replay ceiling: lag grows at about $(calc "$GENK - $REPLAY") MB/s"
  echo "     while the load runs. Compare the ranges above: when they overlap, a small gap can be noise."
else
  echo "  -> with $SESSIONS sessions the primary does not outrun replay on this machine; try a larger SESSIONS (and enough PRIMARY_CPUS)."
fi

if [ "$STREAM" = 1 ]; then
  streaming_round "$SESSIONS"
  echo
  echo "Streaming round (replay not paused, $SESSIONS sessions):"
  echo "  generation $STREAM_GEN MB/s over $STREAM_LOAD_S s; replay average $STREAM_REPLAY MB/s"
  echo "  max receive lag $STREAM_MAX_RECV_LAG MB, max replay lag $STREAM_MAX_REPLAY_LAG MB, catch-up after the load $STREAM_CATCHUP_S s"
  echo "  lag curve: $WORKDIR/lag.csv"
  if command -v python3 >/dev/null && [ -f "$HERE/plot_lag.py" ]; then
    python3 "$HERE/plot_lag.py" "$WORKDIR/lag.csv" --load-seconds "$STREAM_LOAD_S" \
      --title "Standby lag, $ROWS rows, $SESSIONS sessions, generation $STREAM_GEN MB/s" -o "$WORKDIR/lag.svg" \
      && echo "  lag chart: $WORKDIR/lag.svg"
  fi
fi
