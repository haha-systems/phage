#!/usr/bin/env python3
"""Disposable Redis/Valkey setup harness for local Phage comparison runs."""

from __future__ import annotations

import argparse
import datetime as _datetime
import json
import os
import pathlib
import platform
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence

TMP_ROOT = "/tmp"
TMP_PREFIX = "phage-redis-valkey-comparison-"
SERVER_START_TIMEOUT_SECONDS = 5.0
SERVER_TERMINATE_TIMEOUT_SECONDS = 5.0

BENCHMARK_CATEGORIES = [
    {
        "label": "phage-core-in-process",
        "source": "zig build -Doptimize=ReleaseFast benchmark -- ...",
        "interpretation": "Phage storage-engine fast-path context; not directly comparable to network-server rows.",
    },
    {
        "label": "phage-server-load",
        "source": "zig build -Doptimize=ReleaseFast server-load -- ...",
        "interpretation": "Bounded ZeroMQ REQ/REP server-load evidence through the current serialized server loop.",
    },
    {
        "label": "redis-native-benchmark",
        "source": "redis-benchmark",
        "interpretation": "Redis native tool reference evidence; command mix/runtime differ from Phage unless explicitly matched.",
    },
    {
        "label": "valkey-native-benchmark",
        "source": "valkey-benchmark",
        "interpretation": "Valkey native tool reference evidence; command mix/runtime differ from Phage unless explicitly matched.",
    },
    {
        "label": "redis-custom-mixed",
        "source": "repository-local mixed PING/SET/GET/DEL driver",
        "interpretation": "Closest local Redis network-server comparison to Phage server-load, still with protocol/runtime differences.",
    },
    {
        "label": "valkey-custom-mixed",
        "source": "repository-local mixed PING/SET/GET/DEL driver",
        "interpretation": "Closest local Valkey network-server comparison to Phage server-load, still with protocol/runtime differences.",
    },
]

PERSISTENCE_SETTINGS = {
    "rdb": "disabled",
    "save": "",
    "appendonly": "no",
    "dbfilename": "dump.rdb",
    "scope": "disposable local temp dir only",
}

TARGET_SPECS = {
    "redis": {
        "server": {"env": "REDIS_SERVER", "candidates": ["redis-server"], "required": True},
        "benchmark": {"env": "REDIS_BENCHMARK", "candidates": ["redis-benchmark"], "required": False},
        "cli": {"env": "REDIS_CLI", "candidates": ["redis-cli"], "required": False},
    },
    "valkey": {
        "server": {"env": "VALKEY_SERVER", "candidates": ["valkey-server"], "required": True},
        "benchmark": {"env": "VALKEY_BENCHMARK", "candidates": ["valkey-benchmark"], "required": False},
        "cli": {"env": "VALKEY_CLI", "candidates": ["valkey-cli"], "required": False},
    },
}


class SetupError(RuntimeError):
    """Base class for fail-closed setup errors."""

    kind = "setup-error"

    def to_payload(self) -> Dict[str, Any]:
        return {"kind": self.kind, "message": str(self)}


class MissingBinaryError(SetupError):
    """Raised when a required or explicitly configured binary cannot be resolved."""

    kind = "missing-binary"

    def __init__(self, target: str, role: str, env_var: str, candidates: Sequence[str], explicit_value: Optional[str] = None):
        self.target = target
        self.role = role
        self.env_var = env_var
        self.candidates = list(candidates)
        self.explicit_value = explicit_value
        if explicit_value:
            message = f"{target} {role} binary from {env_var}={explicit_value!r} was not found or is not executable"
        else:
            message = f"{target} {role} binary missing; set {env_var} or install one of: {', '.join(self.candidates)}"
        super().__init__(message)

    def to_payload(self) -> Dict[str, Any]:
        payload = super().to_payload()
        payload.update(
            {
                "target": self.target,
                "role": self.role,
                "env_var": self.env_var,
                "candidates": self.candidates,
                "explicit_value": self.explicit_value,
            }
        )
        return payload


