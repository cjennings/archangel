"""Tests for generate_basename(), generate_email_filename(), generate_attachment_filename()."""

import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

import importlib.util
spec = importlib.util.spec_from_file_location(
    "eml_script",
    os.path.join(os.path.dirname(__file__), '..', 'eml-view-and-extract-attachments.py')
)
eml_script = importlib.util.module_from_spec(spec)
spec.loader.exec_module(eml_script)

generate_basename = eml_script.generate_basename
generate_email_filename = eml_script.generate_email_filename
generate_attachment_filename = eml_script.generate_attachment_filename


# --- generate_basename ---

class TestGenerateBasename:
    def test_standard_from_and_date(self):
        metadata = {
            'from': 'Jonathan Smith <jsmith@example.com>',
            'date': 'Wed, 05 Feb 2026 11:36:00 -0600',
        }
        assert generate_basename(metadata) == "2026-02-05-1136-Jonathan"

    def test_from_with_display_name_first_token(self):
        metadata = {
            'from': 'C Ciarm <cciarm@example.com>',
            'date': 'Wed, 05 Feb 2026 11:36:00 -0600',
        }
        result = generate_basename(metadata)
        assert result == "2026-02-05-1136-C"

    def test_from_without_display_name(self):
        metadata = {
            'from': 'jsmith@example.com',
            'date': 'Wed, 05 Feb 2026 11:36:00 -0600',
        }
        result = generate_basename(metadata)
        assert result == "2026-02-05-1136-jsmith"

    def test_missing_date(self):
        metadata = {
            'from': 'Jonathan Smith <jsmith@example.com>',
            'date': None,
        }
        result = generate_basename(metadata)
        assert result == "unknown-Jonathan"

    def test_missing_from(self):
        metadata = {
            'from': None,
            'date': 'Wed, 05 Feb 2026 11:36:00 -0600',
        }
        result = generate_basename(metadata)
        assert result == "2026-02-05-1136-unknown"

    def test_both_missing(self):
        metadata = {'from': None, 'date': None}
        result = generate_basename(metadata)
        assert result == "unknown-unknown"

    def test_unparseable_date(self):
        metadata = {
            'from': 'Jonathan <j@example.com>',
            'date': 'not a real date',
        }
        result = generate_basename(metadata)
        assert result == "unknown-Jonathan"

    def test_none_date_no_crash(self):
        metadata = {'from': 'Test <t@e.com>', 'date': None}
        # Should not raise
        result = generate_basename(metadata)
        assert "unknown" in result


# --- generate_email_filename ---

class TestGenerateEmailFilename:
    def test_standard_subject(self):
        result = generate_email_filename(
            "2026-02-05-1136-Jonathan",
            "Re: Fw: 4319 Danneel Street"
        )
        assert result == "2026-02-05-1136-Jonathan-EMAIL-Re-Fw-4319-Danneel-Street"

    def test_subject_with_special_chars(self):
        result = generate_email_filename(
            "2026-02-05-1136-Jonathan",
            "Update: Meeting (draft) & notes!"
        )
        # Colons, parens, ampersands, exclamation stripped
        assert "EMAIL" in result
        assert ":" not in result
        assert "(" not in result
        assert ")" not in result
        assert "&" not in result
        assert "!" not in result

    def test_none_subject(self):
        result = generate_email_filename("2026-02-05-1136-Jonathan", None)
        assert result == "2026-02-05-1136-Jonathan-EMAIL-no-subject"

    def test_empty_subject(self):
        result = generate_email_filename("2026-02-05-1136-Jonathan", "")
        assert result == "2026-02-05-1136-Jonathan-EMAIL-no-subject"

    def test_very_long_subject(self):
        long_subject = "A" * 100 + " " + "B" * 100
        result = generate_email_filename("2026-02-05-1136-Jonathan", long_subject)
        # The cleaned subject part should be truncated
        # basename (27) + "-EMAIL-" (7) + subject
        # Subject itself is limited to 80 chars by _clean_for_filename
        subject_part = result.split("-EMAIL-")[1]
        assert len(subject_part) <= 80


# --- generate_attachment_filename ---

class TestGenerateAttachmentFilename:
    def test_standard_attachment(self):
        result = generate_attachment_filename(
            "2026-02-05-1136-Jonathan",
            "Ltr Carrollton.pdf"
        )
        assert result == "2026-02-05-1136-Jonathan-ATTACH-Ltr-Carrollton.pdf"

    def test_filename_with_spaces_and_parens(self):
        result = generate_attachment_filename(
            "2026-02-05-1136-Jonathan",
            "Document (final copy).pdf"
        )
        assert " " not in result
        assert "(" not in result
        assert ")" not in result
        assert result.endswith(".pdf")

    def test_preserves_extension(self):
        result = generate_attachment_filename(
            "2026-02-05-1136-Jonathan",
            "photo.jpg"
        )
        assert result.endswith(".jpg")

    def test_none_filename(self):
        result = generate_attachment_filename("2026-02-05-1136-Jonathan", None)
        assert result == "2026-02-05-1136-Jonathan-ATTACH-unnamed"

    def test_empty_filename(self):
        result = generate_attachment_filename("2026-02-05-1136-Jonathan", "")
        assert result == "2026-02-05-1136-Jonathan-ATTACH-unnamed"
