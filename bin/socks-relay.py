#!/usr/bin/env python3
"""socks-relay.py —— 本地 SOCKS5 中继：转发到需要用户名/密码的上游 SOCKS5。

Firefox 不支持 SOCKS5 认证（libxul 里没有 network.proxy.socks_username 这个 pref），
所以「socks5://user:pass@host:port」直接配给 Firefox 是无效的。
这个中继在 127.0.0.1 上开一个不需要认证的 SOCKS5，替客户端向上游做认证。

用法：
  ./bin/socks-relay.py --listen 127.0.0.1:21001 \\
      --upstream istoreos.lan:18805 --user u --pass p [--pidfile path]

只依赖 python3 标准库。
"""
import argparse
import asyncio
import os
import socket
import struct
import sys


async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError, asyncio.IncompleteReadError):
        pass
    finally:
        try:
            writer.write_eof()      # 半关闭：让对向还能把剩余数据写完
        except Exception:
            pass


async def open_upstream(host, port, user, pwd, target_host, target_port):
    reader, writer = await asyncio.wait_for(asyncio.open_connection(host, port), timeout=10)
    # 方法协商：只提供 0x02（用户名/密码）
    writer.write(b"\x05\x01\x02")
    await writer.drain()
    ver, method = await reader.readexactly(2)
    if ver != 5:
        raise RuntimeError("upstream is not socks5")
    if method == 0x02:
        u = user.encode()
        p = pwd.encode()
        writer.write(b"\x01" + bytes([len(u)]) + u + bytes([len(p)]) + p)
        await writer.drain()
        _, status = await reader.readexactly(2)
        if status != 0:
            raise RuntimeError("upstream rejected credentials")
    elif method != 0x00:
        raise RuntimeError(f"upstream refuses auth methods (0x{method:02x})")

    # CONNECT
    th = target_host.encode()
    writer.write(b"\x05\x01\x00\x03" + bytes([len(th)]) + th + struct.pack(">H", target_port))
    await writer.drain()
    ver, rep, _, atyp = await reader.readexactly(4)
    if ver != 5 or rep != 0:
        raise RuntimeError(f"upstream CONNECT failed (rep={rep})")
    if atyp == 0x01:
        await reader.readexactly(4 + 2)
    elif atyp == 0x03:
        ln = (await reader.readexactly(1))[0]
        await reader.readexactly(ln + 2)
    elif atyp == 0x04:
        await reader.readexactly(16 + 2)
    return reader, writer


async def handle(client_reader, client_writer, up_host, up_port, user, pwd):
    try:
        ver, nmethods = await client_reader.readexactly(2)
        if ver != 5:
            client_writer.close()
            return
        await client_reader.readexactly(nmethods)
        client_writer.write(b"\x05\x00")  # 本地不需要认证
        await client_writer.drain()

        ver, cmd, _, atyp = await client_reader.readexactly(4)
        if cmd != 0x01:
            client_writer.write(b"\x05\x07\x00\x01\x00\x00\x00\x00\x00\x00")
            await client_writer.drain()
            client_writer.close()
            return
        if atyp == 0x01:
            host = socket.inet_ntoa(await client_reader.readexactly(4))
        elif atyp == 0x03:
            ln = (await client_reader.readexactly(1))[0]
            host = (await client_reader.readexactly(ln)).decode()
        elif atyp == 0x04:
            host = socket.inet_ntop(socket.AF_INET6, await client_reader.readexactly(16))
        else:
            client_writer.close()
            return
        port = struct.unpack(">H", await client_reader.readexactly(2))[0]

        try:
            up_reader, up_writer = await open_upstream(up_host, up_port, user, pwd, host, port)
        except Exception as e:
            print(f"[relay] upstream error for {host}:{port}: {e}", file=sys.stderr, flush=True)
            client_writer.write(b"\x05\x05\x00\x01\x00\x00\x00\x00\x00\x00")
            await client_writer.drain()
            client_writer.close()
            return

        client_writer.write(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
        await client_writer.drain()
        await asyncio.gather(
            pipe(client_reader, up_writer),
            pipe(up_reader, client_writer),
        )
        for w in (up_writer, client_writer):
            try:
                w.close()
            except Exception:
                pass
    except Exception:
        try:
            client_writer.close()
        except Exception:
            pass


async def main_async(args):
    host, _, port = args.listen.rpartition(":")
    host = host or "127.0.0.1"
    if host not in ("127.0.0.1", "localhost", "::1"):
        print(f"[relay] 拒绝监听 {host}：只允许 loopback（否则会成为带凭据的开放代理）", file=sys.stderr)
        raise SystemExit(2)
    up_host, _, up_port = args.upstream.rpartition(":")

    async def cb(r, w):
        await handle(r, w, up_host, int(up_port), args.user, args.pass_)

    server = await asyncio.start_server(cb, host, int(port))
    if args.pidfile:
        with open(args.pidfile, "w") as f:
            f.write(str(__import__("os").getpid()))
    print(f"[relay] listening on {host}:{port} → {args.upstream}", flush=True)
    async with server:
        await server.serve_forever()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", required=True, help="127.0.0.1:21001")
    ap.add_argument("--upstream", required=True, help="host:port")
    ap.add_argument("--user", default="")
    ap.add_argument("--pass", dest="pass_", default="")
    ap.add_argument("--pidfile", default="")
    args = ap.parse_args()
    # 凭据优先取环境变量：命令行参数会出现在 /proc/PID/cmdline（全机可读）
    if not args.user:
        args.user = os.environ.get("SOCKS_RELAY_USER", "")
    if not args.pass_:
        args.pass_ = os.environ.get("SOCKS_RELAY_PASS", "")
    try:
        asyncio.run(main_async(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
