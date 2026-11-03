#!/usr/bin/env python3
import argparse
import asyncio
import contextlib
from dataclasses import dataclass
import signal
import sys
from typing import Tuple


StreamPair = Tuple[asyncio.StreamReader, asyncio.StreamWriter]


@dataclass
class AppChannel:
    reader: asyncio.StreamReader
    writer: asyncio.StreamWriter
    closed: bool = False


def log(message: str) -> None:
    print(message, flush=True)


async def close_writer(writer: asyncio.StreamWriter) -> None:
    with contextlib.suppress(Exception):
        writer.close()
        await writer.wait_closed()


async def pump(reader: asyncio.StreamReader, writer: asyncio.StreamWriter, label: str) -> None:
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            log(f"pump {label} bytes={len(data)}")
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        await close_writer(writer)
        log(f"closed {label}")


async def proxy_pair(client: StreamPair, app: StreamPair) -> None:
    client_reader, client_writer = client
    app_reader, app_writer = app
    client_peer = client_writer.get_extra_info("peername")
    app_peer = app_writer.get_extra_info("peername")
    log(f"paired client={client_peer} app={app_peer}")
    tasks = [
        asyncio.create_task(pump(client_reader, app_writer, "client->app")),
        asyncio.create_task(pump(app_reader, client_writer, "app->client")),
    ]
    try:
        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)


async def main_async(args: argparse.Namespace) -> None:
    app_channels: asyncio.Queue[AppChannel] = asyncio.Queue()

    async def discard_idle_app_channels() -> None:
        discarded = 0
        while True:
            try:
                channel = app_channels.get_nowait()
            except asyncio.QueueEmpty:
                break
            channel.closed = True
            await close_writer(channel.writer)
            discarded += 1
        if discarded:
            log(f"discarded idle app channels count={discarded}")

    async def next_app_channel() -> StreamPair:
        while True:
            channel = await app_channels.get()
            if not channel.closed and not channel.writer.is_closing() and not channel.reader.at_eof():
                return (channel.reader, channel.writer)
            log("discarded stale app channel")

    async def handle_app(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        peer = writer.get_extra_info("peername")
        log(f"accepted app channel peer={peer}")
        channel = AppChannel(reader=reader, writer=writer)
        await app_channels.put(channel)
        try:
            await writer.wait_closed()
        except (BrokenPipeError, ConnectionError):
            pass
        finally:
            channel.closed = True

    async def handle_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        peer = writer.get_extra_info("peername")
        log(f"accepted X client peer={peer}")
        initial_data = b""
        if args.fresh_app_channel_per_client:
            try:
                initial_data = await asyncio.wait_for(
                    reader.read(65536),
                    timeout=args.initial_read_timeout,
                )
            except asyncio.TimeoutError:
                log(f"timed out waiting for initial X client bytes peer={peer}")
                await close_writer(writer)
                return
            if not initial_data:
                log(f"X client closed before initial bytes peer={peer}")
                await close_writer(writer)
                return
            log(f"buffered initial X client bytes peer={peer} bytes={len(initial_data)}")

        if args.app_unix_socket:
            app = await asyncio.open_unix_connection(args.app_unix_socket)
            log(f"connected app unix socket path={args.app_unix_socket}")
        else:
            if args.fresh_app_channel_per_client:
                await discard_idle_app_channels()
            app = await next_app_channel()
        if initial_data:
            _, app_writer = app
            app_writer.write(initial_data)
            await app_writer.drain()
            log(f"sent initial X client bytes to app peer={peer} bytes={len(initial_data)}")
        await proxy_pair((reader, writer), app)

    client_bind_address = args.client_bind_address or args.bind_address
    app_bind_address = args.app_bind_address or args.bind_address

    app_server = None
    if not args.app_unix_socket:
        app_server = await asyncio.start_server(
            handle_app,
            host=app_bind_address,
            port=args.app_port,
            reuse_address=True,
        )
    client_server = await asyncio.start_server(
        handle_client,
        host=client_bind_address,
        port=args.client_port,
        reuse_address=True,
    )

    if args.app_unix_socket:
        log(
            f"listening client_bind={client_bind_address} client_port={args.client_port} app_unix_socket={args.app_unix_socket}"
        )
    else:
        log(
            f"listening client_bind={client_bind_address} client_port={args.client_port} app_bind={app_bind_address} app_port={args.app_port}"
        )

    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signum in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(signum, stop_event.set)

    if app_server is not None:
        async with app_server, client_server:
            await stop_event.wait()
    else:
        async with client_server:
            await stop_event.wait()

    log("stopped")


def main() -> int:
    parser = argparse.ArgumentParser(description="VisionX simulator reverse TCP bridge")
    parser.add_argument("--bind-address", default="127.0.0.1")
    parser.add_argument("--client-bind-address")
    parser.add_argument("--app-bind-address")
    parser.add_argument("--client-port", type=int, default=6000)
    parser.add_argument("--app-port", type=int, default=16000)
    parser.add_argument("--app-unix-socket")
    parser.add_argument(
        "--fresh-app-channel-per-client",
        action="store_true",
        help="discard idle reverse channels and pair each X client with a newly opened app channel",
    )
    parser.add_argument("--initial-read-timeout", type=float, default=5.0)
    args = parser.parse_args()

    try:
        asyncio.run(main_async(args))
    except KeyboardInterrupt:
        return 130
    except Exception as error:
        print(f"visionx-sim-reverse-bridge: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
