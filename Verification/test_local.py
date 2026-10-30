import json
import os
import pathlib
import subprocess
import sys
import tempfile
import urllib.request

project = pathlib.Path(__file__).resolve().parent.parent
build = project / "build"
build.mkdir(exist_ok=True)
subprocess.run(["swift", "build", "--package-path", str(project)], check=True)
binaries = subprocess.check_output(["swift", "build", "--package-path", str(project), "--show-bin-path"], text=True).strip()

with tempfile.TemporaryDirectory(prefix="verification-", dir=build) as temporary:
    directory = pathlib.Path(temporary)
    sample = directory / "sample.mp4"
    alternate = directory / "portrait.webm"
    subprocess.run([
        "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
        "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100",
        "-t", "12", "-c:v", "libx264", "-preset", "fast", "-b:v", "900k",
        "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", str(sample),
    ], check=True)
    subprocess.run([
        "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
        "-f", "lavfi", "-i", "testsrc2=size=540x960:rate=12",
        "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000",
        "-t", "2", "-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8",
        "-c:a", "libopus", str(alternate),
    ], check=True)
    with (directory / "server.log").open("w+") as log:
        server = subprocess.Popen([
            sys.executable, "-I", str(project / "Verification/fixture_server.py"),
            str(sample), "--port", "0", "--alternate-media", str(alternate),
        ], stdout=subprocess.PIPE, stderr=log, text=True)
        try:
            line = server.stdout.readline().strip()
            prefix = "Fixture server ready: "
            if not line.startswith(prefix):
                raise RuntimeError("Fixture server did not start")
            address = line[len(prefix):]
            environment = dict(os.environ, STREAMDROP_TEST_URL=address, STREAMDROP_TEST_WORKER=str(pathlib.Path(binaries) / "StreamDrop"))
            result = subprocess.run(["swift", "test", "--package-path", str(project)], env=environment)
            with urllib.request.urlopen(address + "/shutdown", timeout=5):
                pass
            output, _ = server.communicate(timeout=10)
            requests = [json.loads(value) for value in output.splitlines() if value.startswith("{")]
            resumed = [value for value in requests if value.get("range")]
            print("RANGE_RESUME_OBSERVED=" + str(bool(resumed)), flush=True)
            if result.returncode:
                raise SystemExit(result.returncode)
            if not resumed:
                raise SystemExit("No HTTP Range resume was observed")
        finally:
            if server.poll() is None:
                server.terminate()
                try:
                    server.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.communicate()
