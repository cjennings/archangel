"""Tests for parse_received_headers()."""

import email
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from conftest import make_plain_message, add_received_headers
from email.message import EmailMessage

# Import the function under test
import importlib.util
spec = importlib.util.spec_from_file_location(
    "eml_script",
    os.path.join(os.path.dirname(__file__), '..', 'eml-view-and-extract-attachments.py')
)
eml_script = importlib.util.module_from_spec(spec)
spec.loader.exec_module(eml_script)

parse_received_headers = eml_script.parse_received_headers


class TestSingleHeader:
    def test_header_with_from_and_by(self):
        msg = EmailMessage()
        msg['Received'] = (
            'from mail-sender.example.com by mx.receiver.example.com '
            'with ESMTP; Thu, 05 Feb 2026 11:36:05 -0600'
        )
        result = parse_received_headers(msg)
        assert result['sent_server'] == 'mail-sender.example.com'
        assert result['received_server'] == 'mx.receiver.example.com'
        assert result['sent_time'] == 'Thu, 05 Feb 2026 11:36:05 -0600'
        assert result['received_time'] == 'Thu, 05 Feb 2026 11:36:05 -0600'


class TestMultipleHeaders:
    def test_uses_first_with_both_from_and_by(self):
        msg = EmailMessage()
        # Most recent first (by only)
        msg['Received'] = 'by internal.example.com with SMTP; Thu, 05 Feb 2026 11:36:10 -0600'
        # Next: has both from and by — this should be selected
        msg['Received'] = (
            'from mail-sender.example.com by mx.receiver.example.com '
            'with ESMTP; Thu, 05 Feb 2026 11:36:05 -0600'
        )
        # Oldest
        msg['Received'] = (
            'from originator.example.com by relay.example.com '
            'with SMTP; Thu, 05 Feb 2026 11:35:58 -0600'
        )
        result = parse_received_headers(msg)
        assert result['sent_server'] == 'mail-sender.example.com'
        assert result['received_server'] == 'mx.receiver.example.com'


class TestNoReceivedHeaders:
    def test_all_values_none(self):
        msg = EmailMessage()
        result = parse_received_headers(msg)
        assert result['sent_time'] is None
        assert result['sent_server'] is None
        assert result['received_time'] is None
        assert result['received_server'] is None


class TestByButNoFrom:
    def test_falls_back_to_first_header(self):
        msg = EmailMessage()
        msg['Received'] = 'by internal.example.com with SMTP; Thu, 05 Feb 2026 11:36:10 -0600'
        result = parse_received_headers(msg)
        assert result['received_server'] == 'internal.example.com'
        assert result['received_time'] == 'Thu, 05 Feb 2026 11:36:10 -0600'
        # No from in any header, so sent_server stays None
        assert result['sent_server'] is None


class TestMultilineFoldedHeader:
    def test_normalizes_whitespace(self):
        # Use email.message_from_string to parse raw folded headers
        # (EmailMessage policy rejects embedded CRLF in set values)
        raw = (
            "From: test@example.com\r\n"
            "Received: from mail-sender.example.com\r\n"
            "        by mx.receiver.example.com\r\n"
            "        with ESMTP; Thu, 05 Feb 2026 11:36:05 -0600\r\n"
            "\r\n"
            "body\r\n"
        )
        msg = email.message_from_string(raw)
        result = parse_received_headers(msg)
        assert result['sent_server'] == 'mail-sender.example.com'
        assert result['received_server'] == 'mx.receiver.example.com'


class TestMalformedTimestamp:
    def test_no_semicolon(self):
        msg = EmailMessage()
        msg['Received'] = 'from sender.example.com by receiver.example.com with SMTP'
        result = parse_received_headers(msg)
        assert result['sent_server'] == 'sender.example.com'
        assert result['received_server'] == 'receiver.example.com'
        assert result['sent_time'] is None
        assert result['received_time'] is None
