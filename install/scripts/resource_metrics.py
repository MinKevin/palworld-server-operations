#!/usr/bin/env python3
"""Low-overhead host and container resource sampling with bounded history."""

from __future__ import annotations

import copy
import math
import os
import re
import sqlite3
import threading
import time
from contextlib import closing
from datetime import datetime
from pathlib import Path
from typing import Any, Callable


DEFAULT_SAMPLE_SECONDS = 1.0
DEFAULT_HISTORY_SECONDS = 15
DEFAULT_RETENTION_SECONDS = 7 * 24 * 60 * 60
MIN_HISTORY_WINDOW_SECONDS = 5 * 60
MAX_HISTORY_WINDOW_SECONDS = DEFAULT_RETENTION_SECONDS
MIN_HISTORY_POINTS = 60
MAX_HISTORY_POINTS = 1000


def _read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def _read_number(path: Path) -> int:
    return int(_read_text(path).strip())


def _read_host_cpu(path: Path) -> tuple[int, int, int]:
    total = idle = 0
    cores = 0
    for line in _read_text(path).splitlines():
        if line.startswith("cpu "):
            values = [int(value) for value in line.split()[1:9]]
            total = sum(values)
            idle = values[3] + values[4]
        elif re.fullmatch(r"cpu[0-9]+\s+.*", line):
            cores += 1
    if total <= 0:
        raise ValueError(f"host CPU counters are unavailable: {path}")
    return total, idle, max(1, cores)


def _read_host_memory(path: Path) -> tuple[int, int]:
    values: dict[str, int] = {}
    for line in _read_text(path).splitlines():
        key, separator, raw = line.partition(":")
        if not separator:
            continue
        match = re.match(r"\s*([0-9]+)\s+kB", raw)
        if match:
            values[key] = int(match.group(1)) * 1024
    total = values.get("MemTotal", 0)
    available = values.get("MemAvailable", 0)
    if total <= 0 or available < 0:
        raise ValueError(f"host memory counters are unavailable: {path}")
    return max(0, total - available), total


def _read_network_devices(path: Path) -> dict[str, tuple[int, int]]:
    devices: dict[str, tuple[int, int]] = {}
    for line in _read_text(path).splitlines():
        if ":" not in line:
            continue
        interface, raw = line.split(":", 1)
        columns = raw.split()
        if len(columns) < 9:
            continue
        devices[interface.strip()] = (int(columns[0]), int(columns[8]))
    return devices


def _read_default_interface(path: Path) -> str:
    selected = ""
    selected_metric: int | None = None
    for line in _read_text(path).splitlines()[1:]:
        columns = line.split()
        if len(columns) < 8 or columns[1] != "00000000":
            continue
        try:
            flags = int(columns[3], 16)
            metric = int(columns[6])
        except ValueError:
            continue
        if not flags & 0x1:
            continue
        if selected_metric is None or metric < selected_metric:
            selected = columns[0]
            selected_metric = metric
    return selected


def _aggregate_container_network(path: Path) -> tuple[int, int]:
    devices = _read_network_devices(path)
    values = [value for name, value in devices.items() if name != "lo"]
    return sum(value[0] for value in values), sum(value[1] for value in values)


def _parse_self_cgroups(path: Path) -> tuple[str, dict[str, str]]:
    unified = ""
    controllers: dict[str, str] = {}
    try:
        lines = _read_text(path).splitlines()
    except OSError:
        return unified, controllers
    for line in lines:
        parts = line.split(":", 2)
        if len(parts) != 3:
            continue
        if parts[0] == "0" and not parts[1]:
            unified = parts[2]
        for controller in parts[1].split(","):
            if controller:
                controllers[controller] = parts[2]
    return unified, controllers


