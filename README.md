# pingtest.sh

`pingtest.sh` is a bash-based network ping monitoring and analysis tool. It runs a long-term ping test in the background and logs every result to a CSV file. Once you have data, a set of built-in analysis commands lets you quickly check on connectivity gaps, latency trends, and overall network health -- covering tests that run anywhere from a few minutes to 30+ days.

---

## Quick Start

The typical workflow looks like this:

```bash
# 1. Start a test
pingtest.sh start -f myhost.csv -h 10.0.0.1

# 2. Check on it while it's running
pingtest.sh status

# 3. Analyze the results
pingtest.sh stats -f myhost.csv

# 4. Stop the test when you're done
pingtest.sh stop -f myhost.csv
```

---

## Data Format

Results are stored in a plain CSV file with metadata comment lines at the top:

```
# PINGTEST.TIC v2
# host=10.0.0.1 (myhost)
# started=2026-03-24T10:00:00+00:00
# interval=1
# total_pings=2592000
timestamp,latency_ms,status
2026-03-24T10:00:01+00:00,4.23,ok
2026-03-24T10:00:02+00:00,8.91,ok
2026-03-24T10:00:03+00:00,-1,timeout
2026-03-24T10:00:04+00:00,5.44,ok
```

- Timestamps are full ISO-8601 format (year-aware, sortable, spans year boundaries correctly)
- Successful pings have a `latency_ms` value and `status` of `ok`
- Missed pings have `latency_ms` of `-1` and `status` of `timeout`
- The comment headers store the host, start time, ping interval, and total ping count

Because the output is plain CSV, it can also be opened directly in Excel, imported into Python/pandas, or processed with any standard text tools.

---

## Commands

### help

Get help on any command. Running `pingtest.sh help` with no arguments shows all available commands. Passing a command name shows detailed usage and examples for that specific command.

```
Usage: pingtest.sh help [command]
```

```bash
pingtest.sh help
pingtest.sh help start
pingtest.sh help latencycheck
```

---

### start

Starts a ping test in the background. Pings are sent to the target host at the specified interval and each result is appended to the output CSV file. When the test finishes (either by reaching the total ping count or being stopped with `stop`), an `# ended=` timestamp is written to the file.

A PID file (`<FILE>.pid`) is created in the current directory when the test starts and is automatically removed when the test ends. A log file (`<FILE>.log`) records start and stop events with timestamps.

```
Usage: pingtest.sh start -f <FILE> -h <HOST> [-t <COUNT>] [-i <INTERVAL>]
```

| Flag | Description | Default |
|------|-------------|---------|
| `-f FILE` | Output CSV file name (required) | |
| `-h HOST` | Target IP address or hostname (required) | |
| `-t COUNT` | Total number of pings to send | `2592000` (30 days at 1/sec) |
| `-i INTERVAL` | Seconds between each ping | `1` |

```bash
# Ping a host by name for the default 30 days
pingtest.sh start -f webserver.csv -h webserver01

# Ping an IP for 1 hour (3600 pings at 1/sec)
pingtest.sh start -f router.csv -h 172.27.84.170 -t 3600

# 24-hour test pinging every 2 seconds
pingtest.sh start -f switch.csv -h core-switch01 -t 43200 -i 2
```

---

### status

Shows the status of running ping tests. If `-f` is provided, it checks only that specific test. Otherwise it scans the current directory for all `.pid` files and reports on each one.

The output shows the data file name, process ID, whether the test is running or stopped, how many pings have been recorded so far, and the target host.

```
Usage: pingtest.sh status [-f <FILE>]
```

| Flag | Description | Default |
|------|-------------|---------|
| `-f FILE` | Check a specific test | All `.pid` files in current directory |

```bash
# Show status of all running tests in the current directory
pingtest.sh status

# Check the status of a specific test
pingtest.sh status -f webserver.csv
```

---

### stats

Shows a comprehensive summary of the entire data file. Useful for getting an at-a-glance picture of network quality over the test period.

```
Usage: pingtest.sh stats -f <FILE>
```

| Flag | Description |
|------|-------------|
| `-f FILE` | Data file to analyze (required) |

**Output metrics explained:**

| Metric | What it means |
|--------|---------------|
| **Total pings** | Total number of ping attempts recorded |
| **Successful** | Pings that got a response, with percentage |
| **Missed** | Pings that got no response (timeouts), with percentage |
| **Min** | Fastest single ping response time |
| **Max** | Slowest single ping response time |
| **Mean** | Average latency across all successful pings |
| **Median** | The middle value when all latencies are sorted -- less skewed by occasional spikes than the mean |
| **P95** | 95% of pings were at or below this latency. Only 5% were slower. Gives a sense of "typical bad" performance |
| **P99** | 99% of pings were at or below this latency. Only 1% were slower. Captures near-worst-case behavior |
| **Jitter** | Standard deviation of latency -- how much it varies ping to ping. A low jitter means consistent response times; a high jitter means unpredictable latency |

