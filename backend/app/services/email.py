"""Transactional email via Azure Communication Services.

ACS's REST API is called directly with ``httpx`` rather than the
``azure-communication-email`` SDK: httpx is already a hard dependency, so
nothing extra ships in the container image, and the request signing is small
enough to own.

Signing (ACS "HMAC-SHA256" scheme)::

    stringToSign = "POST\\n{path?query}\\n{x-ms-date};{host};{content-sha256}"
    signature    = base64(HMAC_SHA256(base64decode(accesskey), stringToSign))

In mock mode nothing is sent — the message is logged instead, and tests read the
code back through the dev router.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import logging
from dataclasses import dataclass
from email.utils import formatdate
from urllib.parse import urlsplit

import httpx

from app.core.config import Settings, get_settings

log = logging.getLogger(__name__)

API_VERSION = "2023-03-31"


class EmailError(RuntimeError):
    """The provider rejected the message, or is not configured."""


@dataclass(frozen=True)
class AcsCredentials:
    endpoint: str  # "https://x.communication.azure.com/"
    access_key: bytes  # already base64-decoded

    @property
    def host(self) -> str:
        return urlsplit(self.endpoint).netloc


def parse_connection_string(value: str) -> AcsCredentials:
    """Split ``endpoint=...;accesskey=...`` into its parts.

    Order-insensitive and tolerant of whitespace, because connection strings get
    copied out of the Azure portal by hand.
    """
    parts: dict[str, str] = {}
    for segment in value.split(";"):
        segment = segment.strip()
        if not segment:
            continue
        key, sep, val = segment.partition("=")
        if not sep:
            continue
        # The key itself is base64 and contains '=' padding, so only split once.
        parts[key.strip().lower()] = val.strip()

    endpoint = parts.get("endpoint", "")
    access_key = parts.get("accesskey", "")
    if not endpoint or not access_key:
        raise EmailError("ACS connection string must contain endpoint= and accesskey=")
    if not endpoint.endswith("/"):
        endpoint += "/"
    try:
        decoded = base64.b64decode(access_key)
    except Exception as exc:  # noqa: BLE001 - surfaced as a config error
        raise EmailError("ACS accesskey is not valid base64") from exc
    return AcsCredentials(endpoint=endpoint, access_key=decoded)


def content_hash(body: bytes) -> str:
    return base64.b64encode(hashlib.sha256(body).digest()).decode()


def build_signature(
    creds: AcsCredentials,
    *,
    method: str,
    path_and_query: str,
    date_header: str,
    body_hash: str,
) -> str:
    string_to_sign = f"{method}\n{path_and_query}\n{date_header};{creds.host};{body_hash}"
    digest = hmac.new(creds.access_key, string_to_sign.encode("utf-8"), hashlib.sha256).digest()
    return base64.b64encode(digest).decode()


def build_headers(creds: AcsCredentials, *, path_and_query: str, body: bytes) -> dict[str, str]:
    # RFC 1123 in GMT, which is what ACS expects and what it signs over.
    date_header = formatdate(timeval=None, localtime=False, usegmt=True)
    body_hash = content_hash(body)
    signature = build_signature(
        creds,
        method="POST",
        path_and_query=path_and_query,
        date_header=date_header,
        body_hash=body_hash,
    )
    return {
        "Content-Type": "application/json",
        "x-ms-date": date_header,
        "x-ms-content-sha256": body_hash,
        "Authorization": (
            "HMAC-SHA256 SignedHeaders=x-ms-date;host;x-ms-content-sha256"
            f"&Signature={signature}"
        ),
    }


def build_payload(sender: str, to: str, subject: str, text: str, html: str = "") -> dict:
    return {
        "senderAddress": sender,
        "recipients": {"to": [{"address": to}]},
        "content": {"subject": subject, "plainText": text, **({"html": html} if html else {})},
    }


class EmailService:
    def __init__(self, settings: Settings | None = None) -> None:
        self.settings = settings or get_settings()

    @property
    def will_send(self) -> bool:
        """Real delivery requires credentials, and either real mode or an override."""
        if not self.settings.email_configured:
            return False
        return not self.settings.effective_mock or self.settings.acs_force_send

    def send(self, to: str, subject: str, text: str, html: str = "") -> None:
        if not self.will_send:
            # Local dev and tests: never touch the network. The code is still
            # readable via the dev router, so the flow can be exercised end to end.
            log.info("email (not sent) to=%s subject=%s\n%s", to, subject, text)
            return
        self._send_acs(to, subject, text, html)  # pragma: no cover - real path

    def _send_acs(self, to, subject, text, html) -> None:  # pragma: no cover - real path
        import json

        creds = parse_connection_string(self.settings.acs_connection_string)
        path_and_query = f"/emails:send?api-version={API_VERSION}"
        body = json.dumps(build_payload(self.settings.acs_sender, to, subject, text, html)).encode()
        headers = build_headers(creds, path_and_query=path_and_query, body=body)

        url = f"{creds.endpoint.rstrip('/')}{path_and_query}"
        try:
            resp = httpx.post(url, content=body, headers=headers, timeout=15.0)
        except httpx.HTTPError as exc:
            raise EmailError(f"could not reach ACS: {exc}") from exc

        # 202 Accepted is success; ACS then delivers asynchronously. Deliberately
        # not polling the operation — a queued message is good enough here.
        if resp.status_code != 202:
            raise EmailError(f"ACS rejected the message ({resp.status_code}): {resp.text[:300]}")


_service: EmailService | None = None


def get_email_service() -> EmailService:
    global _service
    if _service is None:
        _service = EmailService()
    return _service


def reset_email_service() -> None:
    """Test helper."""
    global _service
    _service = None