def _candidate_cgroup_files(
    root: Path,
    name: str,
    *,
    unified_path: str,
    controller_paths: dict[str, str],
    controller: str,
) -> list[Path]:
    relative_unified = unified_path.lstrip("/")
    relative_controller = controller_paths.get(controller, "").lstrip("/")
    values = [
        root / relative_unified / name,
        root / name,
        root / controller / relative_controller / name,
        root / controller / name,
        root / relative_controller / name,
    ]
    unique: list[Path] = []
    for value in values:
        if value not in unique:
            unique.append(value)
    return unique


def _first_existing(paths: list[Path]) -> Path:
    for path in paths:
        if path.is_file():
            return path
    raise FileNotFoundError(str(paths[0] if paths else "cgroup counter"))


def _read_cgroup_cpu_usage_ns(
    root: Path,
    unified_path: str,
    controller_paths: dict[str, str],
) -> int:
    cpu_stat_candidates = _candidate_cgroup_files(
        root,
        "cpu.stat",
        unified_path=unified_path,
        controller_paths=controller_paths,
        controller="cpu",
    )
    cpu_stat = next((path for path in cpu_stat_candidates if path.is_file()), None)
    if cpu_stat is not None:
        for line in _read_text(cpu_stat).splitlines():
            key, _, raw = line.partition(" ")
            if key == "usage_usec":
                return int(raw.strip()) * 1000
    usage = _first_existing(
        _candidate_cgroup_files(
            root,
            "cpuacct.usage",
            unified_path=unified_path,
            controller_paths=controller_paths,
            controller="cpuacct",
        )
    )
    return _read_number(usage)


def _read_inactive_memory(path: Path) -> int:
    try:
        for line in _read_text(path).splitlines():
            key, _, raw = line.partition(" ")
            if key in {"inactive_file", "total_inactive_file"}:
                return max(0, int(raw.strip()))
    except (OSError, ValueError):
        pass
    return 0


def _read_cgroup_memory_used(
    root: Path,
    unified_path: str,
    controller_paths: dict[str, str],
) -> int:
    current_candidates = _candidate_cgroup_files(
        root,
        "memory.current",
        unified_path=unified_path,
        controller_paths=controller_paths,
        controller="memory",
    )
    current_candidates.extend(
        _candidate_cgroup_files(
            root,
            "memory.usage_in_bytes",
            unified_path=unified_path,
            controller_paths=controller_paths,
            controller="memory",
        )
    )
    current_path = _first_existing(current_candidates)
    current = _read_number(current_path)
    stat_path = current_path.with_name("memory.stat")
    return max(0, current - _read_inactive_memory(stat_path))


def _rate(current: int, previous: int | None, elapsed: float) -> float | None:
    if previous is None or elapsed <= 0 or current < previous:
        return None
    return (current - previous) / elapsed


def _percent(value: float | None) -> float | None:
    if value is None:
        return None
    return round(max(0.0, min(100.0, value)), 2)