class BinaryVersionError(SetupError):
    """Raised when an available binary cannot report a usable version."""

    kind = "binary-version"

    def __init__(self, target: str, role: str, path: str):
        self.target = target
        self.role = role
        self.path = path
        super().__init__(f"{target} {role} binary did not report a version: {path}")

    def to_payload(self) -> Dict[str, Any]:
        payload = super().to_payload()
        payload.update({"target": self.target, "role": self.role, "path": self.path})
        return payload


class WrongBinaryError(SetupError):
    """Raised when PATH compatibility aliases point at the other target implementation."""

    kind = "wrong-binary"

    def __init__(self, target: str, role: str, path: str, version: str):
        self.target = target
        self.role = role
        self.path = path
        self.version = version
        super().__init__(f"{target} {role} binary identity mismatch for {path}: version output was {version!r}")

    def to_payload(self) -> Dict[str, Any]:
        payload = super().to_payload()
        payload.update({"target": self.target, "role": self.role, "path": self.path, "version": self.version})
        return payload


@dataclass(frozen=True)
class TargetPlan:
    target: str
    binaries: Dict[str, Dict[str, Optional[str]]]


def command_output(args: Sequence[str], default: str = "unknown", env: Optional[Mapping[str, str]] = None) -> str:
    try:
        completed = subprocess.run(
            list(args),
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env=dict(env) if env is not None else None,
            timeout=5,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return default
    return completed.stdout.strip().splitlines()[0] if completed.stdout.strip() else default


def _default_path_lookup(name: str, env: Mapping[str, str]) -> Optional[str]:
    return shutil.which(name, path=env.get("PATH"))


def _is_executable_file(path: pathlib.Path) -> bool:
    return path.is_file() and os.access(str(path), os.X_OK)


def _resolve_explicit_binary(value: str, env: Mapping[str, str]) -> Optional[str]:
    if os.sep not in value and (os.altsep is None or os.altsep not in value):
        found = shutil.which(value, path=env.get("PATH"))
        return str(pathlib.Path(found).resolve()) if found else None
    path = pathlib.Path(value).expanduser()
    try:
        resolved = path.resolve(strict=True)
    except FileNotFoundError:
        return None
    return str(resolved) if _is_executable_file(resolved) else None


def _version_matches_target(target: str, version: str) -> bool:
    lowered = version.lower()
    if target == "redis":
        return "redis" in lowered and "valkey" not in lowered
    if target == "valkey":
        return "valkey" in lowered
    return True


def _resolve_role_binary(
    target: str,
    role: str,
    env: Mapping[str, str],
    path_lookup: Callable[[str], Optional[str]],
) -> Dict[str, Optional[str]]:
    spec = TARGET_SPECS[target][role]
    env_var = str(spec["env"])
    candidates = list(spec["candidates"])
    required = bool(spec["required"])
    explicit = env.get(env_var)

    resolved: Optional[str] = None
    if explicit:
        resolved = _resolve_explicit_binary(explicit, env)
        if resolved is None:
            raise MissingBinaryError(target, role, env_var, candidates, explicit)
    else:
        for candidate in candidates:
            found = path_lookup(candidate)
            if found:
                candidate_path = pathlib.Path(found).expanduser()
                try:
                    resolved_path = candidate_path.resolve(strict=True)
                except FileNotFoundError:
                    continue
                if _is_executable_file(resolved_path):
                    resolved = str(resolved_path)
                    break
        if resolved is None and required:
            raise MissingBinaryError(target, role, env_var, candidates)

    version = command_output([resolved, "--version"], env=env) if resolved else None
    if resolved:
        if not version or version == "unknown":
            raise BinaryVersionError(target, role, resolved)
        if not _version_matches_target(target, version):
            raise WrongBinaryError(target, role, resolved, version)
    return {"path": resolved, "version": version}


def discover_target_binaries(
    target: str,
    env: Optional[Mapping[str, str]] = None,
    path_lookup: Optional[Callable[[str], Optional[str]]] = None,
) -> Dict[str, Dict[str, Optional[str]]]:
    if target not in TARGET_SPECS:
        raise ValueError(f"unknown target: {target}")
    resolved_env: Mapping[str, str] = dict(os.environ if env is None else env)
    lookup = path_lookup or (lambda name: _default_path_lookup(name, resolved_env))
    return {
        role: _resolve_role_binary(target, role, resolved_env, lookup)
        for role in ("server", "benchmark", "cli")
    }


def validate_disposable_dir(path: pathlib.Path) -> pathlib.Path:
    resolved = path.expanduser().resolve(strict=False)
    root = pathlib.Path(TMP_ROOT).resolve(strict=True)
    if resolved.parent != root or not resolved.name.startswith(TMP_PREFIX):
        raise ValueError(f"unsafe disposable directory {resolved}; expected {root}/{TMP_PREFIX}*")
    return resolved


def make_disposable_dir() -> pathlib.Path:
    return pathlib.Path(tempfile.mkdtemp(prefix=TMP_PREFIX, dir=TMP_ROOT)).resolve(strict=True)


def cleanup_disposable_dir(path: pathlib.Path) -> Dict[str, Any]:
    resolved = validate_disposable_dir(path)
    shutil.rmtree(str(resolved), ignore_errors=True)
    leftovers: List[str] = []
    if resolved.exists():
        leftovers = [str(child) for child in sorted(resolved.rglob("*"))]
    return {"cleanup_ok": not resolved.exists(), "leftovers": leftovers}


def find_available_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def ensure_port_available(port: int) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        try:
            sock.bind(("127.0.0.1", port))
        except OSError as exc:
            raise SetupError(f"port {port} is occupied or unavailable on 127.0.0.1") from exc


def wait_for_port(port: int, timeout_seconds: float = SERVER_START_TIMEOUT_SECONDS) -> bool:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.settimeout(0.1)
            try:
                sock.connect(("127.0.0.1", port))
            except OSError:
                time.sleep(0.05)
            else:
                return True
    return False


def server_command(server_path: str, port: int, temp_dir: pathlib.Path) -> List[str]:
    return [
        server_path,
        "--bind",
        "127.0.0.1",
        "--port",
        str(port),
        "--dir",
        str(temp_dir),
        "--save",
        "",
        "--appendonly",
        "no",
        "--dbfilename",
        PERSISTENCE_SETTINGS["dbfilename"],
        "--daemonize",
        "no",
        "--protected-mode",
        "yes",
    ]


def terminate_process(process: subprocess.Popen[Any]) -> bool:
    if process.poll() is not None:
        return True
    process.terminate()
    try:
        process.wait(timeout=SERVER_TERMINATE_TIMEOUT_SECONDS)
        return True
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=SERVER_TERMINATE_TIMEOUT_SECONDS)
        return False


