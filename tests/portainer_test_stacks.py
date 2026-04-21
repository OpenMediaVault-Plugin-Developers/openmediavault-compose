#!/usr/bin/env python3
"""
Manage a local Portainer test instance and populate it with test stacks
to exercise the omv-compose Portainer import feature.

Subcommands:
  start    Spin up a Portainer container, initialise admin account, and print connection details + API key
  stop     Remove the Portainer container and its data volume
  create   Create test stacks in a running Portainer instance
  delete   Delete the test stacks from a running Portainer instance

Examples:
  python3 portainer_test_stacks.py start
  python3 portainer_test_stacks.py start --port 9443 --password secret
  python3 portainer_test_stacks.py create --url https://localhost:9443 --apikey ptr_xxx
  python3 portainer_test_stacks.py create --url https://localhost:9443 --username admin --password testpassword
  python3 portainer_test_stacks.py delete --url https://localhost:9443 --apikey ptr_xxx
  python3 portainer_test_stacks.py stop
"""

import argparse
import base64
import json
import subprocess
import sys
import time

import requests
from requests.packages.urllib3.exceptions import InsecureRequestWarning

CONTAINER_NAME = "portainer-test"
VOLUME_NAME    = "portainer_data_test"
DEFAULT_PORT   = 9443
DEFAULT_USER   = "admin"
DEFAULT_PASS   = "testpassword"

TEST_STACKS = [
    {
        "name": "test-nginx",
        "compose": """\
services:
  nginx:
    image: nginx:latest
    ports:
      - "${HTTP_PORT}:80"
    restart: unless-stopped
""",
        "env": [
            {"name": "HTTP_PORT", "value": "8080"},
        ],
    },
    {
        "name": "test-whoami",
        "compose": """\
services:
  whoami:
    image: traefik/whoami:latest
    ports:
      - "8081:80"
    restart: unless-stopped
""",
        "env": [],
    },
    {
        "name": "test-redis",
        "compose": """\
services:
  redis:
    image: redis:7-alpine
    ports:
      - "${REDIS_PORT}:6379"
    volumes:
      - redis_data:/data
    restart: unless-stopped

volumes:
  redis_data:
""",
        "env": [
            {"name": "REDIS_PORT", "value": "6379"},
            {"name": "REDIS_PASSWORD", "value": "changeme"},
        ],
    },
    {
        "name": "test-portainer-duplicate",
        "compose": """\
services:
  hello:
    image: hello-world:latest
""",
        "env": [],
    },
]


# ---------------------------------------------------------------------------
# Docker helpers
# ---------------------------------------------------------------------------

def docker(*args: str, capture: bool = True) -> subprocess.CompletedProcess:
    cmd = ["docker", *args]
    result = subprocess.run(cmd, capture_output=capture, text=True)
    return result


def start_portainer(port: int) -> None:
    # Check if container already exists.
    result = docker("inspect", "--format", "{{.State.Status}}", CONTAINER_NAME)
    if result.returncode == 0:
        status = result.stdout.strip()
        print(f"Container '{CONTAINER_NAME}' already exists (status: {status}).")
        if status != "running":
            print("Starting existing container ...")
            docker("start", CONTAINER_NAME, capture=False)
        return

    print(f"  Starting Portainer on port {port} ...")
    result = docker(
        "run", "-d",
        "--name", CONTAINER_NAME,
        "-p", f"{port}:{port}",
        "-v", "/var/run/docker.sock:/var/run/docker.sock",
        "-v", f"{VOLUME_NAME}:/data",
        "portainer/portainer-ce:latest",
        f"--http-disabled",
        f"--bind=:{port}",
    )
    if result.returncode != 0:
        print(f"ERROR: Failed to start Portainer.\n{result.stderr}", file=sys.stderr)
        sys.exit(1)
    print(f"  Container ID: {result.stdout.strip()[:12]}")


