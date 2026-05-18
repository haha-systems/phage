import importlib.util
import json
import os
import pathlib
import shutil
import socket
import stat
import sys
import tempfile
import textwrap
import unittest

MODULE_PATH = pathlib.Path(__file__).with_name("redis_valkey_comparison.py")
spec = importlib.util.spec_from_file_location("redis_valkey_comparison", MODULE_PATH)
assert spec is not None
assert spec.loader is not None
redis_valkey_comparison = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = redis_valkey_comparison
spec.loader.exec_module(redis_valkey_comparison)


class RedisValkeyComparisonSetupTests(unittest.TestCase):
    def test_benchmark_categories_preserve_prd_labels(self):
        labels = {category["label"] for category in redis_valkey_comparison.BENCHMARK_CATEGORIES}

        self.assertEqual(
            {
                "phage-core-in-process",
                "phage-server-load",
                "redis-native-benchmark",
                "valkey-native-benchmark",
                "redis-custom-mixed",
                "valkey-custom-mixed",
            },
            labels,
        )

    def test_missing_server_binary_fails_closed_with_exact_status(self):
        with self.assertRaises(redis_valkey_comparison.MissingBinaryError) as raised:
            redis_valkey_comparison.discover_target_binaries(
                "redis",
                env={},
                path_lookup=lambda _name: None,
            )

        self.assertEqual("redis", raised.exception.target)
        self.assertEqual("REDIS_SERVER", raised.exception.env_var)
        self.assertEqual(["redis-server"], raised.exception.candidates)
        self.assertIn("redis-server", str(raised.exception))

    def test_binary_discovery_records_absolute_paths_and_versions(self):
        with tempfile.TemporaryDirectory(prefix="phage-rv-bin-test-") as tmp:
            tmp_path = pathlib.Path(tmp)
            server = self._write_version_binary(tmp_path / "redis-server", "Redis server v=7.2.4")
            benchmark = self._write_version_binary(tmp_path / "redis-benchmark", "redis-benchmark 7.2.4")
            cli = self._write_version_binary(tmp_path / "redis-cli", "redis-cli 7.2.4")

            discovered = redis_valkey_comparison.discover_target_binaries(
                "redis",
                env={},
                path_lookup=lambda name: str({
                    "redis-server": server,
                    "redis-benchmark": benchmark,
                    "redis-cli": cli,
                }.get(name)),
            )

        self.assertEqual(str(server), discovered["server"]["path"])
        self.assertEqual(str(benchmark), discovered["benchmark"]["path"])
        self.assertEqual(str(cli), discovered["cli"]["path"])
        self.assertEqual("Redis server v=7.2.4", discovered["server"]["version"])
        self.assertTrue(pathlib.Path(discovered["server"]["path"]).is_absolute())

    def test_redis_discovery_rejects_valkey_compatibility_binary(self):
        with tempfile.TemporaryDirectory(prefix="phage-rv-bin-test-") as tmp:
            server = self._write_version_binary(pathlib.Path(tmp) / "redis-server", "Valkey server v=9.0.4")

            with self.assertRaises(redis_valkey_comparison.WrongBinaryError) as raised:
                redis_valkey_comparison.discover_target_binaries(
                    "redis",
                    env={},
                    path_lookup=lambda _name: str(server),
                )

        self.assertEqual("redis", raised.exception.target)
        self.assertEqual("server", raised.exception.role)
        self.assertIn("Valkey", str(raised.exception))

    def test_unsafe_temp_paths_are_rejected(self):
        unsafe = pathlib.Path(tempfile.gettempdir()).parent / "phage-rv-not-in-tmp"

        with self.assertRaises(ValueError):
            redis_valkey_comparison.validate_disposable_dir(unsafe)

    def test_cleanup_removes_disposable_temp_dir_and_artifacts(self):
        temp_dir = pathlib.Path(tempfile.mkdtemp(prefix=redis_valkey_comparison.TMP_PREFIX, dir=redis_valkey_comparison.TMP_ROOT))
        for name in ("dump.rdb", "appendonly.aof", "redis.log", "server.pid"):
            (temp_dir / name).write_text("artifact", encoding="utf-8")

        cleanup = redis_valkey_comparison.cleanup_disposable_dir(temp_dir)

        self.assertTrue(cleanup["cleanup_ok"])
        self.assertFalse(temp_dir.exists())
        self.assertEqual([], cleanup["leftovers"])

    def test_setup_target_starts_disposable_process_and_cleans_temp_dir(self):
        with tempfile.TemporaryDirectory(prefix="phage-rv-fake-server-") as tmp:
            server = self._write_fake_server(pathlib.Path(tmp) / "redis-server")
            plan = redis_valkey_comparison.TargetPlan(
                target="redis",
                binaries={
                    "server": {"path": str(server), "version": "fake redis 1.0"},
                    "benchmark": {"path": None, "version": None},
                    "cli": {"path": None, "version": None},
                },
            )

            result = redis_valkey_comparison.run_setup_for_target(plan)

        self.assertEqual("redis", result["target"])
        self.assertEqual("ok", result["status"])
        self.assertTrue(result["port"] > 0)
        self.assertTrue(result["lifecycle"]["ready"])
        self.assertTrue(result["lifecycle"]["terminated"])
        self.assertTrue(result["cleanup"]["cleanup_ok"])
        self.assertFalse(pathlib.Path(result["temp_dir"]).exists())
        self.assertEqual("disabled", result["persistence"]["rdb"])
        self.assertEqual("no", result["persistence"]["appendonly"])

    def test_setup_only_cli_writes_invalid_environment_diagnostic_json(self):
        with tempfile.TemporaryDirectory(prefix="phage-rv-cli-test-") as tmp:
            output = pathlib.Path(tmp) / "setup.json"
            rc = redis_valkey_comparison.main(
                ["--setup-only", "--target", "redis", "--output", str(output)],
                env={"PATH": ""},
            )
            payload = json.loads(output.read_text(encoding="utf-8"))

        self.assertNotEqual(0, rc)
        self.assertEqual("redis_valkey_comparison_setup", payload["type"])
        self.assertEqual("failed", payload["status"])
        self.assertEqual("missing-binary", payload["error"]["kind"])
        self.assertEqual("redis", payload["error"]["target"])
        self.assertIn("redis-server", payload["error"]["message"])

    def _write_version_binary(self, path: pathlib.Path, output: str) -> pathlib.Path:
        path.write_text(
            "#!/usr/bin/env python3\n"
            "import sys\n"
            f"print({output!r})\n",
            encoding="utf-8",
        )
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return path.resolve()

    def _write_fake_server(self, path: pathlib.Path) -> pathlib.Path:
        path.write_text(
            textwrap.dedent(
                """
                #!/usr/bin/env python3
                import os
                import signal
                import socket
                import sys
                import time

                if "--version" in sys.argv:
                    print("fake redis server 1.0")
                    raise SystemExit(0)

                port = int(sys.argv[sys.argv.index("--port") + 1])
                data_dir = sys.argv[sys.argv.index("--dir") + 1]
                os.makedirs(data_dir, exist_ok=True)
                open(os.path.join(data_dir, "server.pid"), "w", encoding="utf-8").write(str(os.getpid()))

                stop = False
                def handle_stop(_signum, _frame):
                    global stop
                    stop = True
                signal.signal(signal.SIGTERM, handle_stop)

                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                sock.bind(("127.0.0.1", port))
                sock.listen(1)
                sock.settimeout(0.05)
                while not stop:
                    try:
                        conn, _addr = sock.accept()
                    except TimeoutError:
                        continue
                    except socket.timeout:
                        continue
                    else:
                        conn.close()
                sock.close()
                """
            ).lstrip(),
            encoding="utf-8",
        )
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return path.resolve()


if __name__ == "__main__":
    unittest.main()
