"""One-time codes for email verification.

Codes are stored only as a SHA-256 hash — the plaintext exists in the email and
nowhere else, so a leaked datastore can't be replayed. Every guard (expiry,
attempt cap, resend cooldown) is enforced server-side; the app is not trusted to
apply any of them.
"""

from __future__ import annotations

import hashlib
import logging
import secrets
from datetime import datetime, timedelta, timezone

from app.core.config import Settings, get_settings
from app.models.user import OtpChallenge, normalize_email
from app.services.email import get_email_service

log = logging.getLogger(__name__)


class OtpError(RuntimeError):
    """Something the caller did wrong; the message is safe to show a user."""


# Mock mode only: the plaintext of the most recent code per address, so local dev
# and the emulator can complete a real sign-up without an inbox. Never populated
# when `effective_mock` is false, and the dev router that reads it is only
# mounted in mock mode either.
_MOCK_LAST_CODES: dict[str, str] = {}


def peek_mock_code(email: str) -> str | None:
    return _MOCK_LAST_CODES.get(normalize_email(email))


def clear_mock_codes() -> None:
    _MOCK_LAST_CODES.clear()


def hash_code(code: str) -> str:
    return hashlib.sha256(code.encode("utf-8")).hexdigest()


def generate_code(length: int = 6) -> str:
    """A uniformly random numeric code, leading zeros preserved."""
    return "".join(secrets.choice("0123456789") for _ in range(length))


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _body(code: str, ttl_minutes: int) -> tuple[str, str, str]:
    subject = f"{code} is your VoiceIQ code"
    text = (
        f"Your VoiceIQ verification code is {code}.\n\n"
        f"It expires in {ttl_minutes} minutes. If you didn't ask for this, you can "
        f"ignore this email — nothing will change.\n"
    )
    html = (
        f"<p>Your VoiceIQ verification code is</p>"
        f'<p style="font-size:28px;font-weight:600;letter-spacing:4px">{code}</p>'
        f"<p>It expires in {ttl_minutes} minutes. If you didn't ask for this, you can "
        f"ignore this email — nothing will change.</p>"
    )
    return subject, text, html


class OtpService:
    def __init__(self, settings: Settings | None = None) -> None:
        self.settings = settings or get_settings()

    # -- issuing -----------------------------------------------------------
    def request_code(self, repo, email: str, requester_uid: str) -> str:
        """Create and email a code. Returns it, for mock-mode inspection only."""
        email = normalize_email(email)
        existing = repo.get_otp(email)
        if existing is not None:
            elapsed = (_now() - existing.sent_at).total_seconds()
            remaining = self.settings.otp_resend_cooldown_seconds - elapsed
            if remaining > 0:
                raise OtpError(f"Please wait {int(remaining) + 1}s before asking for another code.")

        code = generate_code(self.settings.otp_code_length)
        challenge = OtpChallenge(
            email=email,
            code_sha256=hash_code(code),
            expires_at=_now() + timedelta(seconds=self.settings.otp_ttl_seconds),
            sent_at=_now(),
            attempts=0,
            requester_uid=requester_uid,
        )
        repo.save_otp(challenge)

        if self.settings.effective_mock:
            _MOCK_LAST_CODES[email] = code

        subject, text, html = _body(code, self.settings.otp_ttl_seconds // 60)
        get_email_service().send(email, subject, text, html)
        return code

    # -- checking ----------------------------------------------------------
    def verify_code(self, repo, email: str, code: str) -> OtpChallenge:
        """Consume a code. Raises [OtpError] unless it is correct and live."""
        email = normalize_email(email)
        challenge = repo.get_otp(email)
        if challenge is None:
            raise OtpError("No code is pending for that address. Ask for a new one.")

        if challenge.is_expired():
            repo.delete_otp(email)
            raise OtpError("That code has expired. Ask for a new one.")

        if challenge.attempts >= self.settings.otp_max_attempts:
            repo.delete_otp(email)
            raise OtpError("Too many attempts. Ask for a new code.")

        # compare_digest so a wrong code can't be found by timing the response.
        if not secrets.compare_digest(challenge.code_sha256, hash_code(code.strip())):
            challenge.attempts += 1
            repo.save_otp(challenge)
            left = self.settings.otp_max_attempts - challenge.attempts
            if left <= 0:
                repo.delete_otp(email)
                raise OtpError("Too many attempts. Ask for a new code.")
            raise OtpError(f"That code isn't right. {left} attempt{'s' if left != 1 else ''} left.")

        repo.delete_otp(email)  # single use
        return challenge


_service: OtpService | None = None


def get_otp_service() -> OtpService:
    global _service
    if _service is None:
        _service = OtpService()
    return _service


def reset_otp_service() -> None:
    """Test helper."""
    global _service
    _service = None
