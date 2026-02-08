#!/usr/bin/env python3
"""Extract email content and attachments from EML files.

Without --output-dir: parse and print to stdout (backwards compatible).
With --output-dir: full pipeline — extract, auto-rename, refile, clean up.
"""

import argparse
import email
import email.utils
import os
import re
import shutil
import sys
import tempfile


# ---------------------------------------------------------------------------
# Parsing functions (no I/O beyond reading the input file)
# ---------------------------------------------------------------------------

def parse_received_headers(msg):
    """Parse Received headers to extract sent/received times and servers."""
    received_headers = msg.get_all('Received', [])

    sent_server = None
    sent_time = None
    received_server = None
    received_time = None

    for header in received_headers:
        header = ' '.join(header.split())

        time_match = re.search(r';\s*(.+)$', header)
        timestamp = time_match.group(1).strip() if time_match else None

        from_match = re.search(r'from\s+([\w.-]+)', header)
        by_match = re.search(r'by\s+([\w.-]+)', header)

        if from_match and by_match and received_server is None:
            received_time = timestamp
            received_server = by_match.group(1)
            sent_server = from_match.group(1)
            sent_time = timestamp

    if received_server is None and received_headers:
        header = ' '.join(received_headers[0].split())
        time_match = re.search(r';\s*(.+)$', header)
        received_time = time_match.group(1).strip() if time_match else None
        by_match = re.search(r'by\s+([\w.-]+)', header)
        received_server = by_match.group(1) if by_match else "unknown"

    return {
        'sent_time': sent_time,
        'sent_server': sent_server,
        'received_time': received_time,
        'received_server': received_server
    }


def extract_body(msg):
    """Walk MIME parts, prefer text/plain, fall back to html2text on text/html.

    Returns body text string.
    """
    plain_text = None
    html_text = None

    for part in msg.walk():
        content_type = part.get_content_type()
        if content_type == "text/plain" and plain_text is None:
            payload = part.get_payload(decode=True)
            if payload is not None:
                plain_text = payload.decode('utf-8', errors='ignore')
        elif content_type == "text/html" and html_text is None:
            payload = part.get_payload(decode=True)
            if payload is not None:
                html_text = payload.decode('utf-8', errors='ignore')

    if plain_text is not None:
        return plain_text

    if html_text is not None:
        try:
            import html2text
            h = html2text.HTML2Text()
            h.body_width = 0
            return h.handle(html_text)
        except ImportError:
            # Strip HTML tags as fallback if html2text not installed
            return re.sub(r'<[^>]+>', '', html_text)

    return ""


def extract_metadata(msg):
    """Extract email metadata from headers.

    Returns dict with from, to, subject, date, and timing info.
    """
    return {
        'from': msg.get('From'),
        'to': msg.get('To'),
        'subject': msg.get('Subject'),
        'date': msg.get('Date'),
        'timing': parse_received_headers(msg),
    }


def generate_basename(metadata):
    """Generate date-sender prefix from metadata.

    Returns e.g. "2026-02-05-1136-Jonathan".
    Falls back to "unknown" for missing/malformed Date or From.
    """
    # Parse date
    date_str = metadata.get('date')
    date_prefix = "unknown"
    if date_str:
        try:
            parsed = email.utils.parsedate_to_datetime(date_str)
            date_prefix = parsed.strftime('%Y-%m-%d-%H%M')
        except (ValueError, TypeError):
            pass

    # Parse sender first name
    from_str = metadata.get('from')
    sender = "unknown"
    if from_str:
        # Extract display name or email local part
        display_name, addr = email.utils.parseaddr(from_str)
        if display_name:
            sender = display_name.split()[0]
        elif addr:
            sender = addr.split('@')[0]

    return f"{date_prefix}-{sender}"


