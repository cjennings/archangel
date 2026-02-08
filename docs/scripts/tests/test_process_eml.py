"""Integration tests for process_eml() — full pipeline with --output-dir."""

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

process_eml = eml_script.process_eml

import pytest


FIXTURES = os.path.join(os.path.dirname(__file__), 'fixtures')


class TestPlainTextPipeline:
    def test_creates_eml_and_txt(self, tmp_path):
        eml_src = os.path.join(FIXTURES, 'plain-text.eml')
        # Copy fixture to tmp_path so temp dir can be created as sibling
        working_eml = tmp_path / "inbox" / "message.eml"
        working_eml.parent.mkdir()
        shutil.copy2(eml_src, working_eml)

        output_dir = tmp_path / "output"
        result = process_eml(str(working_eml), str(output_dir))

        # Should have exactly 2 files: .eml and .txt
        assert len(result['files']) == 2
        eml_file = result['files'][0]
        txt_file = result['files'][1]

        assert eml_file['type'] == 'eml'
        assert txt_file['type'] == 'txt'
        assert eml_file['name'].endswith('.eml')
        assert txt_file['name'].endswith('.txt')

        # Files exist in output dir
        assert os.path.isfile(eml_file['path'])
        assert os.path.isfile(txt_file['path'])

        # Filenames contain expected components
        assert 'Jonathan' in eml_file['name']
        assert 'EMAIL' in eml_file['name']
        assert '2026-02-05' in eml_file['name']

        # Temp dir cleaned up (no extract-* dirs in inbox)
        inbox_contents = os.listdir(str(tmp_path / "inbox"))
        assert not any(d.startswith('extract-') for d in inbox_contents)


class TestHtmlFallbackPipeline:
    def test_txt_contains_converted_html(self, tmp_path):
        eml_src = os.path.join(FIXTURES, 'html-only.eml')
        working_eml = tmp_path / "inbox" / "message.eml"
        working_eml.parent.mkdir()
        shutil.copy2(eml_src, working_eml)

        output_dir = tmp_path / "output"
        result = process_eml(str(working_eml), str(output_dir))

        txt_file = result['files'][1]
        with open(txt_file['path'], 'r') as f:
            content = f.read()

        # Should be converted, not raw HTML
        assert '<p>' not in content
        assert '<strong>' not in content
        assert 'HTML' in content


class TestAttachmentPipeline:
    def test_eml_txt_and_attachment_created(self, tmp_path):
        eml_src = os.path.join(FIXTURES, 'with-attachment.eml')
        working_eml = tmp_path / "inbox" / "message.eml"
        working_eml.parent.mkdir()
        shutil.copy2(eml_src, working_eml)

        output_dir = tmp_path / "output"
        result = process_eml(str(working_eml), str(output_dir))

        assert len(result['files']) == 3
        types = [f['type'] for f in result['files']]
        assert types == ['eml', 'txt', 'attach']

        # Attachment is auto-renamed
        attach_file = result['files'][2]
        assert 'ATTACH' in attach_file['name']
        assert attach_file['name'].endswith('.pdf')
        assert os.path.isfile(attach_file['path'])


class TestCollisionDetection:
    def test_raises_on_existing_file(self, tmp_path):
        eml_src = os.path.join(FIXTURES, 'plain-text.eml')
        working_eml = tmp_path / "inbox" / "message.eml"
        working_eml.parent.mkdir()
        shutil.copy2(eml_src, working_eml)

        output_dir = tmp_path / "output"
        # Run once to create files
        result = process_eml(str(working_eml), str(output_dir))

        # Run again — should raise FileExistsError
        with pytest.raises(FileExistsError, match="Collision"):
            process_eml(str(working_eml), str(output_dir))


class TestMissingOutputDir:
    def test_creates_directory(self, tmp_path):
        eml_src = os.path.join(FIXTURES, 'plain-text.eml')
        working_eml = tmp_path / "inbox" / "message.eml"
        working_eml.parent.mkdir()
        shutil.copy2(eml_src, working_eml)

        output_dir = tmp_path / "new" / "nested" / "output"
        assert not output_dir.exists()

        result = process_eml(str(working_eml), str(output_dir))
        assert output_dir.exists()
        assert len(result['files']) == 2
