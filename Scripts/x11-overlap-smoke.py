#!/usr/bin/env python3
import argparse
import socket
import struct
import time


def pad4(data: bytes) -> bytes:
    return data + (b"\0" * ((4 - (len(data) % 4)) % 4))


def send(sock: socket.socket, payload: bytes) -> None:
    sock.sendall(payload)


def alloc(resource_base: int, value: int) -> int:
    return resource_base | value


def create_window(sock, wid, parent, x, y, width, height, bg, event_mask=0x00028000):
    mask = 0x00000002 | 0x00000008 | 0x00000800
    values = struct.pack("<III", bg, 0, event_mask)
    payload = struct.pack(
        "<BBHIIhhHHHHII",
        1,
        0,
        (32 + len(values)) // 4,
        wid,
        parent,
        x,
        y,
        width,
        height,
        0,
        1,
        0,
        mask,
    ) + values
    send(sock, payload)


def change_name(sock, wid, title):
    data = title.encode("utf-8")
    padded = pad4(data)
    payload = (
        struct.pack(
            "<BBHIIIB3xI",
            18,
            0,
            (24 + len(padded)) // 4,
            wid,
            39,
            31,
            8,
            len(data),
        )
        + padded
    )
    send(sock, payload)


def map_window(sock, wid):
    send(sock, struct.pack("<BBHI", 8, 0, 2, wid))


def create_gc(sock, gcid, drawable, fg):
    send(
        sock,
        struct.pack("<BBHIII", 55, 0, 4, gcid, drawable, 0x00000004)
        + struct.pack("<I", fg),
    )


def fill_rects(sock, drawable, gc, rects):
    body = struct.pack("<II", drawable, gc)
    for x, y, width, height in rects:
        body += struct.pack("<hhHH", x, y, width, height)
    send(sock, struct.pack("<BBH", 70, 0, (4 + len(body)) // 4) + body)


def read_setup(sock):
    send(sock, struct.pack("<BxHHHHH", 0x6C, 11, 0, 0, 0, 0))
    header = sock.recv(8)
    if len(header) != 8:
        raise RuntimeError(f"short X11 setup reply: {len(header)} bytes")

    status, _, major, minor, extra_len = struct.unpack("<BBHHH", header)
    payload = b""
    while len(payload) < extra_len * 4:
        chunk = sock.recv(extra_len * 4 - len(payload))
        if not chunk:
            break
        payload += chunk

    if status != 1:
        raise RuntimeError(f"X11 setup failed status={status} protocol={major}.{minor}")

    resource_base, resource_mask = struct.unpack_from("<II", payload, 4)
    vendor_len = struct.unpack_from("<H", payload, 16)[0]
    num_formats = payload[21]
    screen_offset = 32 + ((vendor_len + 3) & ~3) + (num_formats * 8)
    root = struct.unpack_from("<I", payload, screen_offset)[0]
    return root, resource_base, resource_mask


def main():
    parser = argparse.ArgumentParser(description="Create two patterned X11 windows for VisionX overlap smoke testing.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=6000)
    parser.add_argument("--duration", type=float, default=120)
    args = parser.parse_args()

    sock = socket.create_connection((args.host, args.port), timeout=5)
    sock.settimeout(5)
    root, resource_base, resource_mask = read_setup(sock)

    w1 = alloc(resource_base, 0x101)
    w2 = alloc(resource_base, 0x102)
    gc1 = alloc(resource_base, 0x201)
    gc2 = alloc(resource_base, 0x202)
    gc3 = alloc(resource_base, 0x203)
    gc4 = alloc(resource_base, 0x204)

    create_window(sock, w1, root, 40, 40, 220, 160, 0x00FFFFFF)
    create_window(sock, w2, root, 120, 90, 220, 160, 0x00000000)
    change_name(sock, w1, "VisionX overlap A red/blue")
    change_name(sock, w2, "VisionX overlap B green/yellow")
    map_window(sock, w1)
    map_window(sock, w2)
    create_gc(sock, gc1, w1, 0x00FF0000)
    create_gc(sock, gc2, w1, 0x000000FF)
    create_gc(sock, gc3, w2, 0x0000FF00)
    create_gc(sock, gc4, w2, 0x00FFFF00)

    time.sleep(0.75)
    fill_rects(sock, w1, gc1, [(0, 0, 220, 160), (20, 20, 180, 120)])
    fill_rects(sock, w1, gc2, [(40, 40, 140, 80), (0, 0, 25, 160), (195, 0, 25, 160)])
    fill_rects(sock, w2, gc3, [(0, 0, 220, 160), (30, 30, 160, 100)])
    fill_rects(sock, w2, gc4, [(60, 15, 100, 130), (0, 65, 220, 30)])

    print(
        f"mapped windows {w1:#x} and {w2:#x} on {args.host}:{args.port}; "
        f"resource_mask={resource_mask:#x}; holding {args.duration:g}s",
        flush=True,
    )
    time.sleep(args.duration)
    sock.close()


if __name__ == "__main__":
    main()