def _clean_for_filename(text, max_length=80):
    """Clean text for use in a filename.

    Replace spaces with hyphens, strip chars unsafe for filenames,
    collapse multiple hyphens.
    """
    text = text.strip()
    text = text.replace(' ', '-')
    # Keep alphanumeric, hyphens, dots, underscores
    text = re.sub(r'[^\w\-.]', '', text)
    # Collapse multiple hyphens
    text = re.sub(r'-{2,}', '-', text)
    # Strip leading/trailing hyphens
    text = text.strip('-')
    if len(text) > max_length:
        text = text[:max_length].rstrip('-')
    return text


def generate_email_filename(basename, subject):
    """Generate email filename from basename and subject.

    Returns e.g. "2026-02-05-1136-Jonathan-EMAIL-Re-Fw-4319-Danneel-Street"
    (without extension — caller adds .eml or .txt).
    """
    if subject:
        clean_subject = _clean_for_filename(subject)
    else:
        clean_subject = "no-subject"
    return f"{basename}-EMAIL-{clean_subject}"


def generate_attachment_filename(basename, original_filename):
    """Generate attachment filename from basename and original filename.

    Returns e.g. "2026-02-05-1136-Jonathan-ATTACH-Ltr-Carrollton.pdf".
    Preserves original extension.
    """
    if not original_filename:
        return f"{basename}-ATTACH-unnamed"

    name, ext = os.path.splitext(original_filename)
    clean_name = _clean_for_filename(name)
    return f"{basename}-ATTACH-{clean_name}{ext}"


# ---------------------------------------------------------------------------
# I/O functions (file operations)
# ---------------------------------------------------------------------------

def save_attachments(msg, output_dir, basename):
    """Write attachment files to output_dir with auto-renamed filenames.

    Returns list of dicts: {original_name, renamed_name, path}.
    """
    results = []
    for part in msg.walk():
        if part.get_content_maintype() == 'multipart':
            continue
        if part.get('Content-Disposition') is None:
            continue

        filename = part.get_filename()
        if filename:
            renamed = generate_attachment_filename(basename, filename)
            filepath = os.path.join(output_dir, renamed)
            with open(filepath, 'wb') as f:
                f.write(part.get_payload(decode=True))
            results.append({
                'original_name': filename,
                'renamed_name': renamed,
                'path': filepath,
            })

    return results


def save_text(text, filepath):
    """Write body text to a .txt file."""
    with open(filepath, 'w', encoding='utf-8') as f:
        f.write(text)


# ---------------------------------------------------------------------------
# Pipeline function
# ---------------------------------------------------------------------------

def process_eml(eml_path, output_dir):
    """Full extraction pipeline.

    1. Create temp extraction dir
    2. Copy EML into temp dir
    3. Parse email (metadata, body, attachments)
    4. Generate filenames from headers
    5. Save renamed .eml, .txt, and attachments to temp dir
    6. Check for collisions in output_dir
    7. Move all files to output_dir
    8. Clean up temp dir
    9. Return results dict
    """
    eml_path = os.path.abspath(eml_path)
    output_dir = os.path.abspath(output_dir)
    os.makedirs(output_dir, exist_ok=True)

    # Create temp dir as sibling of the EML file
    eml_dir = os.path.dirname(eml_path)
    temp_dir = tempfile.mkdtemp(prefix='extract-', dir=eml_dir)

    try:
        # Copy EML to temp dir
        temp_eml = os.path.join(temp_dir, os.path.basename(eml_path))
        shutil.copy2(eml_path, temp_eml)

        # Parse
        with open(eml_path, 'rb') as f:
            msg = email.message_from_binary_file(f)

        metadata = extract_metadata(msg)
        body = extract_body(msg)
        basename = generate_basename(metadata)
        email_stem = generate_email_filename(basename, metadata['subject'])

        # Save renamed EML
        renamed_eml = f"{email_stem}.eml"
        renamed_eml_path = os.path.join(temp_dir, renamed_eml)
        os.rename(temp_eml, renamed_eml_path)

        # Save .txt
        renamed_txt = f"{email_stem}.txt"
        renamed_txt_path = os.path.join(temp_dir, renamed_txt)
        save_text(body, renamed_txt_path)

        # Save attachments
        attachment_results = save_attachments(msg, temp_dir, basename)

        # Build file list
        files = [
            {'type': 'eml', 'name': renamed_eml, 'path': None},
            {'type': 'txt', 'name': renamed_txt, 'path': None},
        ]
        for att in attachment_results:
            files.append({
                'type': 'attach',
                'name': att['renamed_name'],
                'path': None,
            })

        # Check for collisions in output_dir
        for file_info in files:
            dest = os.path.join(output_dir, file_info['name'])
            if os.path.exists(dest):
                raise FileExistsError(
                    f"Collision: '{file_info['name']}' already exists in {output_dir}"
                )

        # Move all files to output_dir
        for file_info in files:
            src = os.path.join(temp_dir, file_info['name'])
            dest = os.path.join(output_dir, file_info['name'])
            shutil.move(src, dest)
            file_info['path'] = dest

        return {
            'metadata': metadata,
            'body': body,
            'files': files,
        }

    finally:
        # Clean up temp dir
        if os.path.exists(temp_dir):
            shutil.rmtree(temp_dir)


