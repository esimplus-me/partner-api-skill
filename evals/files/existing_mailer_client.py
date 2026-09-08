"""Existing outbound-API client in the host project — the precedent to mirror.

app/integrations/mailer/client.py
"""
from __future__ import annotations

import httpx

from app.config import Settings          # pydantic-settings singleton
from app.errors import IntegrationError  # project-wide error type
from app.observability import logger


class MailerClient:
    """One client per integration, constructed with an injected httpx.Client."""

    def __init__(self, http: httpx.Client, settings: Settings) -> None:
        self._http = http
        self._base_url = settings.mailer_base_url
        self._token = settings.mailer_token.get_secret_value()

    def send(self, to: str, subject: str, body: str) -> str:
        response = self._http.post(
            f"{self._base_url}/messages",
            json={"to": to, "subject": subject, "body": body},
            headers={"Authorization": f"Bearer {self._token}"},
            timeout=10.0,
        )
        if response.is_error:
            logger.warning("mailer.send_failed", status=response.status_code)
            raise IntegrationError.from_response("mailer", response.status_code,
                                                 response.json().get("detail"))
        return response.json()["id"]