def run_setup_for_target(plan: TargetPlan) -> Dict[str, Any]:
    server_path = plan.binaries["server"]["path"]
    if not server_path:
        raise MissingBinaryError(plan.target, "server", str(TARGET_SPECS[plan.target]["server"]["env"]), TARGET_SPECS[plan.target]["server"]["candidates"])

    temp_dir = make_disposable_dir()
    port = find_available_port()
    ensure_port_available(port)
    command = server_command(server_path, port, temp_dir)
    process: Optional[subprocess.Popen[Any]] = None
    ready = False
    terminated = False
    cleanup: Dict[str, Any]
    try:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        ready = wait_for_port(port)
        if not ready:
            exit_code = process.poll()
            raise SetupError(f"{plan.target} server did not become ready on disposable port {port}; exit_code={exit_code}")
    finally:
        if process is not None:
            terminated = terminate_process(process)
        cleanup = cleanup_disposable_dir(temp_dir)

    if not terminated:
        raise SetupError(f"{plan.target} server on disposable port {port} required SIGKILL during shutdown")
    if not cleanup["cleanup_ok"]:
        raise SetupError(f"{plan.target} cleanup left artifacts: {cleanup['leftovers']}")

    return {
        "target": plan.target,
        "status": "ok",
        "binary_paths": {role: info["path"] for role, info in plan.binaries.items()},
        "versions": {role: info["version"] for role, info in plan.binaries.items()},
        "port": port,
        "temp_dir": str(temp_dir),
        "persistence": dict(PERSISTENCE_SETTINGS),
        "command": command,
        "lifecycle": {
            "started": True,
            "ready": ready,
            "terminated": terminated,
        },
        "cleanup": cleanup,
    }


