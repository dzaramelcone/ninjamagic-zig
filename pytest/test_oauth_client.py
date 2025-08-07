import http.client
import os
import pathlib
import subprocess
import time
import urllib.parse
import pytest

PORT = 9224
HOST = "localhost"


def _request(path, headers=None):
    conn = http.client.HTTPConnection(HOST, PORT, timeout=5)
    conn.request("GET", path, headers=headers or {})
    return conn.getresponse()


@pytest.fixture(scope="module")
def zig_server():
    root = pathlib.Path(__file__).resolve().parents[1]
    env = os.environ.copy()
    env.update(
        {
            "GOOGLE_CLIENT_ID": "id",
            "GOOGLE_CLIENT_SECRET": "secret",
            "GOOGLE_REDIRECT_URI": f"http://{HOST}:{PORT}/auth/google/callback",
            "GITHUB_CLIENT_ID": "id",
            "GITHUB_CLIENT_SECRET": "secret",
            "GITHUB_REDIRECT_URI": f"http://{HOST}:{PORT}/auth/github/callback",
            "OAUTH_TEST_MODE": "1",
        }
    )
    try:
        proc = subprocess.Popen(
            ["zig", "build", "run"], cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
    except FileNotFoundError:
        pytest.skip("zig not installed")
    time.sleep(1)
    yield
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()


def test_google_flow(zig_server):
    res = _request("/auth/google")
    assert res.status == 302
    loc = res.getheader("Location")
    cookie = res.getheader("Set-Cookie").split(";", 1)[0]
    qs = urllib.parse.urlparse(loc).query
    state = urllib.parse.parse_qs(qs)["state"][0]
    assert state in cookie
    res2 = _request(f"/auth/google/callback?code=bad&state={state}", {"Cookie": cookie})
    assert res2.status == 400


def test_github_flow(zig_server):
    res = _request("/auth/github")
    assert res.status == 302
    loc = res.getheader("Location")
    cookie = res.getheader("Set-Cookie").split(";", 1)[0]
    qs = urllib.parse.urlparse(loc).query
    state = urllib.parse.parse_qs(qs)["state"][0]
    assert state in cookie
    res2 = _request(f"/auth/github/callback?code=bad&state={state}", {"Cookie": cookie})
    assert res2.status == 400
