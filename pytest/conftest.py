import pytest
import os
import socket
import time


WS_HOST = os.getenv("WS_HOST", "app")
WS_PORT = int(os.getenv("WS_PORT", 9862))
WS_URL  = f"ws://{WS_HOST}:{WS_PORT}/"


def pytest_configure(config):
    config.addinivalue_line("markers", "asyncio")


@pytest.fixture(scope="session")
def server_ready():
    timeout = 10
    deadline = time.monotonic() + timeout
    while True:
        try:
            with socket.create_connection((WS_HOST, WS_PORT), timeout=0.25):
                break
        except OSError:
            if time.monotonic() > deadline:
                raise RuntimeError(
                    f"Websocket server not reachable on {WS_HOST}:{WS_PORT} "
                    f"after {timeout} s. Is the app healthy and hosting at that address?")
            time.sleep(0.1)
    yield
