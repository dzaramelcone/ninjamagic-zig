import pytest
from conftest import WS_URL
import websockets
import asyncio


# @pytest.mark.asyncio
# async def test_solo_client(golden) -> None:
#     async with asyncio.timeout(1):
#         alice = await websockets.connect(WS_URL)
#         assert await alice.ping()
#         await alice.send("asfkld")
#         golden(await alice.recv())
#         await alice.send("\'")
#         golden(await alice.recv())
#         await alice.close()


# @pytest.mark.asyncio
# async def test_chat(golden):
#     alice, bob = await websockets.connect(WS_URL), await websockets.connect(WS_URL)
#     async with asyncio.timeout(1):
#         await alice.send("say hi")
#         golden(await alice.recv())
#         golden(await bob.recv())
    
#         await bob.send("\'hello")
#         golden(await alice.recv())
#         golden(await bob.recv())

#         await alice.close()
#         await bob.close()

@pytest.mark.asyncio
async def test_ws() -> None:
    import socket, time
    s=socket.create_connection(('app',9862),timeout=5)
    req=(
        b"GET / HTTP/1.1\r\n"
        b"Host: x\r\n"
        b"Upgrade: websocket\r\n"
        b"Connection: Upgrade\r\n"
        b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        b"Sec-WebSocket-Version: 13\r\n\r\n"
    )
    s.sendall(req)
    s.settimeout(3)
    try:
        resp=s.recv(4096)
        print('RESP:\n',resp)
    except Exception as e:
        print('recv error:',e)
    s.close()