# ---------------------------------------------------------------------------
# Stdout display (backwards-compatible mode)
# ---------------------------------------------------------------------------

def print_email(eml_path):
    """Parse and print email to stdout. Extract attachments alongside EML.

    This preserves the original script behavior when --output-dir is not given.
    """
    with open(eml_path, 'rb') as f:
        msg = email.message_from_binary_file(f)

    metadata = extract_metadata(msg)
    body = extract_body(msg)
    timing = metadata['timing']

    print(f"From: {metadata['from']}")
    print(f"To: {metadata['to']}")
    print(f"Subject: {metadata['subject']}")
    print(f"Date: {metadata['date']}")
    print(f"Sent: {timing['sent_time']} (via {timing['sent_server']})")
    print(f"Received: {timing['received_time']} (at {timing['received_server']})")
    print()
    print(body)
    print()

    # Extract attachments alongside the EML file
    for part in msg.walk():
        if part.get_content_maintype() == 'multipart':
            continue
        if part.get('Content-Disposition') is None:
            continue

        filename = part.get_filename()
        if filename:
            filepath = os.path.join(os.path.dirname(eml_path), filename)
            with open(filepath, 'wb') as f:
                f.write(part.get_payload(decode=True))
            print(f"Extracted attachment: {filename}")


def print_pipeline_summary(result):
    """Print summary after pipeline extraction."""
    metadata = result['metadata']
    timing = metadata['timing']

    print(f"From: {metadata['from']}")
    print(f"To: {metadata['to']}")
    print(f"Subject: {metadata['subject']}")
    print(f"Date: {metadata['date']}")
    print(f"Sent: {timing['sent_time']} (via {timing['sent_server']})")
    print(f"Received: {timing['received_time']} (at {timing['received_server']})")
    print()
    print("Files created:")
    for f in result['files']:
        print(f"  [{f['type']:>6}] {f['name']}")
    print(f"\nOutput directory: {os.path.dirname(result['files'][0]['path'])}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Extract email content and attachments from EML files."
    )
    parser.add_argument('eml_path', help="Path to source EML file")
    parser.add_argument(
        '--output-dir',
        help="Destination directory for extracted files. "
             "Without this flag, prints to stdout only (backwards compatible)."
    )

    args = parser.parse_args()

    if not os.path.isfile(args.eml_path):
        print(f"Error: '{args.eml_path}' not found or is not a file.", file=sys.stderr)
        sys.exit(1)

    if args.output_dir:
        result = process_eml(args.eml_path, args.output_dir)
        print_pipeline_summary(result)
    else:
        print_email(args.eml_path)
