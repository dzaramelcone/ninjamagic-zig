import os

WS_HOST = os.getenv("WS_HOST", "app")
WS_PORT = int(os.getenv("WS_PORT", 9862))
WS_URL  = f"ws://{WS_HOST}:{WS_PORT}/"


def pytest_configure(config):
    config.addinivalue_line("markers", "asyncio")
