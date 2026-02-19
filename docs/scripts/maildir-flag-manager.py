#!/usr/bin/env python3
"""Manage maildir flags (read, starred) across email accounts.

Uses atomic os.rename() for flag operations directly on maildir files.
Safer and more reliable than shell-based approaches (zsh loses PATH in
while-read loops, piped mu move silently fails).

Supports the same flag semantics as mu4e: maildir files in new/ are moved
to cur/ when the Seen flag is added, and flag changes are persisted to the
filesystem so mbsync picks them up on the next sync.

Usage:
    # Mark all unread INBOX emails as read
    maildir-flag-manager.py mark-read

    # Mark specific emails as read (by path)
    maildir-flag-manager.py mark-read /path/to/message1 /path/to/message2

    # Mark all unread INBOX emails as read, then reindex mu
    maildir-flag-manager.py mark-read --reindex

    # Star specific emails (by path)
    maildir-flag-manager.py star /path/to/message1 /path/to/message2

    # Star and mark read
    maildir-flag-manager.py star --mark-read /path/to/message1

    # Dry run — show what would change without modifying anything
    maildir-flag-manager.py mark-read --dry-run
"""

import argparse
import os
import shutil
import subprocess
import sys


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

MAILDIR_ACCOUNTS = {
    'gmail': os.path.expanduser('~/.mail/gmail/INBOX'),
    'cmail': os.path.expanduser('~/.mail/cmail/Inbox'),
}


# ---------------------------------------------------------------------------
# Core flag operations
# ---------------------------------------------------------------------------

def parse_maildir_flags(filename):
    """Extract flags from a maildir filename.

    Maildir filenames follow the pattern: unique:2,FLAGS
    where FLAGS is a sorted string of flag characters (e.g., "FS" for
    Flagged+Seen).

    Returns (base, flags_string). If no flags section, returns (filename, '').
    """
    if ':2,' in filename:
        base, flags = filename.rsplit(':2,', 1)
        return base, flags
    return filename, ''


def build_flagged_filename(filename, new_flags):
    """Build a maildir filename with the given flags.

    Flags are always sorted alphabetically per maildir spec.
    """
    base, _ = parse_maildir_flags(filename)
    sorted_flags = ''.join(sorted(set(new_flags)))
    return f"{base}:2,{sorted_flags}"


def rename_with_flag(file_path, flag, dry_run=False):
    """Add a flag to a single maildir message file via atomic rename.

    Handles moving from new/ to cur/ when adding the Seen flag.
    Returns True if the flag was added, False if already present.
    """
    dirname = os.path.dirname(file_path)
    filename = os.path.basename(file_path)
    maildir_root = os.path.dirname(dirname)
    subdir = os.path.basename(dirname)

    _, current_flags = parse_maildir_flags(filename)

    if flag in current_flags:
        return False

    new_flags = current_flags + flag
    new_filename = build_flagged_filename(filename, new_flags)

    # Messages with the Seen flag belong in cur/, not new/
    if 'S' in new_flags and subdir == 'new':
        target_dir = os.path.join(maildir_root, 'cur')
    else:
        target_dir = dirname

    new_path = os.path.join(target_dir, new_filename)

    if dry_run:
        return True

    os.rename(file_path, new_path)
    return True


def process_maildir(maildir_path, flag, dry_run=False):
    """Add a flag to all messages in a maildir that don't have it.

    Scans both new/ and cur/ subdirectories.
    Returns (changed_count, skipped_count, error_count).
    """
    if not os.path.isdir(maildir_path):
        print(f"  Skipping {maildir_path} (not found)", file=sys.stderr)
        return 0, 0, 0

    changed = 0
    skipped = 0
    errors = 0

    for subdir in ('new', 'cur'):
        subdir_path = os.path.join(maildir_path, subdir)
        if not os.path.isdir(subdir_path):
            continue

        for filename in os.listdir(subdir_path):
            file_path = os.path.join(subdir_path, filename)
            if not os.path.isfile(file_path):
                continue

            try:
                if rename_with_flag(file_path, flag, dry_run):
                    changed += 1
                else:
                    skipped += 1
            except Exception as e:
                print(f"  Error on {filename}: {e}", file=sys.stderr)
                errors += 1

    return changed, skipped, errors