def init_admin(url: str, username: str, password: str) -> str:
    """Initialise the admin account and return the JWT (if the response includes one)."""
    session = requests.Session()
    session.verify = False
    resp = session.post(f"{url}/api/users/admin/init", json={"Username": username, "Password": password})
    resp.raise_for_status()
    return resp.json().get("jwt", "")


def init_endpoint(url: str, username: str, password: str) -> None:
    """Register the local Docker socket as a Portainer environment."""
    session = get_session(url, "", username, password, False)
    resp = session.post(f"{url}/api/endpoints", data={
        "Name": "local",
        "EndpointCreationType": 1,
        "URL": "unix:///var/run/docker.sock",
    })
    resp.raise_for_status()


def stop_portainer() -> None:
    print(f"Stopping container '{CONTAINER_NAME}' ...")
    r = docker("rm", "-f", CONTAINER_NAME)
    if r.returncode == 0:
        print("  Container removed.")
    else:
        print(f"  Container not found or already removed.")

    print(f"Removing volume '{VOLUME_NAME}' ...")
    r = docker("volume", "rm", VOLUME_NAME)
    if r.returncode == 0:
        print("  Volume removed.")
    else:
        print(f"  Volume not found or already removed.")


# ---------------------------------------------------------------------------
# Portainer API helpers
# ---------------------------------------------------------------------------

def wait_for_portainer(url: str, timeout: int = 60) -> None:
    print(f"  Waiting for Portainer to be ready at {url} ...")
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            requests.get(f"{url}/api/status", verify=False, timeout=2)
            print("  Portainer is up.")
            return
        except requests.exceptions.ConnectionError:
            time.sleep(2)
    print("ERROR: Portainer did not become ready in time.", file=sys.stderr)
    sys.exit(1)


def _csrf_from_jwt(token: str) -> str:
    """Extract the CSRF token from a JWT payload.

    Portainer uses the jti (JWT ID) claim as the double-submit CSRF value.
    The token is readable from the /api/auth response body and must be echoed
    back as the X-CSRF-Token header on state-changing requests.
    """
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)  # re-pad
        claims = json.loads(base64.urlsafe_b64decode(payload))
        # Try dedicated csrf claim first, fall back to jti.
        return claims.get("csrf") or claims.get("jti", "")
    except Exception:
        return ""


def get_session(url: str, apikey: str, username: str, password: str, ssl_verify: bool) -> requests.Session:
    session = requests.Session()
    session.verify = ssl_verify
    # Portainer requires both Referer and X-CSRF-Token on state-changing requests.
    session.headers["Referer"] = url
    if apikey:
        session.headers["X-API-Key"] = apikey
    else:
        resp = session.post(f"{url}/api/auth", json={"Username": username, "Password": password})
        resp.raise_for_status()
        jwt = resp.json()["jwt"]
        session.headers["Authorization"] = f"Bearer {jwt}"

        # Portainer only generates the CSRF token (_gorilla_csrf cookie + X-Csrf-Token
        # header) on GET requests, not on the auth POST. Fetch it now so all subsequent
        # state-changing calls in this session carry the correct token.
        get_resp = session.get(f"{url}/api/users/me")
        csrf = get_resp.headers.get("X-Csrf-Token", "")
        if csrf:
            session.headers["X-CSRF-Token"] = csrf
    return session


def create_api_key(url: str, username: str, password: str) -> str:
    """Authenticate with username/password and create a named API key."""
    session = get_session(url, "", username, password, False)
    # Extract the numeric user ID from the JWT — this version requires
    # /api/users/{id}/tokens rather than /api/users/me/tokens.
    jwt = session.headers.get("Authorization", "").removeprefix("Bearer ")
    try:
        payload = jwt.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        user_id = json.loads(base64.urlsafe_b64decode(payload)).get("id", 1)
    except Exception:
        user_id = 1
    resp = session.post(
        f"{url}/api/users/{user_id}/tokens",
        json={"password": password, "description": "omv-compose-test"},
    )
    resp.raise_for_status()
    return resp.json()["rawAPIKey"]


