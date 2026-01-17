#!/usr/bin/env python3
import email
import sys
import os

def extract_attachments(eml_file):
    with open(eml_file, 'rb') as f:
        msg = email.message_from_binary_file(f)

    # Extract plain text body
    body_text = ""
    for part in msg.walk():
        if part.get_content_type() == "text/plain":
            body_text = part.get_payload(decode=True).decode('utf-8', errors='ignore')
            break
        elif part.get_content_type() == "text/html":
            # Fallback to HTML if no plain text
            if not body_text:
                body_text = part.get_payload(decode=True).decode('utf-8', errors='ignore')

    # Print email metadata and body
    print(f"From: {msg.get('From')}")
    print(f"To: {msg.get('To')}")
    print(f"Subject: {msg.get('Subject')}")
    print(f"Date: {msg.get('Date')}")
    print()
    print(body_text)
    print()

    # Extract attachments
    attachments = []
    for part in msg.walk():
        if part.get_content_maintype() == 'multipart':
            continue
        if part.get('Content-Disposition') is None:
            continue

        filename = part.get_filename()
        if filename:
            filepath = os.path.join(os.path.dirname(eml_file), filename)
            with open(filepath, 'wb') as f:
                f.write(part.get_payload(decode=True))
            attachments.append(filename)
            print(f"Extracted attachment: {filename}")

    return attachments

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: extract_attachments.py <eml_file>")
        sys.exit(1)

    extract_attachments(sys.argv[1])
