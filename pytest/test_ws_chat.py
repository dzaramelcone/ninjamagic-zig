import pytest
from conftest import WS_URL
import websockets
import asyncio

@pytest.mark.asyncio
async def test_solo_client(golden) -> None:
    async with asyncio.timeout(1):
        alice = await websockets.connect(WS_URL)
        assert await alice.ping()
        await alice.send("asfkld")
        assert golden(await alice.recv())
        await alice.send("\'")
        assert golden(await alice.recv())
        await alice.close()


@pytest.mark.asyncio
async def test_chat(golden):
    alice, bob = await websockets.connect(WS_URL), await websockets.connect(WS_URL)
    async with asyncio.timeout(1):
        await alice.send("say hi")
        assert golden(await alice.recv())
        assert golden(await bob.recv())
    
        await bob.send("\'hello")
        assert golden(await alice.recv())
        assert golden(await bob.recv())

        await alice.close()
        await bob.close()
