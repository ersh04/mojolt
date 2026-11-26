"""Measure loopback worker counts with standard-library WebSocket clients."""
import argparse
import asyncio
import json
import os
from pathlib import Path
import platform
import select
import struct
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def frame(payload, opcode=2):
    mask = os.urandom(4)
    size = len(payload)
    head = bytes([128 | opcode])
    if size < 126:
        head += bytes([128 | size])
    elif size < 65536:
        head += bytes([254]) + struct.pack("!H", size)
    else:
        head += bytes([255]) + struct.pack("!Q", size)
    return head + mask + bytes(v ^ mask[i % 4] for i, v in enumerate(payload))


async def receive(reader):
    first, second = await reader.readexactly(2)
    size = second & 127
    if size == 126:
        size = struct.unpack("!H", await reader.readexactly(2))[0]
    elif size == 127:
        size = struct.unpack("!Q", await reader.readexactly(8))[0]
    return first & 15, await reader.readexactly(size)


async def open_peer(port):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    writer.write(b"GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                 b"Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                 b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n")
    await writer.drain()
    response = await reader.readuntil(b"\r\n\r\n")
    if not response.startswith(b"HTTP/1.1 101"):
        raise RuntimeError("Handshake failed")
    return reader, writer


def process_usage(pid):
    fields = Path(f"/proc/{pid}/stat").read_text().split()
    ticks = os.sysconf("SC_CLK_TCK")
    cpu = (int(fields[13]) + int(fields[14])) / ticks
    rss = int(fields[23]) * os.sysconf("SC_PAGE_SIZE")
    return cpu, rss


async def workload(port, clients, messages, size, pid):
    started = time.perf_counter()
    peers = await asyncio.gather(*(open_peer(port) for _ in range(clients)))
    connected = time.perf_counter()
    cpu_start, _ = process_usage(pid)
    payload = bytes(i % 256 for i in range(size))
    async def client(reader, writer):
        latencies = []
        for _ in range(messages):
            before = time.perf_counter_ns()
            writer.write(frame(payload))
            await writer.drain()
            if await receive(reader) != (2, payload):
                raise RuntimeError("Echo mismatch")
            latencies.append((time.perf_counter_ns() - before) / 1e6)
        return latencies
    latencies = sorted(v for result in await asyncio.gather(
        *(client(*peer) for peer in peers)) for v in result)
    elapsed = time.perf_counter() - connected
    cpu_end, rss = process_usage(pid)
    for _, writer in peers:
        writer.close()
    await asyncio.gather(*(writer.wait_closed() for _, writer in peers))
    reader, writer = await open_peer(port)
    writer.write(frame(b"__stop__", 1))
    await writer.drain()
    opcode, close_payload = await receive(reader)
    if opcode != 8:
        raise RuntimeError("Shutdown handshake missing")
    writer.write(frame(close_payload, 8))
    await writer.drain()
    writer.close()
    await writer.wait_closed()
    count = clients * messages
    def percentile(fraction):
        return round(latencies[min(len(latencies) - 1, int(fraction * len(latencies)))], 3)
    return {
        "messages": count, "seconds": round(elapsed, 3),
        "messages_per_second": round(count / elapsed),
        "payload_mib_per_second": round(count * size / elapsed / 1048576, 3),
        "connections_per_second": round(clients / (connected - started)),
        "p50_ms": percentile(.5), "p95_ms": percentile(.95), "p99_ms": percentile(.99),
        "server_cpu_percent": round((cpu_end - cpu_start) / elapsed * 100, 1),
        "server_rss_mib": round(rss / 1048576, 2),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workers", default="1,2")
    parser.add_argument("--clients", type=int, default=16)
    parser.add_argument("--messages", type=int, default=200)
    parser.add_argument("--size", type=int, default=128)
    args = parser.parse_args()
    counts = [int(value) for value in args.workers.split(",")]
    if min(args.clients, args.messages) < 1 or not 0 <= args.size <= 1048576 or min(counts) < 1:
        parser.error("Worker/client/message counts must be positive; size must be 0..1048576")
    compiler = os.environ.get("MOJO", str(ROOT / ".venv/bin/mojo"))
    cpu = next((line.split(":", 1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines()
                if line.startswith("model name")), platform.machine())
    print(json.dumps({"hardware": cpu, "platform": platform.platform(),
        "available_cpu_ids": sorted(os.sched_getaffinity(0)),
        "compiler": subprocess.check_output([compiler, "--version"], text=True).strip(),
        "clients": args.clients, "messages_per_client": args.messages, "payload_bytes": args.size,
        "affinity": False, "transport": "loopback TCP", "clients_runtime": platform.python_version()}))
    for count in counts:
        process = subprocess.Popen([str(ROOT / "build/worker-fixture"), "127.0.0.1", str(count)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            if not select.select([process.stdout], [], [], 15)[0]:
                raise RuntimeError("Server startup timeout")
            line = process.stdout.readline()
            if not line.startswith("READY "):
                raise RuntimeError("Server startup failed")
            port = int(line.split()[1])
            result = asyncio.run(asyncio.wait_for(
                workload(port, args.clients, args.messages, args.size, process.pid), 60))
            process.wait(timeout=5)
            if process.returncode:
                raise RuntimeError(process.stderr.read())
            print(json.dumps({"workers": count, **result}), flush=True)
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)


if __name__ == "__main__":
    main()
