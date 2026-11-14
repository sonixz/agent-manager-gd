#!/usr/bin/env python3
"""Agent Manager GD's door (Loop 48). Fly.io's service 443 (HTTPS, Fly's certificate) reaches port 8443 here; this
passes each connection on to the one port bound to the public URL, written in a door file by Agent Manager and read
at each connection (binding another port needs no restart). No door file: nothing passes, the connection is closed.
The service it reaches may listen on 127.0.0.1 only."""
import asyncio
import os

FILES = tuple(os.environ.get("AGMGD_DOOR_FILES", "/data/.agmgd/door:/var/lib/agmgd/door").split(":"))
LISTEN = int(os.environ.get("AGMGD_DOOR_LISTEN", "8443"))   # the variables are for the tests only


def target() -> int:
    for path in FILES:
        try:
            with open(path, encoding="utf-8") as f:
                port = int(f.read().strip())
        except (OSError, ValueError):
            continue
        if 0 < port < 65536 and port != LISTEN:
            return port
    return 0


async def pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (OSError, asyncio.IncompleteReadError):
        pass
    finally:
        try:
            writer.close()
        except OSError:
            pass


async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    port = target()
    up = None
    if port:
        for host in ("127.0.0.1", "::1"):
            try:
                up = await asyncio.open_connection(host, port)
                break
            except OSError:
                continue
    if up is None:
        writer.close()
        return
    await asyncio.gather(pipe(reader, up[1]), pipe(up[0], writer))


async def main() -> None:
    server = await asyncio.start_server(handle, os.environ.get("AGMGD_DOOR_HOST", "0.0.0.0"), LISTEN)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