**Example:** If you see `Mean: 8ms`, `P95: 34ms`, `P99: 87ms` -- most pings are fast, but occasionally latency spikes. The difference between P95 and P99 tells you how severe those spikes get.

```bash
pingtest.sh stats -f webserver.csv
```

---

### pingcheck

Scans the data file for runs of consecutive missed pings that meet or exceed a minimum count. Each matching gap is reported with its start time, end time, and total number of missed pings. Useful for identifying specific outage windows.

For example, `-c 5` will find every period where the host was unreachable for 5 or more seconds in a row (assuming 1 ping/sec). Single dropped pings or short blips below the threshold are ignored.

```
Usage: pingtest.sh pingcheck -f <FILE> -c <COUNT>
```

| Flag | Description |
|------|-------------|
| `-f FILE` | Data file to analyze (required) |
| `-c COUNT` | Minimum number of consecutive missed pings to report (required) |

```bash
# Find drops of 4+ consecutive missed pings
pingtest.sh pingcheck -f webserver.csv -c 4

# Find only longer outages (10+ consecutive drops)
pingtest.sh pingcheck -f webserver.csv -c 10

# Same command using the short alias
pingtest.sh pc -f router.csv -c 3
```

---

### latencycheck

Shows how latency is distributed across configurable buckets, broken down by day. For each day in the data file, it counts how many pings fell into each latency range and how many were missed.

By default, buckets are in 10ms increments from 0 to 100ms, with a final `100+ ms` bucket. You can supply your own bucket boundaries with `-b` to suit your expected latency range -- for example, if you're monitoring a low-latency LAN you might want tighter buckets like `0,2,5,10,20`.

```
Usage: pingtest.sh latencycheck -f <FILE> [-d <DATE>] [-b <BUCKETS>]
```

| Flag | Description | Default |
|------|-------------|---------|
| `-f FILE` | Data file to analyze (required) | |
| `-d DATE` | Filter output to a single day (`YYYY-MM-DD`) | All days |
| `-b BUCKETS` | Comma-separated bucket boundary values in ms | `0,10,20,30,40,50,60,70,80,90,100` |

```bash
# Show all days with default 10ms buckets
pingtest.sh latencycheck -f webserver.csv

# Filter to a single day
pingtest.sh latencycheck -f webserver.csv -d 2026-03-26

# Custom bucket boundaries
pingtest.sh latencycheck -f webserver.csv -b 0,5,10,25,50,100,200

# Single day with custom buckets using the short alias
pingtest.sh lc -f webserver.csv -d 2026-03-26 -b 0,5,25,50,100
```

---

### avglat

Computes a rolling average latency over a sliding window of pings, outputting one row per window. Also reports how many pings were missed within each window. This is useful for spotting trends -- gradual latency increases, time-of-day patterns, or periods of instability.

The window size is set with `-c`. At the default of 30 (with 1 ping/sec), you get one data point every 30 seconds. Setting `-c 3600` gives hourly averages.

Output is CSV format: `Start Time, End Time, Avg Latency (ms), Missed Pings`

```
Usage: pingtest.sh avglat -f <FILE> [-c <COUNT>]
```

| Flag | Description | Default |
|------|-------------|---------|
| `-f FILE` | Data file to analyze (required) | |
| `-c COUNT` | Number of pings per window | `30` |

```bash
# Rolling average over default 30 pings (~30 second windows)
pingtest.sh avglat -f webserver.csv

# Average over 60-ping windows (~1 minute windows)
pingtest.sh avglat -f webserver.csv -c 60

# Hourly averages using the short alias
pingtest.sh al -f webserver.csv -c 3600
```

---

### stop

Gracefully stops a running ping test. Sends `SIGTERM` to the background process, waits up to 10 seconds for it to exit cleanly, and falls back to `SIGKILL` if it doesn't. On a clean stop, an `# ended=` timestamp is written to the data file before the process exits.

The `.pid` file is removed automatically after a successful stop.

```
Usage: pingtest.sh stop -f <FILE>
```

| Flag | Description |
|------|-------------|
| `-f FILE` | Data file of the test to stop (required) |

```bash
pingtest.sh stop -f webserver.csv
```

---

## Command Aliases

Shorter aliases are available for the three analysis commands:

| Alias | Full command |
|-------|-------------|
| `pc` | `pingcheck` |
| `lc` | `latencycheck` |
| `al` | `avglat` |

---

## Files Created

When you run `start`, three files are created alongside your data file:

| File | Purpose |
|------|---------|
| `<name>.csv` | The main ping data file in CSV format |
| `<name>.csv.pid` | Tracks the background process PID while the test is running. Removed automatically when the test ends or is stopped |
| `<name>.csv.log` | Records start and stop events with timestamps. Useful for auditing when tests were run |

---

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Usage error (bad command or missing required argument) |
| `2` | Output file already exists |
| `3` | Data file not found |
| `4` | Invalid input (bad format for a flag value) |
| `5` | Process not running (when trying to stop a test) |
| `6` | Ping failed to start |