def get_endpoint_id(session: requests.Session, url: str) -> int:
    resp = session.get(f"{url}/api/endpoints")
    resp.raise_for_status()
    endpoints = resp.json()
    if not endpoints:
        print("ERROR: No endpoints found in Portainer.", file=sys.stderr)
        sys.exit(1)
    if len(endpoints) > 1:
        print("Multiple endpoints found:")
        for ep in endpoints:
            print(f"  [{ep['Id']}] {ep['Name']}")
        choice = input("Enter endpoint ID to use: ").strip()
        return int(choice)
    ep = endpoints[0]
    print(f"  Using endpoint: [{ep['Id']}] {ep['Name']}")
    return ep["Id"]


def list_stacks(session: requests.Session, url: str) -> list[dict]:
    resp = session.get(f"{url}/api/stacks")
    resp.raise_for_status()
    return resp.json()


def create_stack(session: requests.Session, url: str, endpoint_id: int, stack: dict) -> dict:
    resp = session.post(
        f"{url}/api/stacks/create/standalone/string",
        params={"endpointId": endpoint_id},
        json={
            "name": stack["name"],
            "stackFileContent": stack["compose"],
            "env": stack["env"],
        },
    )
    resp.raise_for_status()
    return resp.json()


def delete_stack(session: requests.Session, url: str, stack_id: int, endpoint_id: int) -> None:
    resp = session.delete(f"{url}/api/stacks/{stack_id}", params={"endpointId": endpoint_id})
    resp.raise_for_status()


# ---------------------------------------------------------------------------
# Subcommand handlers
# ---------------------------------------------------------------------------

def cmd_start(args: argparse.Namespace) -> None:
    requests.packages.urllib3.disable_warnings(InsecureRequestWarning)
    url = f"https://localhost:{args.port}"

    print(f"Starting Portainer test instance ...")
    start_portainer(args.port)
    wait_for_portainer(url)

    setup_jwt = ""
    print(f"  Initialising admin account ...")
    try:
        setup_jwt = init_admin(url, DEFAULT_USER, args.password)
    except requests.HTTPError as e:
        if e.response.status_code == 409:
            print("  Admin account already initialised.")
        else:
            print(f"WARNING: Could not initialise admin: {e}\n    Response body: {e.response.text}")

    print("  Registering local Docker environment ...")
    try:
        init_endpoint(url, DEFAULT_USER, args.password)
    except requests.HTTPError as e:
        if e.response.status_code == 409:
            print("  Environment already registered.")
        else:
            print(f"WARNING: Could not register environment: {e}")

    print("  Creating API key ...")
    try:
        api_key = create_api_key(url, DEFAULT_USER, args.password)
    except requests.HTTPError as e:
        print(f"WARNING: Could not create API key: {e}\n    Response body: {e.response.text}")
        api_key = None

    print()
    print("=" * 60)
    print("  Portainer is ready")
    print(f"  URL:      {url}")
    print(f"  Username: {DEFAULT_USER}")
    print(f"  Password: {args.password}")
    if api_key:
        print(f"  API key:  {api_key}")
    print()
    print("  To create test stacks:")
    if api_key:
        print(f"    python3 portainer_test_stacks.py create \\")
        print(f"      --url {url} --apikey {api_key} --no-ssl-verify")
    else:
        print(f"    python3 portainer_test_stacks.py create \\")
        print(f"      --url {url} --username {DEFAULT_USER} --password {args.password} --no-ssl-verify")
    print()
    print("  To stop and remove everything:")
    print("    python3 portainer_test_stacks.py stop")
    print("=" * 60)


def cmd_stop(args: argparse.Namespace) -> None:
    stop_portainer()


