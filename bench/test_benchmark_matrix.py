import importlib.util
import json
import pathlib
import shutil
import sys
import tempfile
import unittest

MODULE_PATH = pathlib.Path(__file__).with_name("benchmark_matrix.py")
spec = importlib.util.spec_from_file_location("benchmark_matrix", MODULE_PATH)
assert spec is not None
assert spec.loader is not None
benchmark_matrix = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = benchmark_matrix
spec.loader.exec_module(benchmark_matrix)


SAMPLE_BENCHMARK_JSON = json.dumps(
    {
        "workload_profile": "standard",
        "mode": "memory",
        "operation_count": 1000,
        "value_size": 16,
        "batch_size": 16,
        "read_api": "getInto",
        "throughput": {
            "write_ops_per_sec": 100.0,
            "read_ops_per_sec": 200.0,
            "total_ops_per_sec": 150.0,
        },
        "latency_us": {
            "write": {"p50": 1.0, "p95": 2.0, "p99": 3.0},
            "read": {"p50": 0.5, "p95": 0.8, "p99": 1.1},
        },
    }
)

SAMPLE_COMPACTION_JSON = json.dumps(
    {
        "workload_profile": "compaction",
        "mode": "persisted",
        "operation_count": 384,
        "live_key_count": 128,
        "value_size": 64,
        "update_rounds": 2,
        "batch_size": 1,
        "read_api": "getInto",
        "backend_status": "macos-posix-fallback",
        "throughput": {"write_ops_per_sec": 3210.0},
        "latency_us": {"write": {"p50": 3.0, "p95": 5.0, "p99": 8.0}, "trigger": 25.0},
        "compaction": {
            "triggered": True,
            "trigger_count": 2,
            "waste_ratio_before": 0.49,
            "waste_ratio_after": 0.0,
            "file_size_before": 20480,
            "file_size_after": 10240,
            "file_size_reduction_bytes": 10240,
        },
    }
)


