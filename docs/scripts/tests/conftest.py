"""Shared fixtures for EML extraction tests."""

import os
from email.message import EmailMessage
from email.mime.application import MIMEApplication
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText

import pytest


@pytest.fixture
def fixtures_dir():
    """Return path to the fixtures/ directory."""
    return os.path.join(os.path.dirname(__file__), 'fixtures')


def make_plain_message(body="Test body", from_="Jonathan Smith <jsmith@example.com>",
                       to="Craig <craig@example.com>",
                       subject="Test Subject",
                       date="Wed, 05 Feb 2026 11:36:00 -0600"):
    """Create an EmailMessage with text/plain body."""
    msg = EmailMessage()
    msg['From'] = from_
    msg['To'] = to
    msg['Subject'] = subject
    msg['Date'] = date
    msg.set_content(body)
    return msg


def make_html_message(html_body="<p>Test body</p>",
                      from_="Jonathan Smith <jsmith@example.com>",
                      to="Craig <craig@example.com>",
                      subject="Test Subject",
                      date="Wed, 05 Feb 2026 11:36:00 -0600"):
    """Create an EmailMessage with text/html body only."""
    msg = EmailMessage()
    msg['From'] = from_
    msg['To'] = to
    msg['Subject'] = subject
    msg['Date'] = date
    msg.set_content(html_body, subtype='html')
    return msg


def make_message_with_attachment(body="Test body",
                                from_="Jonathan Smith <jsmith@example.com>",
                                to="Craig <craig@example.com>",
                                subject="Test Subject",
                                date="Wed, 05 Feb 2026 11:36:00 -0600",
                                attachment_filename="document.pdf",
                                attachment_content=b"fake pdf content"):
    """Create a multipart message with a text body and one attachment."""
    msg = MIMEMultipart()
    msg['From'] = from_
    msg['To'] = to
    msg['Subject'] = subject
    msg['Date'] = date

    msg.attach(MIMEText(body, 'plain'))

    att = MIMEApplication(attachment_content, Name=attachment_filename)
    att['Content-Disposition'] = f'attachment; filename="{attachment_filename}"'
    msg.attach(att)

    return msg


def add_received_headers(msg, headers):
    """Add Received headers to an existing message.

    headers: list of header strings, added in order (first = most recent).
    """
    for header in headers:
        msg['Received'] = header
    return msg
