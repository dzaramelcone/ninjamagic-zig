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
        golden(await alice.recv())
        await alice.send("\'")
        golden(await alice.recv())
        await alice.close()


@pytest.mark.asyncio
async def test_chat(golden):
    alice, bob = await websockets.connect(WS_URL), await websockets.connect(WS_URL)
    async with asyncio.timeout(1):
        await alice.send("say hi")
        golden(await alice.recv())
        golden(await bob.recv())
    
        await bob.send("\'hello")
        golden(await alice.recv())
        golden(await bob.recv())

        await alice.close()
        await bob.close()

