"""ACS request signing.

Signing is the part that either works or silently 401s in production, so it's
pinned to fixed vectors rather than trusted to review.
"""

from __future__ import annotations

import base64
import hashlib
import hmac

import pytest

from app.core.config import Settings
from app.services.email import (
    EmailError,
    EmailService,
    build_headers,
    build_payload,
    build_signature,
    content_hash,
    parse_connection_string,
)

KEY = base64.b64encode(b"super-secret-key").decode()
CONN = f"endpoint=https://voiceiq.communication.azure.com/;accesskey={KEY}"


def test_parses_a_connection_string():
    creds = parse_connection_string(CONN)
    assert creds.endpoint == "https://voiceiq.communication.azure.com/"
    assert creds.access_key == b"super-secret-key"
    assert creds.host == "voiceiq.communication.azure.com"


def test_parsing_is_order_insensitive_and_trims_whitespace():
    creds = parse_connection_string(f"  accesskey={KEY} ; endpoint=https://x.azure.com  ")
    assert creds.host == "x.azure.com"
    assert creds.access_key == b"super-secret-key"


def test_missing_endpoint_is_a_clear_config_error():
    with pytest.raises(EmailError, match="endpoint"):
        parse_connection_string(f"accesskey={KEY}")


def test_base64_padding_in_the_key_is_not_split_on():
    # Real ACS keys are base64 and end with '=' padding; a naive split("=") loses it.
    key = base64.b64encode(b"x" * 32).decode()
    assert key.endswith("=")
    creds = parse_connection_string(f"endpoint=https://x.azure.com/;accesskey={key}")
    assert creds.access_key == b"x" * 32


def test_content_hash_matches_sha256_base64():
    body = b'{"a":1}'
    expected = base64.b64encode(hashlib.sha256(body).digest()).decode()
    assert content_hash(body) == expected


def test_signature_matches_the_documented_string_to_sign():
    creds = parse_connection_string(CONN)
    date = "Mon, 16 Aug 2026 12:00:00 GMT"
    body_hash = content_hash(b"{}")
    path = "/emails:send?api-version=2023-03-31"

    expected_sts = f"POST\n{path}\n{date};{creds.host};{body_hash}"
    expected = base64.b64encode(
        hmac.new(b"super-secret-key", expected_sts.encode(), hashlib.sha256).digest()
    ).decode()

    assert (
        build_signature(
            creds,
            method="POST",
            path_and_query=path,
            date_header=date,
            body_hash=body_hash,
        )
        == expected
    )


def test_signature_changes_with_the_body():
    creds = parse_connection_string(CONN)
    date = "Mon, 16 Aug 2026 12:00:00 GMT"
    path = "/emails:send?api-version=2023-03-31"
    args = {"method": "POST", "path_and_query": path, "date_header": date}
    one = build_signature(creds, body_hash=content_hash(b'{"to":"a@b.com"}'), **args)
    two = build_signature(creds, body_hash=content_hash(b'{"to":"c@d.com"}'), **args)
    assert one != two, "the body must be covered by the signature"


def test_headers_carry_everything_acs_signs_over():
    creds = parse_connection_string(CONN)
    headers = build_headers(creds, path_and_query="/emails:send", body=b"{}")

    assert headers["x-ms-content-sha256"] == content_hash(b"{}")
    assert headers["x-ms-date"].endswith("GMT"), "ACS requires RFC 1123 in GMT"
    assert headers["Authorization"].startswith(
        "HMAC-SHA256 SignedHeaders=x-ms-date;host;x-ms-content-sha256&Signature="
    )


def test_payload_shape_matches_the_acs_api():
    payload = build_payload("no-reply@x.com", "user@y.com", "Subject", "text", "<p>html</p>")
    assert payload == {
        "senderAddress": "no-reply@x.com",
        "recipients": {"to": [{"address": "user@y.com"}]},
        "content": {"subject": "Subject", "plainText": "text", "html": "<p>html</p>"},
    }


def test_html_is_omitted_when_empty():
    assert "html" not in build_payload("a@b.com", "c@d.com", "s", "t")["content"]


def test_mock_mode_never_sends(caplog):
    service = EmailService(Settings(mock=True, acs_connection_string=CONN, acs_sender="a@b.com"))
    assert service.will_send is False
    with caplog.at_level("INFO"):
        service.send("user@example.com", "Subject", "body")
    assert "not sent" in caplog.text


def test_real_mode_without_credentials_also_stays_offline(caplog):
    # Misconfiguration must not raise into the signup flow — better a code that
    # never arrives than a 500 on every request.
    service = EmailService(Settings(mock=False, gcp_project="p", acs_connection_string=""))
    assert service.will_send is False
    with caplog.at_level("INFO"):
        service.send("user@example.com", "Subject", "body")
    assert "not sent" in caplog.text


def test_the_override_allows_a_real_send_from_mock_mode():
    """How delivery gets proven locally without switching everything to real GCP."""
    service = EmailService(
        Settings(mock=True, acs_connection_string=CONN, acs_sender="a@b.com", acs_force_send=True)
    )
    assert service.will_send is True


def test_the_override_alone_is_not_enough_without_credentials():
    service = EmailService(Settings(mock=True, acs_force_send=True))
    assert service.will_send is False


def test_the_test_suite_itself_can_never_send():
    """Guards the conftest blanking — a populated .env must not reach the network."""
    from app.core.config import get_settings

    assert EmailService(get_settings()).will_send is False
