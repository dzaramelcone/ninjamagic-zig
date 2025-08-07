import os
import subprocess
import pathlib
import time
import socket
import urllib.request
import urllib.error
import shutil

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
PORT = 9224


def wait_for_port(host: str, port: int, timeout: float = 5.0) -> None:
    """Poll until the TCP port opens or timeout expires."""
    start = time.time()
    while time.time() - start < timeout:
        with socket.socket() as sock:
            try:
                sock.connect((host, port))
            except OSError:
                time.sleep(0.1)
                continue
            return
    raise RuntimeError(f"port {port} on {host} did not open")


@pytest.fixture()
def server():
    if shutil.which("zig") is None:
        pytest.skip("zig not installed")
    env = os.environ.copy()
    env.update(
        {
            "GOOGLE_CLIENT_ID": "id",
            "GOOGLE_CLIENT_SECRET": "secret",
            "GOOGLE_REDIRECT_URI": "http://localhost/auth/google/callback",
            "GITHUB_CLIENT_ID": "id",
            "GITHUB_CLIENT_SECRET": "secret",
            "GITHUB_REDIRECT_URI": "http://localhost/auth/github/callback",
        }
    )
    proc = subprocess.Popen(["zig", "build", "run"], cwd=ROOT, env=env)
    try:
        wait_for_port("127.0.0.1", PORT, timeout=10)
        yield
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, msg, headers, fp)


def opener_no_redirect():
    return urllib.request.build_opener(NoRedirect)


def test_google_start_redirect(server):
    opener = opener_no_redirect()
    with pytest.raises(urllib.error.HTTPError) as exc:
        opener.open(f"http://127.0.0.1:{PORT}/auth/google")
    assert exc.value.code == 302
    assert "accounts.google.com" in exc.value.headers["Location"]


def test_google_callback_requires_code(server):
    opener = opener_no_redirect()
    with pytest.raises(urllib.error.HTTPError) as exc:
        opener.open(f"http://127.0.0.1:{PORT}/auth/google/callback")
    assert exc.value.code == 400


def test_google_callback_bad_code(server):
    opener = opener_no_redirect()
    with pytest.raises(urllib.error.HTTPError) as exc:
        opener.open(
            f"http://127.0.0.1:{PORT}/auth/google/callback?code=bad"
        )
    # Expect server to reject invalid code with 500
    assert exc.value.code == 500


def test_github_start_redirect(server):
    opener = opener_no_redirect()
    with pytest.raises(urllib.error.HTTPError) as exc:
        opener.open(f"http://127.0.0.1:{PORT}/auth/github")
    assert exc.value.code == 302
    assert "github.com/login/oauth" in exc.value.headers["Location"]


def test_github_callback_requires_code(server):
    opener = opener_no_redirect()
    with pytest.raises(urllib.error.HTTPError) as exc:
        opener.open(f"http://127.0.0.1:{PORT}/auth/github/callback")
    assert exc.value.code == 400


def test_github_callback_bad_code(server):
    opener = opener_no_redirect()
    with pytest.raises(urllib.error.HTTPError) as exc:
        opener.open(
            f"http://127.0.0.1:{PORT}/auth/github/callback?code=bad"
        )
    assert exc.value.code == 500

