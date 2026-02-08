"""Integration tests for backwards-compatible stdout mode (no --output-dir)."""

import os
import shutil
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import importlib.util
spec = importlib.util.spec_from_file_location(
    "eml_script",
    os.path.join(os.path.dirname(__file__), '..', 'eml-view-and-extract-attachments.py')
)
eml_script = importlib.util.module_from_spec(spec)
spec.loader.exec_module(eml_script)

print_email = eml_script.print_email

FIXTURES = os.path.join(os.path.dirname(__file__), 'fixtures')


class TestPlainTextStdout:
    def test_metadata_and_body_printed(self, tmp_path, capsys):
        eml_src = os.path.join(FIXTURES, 'plain-text.eml')
        working_eml = tmp_path / "message.eml"
        shutil.copy2(eml_src, working_eml)

        print_email(str(working_eml))
        captured = capsys.readouterr()

        assert "From: Jonathan Smith <jsmith@example.com>" in captured.out
        assert "To: Craig Jennings <craig@example.com>" in captured.out
        assert "Subject: Re: Fw: 4319 Danneel Street" in captured.out
        assert "Date:" in captured.out
        assert "Sent:" in captured.out
        assert "Received:" in captured.out
        assert "4319 Danneel Street" in captured.out


class TestHtmlFallbackStdout:
    def test_html_converted_on_stdout(self, tmp_path, capsys):
        eml_src = os.path.join(FIXTURES, 'html-only.eml')
        working_eml = tmp_path / "message.eml"
        shutil.copy2(eml_src, working_eml)

        print_email(str(working_eml))
        captured = capsys.readouterr()

        # Should see converted text, not raw HTML
        assert "HTML" in captured.out
        assert "<p>" not in captured.out


class TestAttachmentsStdout:
    def test_attachment_extracted_alongside_eml(self, tmp_path, capsys):
        eml_src = os.path.join(FIXTURES, 'with-attachment.eml')
        working_eml = tmp_path / "message.eml"
        shutil.copy2(eml_src, working_eml)

        print_email(str(working_eml))
        captured = capsys.readouterr()

        assert "Extracted attachment:" in captured.out
        assert "Ltr Carrollton.pdf" in captured.out

        # File should exist alongside the EML
        extracted = tmp_path / "Ltr Carrollton.pdf"
        assert extracted.exists()
