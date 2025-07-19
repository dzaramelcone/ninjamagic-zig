from uuid import uuid4
import pytest
from conftest import WS_URL
import websockets

@pytest.mark.asyncio
async def test_client_has_good_ping() -> None:
    alice = await websockets.connect(WS_URL)
    assert await alice.ping()
    await alice.close()


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
