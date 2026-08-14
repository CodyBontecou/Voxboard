#!/usr/bin/env python3
"""Authenticate the exact GitHub Actions identity used for hosted M2 evidence."""
from __future__ import annotations

import base64
import hashlib
import json
import os
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable

ISSUER = "https://token.actions.githubusercontent.com"
JWKS_URL = "https://token.actions.githubusercontent.com/.well-known/jwks"
TOKEN_ENDPOINT_HOSTS = frozenset({
    "pipelines.actions.githubusercontent.com",
    "vstoken.actions.githubusercontent.com",
})
AUDIENCE = "https://vox.md/m2-evidence/v1"
REPOSITORY = "CodyBontecou/vox.md"
REPOSITORY_ID = "1153091883"
OWNER = "CodyBontecou"
OWNER_ID = "20440899"
VISIBILITY = "public"
WORKFLOW_PATH = ".github/workflows/core-rust-ci.yml"
ORCHESTRATOR_PATH = "Packages/vox-core-rust/scripts/run-m2-hosted-evidence.sh"
MAX_TOKEN_BYTES = 16 * 1024
MAX_SEGMENT_BYTES = 12 * 1024
MAX_JSON_BYTES = 64 * 1024
MAX_KEYS = 64

class OIDCError(Exception):
    pass

def _json(data: bytes, label: str, limit: int = MAX_JSON_BYTES) -> Any:
    if len(data) > limit:
        raise OIDCError(f"{label} exceeds byte bound")
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise OIDCError(f"{label} has duplicate property {key!r}")
            result[key] = value
        return result
    try:
        return json.loads(data.decode("utf-8"), object_pairs_hook=pairs)
    except OIDCError:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise OIDCError(f"{label} is invalid JSON") from error

def _get(url: str, headers: dict[str, str], label: str, expected_hosts: frozenset[str]) -> bytes:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or parsed.hostname not in expected_hosts or parsed.username is not None or parsed.password is not None or parsed.fragment:
        raise OIDCError(f"{label} URL is not the pinned HTTPS endpoint")
    try:
        request = urllib.request.Request(url, headers=headers, method="GET")
        with urllib.request.urlopen(request, timeout=10) as response:
            final = urllib.parse.urlsplit(response.geturl())
            if final.scheme != "https" or final.hostname not in expected_hosts or final.username is not None or final.password is not None:
                raise OIDCError(f"{label} redirected away from the pinned HTTPS endpoint")
            if response.status != 200:
                raise OIDCError(f"{label} returned HTTP {response.status}")
            data = response.read(MAX_JSON_BYTES + 1)
    except OIDCError:
        raise
    except Exception as error:
        raise OIDCError(f"{label} request failed") from error
    if len(data) > MAX_JSON_BYTES:
        raise OIDCError(f"{label} exceeds byte bound")
    return data

