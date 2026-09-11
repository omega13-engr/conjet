#!/usr/bin/env python3
"""Correctness checks against an explicitly selected, already booted QA VM."""

import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import threading
import time
import uuid


def return_evidence(before, after):
    start, end = before["host_memory"], after["host_memory"]
    required = ("resident_bytes", "physical_footprint_bytes", "compressed_bytes")
    for key in required:
        if start.get(key) is None or end.get(key) is None:
            raise AssertionError(f"memory return requires {key}; use a VMM with Darwin backing diagnostics")
    return {
        "before": before,
        "after": after,
        "rss_drop_bytes": start["resident_bytes"] - end["resident_bytes"],
        "footprint_drop_bytes": start["physical_footprint_bytes"] - end["physical_footprint_bytes"],
        "compressed_growth_bytes": end["compressed_bytes"] - start["compressed_bytes"],
        "resident_plus_compressed_drop_bytes": (
            start["resident_bytes"] + start["compressed_bytes"]
            - end["resident_bytes"] - end["compressed_bytes"]),
    }


def memory_returned(evidence, minimum):
    # Moving dirty pages into the compressor must not satisfy an RSS-drop check.
    # Original-object retention is covered by the native/HVF backing regression;
    # task accounting alone cannot detect pages orphaned by MAP_FIXED.
    return (evidence["rss_drop_bytes"] >= minimum
            and evidence["footprint_drop_bytes"] >= minimum
            and evidence["resident_plus_compressed_drop_bytes"] >= minimum)


