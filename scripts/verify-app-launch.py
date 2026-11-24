#!/usr/bin/env python3
"""Check that a packaged app starts without its original SwiftPM resource bundle."""
import pathlib
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time


def process_tree():
    result = subprocess.check_output(["ps", "-axo", "pid=,ppid=,stat="], text=True)
    return {int(pid): (int(parent), state) for pid, parent, state in
            (line.split() for line in result.splitlines())}


def descendants(pid, tree):
    children = [child for child, (parent, _) in tree.items() if parent == pid]
    return [descendant for child in children for descendant in descendants(child, tree)] + children


def stop_processes(process):
    children = descendants(process.pid, process_tree())
    for pid in children:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    if process.poll() is None:
        process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    deadline = time.monotonic() + 5
    remaining = children
    while remaining and time.monotonic() < deadline:
        tree = process_tree()
        remaining = [pid for pid in remaining if pid in tree and not tree[pid][1].startswith("Z")]
        if remaining:
            time.sleep(0.1)
    for pid in remaining:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    if remaining:
        raise SystemExit(f"App launch left child processes running; forced cleanup: {remaining}")

app = pathlib.Path(sys.argv[1]).resolve()
build_bundle = pathlib.Path(sys.argv[2]).resolve()
with tempfile.TemporaryDirectory(dir=build_bundle.parent) as directory:
    environment = os.environ.copy()
    environment["REQNIVO_DATA_DIR"] = str(pathlib.Path(directory) / "data")
    # Reserve distinct unused ports without touching the user's capture listener.
    with socket.socket() as proxy, socket.socket() as api:
        proxy.bind(("127.0.0.1", 0))
        api.bind(("127.0.0.1", 0))
        proxy_port, api_port = proxy.getsockname()[1], api.getsockname()[1]
    environment["REQNIVO_PROXY_PORT"] = str(proxy_port)
    environment["REQNIVO_API_PORT"] = str(api_port)
    hidden = pathlib.Path(directory) / build_bundle.name
    build_bundle.rename(hidden)
    try:
        with tempfile.TemporaryFile() as log:
            process = subprocess.Popen([str(app / "Contents/MacOS/Reqnivo")],
                                       stdout=log, stderr=subprocess.STDOUT,
                                       env=environment,
                                       start_new_session=True)
            try:
                process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                print("Verified packaged app stays running without build resources")
            else:
                log.seek(0)
                raise SystemExit(f"App exited during launch ({process.returncode}):\n"
                                 + log.read().decode(errors="replace"))
            finally:
                # Capture can start automatically; stop the engine as well as the app.
                stop_processes(process)
            for port in (proxy_port, api_port):
                with socket.socket() as listener:
                    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    try:
                        listener.bind(("127.0.0.1", port))
                    except OSError as error:
                        raise SystemExit(f"App launch left capture port {port} unavailable: {error}") from error
            print("Verified app and engine cleanup releases both isolated capture ports")
    finally:
        hidden.rename(build_bundle)