def _decode(segment: str, label: str) -> bytes:
    if not segment or len(segment) > MAX_SEGMENT_BYTES or any(c not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_" for c in segment):
        raise OIDCError(f"JWT {label} segment is malformed or oversized")
    try:
        data = base64.urlsafe_b64decode(segment + "=" * (-len(segment) % 4))
    except Exception as error:
        raise OIDCError(f"JWT {label} segment is not base64url") from error
    if base64.urlsafe_b64encode(data).decode().rstrip("=") != segment:
        raise OIDCError(f"JWT {label} segment is noncanonical base64url")
    return data

def _integer(value: str, label: str) -> int:
    data = _decode(value, label)
    if not data or len(data) > 1024 or data[0] == 0:
        raise OIDCError(f"JWKS {label} is invalid")
    return int.from_bytes(data, "big")

def validate_token(token: str, jwks: dict[str, Any], expected: dict[str, Any], now: int | None = None) -> dict[str, Any]:
    if not isinstance(token, str) or len(token.encode()) > MAX_TOKEN_BYTES or token.count(".") != 2:
        raise OIDCError("OIDC token is malformed or oversized")
    encoded_header, encoded_payload, encoded_signature = token.split(".")
    header = _json(_decode(encoded_header, "header"), "JWT header", 4096)
    claims = _json(_decode(encoded_payload, "payload"), "JWT payload", 8192)
    allowed_header={"alg","kid","typ","x5t"}
    if not isinstance(header, dict) or not {"alg","kid","typ"} <= set(header) <= allowed_header or header["alg"] != "RS256" or header["typ"] != "JWT" or not isinstance(header["kid"], str) or not (1 <= len(header["kid"]) <= 256) or ("x5t" in header and (not isinstance(header["x5t"],str) or not (1<=len(header["x5t"])<=256))):
        raise OIDCError("JWT header is not a bounded RS256 header")
    if not isinstance(claims,dict) or len(claims) > 128: raise OIDCError("JWT payload must be a bounded object")
    keys = jwks.get("keys") if isinstance(jwks, dict) and set(jwks) == {"keys"} else None
    if not isinstance(keys, list) or not (1 <= len(keys) <= MAX_KEYS):
        raise OIDCError("GitHub JWKS key inventory is invalid")
    matches = [key for key in keys if isinstance(key, dict) and key.get("kid") == header["kid"]]
    if len(matches) != 1:
        raise OIDCError("JWT signing key is absent or ambiguous")
    key = matches[0]
    if key.get("kty") != "RSA" or key.get("use") != "sig" or key.get("alg") not in (None, "RS256") or not isinstance(key.get("n"), str) or not isinstance(key.get("e"), str):
        raise OIDCError("JWT signing key is not an allowed RSA signing key")
    modulus = _integer(key["n"], "modulus"); exponent = _integer(key["e"], "exponent")
    if modulus.bit_length() < 2048 or modulus.bit_length() > 8192 or exponent < 3 or exponent > 0xffffffff or exponent % 2 == 0:
        raise OIDCError("JWT RSA key parameters are outside bounds")
    signature = _decode(encoded_signature, "signature"); width = (modulus.bit_length() + 7) // 8
    signature_integer = int.from_bytes(signature, "big")
    if len(signature) != width or signature_integer >= modulus:
        raise OIDCError("JWT RSA signature length or representative mismatch")
    decoded = pow(signature_integer, exponent, modulus).to_bytes(width, "big")
    digest_info = bytes.fromhex("3031300d060960864801650304020105000420") + hashlib.sha256(f"{encoded_header}.{encoded_payload}".encode()).digest()
    padding = width - len(digest_info) - 3
    if padding < 8 or decoded != b"\x00\x01" + b"\xff" * padding + b"\x00" + digest_info:
        raise OIDCError("JWT RS256 signature verification failed")
    current = int(time.time()) if now is None else now
    for name in ("exp", "nbf", "iat"):
        if not isinstance(claims.get(name), int) or isinstance(claims[name], bool):
            raise OIDCError(f"JWT {name} claim is missing or invalid")
    if claims["exp"] <= current or claims["nbf"] > current + 30 or claims["iat"] > current + 30 or claims["iat"] < current - 600 or claims["exp"] - claims["iat"] > 900:
        raise OIDCError("JWT time claims are expired, future, or outside bounds")
    expected_subject = (
        f"repo:{REPOSITORY}:pull_request"
        if expected["eventName"] == "pull_request"
        else f"repo:{REPOSITORY}:ref:{expected['ref']}"
    )
    if not isinstance(claims.get("jti"), str) or not (1 <= len(claims["jti"]) <= 256):
        raise OIDCError("JWT jti claim is missing or invalid")
    exact = {
        "iss": ISSUER, "aud": AUDIENCE, "sub": expected_subject,
        "repository": REPOSITORY,
        "repository_id": REPOSITORY_ID, "repository_owner": OWNER,
        "repository_owner_id": OWNER_ID, "repository_visibility": VISIBILITY,
        "sha": expected["sourceRevision"], "workflow_sha": expected["workflowRevision"],
        "workflow_ref": expected["workflowReference"], "run_id": expected["runID"],
        "run_attempt": str(expected["runAttempt"]), "ref": expected["ref"],
        "event_name": expected["eventName"], "runner_environment": "github-hosted",
    }
    for name, value in exact.items():
        if claims.get(name) != value:
            raise OIDCError(f"JWT {name} claim mismatch")
    return claims

def expected_identity(repository_root: Path, qualification: dict[str, Any], git_revision: str) -> dict[str, Any]:
    required = ("GITHUB_REF", "GITHUB_EVENT_NAME", "GITHUB_WORKFLOW_REF", "GITHUB_WORKFLOW_SHA")
    if any(not os.environ.get(name) for name in required):
        raise OIDCError("GitHub workflow identity environment is incomplete")
    workflow_reference=os.environ["GITHUB_WORKFLOW_REF"]
    before_ref,separator,_=workflow_reference.rpartition("@")
    if not separator or before_ref!=f"{REPOSITORY}/{WORKFLOW_PATH}":
        raise OIDCError("GitHub workflow reference is not the canonical repository workflow")
    return {
        "repository": REPOSITORY, "repositoryID": REPOSITORY_ID, "repositoryOwner": OWNER,
        "repositoryOwnerID": OWNER_ID, "repositoryVisibility": VISIBILITY,
        "oidcIssuer": ISSUER, "oidcAudience": AUDIENCE,
        "sourceRevision": git_revision, "workflowRevision": os.environ["GITHUB_WORKFLOW_SHA"],
        "workflowReference": workflow_reference,
        "ref": os.environ["GITHUB_REF"], "eventName": os.environ["GITHUB_EVENT_NAME"],
        "runnerEnvironment": "github-hosted", "runID": qualification["runID"],
        "runAttempt": qualification["runAttempt"],
        "orchestratorRepositoryPath": ORCHESTRATOR_PATH,
        "orchestratorSha256": hashlib.sha256((repository_root / ORCHESTRATOR_PATH).read_bytes()).hexdigest(),
    }

def authenticate(repository_root: Path, qualification: dict[str, Any], git_revision: str,
                 token_fetcher: Callable[[str, str], tuple[str, dict[str, Any]]] | None = None) -> dict[str, Any]:
    expected = expected_identity(repository_root, qualification, git_revision)
    if token_fetcher is None:
        request_url = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_URL")
        request_token = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_TOKEN")
        if not request_url or not request_token:
            raise OIDCError("GitHub Actions OIDC request credentials are required")
        if len(request_url) > 8192 or not (32 <= len(request_token) <= 8192) or any(character in request_token for character in "\r\n"):
            raise OIDCError("GitHub Actions OIDC request credentials are outside bounds")
        parsed = urllib.parse.urlsplit(request_url)
        if parsed.scheme != "https" or parsed.hostname not in TOKEN_ENDPOINT_HOSTS or parsed.username is not None or parsed.password is not None or parsed.fragment:
            raise OIDCError("GitHub OIDC token URL is not the pinned HTTPS endpoint")
        query = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
        if any(key == "audience" for key, _ in query):
            raise OIDCError("GitHub OIDC token URL already contains an audience")
        query.append(("audience", AUDIENCE))
        token_url = urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, parsed.path, urllib.parse.urlencode(query), ""))
        response = _json(_get(token_url, {"Authorization": f"Bearer {request_token}", "Accept": "application/json"}, "GitHub OIDC token", TOKEN_ENDPOINT_HOSTS), "GitHub OIDC token response")
        if not isinstance(response, dict) or set(response) != {"value"} or not isinstance(response["value"], str):
            raise OIDCError("GitHub OIDC token response is invalid")
        token = response["value"]
        jwks = _json(_get(JWKS_URL, {"Accept": "application/json"}, "GitHub JWKS", frozenset({"token.actions.githubusercontent.com"})), "GitHub JWKS")
    else:
        token, jwks = token_fetcher(AUDIENCE, JWKS_URL)
    validate_token(token, jwks, expected)
    return expected