def cmd_create(args: argparse.Namespace) -> None:
    ssl_verify = not args.no_ssl_verify
    if not ssl_verify:
        requests.packages.urllib3.disable_warnings(InsecureRequestWarning)

    if not args.apikey and not (args.username and args.password):
        print("ERROR: Provide either --apikey or both --username and --password.", file=sys.stderr)
        sys.exit(1)

    url = args.url.rstrip("/")
    print(f"Connecting to {url} ...")
    session = get_session(url, args.apikey, args.username, args.password, ssl_verify)
    endpoint_id = get_endpoint_id(session, url)

    existing_names = {s["Name"] for s in list_stacks(session, url)}
    created = skipped = 0

    for stack in TEST_STACKS:
        name = stack["name"]
        if name in existing_names:
            print(f"  Skipping '{name}' — already exists.")
            skipped += 1
            continue
        print(f"  Creating '{name}' ...", end=" ", flush=True)
        try:
            result = create_stack(session, url, endpoint_id, stack)
            print(f"created (id={result['Id']})")
            created += 1
        except requests.HTTPError as e:
            print(f"FAILED: {e.response.text}")

    print(f"\nDone. {created} created, {skipped} skipped.")
    if created:
        print("\nYou can now test 'Import from Portainer' in the compose plugin.")
        print("Import once, then import again — 'test-portainer-duplicate' verifies that existing stacks are skipped.")


def cmd_delete(args: argparse.Namespace) -> None:
    ssl_verify = not args.no_ssl_verify
    if not ssl_verify:
        requests.packages.urllib3.disable_warnings(InsecureRequestWarning)

    if not args.apikey and not (args.username and args.password):
        print("ERROR: Provide either --apikey or both --username and --password.", file=sys.stderr)
        sys.exit(1)

    url = args.url.rstrip("/")
    print(f"Connecting to {url} ...")
    session = get_session(url, args.apikey, args.username, args.password, ssl_verify)
    endpoint_id = get_endpoint_id(session, url)

    test_names = {s["name"] for s in TEST_STACKS}
    to_delete = [s for s in list_stacks(session, url) if s["Name"] in test_names]

    if not to_delete:
        print("No test stacks found to delete.")
        return

    for stack in to_delete:
        print(f"  Deleting '{stack['Name']}' (id={stack['Id']}) ...", end=" ", flush=True)
        try:
            delete_stack(session, url, stack["Id"], endpoint_id)
            print("deleted")
        except requests.HTTPError as e:
            print(f"FAILED: {e}")


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Manage a local Portainer test instance and its test stacks.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # start
    p_start = sub.add_parser("start", help="Spin up a local Portainer container")
    p_start.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"HTTPS port (default: {DEFAULT_PORT})")
    p_start.add_argument("--password", default=DEFAULT_PASS, help=f"Admin password (default: {DEFAULT_PASS})")

    # stop
    sub.add_parser("stop", help=f"Remove the '{CONTAINER_NAME}' container and its volume")

    # shared auth args for create/delete
    def add_auth_args(p: argparse.ArgumentParser) -> None:
        p.add_argument("--url", required=True, help="Portainer base URL, e.g. https://localhost:9443")
        p.add_argument("--apikey", default="", help="Portainer API key")
        p.add_argument("--username", default="", help="Portainer username")
        p.add_argument("--password", default="", help="Portainer password")
        p.add_argument("--no-ssl-verify", action="store_true", help="Disable SSL certificate verification")

    # create
    p_create = sub.add_parser("create", help="Create test stacks in a running Portainer instance")
    add_auth_args(p_create)

    # delete
    p_delete = sub.add_parser("delete", help="Delete test stacks from a running Portainer instance")
    add_auth_args(p_delete)

    args = parser.parse_args()
    {"start": cmd_start, "stop": cmd_stop, "create": cmd_create, "delete": cmd_delete}[args.command](args)


if __name__ == "__main__":
    main()