class BenchmarkMatrixTests(unittest.TestCase):
    def test_full_profile_covers_required_dimensions(self):
        rows = benchmark_matrix.profile_rows("full", ops=123, tmp_root="/tmp/phage-test")

        self.assertEqual(24, len(rows))
        self.assertEqual({"memory", "persisted"}, {row.mode for row in rows})
        self.assertEqual({1, 16, 64}, {row.batch_size for row in rows})
        self.assertEqual({16, 256}, {row.value_size for row in rows})
        self.assertEqual({"get", "get-into"}, {row.read_api for row in rows})
        self.assertTrue(all(row.ops == 123 for row in rows))

    def test_persisted_rows_get_unique_tmp_paths_and_cleanup_targets(self):
        with tempfile.TemporaryDirectory(prefix="phage-matrix-test-") as tmp_root:
            rows = benchmark_matrix.profile_rows("quick", ops=1000, tmp_root=tmp_root)
            persisted = [row for row in rows if row.mode == "persisted"]

            self.assertGreaterEqual(len(persisted), 1)
            self.assertEqual(len({row.db_path for row in persisted}), len(persisted))
            for row in persisted:
                self.assertTrue(row.db_path.startswith(tmp_root))
                self.assertEqual([row.db_path, row.db_path + ".wal", row.db_path + ".compact.tmp"], benchmark_matrix.cleanup_targets(row))

    def test_default_persisted_rows_use_tmp_root_contract(self):
        rows = benchmark_matrix.profile_rows("quick", ops=1000)
        persisted_roots = []
        try:
            persisted = [row for row in rows if row.mode == "persisted"]

            self.assertGreaterEqual(len(persisted), 1)
            for row in persisted:
                persisted_roots.append(str(pathlib.Path(row.db_path).parent))
                self.assertTrue(
                    row.db_path.startswith("/tmp/phage-benchmark-matrix-"),
                    f"expected default persisted db_path under /tmp/phage-benchmark-matrix-, got {row.db_path}",
                )
        finally:
            for root in set(persisted_roots):
                shutil.rmtree(root, ignore_errors=True)

    def test_enrich_row_preserves_benchmark_metrics_and_metadata(self):
        row = benchmark_matrix.MatrixRow(
            index=0,
            mode="memory",
            ops=1000,
            value_size=16,
            batch_size=16,
            read_api="get-into",
            db_path=None,
        )
        metadata = {
            "profile": "quick",
            "git_revision": "abc123",
            "os_platform": "Darwin-25.0.0-arm64-arm-64bit",
            "zig_version": "0.15.2",
            "backend_status": "macos-posix-fallback",
            "timestamp": "2026-05-18T00:00:00Z",
            "command": "bench/benchmark-matrix.sh --quick --output /tmp/out.jsonl",
        }

        enriched = benchmark_matrix.enrich_row(row, SAMPLE_BENCHMARK_JSON, metadata)

        self.assertEqual("benchmark_row", enriched["type"])
        self.assertEqual(0, enriched["row_index"])
        self.assertEqual("quick", enriched["profile"])
        self.assertEqual("macos-posix-fallback", enriched["backend_status"])
        self.assertEqual("memory", enriched["mode"])
        self.assertEqual(1000, enriched["operation_count"])
        self.assertEqual(16, enriched["value_size"])
        self.assertEqual(16, enriched["batch_size"])
        self.assertEqual("getInto", enriched["read_api"])
        self.assertEqual(150.0, enriched["throughput"]["total_ops_per_sec"])
        self.assertEqual(2.0, enriched["latency_us"]["write"]["p95"])

    def test_compaction_profile_uses_tmp_persisted_row_and_cleanup_contract(self):
        with tempfile.TemporaryDirectory(prefix="phage-matrix-test-") as tmp_root:
            rows = benchmark_matrix.profile_rows("compaction", ops=128, tmp_root=tmp_root)

            self.assertEqual(1, len(rows))
            row = rows[0]
            self.assertEqual("persisted", row.mode)
            self.assertEqual("compaction", row.workload_profile)
            self.assertEqual(128, row.ops)
            self.assertEqual(2, row.update_rounds)
            self.assertEqual(64, row.value_size)
            self.assertTrue(row.db_path.startswith(tmp_root))
            self.assertEqual(
                [row.db_path, row.db_path + ".wal", row.db_path + ".compact.tmp"],
                benchmark_matrix.cleanup_targets(row),
            )
            command = benchmark_matrix.benchmark_command(row)
            self.assertIn("--profile", command)
            self.assertIn("compaction", command)
            self.assertIn("--update-rounds", command)
            self.assertIn("2", command)

    def test_enrich_row_preserves_compaction_fields(self):
        row = benchmark_matrix.MatrixRow(
            index=0,
            mode="persisted",
            ops=128,
            value_size=64,
            batch_size=1,
            read_api="get-into",
            db_path="/tmp/phage-test-compaction",
            workload_profile="compaction",
            update_rounds=2,
        )
        metadata = {
            "profile": "compaction",
            "git_revision": "abc123",
            "os_platform": "Darwin-25.0.0-arm64-arm-64bit",
            "zig_version": "0.15.2",
            "backend_status": "macos-posix-fallback",
            "timestamp": "2026-05-18T00:00:00Z",
            "command": "bench/benchmark-matrix.sh --profile compaction --output /tmp/out.jsonl",
        }

        enriched = benchmark_matrix.enrich_row(row, SAMPLE_COMPACTION_JSON, metadata)

        self.assertEqual("benchmark_row", enriched["type"])
        self.assertEqual("compaction", enriched["profile"])
        self.assertEqual("compaction", enriched["workload_profile"])
        self.assertEqual(384, enriched["operation_count"])
        self.assertEqual(128, enriched["live_key_count"])
        self.assertEqual(2, enriched["update_rounds"])
        self.assertEqual("macos-posix-fallback", enriched["backend_status"])
        self.assertTrue(enriched["compaction"]["triggered"])
        self.assertEqual(2, enriched["compaction"]["trigger_count"])
        self.assertEqual(10240, enriched["compaction"]["file_size_reduction_bytes"])
        self.assertEqual(3210.0, enriched["throughput"]["write_ops_per_sec"])
        self.assertEqual(25.0, enriched["latency_us"]["trigger"])

    def test_summary_handles_compaction_write_throughput_rows(self):
        metadata = {
            "profile": "compaction",
            "git_revision": "abc123",
            "os_platform": "Darwin-25.0.0-arm64-arm-64bit",
            "zig_version": "0.15.2",
            "backend_status": "macos-posix-fallback",
            "timestamp": "2026-05-18T00:00:00Z",
            "command": "bench/benchmark-matrix.sh --profile compaction --output /tmp/out.jsonl",
        }
        row = benchmark_matrix.MatrixRow(
            index=0,
            mode="persisted",
            ops=128,
            value_size=64,
            batch_size=1,
            read_api="get-into",
            db_path="/tmp/phage-test-compaction",
            workload_profile="compaction",
            update_rounds=2,
        )
        enriched = benchmark_matrix.enrich_row(row, SAMPLE_COMPACTION_JSON, metadata)

        summary = benchmark_matrix.build_summary(metadata, [enriched])

        self.assertEqual("benchmark_summary", summary["type"])
        self.assertEqual(1, summary["row_count"])
        self.assertEqual(3210.0, summary["best_total_ops_per_sec"]["throughput"]["write_ops_per_sec"])

    def test_summary_is_machine_readable_and_names_stable_metadata(self):
        metadata = {
            "profile": "quick",
            "git_revision": "abc123",
            "os_platform": "Darwin-25.0.0-arm64-arm-64bit",
            "zig_version": "0.15.2",
            "backend_status": "macos-posix-fallback",
            "timestamp": "2026-05-18T00:00:00Z",
            "command": "bench/benchmark-matrix.sh --quick --output /tmp/out.jsonl",
        }
        row = benchmark_matrix.MatrixRow(
            index=0,
            mode="memory",
            ops=1000,
            value_size=16,
            batch_size=16,
            read_api="get-into",
            db_path=None,
        )
        enriched = benchmark_matrix.enrich_row(row, SAMPLE_BENCHMARK_JSON, metadata)

        summary = benchmark_matrix.build_summary(metadata, [enriched])

        encoded = json.dumps(summary)
        decoded = json.loads(encoded)
        self.assertEqual("benchmark_summary", decoded["type"])
        self.assertEqual("quick", decoded["metadata"]["profile"])
        self.assertEqual("abc123", decoded["metadata"]["git_revision"])
        self.assertEqual("macos-posix-fallback", decoded["metadata"]["backend_status"])
        self.assertEqual(1, decoded["row_count"])
        self.assertEqual(150.0, decoded["best_total_ops_per_sec"]["throughput"]["total_ops_per_sec"])
        self.assertIn("Stable automation fields", decoded["schema_notes"][0])


if __name__ == "__main__":
    unittest.main()
