import http.client
import os
import pathlib
import subprocess
import time
import pytest

PORT = 9224
HOST = "localhost"


def _request(path):
    conn = http.client.HTTPConnection(HOST, PORT, timeout=5)
    conn.request("GET", path)
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


def test_google_start_redirect(zig_server):
    res = _request("/auth/google")
    assert res.status == 302
    assert "accounts.google.com" in res.getheader("Location")


def test_google_callback_invalid_code(zig_server):
    res = _request("/auth/google/callback?code=bad")
    assert res.status != 200


def test_github_start_redirect(zig_server):
    res = _request("/auth/github")
    assert res.status == 302
    assert "github.com/login/oauth/authorize" in res.getheader("Location")


def test_github_callback_invalid_code(zig_server):
    res = _request("/auth/github/callback?code=bad")
    assert res.status != 200
