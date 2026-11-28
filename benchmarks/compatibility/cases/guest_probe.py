"""Compile and verify neutral, architecture-specific guest probes."""

import base64
import hashlib
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory


def compile_probe(test, connection, filename, checksum):
    clang = Path('/Applications/Xcode.app/Contents/Developer/Toolchains/'
                 'XcodeDefault.xctoolchain/usr/bin/clang')
    lld = (Path.home() / '.rustup/toolchains/stable-aarch64-apple-darwin'
           / 'lib/rustlib/aarch64-apple-darwin/bin/rust-lld')
    tools = (
        (clang, 'ee029330bf58ab6e481385f4237cc54602eaa8b81526242e5c5ab5b76e8c5a7e'),
        (lld, 'f719ec5b06dcf9ec5f8e4dc2a5032a72c6469ba4e195c17011090d10b4229c5c'),
    )
    for tool, expected in tools:
        with tool.open('rb') as source:
            test.assertEqual(hashlib.file_digest(source, 'sha256').hexdigest(), expected, tool)
    source = Path(__file__).resolve().parents[1] / 'fixtures' / filename
    with TemporaryDirectory(dir=connection.root) as scratch:
        root = Path(scratch)
        obj, executable = root / 'probe.o', root / 'probe'
        for command in (
                [clang, '--target=aarch64-linux-musl', '-c', source, '-o', obj],
                [lld, '-flavor', 'gnu', '-m', 'aarch64linux', '--build-id=none', '-static',
                 '-s', '-o', executable, obj]):
            compiled = subprocess.run(command, cwd=root, env={'HOME': scratch,
                                       'PATH': '/usr/bin:/bin'}, capture_output=True,
                                      text=True, timeout=10)
            test.assertEqual(compiled.returncode, 0, compiled.stderr)
        payload = executable.read_bytes()
        test.assertEqual(hashlib.sha256(payload).hexdigest(), checksum)
        return base64.b64encode(payload).decode()
