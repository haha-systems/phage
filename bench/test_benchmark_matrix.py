import importlib.util
import json
import pathlib
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
                self.assertEqual([row.db_path, row.db_path + ".wal"], benchmark_matrix.cleanup_targets(row))

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
