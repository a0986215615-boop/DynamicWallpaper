#!/usr/bin/env python3
"""Heuristic pre-publication check. Reports locations, never matching secrets."""
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
IGNORED_DIRECTORIES = {'.git', '.build', '.swiftpm', 'dist', '__pycache__'}
FORBIDDEN_DIRECTORIES = {'Backup', '.aws', '.codex', '.agents', '__MACOSX', '.AppleDouble'}
FORBIDDEN_SUFFIXES = {'.pem', '.key', '.p12', '.pfx', '.mobileprovision', '.zip', '.log', '.mp4', '.mov', '.m4v'}
PATTERNS = {
    'personal home path': re.compile(r'/(?:Users|home)/[A-Za-z0-9_.-]+/'),
    'Windows home path': re.compile(r'[A-Za-z]:\\Users\\[A-Za-z0-9_.-]+\\'),
    'private temporary path': re.compile(r'/private/var/folders/[A-Za-z0-9_]+/'),
    'email address': re.compile(r'(?<![\w.+-])[\w.+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+'),
    'private key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'),
    'GitHub token': re.compile(r'(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,})'),
    'AWS access key': re.compile(r'AKIA[0-9A-Z]{16}'),
    'Slack token': re.compile(r'xox[baprs]-[A-Za-z0-9-]{20,}'),
    'credential assignment': re.compile(r'(?i)(?:api[_-]?key|access[_-]?token|password|secret)\s*[:=]\s*[\x22\x27][A-Za-z0-9_+/=-]{16,}[\x22\x27]'),
}

def candidate_files():
    top = subprocess.run(['git', '-C', str(ROOT), 'rev-parse', '--show-toplevel'], capture_output=True, text=True)
    if top.returncode == 0 and Path(top.stdout.strip()).resolve() == ROOT:
        result = subprocess.run(['git', '-C', str(ROOT), 'ls-files', '--cached', '-z'], capture_output=True, check=True)
        return [ROOT / p.decode('utf-8') for p in result.stdout.split(b'\0') if p]
    return [p for p in ROOT.rglob('*') if p.is_file() and not (set(p.relative_to(ROOT).parts) & IGNORED_DIRECTORIES)]

def main():
    findings = []
    files = candidate_files()
    if not files:
        print('No source files found; stage the intended files before checking.', file=sys.stderr)
        return 1
    for path in sorted(files):
        relative = path.relative_to(ROOT)
        parts = set(relative.parts)
        if path.is_symlink():
            findings.append(f'{relative}: symbolic link requires review')
            continue
        if parts & FORBIDDEN_DIRECTORIES or 'Results' in parts or path.suffix.lower() in FORBIDDEN_SUFFIXES or path.name == '.DS_Store' or path.name.startswith('._') or (path.name.startswith('.env') and path.name != '.env.example'):
            findings.append(f'{relative}: local/private artifact')
            continue
        try:
            text = path.read_text(encoding='utf-8')
            if '\0' in text:
                raise ValueError('binary')
        except (UnicodeError, ValueError):
            findings.append(f'{relative}: binary file requires review')
            continue
        for number, line in enumerate(text.splitlines(), 1):
            for label, pattern in PATTERNS.items():
                if pattern.search(line):
                    findings.append(f'{relative}:{number}: possible {label}')
    if findings:
        print('\n'.join(findings), file=sys.stderr)
        return 1
    print(f'PASS: {len(files)} public files; no flagged private artifacts, paths, contacts or credential patterns.')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