class ResourceUsageSampler:
    def __init__(
        self,
        *,
        instance_name: str | None = None,
        host_cpu_stat: Path | None = None,
        host_meminfo: Path | None = None,
        host_net_dev: Path | None = None,
        host_net_route: Path | None = None,
        container_net_dev: Path | None = None,
        cgroup_root: Path | None = None,
        self_cgroup: Path | None = None,
    ) -> None:
        self.instance_name = instance_name or os.getenv("INSTANCE_NAME", "unknown")
        self.host_cpu_stat = host_cpu_stat or Path(
            os.getenv("HOST_PROC_STAT", "/host-proc-stat")
        )
        self.host_meminfo = host_meminfo or Path(
            os.getenv("HOST_PROC_MEMINFO", "/host-proc-meminfo")
        )
        self.host_net_dev = host_net_dev or Path(
            os.getenv("HOST_PROC_NET_DEV", "/host-proc-net-dev")
        )
        self.host_net_route = host_net_route or Path(
            os.getenv("HOST_PROC_NET_ROUTE", "/host-proc-net-route")
        )
        self.container_net_dev = container_net_dev or Path("/proc/net/dev")
        self.cgroup_root = cgroup_root or Path("/sys/fs/cgroup")
        self.self_cgroup = self_cgroup or Path("/proc/self/cgroup")
        self._previous_monotonic: float | None = None
        self._previous_host_total: int | None = None
        self._previous_host_idle: int | None = None
        self._previous_host_interface = ""
        self._previous_host_receive: int | None = None
        self._previous_host_transmit: int | None = None
        self._previous_container_cpu: int | None = None
        self._previous_container_receive: int | None = None
        self._previous_container_transmit: int | None = None

    def sample(self) -> dict[str, Any]:
        sampled_at = time.time()
        current_monotonic = time.monotonic()
        elapsed = (
            current_monotonic - self._previous_monotonic
            if self._previous_monotonic is not None
            else 0.0
        )
        errors: list[str] = []

        host_total = host_idle = 0
        host_cores = 1
        host_cpu: float | None = None
        try:
            host_total, host_idle, host_cores = _read_host_cpu(self.host_cpu_stat)
            if self._previous_host_total is not None and self._previous_host_idle is not None:
                total_delta = host_total - self._previous_host_total
                idle_delta = host_idle - self._previous_host_idle
                if total_delta > 0 and idle_delta >= 0:
                    host_cpu = _percent((total_delta - idle_delta) * 100.0 / total_delta)
        except (OSError, ValueError) as error:
            errors.append(f"host cpu: {error}")

        host_memory_used = host_memory_total = None
        try:
            host_memory_used, host_memory_total = _read_host_memory(self.host_meminfo)
        except (OSError, ValueError) as error:
            errors.append(f"host memory: {error}")

        host_interface = ""
        host_receive = host_transmit = 0
        host_receive_rate = host_transmit_rate = None
        try:
            host_interface = _read_default_interface(self.host_net_route)
            devices = _read_network_devices(self.host_net_dev)
            if not host_interface or host_interface not in devices:
                raise ValueError("default host network interface is unavailable")
            host_receive, host_transmit = devices[host_interface]
            if host_interface == self._previous_host_interface:
                host_receive_rate = _rate(
                    host_receive, self._previous_host_receive, elapsed
                )
                host_transmit_rate = _rate(
                    host_transmit, self._previous_host_transmit, elapsed
                )
        except (OSError, ValueError) as error:
            errors.append(f"host network: {error}")

        unified_path, controller_paths = _parse_self_cgroups(self.self_cgroup)
        container_cpu_usage = 0
        container_cpu: float | None = None
        try:
            container_cpu_usage = _read_cgroup_cpu_usage_ns(
                self.cgroup_root, unified_path, controller_paths
            )
            cpu_rate = _rate(
                container_cpu_usage, self._previous_container_cpu, elapsed
            )
            if cpu_rate is not None:
                container_cpu = _percent(cpu_rate / 1_000_000_000 / host_cores * 100.0)
        except (OSError, ValueError) as error:
            errors.append(f"container cpu: {error}")

        container_memory_used = None
        try:
            container_memory_used = _read_cgroup_memory_used(
                self.cgroup_root, unified_path, controller_paths
            )
        except (OSError, ValueError) as error:
            errors.append(f"container memory: {error}")

        container_receive = container_transmit = 0
        container_receive_rate = container_transmit_rate = None
        container_network_available = False
        try:
            container_receive, container_transmit = _aggregate_container_network(
                self.container_net_dev
            )
            container_network_available = True
            container_receive_rate = _rate(
                container_receive, self._previous_container_receive, elapsed
            )
            container_transmit_rate = _rate(
                container_transmit, self._previous_container_transmit, elapsed
            )
        except (OSError, ValueError) as error:
            errors.append(f"container network: {error}")

        self._previous_monotonic = current_monotonic
        if host_total > 0:
            self._previous_host_total = host_total
            self._previous_host_idle = host_idle
        if host_interface:
            self._previous_host_interface = host_interface
            self._previous_host_receive = host_receive
            self._previous_host_transmit = host_transmit
        if container_cpu_usage > 0:
            self._previous_container_cpu = container_cpu_usage
        if container_network_available:
            self._previous_container_receive = container_receive
            self._previous_container_transmit = container_transmit

        return {
            "sampled_at": sampled_at,
            "sampled_at_iso": datetime.now().astimezone().isoformat(timespec="seconds"),
            "interval_seconds": round(elapsed, 3) if elapsed > 0 else None,
            "host": {
                "cpu_percent": host_cpu,
                "memory_used_bytes": host_memory_used,
                "memory_total_bytes": host_memory_total,
                "network_receive_bytes_per_second": (
                    round(host_receive_rate, 2) if host_receive_rate is not None else None
                ),
                "network_transmit_bytes_per_second": (
                    round(host_transmit_rate, 2) if host_transmit_rate is not None else None
                ),
                "network_interface": host_interface,
            },
            "container": {
                "instance": self.instance_name,
                "cpu_percent": container_cpu,
                "memory_used_bytes": container_memory_used,
                "network_receive_bytes_per_second": (
                    round(container_receive_rate, 2)
                    if container_receive_rate is not None
                    else None
                ),
                "network_transmit_bytes_per_second": (
                    round(container_transmit_rate, 2)
                    if container_transmit_rate is not None
                    else None
                ),
            },
            "errors": errors,
        }


