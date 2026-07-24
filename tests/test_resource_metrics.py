from __future__ import annotations

import sqlite3
import sys
import tempfile
import unittest
from contextlib import closing
from pathlib import Path
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[1] / "install" / "scripts"
sys.path.insert(0, str(SCRIPTS))

import resource_metrics  # noqa: E402


class ResourceUsageTests(unittest.TestCase):
    def test_sampler_reports_host_and_container_rates_without_a_memory_limit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host_stat = root / "host-stat"
            host_mem = root / "host-meminfo"
            host_net = root / "host-net-dev"
            host_route = root / "host-route"
            container_net = root / "container-net-dev"
            self_cgroup = root / "self-cgroup"
            cgroup = root / "cgroup"
            cgroup.mkdir()
            self_cgroup.write_text("0::/\n", encoding="utf-8")
            host_mem.write_text(
                "MemTotal:       32768000 kB\nMemAvailable:   20480000 kB\n",
                encoding="utf-8",
            )
            host_route.write_text(
                "Iface Destination Gateway Flags RefCnt Use Metric Mask MTU Window IRTT\n"
                "ens18 00000000 0100000A 0003 0 0 100 00000000 0 0 0\n",
                encoding="utf-8",
            )
            host_stat.write_text(
                "cpu  100 0 100 800 0 0 0 0 0 0\n"
                "cpu0 50 0 50 400 0 0 0 0 0 0\n"
                "cpu1 50 0 50 400 0 0 0 0 0 0\n",
                encoding="utf-8",
            )
            host_net.write_text(
                "Inter-| Receive | Transmit\n face |bytes packets errs drop fifo frame compressed multicast|bytes packets errs drop fifo colls carrier compressed\n"
                "ens18: 1000000 0 0 0 0 0 0 0 2000000 0 0 0 0 0 0 0\n",
                encoding="utf-8",
            )
            container_net.write_text(
                "Inter-| Receive | Transmit\n face |bytes packets errs drop fifo frame compressed multicast|bytes packets errs drop fifo colls carrier compressed\n"
                "eth0: 100000 0 0 0 0 0 0 0 200000 0 0 0 0 0 0 0\n",
                encoding="utf-8",
            )
            (cgroup / "cpu.stat").write_text("usage_usec 1000000\n", encoding="utf-8")
            (cgroup / "memory.current").write_text("524288000\n", encoding="utf-8")
            (cgroup / "memory.stat").write_text("inactive_file 104857600\n", encoding="utf-8")
            sampler = resource_metrics.ResourceUsageSampler(
                instance_name="server2",
                host_cpu_stat=host_stat,
                host_meminfo=host_mem,
                host_net_dev=host_net,
                host_net_route=host_route,
                container_net_dev=container_net,
                cgroup_root=cgroup,
                self_cgroup=self_cgroup,
            )
            with (
                mock.patch.object(resource_metrics.time, "time", side_effect=[1000.0, 1001.0]),
                mock.patch.object(resource_metrics.time, "monotonic", side_effect=[50.0, 51.0]),
            ):
                first = sampler.sample()
                host_stat.write_text(
                    "cpu  110 0 110 880 0 0 0 0 0 0\n"
                    "cpu0 55 0 55 440 0 0 0 0 0 0\n"
                    "cpu1 55 0 55 440 0 0 0 0 0 0\n",
                    encoding="utf-8",
                )
                host_net.write_text(
                    "Inter-| Receive | Transmit\n face |bytes packets errs drop fifo frame compressed multicast|bytes packets errs drop fifo colls carrier compressed\n"
                    "ens18: 2000000 0 0 0 0 0 0 0 2500000 0 0 0 0 0 0 0\n",
                    encoding="utf-8",
                )
                container_net.write_text(
                    "Inter-| Receive | Transmit\n face |bytes packets errs drop fifo frame compressed multicast|bytes packets errs drop fifo colls carrier compressed\n"
                    "eth0: 300000 0 0 0 0 0 0 0 300000 0 0 0 0 0 0 0\n",
                    encoding="utf-8",
                )
                (cgroup / "cpu.stat").write_text(
                    "usage_usec 1200000\n", encoding="utf-8"
                )
                second = sampler.sample()

            self.assertIsNone(first["host"]["cpu_percent"])
            self.assertAlmostEqual(second["host"]["cpu_percent"], 20.0)
            self.assertEqual(second["host"]["memory_total_bytes"], 32768000 * 1024)
            self.assertEqual(second["host"]["memory_used_bytes"], 12288000 * 1024)
            self.assertAlmostEqual(
                second["host"]["network_receive_bytes_per_second"], 1_000_000
            )
            self.assertAlmostEqual(second["container"]["cpu_percent"], 10.0)
            self.assertEqual(second["container"]["memory_used_bytes"], 419430400)
            self.assertNotIn("memory_limit_bytes", second["container"])
            self.assertEqual(second["container"]["instance"], "server2")

    def test_history_is_bounded_and_downsampled(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "resource-usage.sqlite3"
            sampler = mock.Mock()
            sampler.instance_name = "server1"
            monitor = resource_metrics.ResourceUsageMonitor(
                mock.Mock(), sampler=sampler, database_path=database
            )
            now = 2_000_000
            with closing(sqlite3.connect(database)) as connection:
                monitor._initialize_database(connection)
                for offset in range(0, 3600, 15):
                    connection.execute(
                        "INSERT INTO resource_samples VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                        (
                            now - 3600 + offset,
                            20.0,
                            10_000,
                            20_000,
                            100.0,
                            50.0,
                            5.0,
                            2_000,
                            25.0,
                            10.0,
                        ),
                    )
                connection.commit()
            with mock.patch.object(resource_metrics.time, "time", return_value=now):
                payload = monitor.history(3600, 60)
            self.assertLessEqual(len(payload["points"]), 60)
            self.assertGreater(len(payload["points"]), 0)
            self.assertEqual(payload["points"][0]["container"]["instance"], "server1")
            with self.assertRaises(ValueError):
                monitor.history(60, 60)


if __name__ == "__main__":
    unittest.main()
