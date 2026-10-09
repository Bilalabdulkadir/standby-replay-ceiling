# Standby replay ceiling: a reproducible demonstration

[![CI](https://github.com/Manuelreyesbravo/standby-replay-ceiling/actions/workflows/ci.yml/badge.svg)](https://github.com/Manuelreyesbravo/standby-replay-ceiling/actions/workflows/ci.yml)

WAL replay on a PostgreSQL physical standby is done by a single process (the
startup process), while the primary generates WAL from many backends at once.
This is well known. This kit does not report anything new: it lets you **see**
that limit on your own hardware, with numbers, in about 15 minutes.

It builds a throwaway primary and one streaming standby from the PostgreSQL build
you point it at, bulk-loads rows into indexed tables, and measures:

- the **replay ceiling**: how fast the standby applies WAL when replay is the only
  thing happening;
- **WAL generation** on the primary with 1 and with K concurrent loading sessions;
- a **lag curve** of a normal streaming run, separating receive lag from replay lag.

## Quick start

```sh
PG_CONFIG=/path/to/pgsql/bin/pg_config ./replay_ceiling.sh
```

Use a build **without** assertions (`--enable-cassert` or `debug_assertions = on`
slows everything down and the script refuses to run unless `ALLOW_ASSERTS=1`).

To keep the standby from sharing CPU with the load, pin them apart, for example:

```sh
PG_CONFIG=... STANDBY_CPUS=0,12 PRIMARY_CPUS=1-3,13-15 ./replay_ceiling.sh
```

Requirements: Linux (it reads `/proc` and uses GNU `date`), bash, awk, and
`psql`, `initdb`, `pg_ctl`, `pg_basebackup` from the same build. `python3` is
optional and only used to draw `lag.svg`. Disk: up to about 70 GB free in `WORKDIR`
with the defaults (two clusters, each keeping up to 32 GB of recycled WAL).

## Settings (environment variables)

| variable | default | meaning |
|---|---|---|
| `PG_CONFIG` | `pg_config` in PATH | build under test |
| `ROWS` | 10000000 | rows per load (about 255 bytes of WAL per row) |
| `SESSIONS` | 4 | concurrent loading sessions (K) |
| `ROUNDS` | 5 | rounds per mode; medians and ranges are reported |
| `WORKDIR` | `./replay-ceiling-work` | scratch directory, wiped at start |
| `PRIMARY_PORT`, `STANDBY_PORT` | 5601, 5602 | ports (unix sockets only) |
| `SOCKET_DIR` | a new `/tmp/rc.XXXXXX` | socket directory (kept short: socket paths max out near 107 bytes) |
| `SHARED_BUFFERS` | 2GB | for both servers |
| `PRIMARY_CPUS`, `STANDBY_CPUS` | unset | `taskset` CPU lists |
| `COOLDOWN` | 20 | seconds to let the disk settle before each load |
| `STREAM` | 1 | also run the streaming lag-curve round |
| `KEEP` | 0 | keep `WORKDIR` afterwards |

## How it measures

Each round starts from the same state: previous tables dropped, a checkpoint on
both servers, a short cool-down, then fresh tables with a primary key and a
secondary btree on a random integer. `ROWS` rows are split over the sessions,
one table per session, in batches of 100,000 rows per transaction.

**The pause/resume trick.** During the load, replay on the standby is paused with
`pg_wal_replay_pause()`. The walreceiver keeps receiving, so generation is
measured against reception alone. When the standby has received all the WAL,
replay is resumed with `pg_wal_replay_resume()` and timed until it reaches the
primary's last LSN. That time is pure replay from local WAL, with the network and
the primary out of the picture: the replay ceiling.

Rates are WAL bytes (LSN deltas) per second; MB = 10^6 bytes. "startup CPU%" is
the CPU time of the startup process (from `/proc`) during the replay phase, as a
percentage of one core.

The final streaming round does the same load with replay running normally and
samples, every 0.25 s, how far the standby's receive and replay positions are
behind the primary.

## Example output (one laptop-class machine)

PostgreSQL 19beta2 without assertions; AMD Ryzen AI 9 HX 370; primary and standby
on the same consumer NVMe; standby pinned to one core, primary to three:

```
round  sessions      gen MB/s    recv MB/s    replay MB/s  startup CPU%
1      1                 78.3         78.2          246.7          95.7
1      4                240.9        239.4          193.4          97.0
2      1                 72.5         72.5          215.8          91.6
2      4                203.6        202.5          165.5          69.6
3      1                 73.6         73.4          172.8          88.3
3      4                218.6        218.3          213.1          91.7
4      1                 71.5         71.4          189.0          87.9
4      4                214.0        213.7          197.3          94.0
5      1                 77.0         76.8          183.2          86.4
5      4                160.4        160.2          223.6          89.4

Summary (medians over 5 rounds; MB = 10^6 bytes)
  replay ceiling (paused replay, local WAL): 195.4 MB/s  [165.5..246.7]   startup process CPU: 90.5%
  WAL generation, 1 session:                 73.6 MB/s  [71.5..78.3]   = 0.38 x replay ceiling
  WAL generation, 4 sessions:                214.0 MB/s  [160.4..240.9]   = 1.10 x replay ceiling
  walreceiver vs generation, 4 sessions:     213.7 MB/s received (receive keeps up if close to generation)

Streaming round (replay not paused, 4 sessions):
  generation 172.9 MB/s over 14.8 s; replay average 144.9 MB/s
  max receive lag 64 MB, max replay lag 591 MB, catch-up after the load 2.9 s
```

`example-lag.svg` is the lag chart from that streaming round.

## How to read it

- **replay ceiling**: the rate one startup process can apply this kind of WAL on
  your standby. It does not grow with more primary sessions or more standby cores.
- **startup CPU%**: close to 100% means replay is limited by one CPU core. Lower
  values mean the startup process also spends time blocked (I/O, memory), which
  this script does not break down.
- **generation, 1 session vs K sessions**: the primary scales with sessions (and
  cores); replay does not. Where K-session generation passes the replay ceiling,
  a standby falls behind for as long as the load runs, at roughly the difference.
  On the machine above, one session is about 0.4x the ceiling and four sessions on
  three cores reach it; the ranges overlap, so the gap at K=4 is within noise
  there. A primary with more cores and more sessions goes further past it.
- **receive vs generation**: if received MB/s tracks generated MB/s, the network
  and the standby's WAL storage keep up, and any lag is replay.
- **lag curve**: replay lag growing while receive lag stays flat is the
  replay-bound case. If both grow together, the problem is WAL delivery (network
  or standby storage), and a faster replay would not help.

## Caveats

- **The numbers are your hardware's, not universal.** CPU speed, storage, memory
  and the shape of the WAL all move them. What carries over is the mechanism: one
  process replays, and its rate is a ceiling that primary concurrency can exceed.
- **Shared storage inflates the large case.** If primary and standby share a disk
  (as on the example machine), streaming replay runs slower than the paused
  ceiling (145 vs 195 MB/s above) because both servers compete for the same device
  and memory. Separate machines give a cleaner picture.
- **The ceiling degrades with the working set.** With 1M rows per load the same
  machine replays about 380 MB/s; with 10M rows, about 195 MB/s. When indexes and
  data no longer fit in shared buffers and the page cache, every WAL record costs
  more to apply. Run it with a `ROWS` that resembles your real batches.
- **Heavy writes can dirty a consumer disk for minutes.** Gigabytes of WAL and data
  per round can leave fsync latency several times higher for a while; `COOLDOWN`
  softens this, and spread between rounds is the honest error bar.
- **`recovery_prefetch`** (default `try`) helps when replay has to read pages that
  are not in memory. This load inserts into new pages that are already cached, so
  do not expect it to change the ceiling here.
- **Synthetic load.** One shape of WAL: inserts with a primary key and one random
  secondary index. Updates, wide rows, full-page writes after checkpoints and
  `wal_compression` all change the per-byte cost of replay.

## Files

- `replay_ceiling.sh`: the whole experiment, self-contained.
- `plot_lag.py`: draws `lag.svg` from `lag.csv`; standard library only. Run by the
  script when `python3` is available, or by hand:
  `python3 plot_lag.py WORKDIR/lag.csv --load-seconds 14.8 -o lag.svg`
- `example-lag.svg`: the chart from the example run above.
- `.github/workflows/ci.yml`: shellcheck, plus a functional smoke on PostgreSQL 17
  and 18 from PGDG.
- `LICENSE`: Apache License 2.0.

CI runs a functional smoke on a tiny load; the numbers above are from the hardware
described, not from CI.