def phage_metadata(env: Optional[Mapping[str, str]] = None) -> Dict[str, Any]:
    return {
        "worktree": command_output(["git", "rev-parse", "--show-toplevel"], env=env),
        "git_revision": command_output(["git", "rev-parse", "HEAD"], env=env),
        "git_status_short": command_output(["git", "status", "--short", "--untracked-files=all"], default="unknown", env=env),
        "dirty_worktree": command_output(["git", "status", "--porcelain", "--untracked-files=all"], default="unknown", env=env) not in ("", "unknown"),
    }


def host_metadata(env: Optional[Mapping[str, str]] = None) -> Dict[str, Any]:
    return {
        "timestamp": _datetime.datetime.now(_datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "uname": command_output(["uname", "-a"], env=env),
        "macos_version": command_output(["sw_vers", "-productVersion"], default="unknown", env=env),
        "platform": platform.platform(),
        "machine": platform.machine(),
        "python_version": platform.python_version(),
        "zig_version": command_output(["zig", "version"], env=env),
    }


def target_names_from_arg(target: str) -> List[str]:
    if target == "all":
        return ["redis", "valkey"]
    return [target]


def build_base_manifest(argv: Sequence[str], env: Optional[Mapping[str, str]] = None) -> Dict[str, Any]:
    return {
        "type": "redis_valkey_comparison_setup",
        "setup_only": True,
        "status": "started",
        "command": " ".join(argv),
        "phage": phage_metadata(env=env),
        "host": host_metadata(env=env),
        "benchmark_categories": BENCHMARK_CATEGORIES,
        "targets": [],
    }


def write_json(path: pathlib.Path, payload: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run disposable Redis/Valkey setup checks for Phage comparison benchmarks.")
    parser.add_argument("--setup-only", action="store_true", help="Validate binary discovery, disposable process lifecycle, temp dirs, ports, and cleanup.")
    parser.add_argument("--target", choices=("all", "redis", "valkey"), default="all", help="Which reference system to validate.")
    parser.add_argument("--output", required=True, help="JSON setup report path, preferably under /tmp for local runs.")
    args = parser.parse_args(argv)
    if not args.setup_only:
        parser.error("only --setup-only is implemented in this S1 harness slice")
    return args


def main(argv: Optional[Sequence[str]] = None, env: Optional[Mapping[str, str]] = None) -> int:
    resolved_argv = list(argv if argv is not None else sys.argv[1:])
    args = parse_args(resolved_argv)
    resolved_env: Mapping[str, str] = dict(os.environ if env is None else env)
    manifest = build_base_manifest(["bench/redis_valkey_comparison.py"] + resolved_argv, env=resolved_env)
    output_path = pathlib.Path(args.output)

    try:
        plans = [
            TargetPlan(target=target, binaries=discover_target_binaries(target, env=resolved_env))
            for target in target_names_from_arg(args.target)
        ]
        manifest["targets"] = [run_setup_for_target(plan) for plan in plans]
    except MissingBinaryError as exc:
        manifest["status"] = "failed"
        manifest["error"] = exc.to_payload()
        write_json(output_path, manifest)
        return 2
    except (OSError, ValueError, SetupError) as exc:
        error = exc.to_payload() if isinstance(exc, SetupError) else {"kind": "setup-error", "message": str(exc)}
        manifest["status"] = "failed"
        manifest["error"] = error
        write_json(output_path, manifest)
        return 1

    manifest["status"] = "ok"
    write_json(output_path, manifest)
    print(f"setup-only ok targets={','.join(target_names_from_arg(args.target))} output={output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
