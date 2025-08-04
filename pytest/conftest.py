import json
import os
import pathlib
import pytest

WS_HOST = os.getenv("WS_HOST", "app")
WS_PORT = int(os.getenv("WS_PORT", 9862))
WS_URL  = f"ws://{WS_HOST}:{WS_PORT}/"


def pytest_configure(config):
    config.addinivalue_line("markers", "asyncio")


@pytest.fixture(scope="session")
def golden_update():
    return False

@pytest.fixture
def golden(request, golden_update):
    base_dir = pathlib.Path(__file__).parent / "goldens"
    ctr = 0

    def _golden(data):
        data = json.loads(data)
        assert data, "Did not receive valid json data!"
        nonlocal ctr
        g_path = base_dir / f"{request.node.name}-{ctr}.json"
        ctr += 1
        if golden_update or not g_path.exists():
            g_path.parent.mkdir(parents=True, exist_ok=True)
            g_path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
            return

        expected = json.loads(g_path.read_text())
        assert data == expected

    return _golden