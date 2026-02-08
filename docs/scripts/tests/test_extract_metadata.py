"""Tests for extract_metadata()."""

import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from conftest import make_plain_message, add_received_headers
from email.message import EmailMessage

import importlib.util
spec = importlib.util.spec_from_file_location(
    "eml_script",
    os.path.join(os.path.dirname(__file__), '..', 'eml-view-and-extract-attachments.py')
)
eml_script = importlib.util.module_from_spec(spec)
spec.loader.exec_module(eml_script)

extract_metadata = eml_script.extract_metadata


class TestAllHeadersPresent:
    def test_complete_dict(self):
        msg = make_plain_message(
            from_="Jonathan Smith <jsmith@example.com>",
            to="Craig <craig@example.com>",
            subject="Test Subject",
            date="Thu, 05 Feb 2026 11:36:00 -0600"
        )
        result = extract_metadata(msg)
        assert result['from'] == "Jonathan Smith <jsmith@example.com>"
        assert result['to'] == "Craig <craig@example.com>"
        assert result['subject'] == "Test Subject"
        assert result['date'] == "Thu, 05 Feb 2026 11:36:00 -0600"
        assert 'timing' in result


class TestMissingFrom:
    def test_from_is_none(self):
        msg = EmailMessage()
        msg['To'] = 'craig@example.com'
        msg['Subject'] = 'Test'
        msg['Date'] = 'Thu, 05 Feb 2026 11:36:00 -0600'
        msg.set_content("body")
        result = extract_metadata(msg)
        assert result['from'] is None


class TestMissingDate:
    def test_date_is_none(self):
        msg = EmailMessage()
        msg['From'] = 'test@example.com'
        msg['To'] = 'craig@example.com'
        msg['Subject'] = 'Test'
        msg.set_content("body")
        result = extract_metadata(msg)
        assert result['date'] is None


class TestLongSubject:
    def test_full_subject_returned(self):
        long_subject = "Re: Fw: This is a very long subject line that spans many words and might be folded"
        msg = make_plain_message(subject=long_subject)
        result = extract_metadata(msg)
        assert result['subject'] == long_subject
