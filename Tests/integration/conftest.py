"""Shared fixtures for integration tests -- server health guards."""
import httpx
import pytest


def _server_alive(url: str) -> bool:
    try:
        resp = httpx.get(f"{url}/health", timeout=2)
        return resp.status_code == 200
    except httpx.HTTPError:
        return False


@pytest.fixture(scope="session", autouse=True)
def guard_server_11434():
    """Skip server-dependent tests early if port 11434 is unreachable."""
    if not _server_alive("http://localhost:11434"):
        pytest.skip("apfel server on port 11434 not running")


@pytest.fixture(scope="session", autouse=True)
def guard_server_11435():
    """Skip MCP server tests early if port 11435 is unreachable."""
    if not _server_alive("http://localhost:11435"):
        pytest.skip("apfel MCP server on port 11435 not running")
