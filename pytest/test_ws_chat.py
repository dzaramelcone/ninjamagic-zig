from uuid import uuid4
import pytest
from conftest import WS_URL
import websockets

@pytest.mark.asyncio
async def test_client_has_good_ping() -> None:
    alice = await websockets.connect(WS_URL)
    assert await alice.ping()


@pytest.mark.asyncio
async def test_chat():
    alice, bob = await websockets.connect(WS_URL), await websockets.connect(WS_URL)
    await alice.send("hello-from-alice")
    assert await alice.recv() == "hello-from-alice"
    assert await alice.recv() == "hello-from-alice"
    assert await bob.recv() == "hello-from-alice"
    
    await bob.send("hello-from-bob")
    assert await alice.recv() == "hello-from-bob"
    assert await bob.recv() == "hello-from-bob"
    assert await bob.recv() == "hello-from-bob"
    await alice.close()
    await bob.close()

# @pytest.mark.asyncio
# @pytest.mark.parametrize("ws_clients", [2], indirect=True)
# async def test_chat(ws_clients):
#     alice, bob = ws_clients
#     await send_and_broadcast(alice, "hello-from-alice")
#     heard = await asyncio.wait_for(bob.recv(), 1)
#     assert heard == "hello-from-alice"


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
