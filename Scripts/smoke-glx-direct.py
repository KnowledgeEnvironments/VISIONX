#!/usr/bin/env python3
"""Direct GLX discovery smoke test for UHF X11.

This intentionally speaks enough X11/GLX wire protocol to validate the
experimental provider when xdpyinfo/glxinfo are not installed on the client
machine. With --render-triangle it also validates the first indirect GLXRender
decoder path, but it does not test rasterization.
"""

from __future__ import annotations

import argparse
import os
import socket
import struct
import sys
import time

X_TRUE_COLOR = 4
GLX_RENDER_TYPE = 0x8011
GLX_X_RENDERABLE = 0x8012
GLX_DRAWABLE_TYPE = 0x8010
GLX_WINDOW_BIT = 0x00000001
GLX_RGBA_BIT = 0x00000001
X_GLSOP_GET_STRING = 129
GL_VENDOR = 0x1F00
GL_RENDERER = 0x1F01
GL_VERSION = 0x1F02
GL_EXTENSIONS = 0x1F03


def pad4(length: int) -> int:
    return (4 - (length % 4)) % 4


def recvn(sock: socket.socket, count: int) -> bytes:
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise EOFError(f"wanted {count} bytes, received {len(data)}")
        data += chunk
    return data


def read_reply(sock: socket.socket) -> tuple[bytes, bytes]:
    while True:
        header = recvn(sock, 32)
        response_type = header[0] & 0x7F
        if response_type == 0:
            code = header[1]
            sequence = struct.unpack_from("<H", header, 2)[0]
            bad_value = struct.unpack_from("<I", header, 4)[0]
            minor_opcode = struct.unpack_from("<H", header, 8)[0]
            major_opcode = header[10]
            raise RuntimeError(
                f"X error code={code} sequence={sequence} bad=0x{bad_value:x} "
                f"major={major_opcode} minor={minor_opcode}"
            )

        if response_type == 1:
            length = struct.unpack_from("<I", header, 4)[0]
            body = recvn(sock, length * 4) if length else b""
            return header, body

        if response_type == 35:
            length = struct.unpack_from("<I", header, 4)[0]
            if length:
                recvn(sock, length * 4)


def connect_x11(host: str, port: int) -> tuple[socket.socket, int, int, int, int, int]:
    sock = socket.create_connection((host, port), timeout=5)
    sock.settimeout(5)
    sock.sendall(struct.pack("<BBHHHHH", 0x6C, 0, 11, 0, 0, 0, 0))

    setup_header = recvn(sock, 8)
    if setup_header[0] != 1:
        reason_length = setup_header[1]
        reason = recvn(sock, reason_length).decode("ascii", "replace") if reason_length else ""
        raise RuntimeError(f"X11 setup failed status={setup_header[0]} reason={reason!r}")

    major, minor, additional_length = struct.unpack_from("<HHH", setup_header, 2)
    setup = recvn(sock, additional_length * 4)

    rid_base, rid_mask = struct.unpack_from("<II", setup, 4)
    vendor_length = struct.unpack_from("<H", setup, 16)[0]
    formats_length = setup[21]
    roots_start = 32 + vendor_length + pad4(vendor_length) + formats_length * 8
    root = struct.unpack_from("<I", setup, roots_start)[0]
    root_visual = struct.unpack_from("<I", setup, roots_start + 32)[0]
    root_depth = setup[roots_start + 38]

    print(
        f"X setup ok protocol={major}.{minor} root=0x{root:x} "
        f"visual=0x{root_visual:x} depth={root_depth} ridBase=0x{rid_base:x} ridMask=0x{rid_mask:x}"
    )
    return sock, root, root_visual, root_depth, rid_base, rid_mask