class ResourceUsageMonitor:
    def __init__(
        self,
        logger: Callable[[str], None],
        *,
        sampler: ResourceUsageSampler | None = None,
        database_path: Path | None = None,
        sample_seconds: float = DEFAULT_SAMPLE_SECONDS,
        history_seconds: int = DEFAULT_HISTORY_SECONDS,
        retention_seconds: int = DEFAULT_RETENTION_SECONDS,
    ) -> None:
        self.logger = logger
        self.sampler = sampler or ResourceUsageSampler()
        self.database_path = database_path or Path(
            os.getenv(
                "RESOURCE_USAGE_DB",
                "/palworld/logs/resource-usage.sqlite3",
            )
        )
        self.sample_seconds = max(0.5, float(sample_seconds))
        self.history_seconds = max(5, int(history_seconds))
        self.retention_seconds = max(self.history_seconds, int(retention_seconds))
        self._lock = threading.Lock()
        self._current: dict[str, Any] | None = None
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread is not None:
            return
        self._thread = threading.Thread(
            target=self._run,
            name="resource-usage-monitor",
            daemon=True,
        )
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=max(2.0, self.sample_seconds * 2))
            self._thread = None

    def current(self) -> dict[str, Any] | None:
        with self._lock:
            return copy.deepcopy(self._current)

    @staticmethod
    def _initialize_database(connection: sqlite3.Connection) -> None:
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("PRAGMA synchronous=NORMAL")
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS resource_samples (
                sampled_at INTEGER PRIMARY KEY,
                host_cpu REAL,
                host_memory_used INTEGER,
                host_memory_total INTEGER,
                host_receive REAL,
                host_transmit REAL,
                container_cpu REAL,
                container_memory_used INTEGER,
                container_receive REAL,
                container_transmit REAL
            )
            """
        )
        connection.commit()

    @staticmethod
    def _sample_values(sample: dict[str, Any]) -> tuple[Any, ...]:
        host = sample.get("host") or {}
        container = sample.get("container") or {}
        return (
            int(float(sample["sampled_at"])),
            host.get("cpu_percent"),
            host.get("memory_used_bytes"),
            host.get("memory_total_bytes"),
            host.get("network_receive_bytes_per_second"),
            host.get("network_transmit_bytes_per_second"),
            container.get("cpu_percent"),
            container.get("memory_used_bytes"),
            container.get("network_receive_bytes_per_second"),
            container.get("network_transmit_bytes_per_second"),
        )

    def _run(self) -> None:
        connection: sqlite3.Connection | None = None
        next_history = 0.0
        next_cleanup = 0.0
        database_error = ""
        try:
            while not self._stop.is_set():
                cycle_started = time.monotonic()
                try:
                    sample = self.sampler.sample()
                    with self._lock:
                        self._current = sample
                    now = time.time()
                    if now >= next_history:
                        try:
                            if connection is None:
                                self.database_path.parent.mkdir(parents=True, exist_ok=True)
                                connection = sqlite3.connect(
                                    self.database_path, timeout=2.0
                                )
                                self._initialize_database(connection)
                            connection.execute(
                                """
                                INSERT OR REPLACE INTO resource_samples VALUES
                                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                                """,
                                self._sample_values(sample),
                            )
                            if now >= next_cleanup:
                                connection.execute(
                                    "DELETE FROM resource_samples WHERE sampled_at < ?",
                                    (int(now - self.retention_seconds),),
                                )
                                next_cleanup = now + 60 * 60
                            connection.commit()
                            next_history = now + self.history_seconds
                            if database_error:
                                self.logger("resource history storage recovered")
                                database_error = ""
                        except (OSError, sqlite3.Error, ValueError) as error:
                            message = str(error)
                            if message != database_error:
                                self.logger(f"resource history storage warning: {message}")
                                database_error = message
                            if connection is not None:
                                connection.close()
                                connection = None
                            next_history = now + 60
                except (OSError, ValueError) as error:
                    self.logger(f"resource sampling warning: {error}")
                remaining = self.sample_seconds - (time.monotonic() - cycle_started)
                self._stop.wait(max(0.05, remaining))
        finally:
            if connection is not None:
                connection.close()

    def history(self, window_seconds: int, max_points: int) -> dict[str, Any]:
        if not MIN_HISTORY_WINDOW_SECONDS <= window_seconds <= self.retention_seconds:
            raise ValueError(
                f"seconds must be between {MIN_HISTORY_WINDOW_SECONDS} and "
                f"{self.retention_seconds}"
            )
        if not MIN_HISTORY_POINTS <= max_points <= MAX_HISTORY_POINTS:
            raise ValueError(
                f"points must be between {MIN_HISTORY_POINTS} and {MAX_HISTORY_POINTS}"
            )
        bucket_seconds = max(
            self.history_seconds,
            int(math.ceil(window_seconds / max(1, max_points - 1))),
        )
        if not self.database_path.is_file():
            return {
                "window_seconds": window_seconds,
                "retention_seconds": self.retention_seconds,
                "bucket_seconds": bucket_seconds,
                "points": [],
            }
        cutoff = int(time.time()) - window_seconds
        with closing(sqlite3.connect(self.database_path, timeout=2.0)) as connection:
            rows = connection.execute(
                """
                SELECT
                    MAX(sampled_at),
                    AVG(host_cpu),
                    AVG(host_memory_used),
                    AVG(host_memory_total),
                    AVG(host_receive),
                    AVG(host_transmit),
                    AVG(container_cpu),
                    AVG(container_memory_used),
                    AVG(container_receive),
                    AVG(container_transmit)
                FROM resource_samples
                WHERE sampled_at >= ?
                GROUP BY CAST(sampled_at / ? AS INTEGER)
                ORDER BY MAX(sampled_at)
                """,
                (cutoff, bucket_seconds),
            ).fetchall()
        points = []
        for row in rows:
            points.append(
                {
                    "sampled_at": int(row[0]),
                    "host": {
                        "cpu_percent": row[1],
                        "memory_used_bytes": row[2],
                        "memory_total_bytes": row[3],
                        "network_receive_bytes_per_second": row[4],
                        "network_transmit_bytes_per_second": row[5],
                    },
                    "container": {
                        "instance": self.sampler.instance_name,
                        "cpu_percent": row[6],
                        "memory_used_bytes": row[7],
                        "network_receive_bytes_per_second": row[8],
                        "network_transmit_bytes_per_second": row[9],
                    },
                }
            )
        return {
            "window_seconds": window_seconds,
            "retention_seconds": self.retention_seconds,
            "bucket_seconds": bucket_seconds,
            "points": points,
        }