def process_specific_files(paths, flag, dry_run=False):
    """Add a flag to specific message files by path.

    Returns (changed_count, skipped_count, error_count).
    """
    changed = 0
    skipped = 0
    errors = 0

    for path in paths:
        path = os.path.abspath(path)
        if not os.path.isfile(path):
            print(f"  File not found: {path}", file=sys.stderr)
            errors += 1
            continue

        # Verify file is inside a maildir (parent should be cur/ or new/)
        parent_dir = os.path.basename(os.path.dirname(path))
        if parent_dir not in ('cur', 'new'):
            print(f"  Not in a maildir cur/ or new/ dir: {path}",
                  file=sys.stderr)
            errors += 1
            continue

        try:
            if rename_with_flag(path, flag, dry_run):
                changed += 1
            else:
                skipped += 1
        except Exception as e:
            print(f"  Error on {path}: {e}", file=sys.stderr)
            errors += 1

    return changed, skipped, errors


def reindex_mu():
    """Run mu index to update the database after flag changes."""
    mu_path = shutil.which('mu')
    if not mu_path:
        print("Warning: mu not found in PATH, skipping reindex",
              file=sys.stderr)
        return False

    try:
        result = subprocess.run(
            [mu_path, 'index'],
            capture_output=True, text=True, timeout=120
        )
        if result.returncode == 0:
            print("mu index: database updated")
            return True
        else:
            print(f"mu index failed: {result.stderr}", file=sys.stderr)
            return False
    except subprocess.TimeoutExpired:
        print("mu index timed out after 120s", file=sys.stderr)
        return False


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_mark_read(args):
    """Mark emails as read (add Seen flag)."""
    flag = 'S'
    action = "Marking as read"
    if args.dry_run:
        action = "Would mark as read"

    total_changed = 0
    total_skipped = 0
    total_errors = 0

    if args.paths:
        print(f"{action}: {len(args.paths)} specific message(s)")
        c, s, e = process_specific_files(args.paths, flag, args.dry_run)
        total_changed += c
        total_skipped += s
        total_errors += e
    else:
        for name, maildir_path in MAILDIR_ACCOUNTS.items():
            print(f"{action} in {name} ({maildir_path})")
            c, s, e = process_maildir(maildir_path, flag, args.dry_run)
            total_changed += c
            total_skipped += s
            total_errors += e
            if c > 0:
                print(f"  {c} message(s) marked as read")
            if s > 0:
                print(f"  {s} already read")

    print(f"\nTotal: {total_changed} changed, {total_skipped} already set, "
          f"{total_errors} errors")

    if args.reindex and not args.dry_run and total_changed > 0:
        reindex_mu()

    return 0 if total_errors == 0 else 1


def cmd_star(args):
    """Star/flag emails (add Flagged flag)."""
    flag = 'F'
    action = "Starring"
    if args.dry_run:
        action = "Would star"

    if not args.paths:
        print("Error: star requires specific message paths", file=sys.stderr)
        return 1

    print(f"{action}: {len(args.paths)} message(s)")
    total_changed = 0
    total_skipped = 0
    total_errors = 0

    c, s, e = process_specific_files(args.paths, flag, args.dry_run)
    total_changed += c
    total_skipped += s
    total_errors += e

    # Also mark as read if requested
    if args.mark_read:
        print("Also marking as read...")
        c2, _, e2 = process_specific_files(args.paths, 'S', args.dry_run)
        total_changed += c2
        total_errors += e2

    print(f"\nTotal: {total_changed} flag(s) changed, {total_skipped} already set, "
          f"{total_errors} errors")

    if args.reindex and not args.dry_run and total_changed > 0:
        reindex_mu()

    return 0 if total_errors == 0 else 1


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Manage maildir flags (read, starred) across email accounts."
    )
    subparsers = parser.add_subparsers(dest='command', required=True)

    # mark-read
    p_read = subparsers.add_parser(
        'mark-read',
        help="Mark emails as read (add Seen flag)"
    )
    p_read.add_argument(
        'paths', nargs='*',
        help="Specific message file paths. If omitted, marks all unread "
             "messages in configured INBOX maildirs."
    )
    p_read.add_argument(
        '--reindex', action='store_true',
        help="Run mu index after changing flags"
    )
    p_read.add_argument(
        '--dry-run', action='store_true',
        help="Show what would change without modifying anything"
    )
    p_read.set_defaults(func=cmd_mark_read)

    # star
    p_star = subparsers.add_parser(
        'star',
        help="Star/flag emails (add Flagged flag)"
    )
    p_star.add_argument(
        'paths', nargs='+',
        help="Message file paths to star"
    )
    p_star.add_argument(
        '--mark-read', action='store_true',
        help="Also mark starred messages as read"
    )
    p_star.add_argument(
        '--reindex', action='store_true',
        help="Run mu index after changing flags"
    )
    p_star.add_argument(
        '--dry-run', action='store_true',
        help="Show what would change without modifying anything"
    )
    p_star.set_defaults(func=cmd_star)

    args = parser.parse_args()
    sys.exit(args.func(args))


if __name__ == '__main__':
    main()
