"""Tests for save_attachments()."""

import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from conftest import make_plain_message, make_message_with_attachment
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

save_attachments = eml_script.save_attachments


class TestSingleAttachment:
    def test_file_written_and_returned(self, tmp_path):
        msg = make_message_with_attachment(
            attachment_filename="report.pdf",
            attachment_content=b"pdf bytes here"
        )
        result = save_attachments(msg, str(tmp_path), "2026-02-05-1136-Jonathan")

        assert len(result) == 1
        assert result[0]['original_name'] == "report.pdf"
        assert "ATTACH" in result[0]['renamed_name']
        assert result[0]['renamed_name'].endswith(".pdf")

        # File actually exists and has correct content
        written_path = result[0]['path']
        assert os.path.isfile(written_path)
        with open(written_path, 'rb') as f:
            assert f.read() == b"pdf bytes here"


class TestMultipleAttachments:
    def test_all_written_and_returned(self, tmp_path):
        msg = MIMEMultipart()
        msg['From'] = 'test@example.com'
        msg['Date'] = 'Thu, 05 Feb 2026 11:36:00 -0600'
        msg.attach(MIMEText("body", 'plain'))

        for name, content in [("doc1.pdf", b"pdf1"), ("image.png", b"png1")]:
            att = MIMEApplication(content, Name=name)
            att['Content-Disposition'] = f'attachment; filename="{name}"'
            msg.attach(att)

        result = save_attachments(msg, str(tmp_path), "2026-02-05-1136-Jonathan")

        assert len(result) == 2
        for r in result:
            assert os.path.isfile(r['path'])


class TestNoAttachments:
    def test_empty_list(self, tmp_path):
        msg = make_plain_message()
        result = save_attachments(msg, str(tmp_path), "2026-02-05-1136-Jonathan")
        assert result == []


class TestFilenameWithSpaces:
    def test_cleaned_filename(self, tmp_path):
        msg = make_message_with_attachment(
            attachment_filename="My Document (1).pdf",
            attachment_content=b"data"
        )
        result = save_attachments(msg, str(tmp_path), "2026-02-05-1136-Jonathan")

        assert len(result) == 1
        assert " " not in result[0]['renamed_name']
        assert os.path.isfile(result[0]['path'])


class TestNoContentDisposition:
    def test_skipped(self, tmp_path):
        msg = MIMEMultipart()
        msg['From'] = 'test@example.com'
        msg.attach(MIMEText("body", 'plain'))

        # Add a part without Content-Disposition
        part = MIMEApplication(b"data", Name="file.bin")
        # Explicitly remove Content-Disposition if present
        if 'Content-Disposition' in part:
            del part['Content-Disposition']
        msg.attach(part)

        result = save_attachments(msg, str(tmp_path), "2026-02-05-1136-Jonathan")
        assert result == []
