import asyncio,socket
import pytest
import websockets

from conftest import WS_HOST, WS_PORT, WS_URL


async def _wait_for_port(host, port, timeout=1.0):
    deadline = asyncio.get_event_loop().time() + timeout
    while True:
        try:
            with socket.create_connection((host, port), timeout=1):
                return
        except OSError:
            if asyncio.get_event_loop().time() > deadline:
                raise RuntimeError(f"Server not up on {host}:{port} after {timeout}s")
            await asyncio.sleep(0.05)


@pytest.mark.asyncio
async def test_clients_get_own_echo() -> None:
    await _wait_for_port(WS_HOST, WS_PORT)

    async with (
        websockets.connect(WS_URL) as alice,
    ):
        await alice.send("hi-bob")
        msg_a = await asyncio.wait_for(alice.recv(), timeout=1)
        assert msg_a == "hi-bob"


@pytest.mark.asyncio
async def test_two_clients_can_chat(server_ready):
    async with websockets.connect(WS_URL) as alice, websockets.connect(WS_URL) as bob:
        await alice.send("hello-from-alice")

        bob_hears = await asyncio.wait_for(bob.recv(), timeout=1)
        assert bob_hears == "hello-from-alice"

        await bob.send("hello-from-bob")

        alice_hears = await asyncio.wait_for(alice.recv(), timeout=1)
        assert alice_hears == "hello-from-bob"


# @pytest.mark.asyncio
# @pytest.mark.parametrize("n_clients", [5, 25])
# async def test_many_clients_can_connect(server_ready, n_clients):
#     async def _echo(ws, idx):
#         msg = f"msg-{idx}"
#         await ws.send(msg)
#         received = await asyncio.wait_for(ws.recv(), 1)
#         assert received == msg

#     clients = [await websockets.connect(WS_URL) for _ in range(n_clients)]
#     try:
#         # a quick no-op send/recv round to ensure each is functional
#         await asyncio.gather(*[
#             _echo(c, idx) for idx, c in enumerate(clients)
#         ])
#     finally:
#         await asyncio.gather(*[c.close() for c in clients])