class Suite:
    def __init__(self, args):
        self.args = args
        self.root = Path(args.qa_root).resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.fixture = Path(__file__).resolve().parent / "docker-memory-e2e"
        self.project = "conjet-memory-e2e-" + uuid.uuid4().hex[:10]
        self.env = os.environ.copy()
        self.env.pop("DOCKER_CONTEXT", None)
        self.env.update(DOCKER_HOST="unix://" + str(Path(args.docker_socket).resolve()),
                        COMPOSE_PROJECT_NAME=self.project,
                        CONJET_MEMORY_E2E_IMAGE=self.project + ":fixture")
        config = Path(args.docker_config) if args.docker_config else self.root / "docker-config"
        config.mkdir(parents=True, exist_ok=True)
        if not args.docker_config:
            plugin_dirs = [str(p) for p in (Path("/opt/homebrew/lib/docker/cli-plugins"),
                                           Path("/usr/local/lib/docker/cli-plugins")) if p.is_dir()]
            (config / "config.json").write_text(json.dumps({"cliPluginsExtraDirs": plugin_dirs}))
        self.env["DOCKER_CONFIG"] = str(config.resolve())
        self.compose = ["docker", "compose", "-f", str(self.fixture / "compose.yml")]
        self.phase = "setup"
        self.samples = []
        self.errors = []
        self.done = threading.Event()
        self.collector = threading.Thread(target=self.sample_loop, daemon=True)

    def run_command(self, args, name, timeout=180):
        with (self.root / (name + ".log")).open("w") as log:
            result = subprocess.run(args, env=self.env, stdout=log, stderr=subprocess.STDOUT,
                                    timeout=timeout)
        if result.returncode:
            raise RuntimeError(f"{name} exited {result.returncode}; see {self.root / (name + '.log')}")
        return (self.root / (name + ".log")).read_text()

    def metrics(self):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(5)
            client.connect(self.args.memory_control_socket)
            client.sendall(b'{"command":"metrics"}\n')
            result = json.loads(client.makefile("rb").readline())
        ledger = result["memory_ledger"]
        assert result["ok"] and ledger["ok"], result
        for key in ("reclaim_without_authority_bytes", "guest_owned_reclaimed_bytes",
                    "pinned_reclaimed_bytes", "report_acked_before_reclaim_bytes"):
            assert ledger[key] == 0, (key, ledger[key])
        assert ledger["cumulative_hard_decommitted_bytes"] <= (
            ledger["cumulative_report_authorized_bytes"] + ledger["cumulative_balloon_authorized_bytes"])
        assert result["balloon"]["reclaim_failures"] == 0, result["balloon"]
        assert result["balloon"]["reuse_failures"] == 0, result["balloon"]
        return result

    def sample_loop(self):
        with (self.root / "memory-trace.jsonl").open("w") as log:
            while not self.done.is_set():
                record = {"time": time.time(), "phase": self.phase}
                try:
                    record["metrics"] = self.metrics()
                except Exception as error:
                    record["error"] = str(error)
                    self.errors.append(str(error))
                self.samples.append(record)
                log.write(json.dumps(record) + "\n")
                log.flush()
                self.done.wait(2)

    def control(self, service, command, size=None):
        args = self.compose + ["exec", "-T", service, "memory-fixture", "ctl", command]
        if size is not None:
            args.append(str(size))
        result = json.loads(self.run_command(args, f"{self.phase}-{service}-{command}"))
        assert result["ok"], result
        assert result["retained_bytes"] == 64 * 1024 * 1024, result
        return result

    def await_return(self, before, name):
        deadline = time.monotonic() + self.args.return_timeout
        minimum = self.args.minimum_return_mib * 1024 * 1024
        while True:
            after = self.metrics()
            evidence = return_evidence(before, after)
            if memory_returned(evidence, minimum):
                (self.root / (name + ".json")).write_text(json.dumps(evidence, indent=2) + "\n")
                return
            if time.monotonic() >= deadline:
                (self.root / (name + "-failed.json")).write_text(json.dumps(evidence, indent=2))
                raise AssertionError(
                    f"{name}: return requires {self.args.minimum_return_mib} MiB RSS and footprint reduction "
                    f"and net resident-plus-compressed reduction; RSS drop={evidence['rss_drop_bytes']}, "
                    f"footprint drop={evidence['footprint_drop_bytes']}, "
                    f"compressed growth={evidence['compressed_growth_bytes']}; see trace")
            time.sleep(2)

    def verify_container_states(self, name):
        ids = self.run_command(self.compose + ["ps", "-q"], name + "-ids").split()
        assert len(ids) == 2, ids
        states = json.loads(self.run_command(["docker", "inspect"] + ids, name + "-inspect"))
        for container in states:
            assert container["State"]["Running"] and not container["State"]["OOMKilled"], container["State"]
            assert container["RestartCount"] == 0, container["RestartCount"]

    def run(self):
        initial = self.metrics()
        assert initial["configured_mib"] >= 2048, "fixture requires at least 2 GiB configured guest RAM"
        (self.root / "run.json").write_text(json.dumps({"project": self.project, "args": vars(self.args)}, indent=2))
        self.collector.start()
        try:
            self.run_command(self.compose + ["build", "canary"], "fixture-build", timeout=900)
            self.run_command(self.compose + ["up", "-d", "--no-build", "--wait", "--wait-timeout", "90"], "fixture-up")
            for cycle in range(1, 4):
                self.phase = f"cycle-{cycle}-held"
                allocated = self.control("allocator", "allocate", 512)
                assert allocated["allocated_bytes"] == 512 * 1024 * 1024, allocated
                time.sleep(4)
                before = self.metrics()
                self.phase = f"cycle-{cycle}-free"
                freed = self.control("allocator", "free")
                assert freed["allocated_bytes"] == 0, freed
                self.await_return(before, f"cycle-{cycle}-return")
                self.control("canary", "verify")
                reused = self.control("allocator", "reuse", 512)
                assert reused["allocated_bytes"] == 0, reused
                print(f"cycle {cycle}: release, live canary, and demand-zero reuse verified", flush=True)

            self.phase = "docker-build"
            start_index = len(self.samples)
            self.run_command(["docker", "build", "--progress=plain", "--target", "build-workload",
                              "--build-arg", "E2E_BUILD_ID=" + uuid.uuid4().hex,
                              "-t", self.project + ":build", str(self.fixture)], "docker-build", timeout=900)
            samples = [r["metrics"] for r in self.samples[start_index:] if "metrics" in r]
            assert samples, "build allocation was not sampled"
            peak = max(samples, key=lambda m: m["host_memory"]["resident_bytes"])
            self.phase = "after-build"
            self.await_return(peak, "build-return")
            for service in ("canary", "allocator"):
                self.control(service, "verify")
            self.verify_container_states("before-restart")

            self.phase = "restart"
            self.run_command(self.compose + ["restart"], "fixture-restart")
            self.run_command(self.compose + ["up", "-d", "--no-build", "--wait", "--wait-timeout", "90"], "fixture-restarted")
            for service in ("canary", "allocator"):
                self.control(service, "verify")
            self.verify_container_states("after-restart")
            self.metrics()
            assert not self.errors, self.errors
            print("Docker build release and container restart verified; no performance comparison ran", flush=True)
        finally:
            self.phase = "cleanup"
            try:
                self.run_command(self.compose + ["logs", "--no-color"], "fixture-logs")
            finally:
                try:
                    self.run_command(self.compose + ["down", "--volumes"], "fixture-down")
                finally:
                    self.done.set()
                    self.collector.join(timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--docker-socket", required=True, help="Docker socket of your isolated QA VM")
    parser.add_argument("--memory-control-socket", required=True, help="Jetstream QA memory control socket")
    parser.add_argument("--qa-root", required=True, help="Scratch output directory, normally under /tmp")
    parser.add_argument("--docker-config", help="Optional QA Docker config, including registry/proxy settings")
    parser.add_argument("--return-timeout", type=int, default=60, help="Correctness timeout in seconds, not a latency target")
    parser.add_argument("--minimum-return-mib", type=int, default=256, help="Required observable return from a 512 MiB allocation")
    args = parser.parse_args()
    if args.return_timeout < 1 or not 1 <= args.minimum_return_mib <= 512:
        parser.error("timeout must be positive and minimum return must be between 1 and 512 MiB")
    for path in (args.docker_socket, args.memory_control_socket):
        if not Path(path).is_socket():
            parser.error(f"not an existing Unix socket: {path}")
    Suite(args).run()


if __name__ == "__main__":
    main()
