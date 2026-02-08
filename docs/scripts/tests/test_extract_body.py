"""Tests for extract_body()."""

import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from conftest import make_plain_message, make_html_message, make_message_with_attachment
from email.message import EmailMessage
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.mime.application import MIMEApplication

import importlib.util
spec = importlib.util.spec_from_file_location(
    "eml_script",
    os.path.join(os.path.dirname(__file__), '..', 'eml-view-and-extract-attachments.py')
)
eml_script = importlib.util.module_from_spec(spec)
spec.loader.exec_module(eml_script)

extract_body = eml_script.extract_body


class TestPlainText:
    def test_returns_plain_text(self):
        msg = make_plain_message(body="Hello, this is plain text.")
        result = extract_body(msg)
        assert "Hello, this is plain text." in result


class TestHtmlOnly:
    def test_returns_converted_html(self):
        msg = make_html_message(html_body="<p>Hello <strong>world</strong></p>")
        result = extract_body(msg)
        assert "Hello" in result
        assert "world" in result
        # Should not contain raw HTML tags
        assert "<p>" not in result
        assert "<strong>" not in result


class TestBothPlainAndHtml:
    def test_prefers_plain_text(self):
        msg = MIMEMultipart('alternative')
        msg['From'] = 'test@example.com'
        msg['To'] = 'dest@example.com'
        msg['Subject'] = 'Test'
        msg['Date'] = 'Thu, 05 Feb 2026 11:36:00 -0600'
        msg.attach(MIMEText("Plain text version", 'plain'))
        msg.attach(MIMEText("<p>HTML version</p>", 'html'))
        result = extract_body(msg)
        assert "Plain text version" in result
        assert "HTML version" not in result


class TestEmptyBody:
    def test_returns_empty_string(self):
        # Multipart with only attachments, no text parts
        msg = MIMEMultipart()
        msg['From'] = 'test@example.com'
        att = MIMEApplication(b"binary data", Name="file.bin")
        att['Content-Disposition'] = 'attachment; filename="file.bin"'
        msg.attach(att)
        result = extract_body(msg)
        assert result == ""


class TestNonUtf8Encoding:
    def test_decodes_with_errors_ignore(self):
        msg = EmailMessage()
        msg['From'] = 'test@example.com'
        # Set raw bytes that include invalid UTF-8
        msg.set_content("Valid text with special: café")
        result = extract_body(msg)
        assert "Valid text" in result


class TestHtmlWithStructure:
    def test_preserves_list_structure(self):
        html = "<ul><li>Item one</li><li>Item two</li></ul>"
        msg = make_html_message(html_body=html)
        result = extract_body(msg)
        assert "Item one" in result
        assert "Item two" in result


class TestNoTextParts:
    def test_returns_empty_string(self):
        msg = MIMEMultipart()
        msg['From'] = 'test@example.com'
        att = MIMEApplication(b"data", Name="image.png")
        att['Content-Disposition'] = 'attachment; filename="image.png"'
        msg.attach(att)
        result = extract_body(msg)
        assert result == ""
