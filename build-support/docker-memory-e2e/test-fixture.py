#!/usr/bin/env python3
"""Native fixture regression checks; pass a scratch directory outside the repo."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

root = Path(sys.argv[1]).resolve()
root.mkdir(parents=True, exist_ok=True)
binary = root / "memory-fixture"
source = Path(__file__).with_name("memory-fixture.c")
subprocess.run(["cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", str(source), "-o", str(binary)], check=True)
env = os.environ.copy()
endpoint = root / "fixture.sock"
env["CONJET_MEMORY_FIXTURE_SOCKET"] = str(endpoint)
server = subprocess.Popen([str(binary), "serve", "2"], env=env)
try:
    deadline = time.monotonic() + 5
    while not endpoint.exists():
        assert server.poll() is None, "fixture failed to start"
        assert time.monotonic() < deadline, "fixture startup timed out"
        time.sleep(0.05)

    def control(*args):
        result = subprocess.run([str(binary), "ctl", *args], env=env, text=True,
                                capture_output=True, timeout=10, check=True)
        return json.loads(result.stdout)

    for invalid in ("0", "-1", "1025", "nan", "8x", "+8", " 8"):
        assert not control("allocate", invalid)["ok"], invalid
        assert control("status")["ok"]
    assert not control("unknown")["ok"]
    for _ in range(3):
        assert control("allocate", "8")["allocated_bytes"] == 8 * 1024 * 1024
        assert not control("allocate", "8")["ok"]
        assert control("verify")["ok"]
        assert control("free")["allocated_bytes"] == 0
        assert control("free")["ok"]
        assert control("reuse", "8")["allocated_bytes"] == 0
        assert control("verify")["retained_bytes"] == 2 * 1024 * 1024
    conflict = subprocess.run([str(binary), "serve", "1"], env=env, capture_output=True, timeout=10)
    assert conflict.returncode != 0
    assert control("verify")["ok"], "existing socket was disturbed"
finally:
    server.terminate()
    server.wait(timeout=10)
assert server.returncode == 0, server.returncode
assert not endpoint.exists(), "socket was not cleaned up"
file_path = root / "build-canary"
file_path.write_text("preserve existing data")
result = subprocess.run([str(binary), "build", "1", str(file_path)], capture_output=True, timeout=10)
assert result.returncode != 0 and file_path.read_text() == "preserve existing data"
file_path.unlink()
subprocess.run([str(binary), "build", "1", str(file_path)], check=True, timeout=15)
assert not file_path.exists(), "build fixture left its file behind"
print("fixture argument, lifetime, reuse, socket, and file checks passed")