def query_glx_extension(sock: socket.socket) -> int:
    name = b"GLX"
    body = name + b"\0" * pad4(len(name))
    sock.sendall(struct.pack("<BBHHH", 98, 0, (8 + len(body)) // 4, len(name), 0) + body)
    header, _ = read_reply(sock)

    present = header[8]
    opcode = header[9]
    first_event = header[10]
    first_error = header[11]
    print(f"QueryExtension GLX present={present} opcode={opcode} firstEvent={first_event} firstError={first_error}")
    if not present:
        raise RuntimeError("GLX extension is not advertised")
    return opcode


def query_server_string(sock: socket.socket, opcode: int, name_id: int) -> str:
    sock.sendall(struct.pack("<BBHII", opcode, 19, 3, 0, name_id))
    header, body = read_reply(sock)
    length = struct.unpack_from("<I", header, 12)[0]
    return body[:length].rstrip(b"\0").decode("ascii", "replace")


def query_gl_string(sock: socket.socket, opcode: int, context_tag: int, name_id: int) -> str:
    sock.sendall(struct.pack("<BBHII", opcode, X_GLSOP_GET_STRING, 3, context_tag, name_id))
    header, body = read_reply(sock)
    length = struct.unpack_from("<I", header, 12)[0]
    return body[:length].rstrip(b"\0").decode("ascii", "replace")


def render_command(opcode: int, payload: bytes = b"") -> bytes:
    command = struct.pack("<HH", 4 + len(payload), opcode) + payload
    return command + b"\0" * pad4(len(command))


def validate_visual_configs(root_visual: int, header: bytes, body: bytes) -> None:
    visual_count, prop_count = struct.unpack_from("<II", header, 8)
    print(f"GLX GetVisualConfigs visuals/props={(visual_count, prop_count)} bodyBytes={len(body)}")
    if visual_count < 1 or prop_count < 18:
        raise RuntimeError(f"GLX visual config reply is too small: visuals={visual_count} props={prop_count}")
    if len(body) < prop_count * 4:
        raise RuntimeError(f"GLX visual config body too short: body={len(body)} props={prop_count}")

    props = struct.unpack_from("<" + "I" * prop_count, body, 0)
    visual_id = props[0]
    visual_type = props[1]
    rgba = props[2]
    if visual_id != root_visual:
        raise RuntimeError(f"GLX visual id 0x{visual_id:x} does not match root visual 0x{root_visual:x}")
    if visual_type != X_TRUE_COLOR:
        raise RuntimeError(f"GLX legacy visual type must be X TrueColor ({X_TRUE_COLOR}), got 0x{visual_type:x}")
    if rgba != 1:
        raise RuntimeError(f"GLX visual is not advertised as RGBA: {rgba}")


def validate_fbconfigs(header: bytes, body: bytes) -> None:
    config_count, attrib_count = struct.unpack_from("<II", header, 8)
    print(f"GLX GetFBConfigs configs/attrs={(config_count, attrib_count)} bodyBytes={len(body)}")
    if config_count < 1 or attrib_count < 1:
        raise RuntimeError(f"GLX FBConfig reply is too small: configs={config_count} attrs={attrib_count}")
    word_count = attrib_count * 2
    if len(body) < word_count * 4:
        raise RuntimeError(f"GLX FBConfig body too short: body={len(body)} attrs={attrib_count}")

    values = struct.unpack_from("<" + "I" * word_count, body, 0)
    attrs = {values[index]: values[index + 1] for index in range(0, len(values), 2) if values[index] != 0}
    if attrs.get(GLX_X_RENDERABLE) != 1:
        raise RuntimeError("GLX FBConfig is not X-renderable")
    if (attrs.get(GLX_RENDER_TYPE, 0) & GLX_RGBA_BIT) == 0:
        raise RuntimeError("GLX FBConfig does not support RGBA rendering")
    if (attrs.get(GLX_DRAWABLE_TYPE, 0) & GLX_WINDOW_BIT) == 0:
        raise RuntimeError("GLX FBConfig does not support window drawables")


def render_triangle_payload() -> bytes:
    commands = b""
    commands += render_command(130, struct.pack("<ffff", 0.1, 0.2, 0.3, 1.0))
    commands += render_command(127, struct.pack("<I", 0x00004000))
    commands += render_command(4, struct.pack("<I", 0x0004))
    commands += render_command(16, struct.pack("<ffff", 1.0, 0.0, 0.0, 1.0))
    commands += render_command(70, struct.pack("<fff", 0.0, 0.0, 0.0))
    commands += render_command(70, struct.pack("<fff", 1.0, 0.0, 0.0))
    commands += render_command(70, struct.pack("<fff", 0.0, 1.0, 0.0))
    commands += render_command(23)
    return commands


def send_checked(sock: socket.socket, request: bytes) -> None:
    sock.sendall(request)
    sock.sendall(struct.pack("<BBH", 43, 0, 1))
    read_reply(sock)


def create_visible_window(
    sock: socket.socket,
    window: int,
    root: int,
    root_visual: int,
    root_depth: int,
    width: int,
    height: int,
) -> None:
    value_mask = 0x00000002 | 0x00000800
    back_pixel = 0x101820
    event_mask = 0x00008000 | 0x00020000
    request = struct.pack(
        "<BBHIIhhHHHHII",
        1,
        root_depth,
        10,
        window,
        root,
        80,
        80,
        width,
        height,
        0,
        1,
        root_visual,
        value_mask,
    )
    request += struct.pack("<II", back_pixel, event_mask)
    send_checked(sock, request)
    send_checked(sock, struct.pack("<BBHI", 8, 0, 2, window))
    print(f"X visible window mapped id=0x{window:x} size={width}x{height}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Smoke-test UHF X11 experimental GLX discovery.")
    parser.add_argument(
        "--context-offset",
        type=lambda value: int(value, 0),
        help="resource-id offset to use for the GLX context, useful for cleanup regression tests",
    )
    parser.add_argument(
        "--leave-context",
        action="store_true",
        help="close the client without sending DestroyContext, useful for disconnect cleanup regression tests",
    )
    parser.add_argument(
        "--render-triangle",
        action="store_true",
        help="send a minimal indirect GLXRender clear/begin/vertex/end stream and flush errors with QueryContext",
    )
    parser.add_argument(
        "--visible-window",
        action="store_true",
        help="map a real top-level X window and render/swap GLX into it instead of the root drawable",
    )
    parser.add_argument("display", nargs="?", default="127.0.0.1:0", help="DISPLAY-style host:display")
    args = parser.parse_args()

    if ":" not in args.display:
        raise SystemExit("display must look like host:display")
    host, display_number_text = args.display.rsplit(":", 1)
    port = 6000 + int(display_number_text.split(".")[0])

    sock, root, root_visual, root_depth, rid_base, rid_mask = connect_x11(host, port)
    with sock:
        opcode = query_glx_extension(sock)

        sock.sendall(struct.pack("<BBHII", opcode, 7, 3, 1, 2))
        header, _ = read_reply(sock)
        major, minor = struct.unpack_from("<II", header, 8)
        print(f"GLX QueryVersion -> {major}.{minor}")

        print(f"GLX vendor={query_server_string(sock, opcode, 1)!r}")
        print(f"GLX version={query_server_string(sock, opcode, 2)!r}")
        print(f"GLX extensions={query_server_string(sock, opcode, 3)!r}")

        sock.sendall(struct.pack("<BBHI", opcode, 14, 2, 0))
        header, body = read_reply(sock)
        validate_visual_configs(root_visual, header, body)

        sock.sendall(struct.pack("<BBHI", opcode, 21, 2, 0))
        header, body = read_reply(sock)
        validate_fbconfigs(header, body)

        if args.context_offset is not None:
            dynamic_bits = args.context_offset & rid_mask
        else:
            dynamic_bits = (os.getpid() ^ time.monotonic_ns()) & rid_mask
        context = rid_base | (dynamic_bits if dynamic_bits else 0x101)
        drawable = root
        if args.visible_window:
            window_bits = (dynamic_bits + 1) & rid_mask
            drawable = rid_base | (window_bits if window_bits else 0x102)
            create_visible_window(sock, drawable, root, root_visual, root_depth, 420, 320)
        sock.sendall(struct.pack("<BBHIIIIIBBH", opcode, 24, 7, context, 1, 0, 0x8014, 0, 0, 0, 0))
        sock.sendall(struct.pack("<BBHIIII", opcode, 26, 5, 0, drawable, drawable, context))
        header, _ = read_reply(sock)
        tag = struct.unpack_from("<I", header, 8)[0]
        print(f"GLX MakeContextCurrent contextTag=0x{tag:x}")
        print(f"GL vendor={query_gl_string(sock, opcode, tag, GL_VENDOR)!r}")
        print(f"GL renderer={query_gl_string(sock, opcode, tag, GL_RENDERER)!r}")
        print(f"GL version={query_gl_string(sock, opcode, tag, GL_VERSION)!r}")
        print(f"GL extensions={query_gl_string(sock, opcode, tag, GL_EXTENSIONS)!r}")

        sock.sendall(struct.pack("<BBHI", opcode, 25, 2, context))
        header, body = read_reply(sock)
        count = struct.unpack_from("<I", header, 8)[0]
        values = struct.unpack_from("<" + "I" * (count * 2), body, 0) if count else ()
        print(f"GLX QueryContext pairs={count} values={[hex(value) for value in values]}")

        if args.render_triangle:
            render_payload = render_triangle_payload()
            sock.sendall(struct.pack("<BBHI", opcode, 1, (8 + len(render_payload)) // 4, tag) + render_payload)
            sock.sendall(struct.pack("<BBHI", opcode, 25, 2, context))
            read_reply(sock)
            print(f"GLX Render triangle stream accepted bytes={len(render_payload)}")

        sock.sendall(struct.pack("<BBHII", opcode, 11, 3, tag, drawable))
        print("GLX SwapBuffers request sent")

        if args.leave_context:
            print("GLX DestroyContext intentionally skipped")
        else:
            sock.sendall(struct.pack("<BBHI", opcode, 4, 2, context))
            print("GLX DestroyContext request sent")
        print("GLX direct smoke passed")

    return 0


if __name__ == "__main__":
    sys.exit(main())
