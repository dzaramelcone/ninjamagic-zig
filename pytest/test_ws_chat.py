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
    await alice.send("say hi")
    assert await alice.recv() == "You say, \'hi\'"
    assert await bob.recv() == "Alice says, \'hi\'"
    
    await bob.send("\'hello")
    assert await alice.recv() == "Bob says, \'hello\'"
    assert await bob.recv() == "You say, \'hello\'"

    await alice.close()
    await bob.close()
