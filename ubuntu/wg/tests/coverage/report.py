#!/usr/bin/env python3
"""Coverage report for wg-network built from bash xtrace output.

Metrics:
  statements  executable statements (a multi-line command counts once)
  branches    explicit branches: bodies of if/elif/else and every case label
  guards      right-hand sides of "A || die", "A || return", "A && die" on one line, i.e. an
              error check that actually fired (a negative scenario), visible in the trace text

Usage: report.py SRC_DIR TRACE_DIR [--json OUT] [--min-statements N] [--min-guards N] [--uncovered]
"""
import json
import os
import re
import sys
from collections import defaultdict

STRUCTURAL = re.compile(r'^(\}|\{|fi|done|esac|;;|else|then|do|\)|\(|in)\s*(;;)?\s*$')
# A closing line with a redirection (done < <(cmd), } | cmd) is not a statement: xtrace
# attributes its commands to other lines.
CLOSING = re.compile(r'^(\}|done|fi|esac|\))(\s|$)')
FUNC_DEF = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*\(\)\s*\{\s*$')
CASE_PATTERN_ONLY = re.compile(r'^[^()]*[^\s()]\)\s*$')
CASE_PATTERN_CMD = re.compile(r'^((?:[^\s()|]+)(?:\s*\|\s*[^\s()|]+)*)\)\s+\S')
BRANCH_HEAD = re.compile(r'^(if|elif)\s')
GUARD = re.compile(r'(\|\||&&)\s*(die_code|die_usage|die_unknown_arg|die|return|exit)\b')
HEREDOC = re.compile(r'(?<!<)<<(-?)\s*([\'"]?)([A-Za-z_][A-Za-z0-9_]*)\2')


def logical_statements(lines):
    """Split a file into statements: [(first line, last line, text of the first line)].

    The lexer understands quotes, $( ), backticks, comments, heredocs, line continuations
    (\\, |, &&, ||) and multi-line array literals.
    """
    stmts, i, n = [], 0, len(lines)
    stack = []          # contexts: "'", '"', '$(', '`', '(' (array literal or subshell)
    start = None
    heredocs = []
    while i < n:
        line = lines[i]
        if heredocs:                                   # a heredoc body is not code
            term = heredocs[0]
            if (line.strip() if term[1] else line) == term[0]:
                heredocs.pop(0)
            i += 1
            continue
        if start is None:
            stripped = line.strip()
            if not stripped or stripped.startswith('#'):
                i += 1
                continue
            start = i
        j, L = 0, len(line)
        while j < L:
            c = line[j]
            top = stack[-1] if stack else None
            if top == "'":
                if c == "'":
                    stack.pop()
            elif top == '"':
                if c == '\\':
                    j += 1
                elif c == '"':
                    stack.pop()
                elif line.startswith('$(', j):
                    stack.append('$(')
                    j += 1
                elif c == '`':
                    stack.append('`')
            elif top == '`':
                if c == '`':
                    stack.pop()
            else:
                if c == '\\':
                    j += 1
                elif c == '#' and (j == 0 or line[j - 1] in ' \t;|&('):
                    break
                elif c == "'":
                    stack.append("'")
                elif c == '"':
                    stack.append('"')
                elif c == '`':
                    stack.append('`')
                elif line.startswith('$((', j):
                    stack.append('(')
                    stack.append('(')
                    j += 2
                elif line.startswith('$(', j):
                    stack.append('$(')
                    j += 1
                elif c == '(':
                    stack.append('(')
                elif c == ')' and top in ('$(', '('):
                    stack.pop()
                elif c == '<' and not stack:
                    m = HEREDOC.match(line, j)
                    if m:
                        heredocs.append((m.group(3), m.group(1) == '-'))
                        j = m.end() - 1
            j += 1
        code = re.sub(r'\s+#.*$', '', line).rstrip()
        cont = code.endswith('\\') or code.endswith('|') or code.endswith('&&') or code.endswith('||')
        if not stack and not cont:
            stmts.append((start, i, lines[start]))
            start = None
        i += 1
    if start is not None:
        stmts.append((start, n - 1, lines[start]))
    return stmts


def executable(text):
    s = text.strip()
    if STRUCTURAL.match(s) or CLOSING.match(s) or FUNC_DEF.match(s) or s.startswith('#'):
        return False
    if CASE_PATTERN_ONLY.match(s) and not s.startswith(('[[', '((', '$(')):
        return False
    return True


def indent(text):
    return len(text) - len(text.lstrip(' '))


def branches(lines, stmts):
    """Explicit branches: (header line, first body line, last body line, label)."""
    out = []
    starts = [s for s, _, _ in stmts]
    for idx, (s, e, text) in enumerate(stmts):
        t = text.strip()
        ind = indent(text)
        label = None
        if BRANCH_HEAD.match(t):
            label = t.split()[0]
        elif t == 'else':
            label = 'else'
        elif CASE_PATTERN_CMD.match(t) and not t.startswith(('[[', '((')):
            out.append((s, s, e, 'case ' + t.split(')')[0]))
            continue
        elif CASE_PATTERN_ONLY.match(t) and not t.startswith(('[[', '((', '$(')) and not STRUCTURAL.match(t):
            label = 'case ' + t.rstrip(')').strip()
        if not label:
            continue
        body_end = e
        for s2, e2, text2 in stmts[idx + 1:]:
            t2 = text2.strip()
            if indent(text2) <= ind and (t2 in ('fi', 'else', 'esac', ';;', '}', 'done') or BRANCH_HEAD.match(t2)
                                          or CASE_PATTERN_ONLY.match(t2) or CASE_PATTERN_CMD.match(t2)):
                break
            if indent(text2) < ind:
                break
            body_end = e2
        if body_end > e:
            out.append((s, e + 1, body_end, label))
    return out


def load_traces(trace_dir, src):
    """Executed lines and the commands on them: {rel: {line: {first_word}}}."""
    hits = defaultdict(lambda: defaultdict(set))
    src = os.path.realpath(src)
    roots = [src + '/', '/opt/wg-network/', '/src/']
    unreadable = 0
    for name in os.listdir(trace_dir):
        if not name.startswith('trace.'):
            continue
        try:
            f = open(os.path.join(trace_dir, name), 'rb')
        except OSError:
            unreadable += 1
            continue
        with f:
            for raw in f:
                parts = raw.split(b'\x01')
                if len(parts) < 4:
                    continue
                path = parts[1].decode('utf-8', 'replace')
                rel = None
                # The entry point runs through a symlink, and BASH_SOURCE holds the link path.
                if path.endswith('/usr/local/bin/wg-network'):
                    rel = 'wg-network'
                for r in roots:
                    if rel is None and path.startswith(r):
                        rel = path[len(r):]
                        break
                if rel is None or rel.startswith('tests/'):
                    continue
                try:
                    ln = int(parts[2])
                except ValueError:
                    continue
                text = parts[3].decode('utf-8', 'replace').strip()
                hits[rel][ln].add(text.split(' ', 1)[0] if text else '')
    if unreadable:
        print(f'WARNING: {unreadable} trace files were unreadable, coverage is understated', file=sys.stderr)
    return hits


def analyze(src, hits):
    files = ['wg-network', 'install.sh'] + sorted(
        os.path.join(d, f) for d in ('lib', 'commands') for f in os.listdir(os.path.join(src, d)) if f.endswith('.sh'))
    report = {}
    for rel in files:
        with open(os.path.join(src, rel), encoding='utf-8') as f:
            lines = f.read().split('\n')
        h = hits.get(rel, {})
        stmts = [st for st in logical_statements(lines) if executable(st[2])]
        cov = lambda a, b: any((ln + 1) in h for ln in range(a, b + 1))
        st_cov = [st for st in stmts if cov(st[0], st[1])]
        st_unc = [st for st in stmts if not cov(st[0], st[1])]
        br = branches(lines, stmts)
        br_cov = [b for b in br if cov(b[1], b[2])]
        br_unc = [b for b in br if not cov(b[1], b[2])]
        guards, g_cov, g_unc = [], [], []
        for s, e, text in stmts:
            for m in GUARD.finditer(text):
                cmd = m.group(2)
                guards.append((s, cmd))
                words = set().union(*(h.get(ln + 1, set()) for ln in range(s, e + 1)))
                if cmd in words:
                    g_cov.append((s, cmd, text.strip()))
                else:
                    g_unc.append((s, cmd, text.strip()))
        report[rel] = {
            'statements': [len(st_cov), len(stmts)],
            'branches': [len(br_cov), len(br)],
            'guards': [len(g_cov), len(guards)],
            'uncovered_statements': [[s + 1, t.strip()[:100]] for s, _, t in st_unc],
            'uncovered_branches': [[b[0] + 1, b[3][:60]] for b in br_unc],
            'uncovered_guards': [[g[0] + 1, g[2][:100]] for g in g_unc],
        }
    return report


def pct(a, b):
    return 100.0 * a / b if b else 100.0


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        print(__doc__)
        return 2
    src, trace_dir = args[0], args[1]
    opts = dict(zip(args[2::2], args[3::2]))
    show_uncovered = '--uncovered' in args
    report = analyze(src, load_traces(trace_dir, src))
    tot = {k: [0, 0] for k in ('statements', 'branches', 'guards')}
    print(f"{'file':<28} {'statements':>18} {'branches':>16} {'guards (|| die)':>18}")
    for rel, r in report.items():
        for k in tot:
            tot[k][0] += r[k][0]
            tot[k][1] += r[k][1]
        print(f"{rel:<28} " + ' '.join(f"{r[k][0]:>5}/{r[k][1]:<5}{pct(*r[k]):5.1f}%" for k in tot))
    print('-' * 84)
    print(f"{'TOTAL':<28} " + ' '.join(f"{tot[k][0]:>5}/{tot[k][1]:<5}{pct(*tot[k]):5.1f}%" for k in tot))
    if show_uncovered:
        for rel, r in report.items():
            if r['uncovered_statements'] or r['uncovered_branches']:
                print(f"\n## {rel}")
                for ln, t in r['uncovered_statements']:
                    print(f"  statement {ln}: {t}")
                for ln, t in r['uncovered_branches']:
                    print(f"  branch    {ln}: {t}")
                for ln, t in r['uncovered_guards']:
                    print(f"  guard     {ln}: {t}")
    if '--json' in opts:
        with open(opts['--json'], 'w', encoding='utf-8') as f:
            json.dump({'total': tot, 'files': report}, f, ensure_ascii=False, indent=1)
    rc = 0
    if '--min-statements' in opts and pct(*tot['statements']) < float(opts['--min-statements']):
        print(f"statement coverage is below {opts['--min-statements']}%")
        rc = 1
    if '--min-guards' in opts and pct(*tot['guards']) < float(opts['--min-guards']):
        print(f"guard coverage is below {opts['--min-guards']}%")
        rc = 1
    return rc


if __name__ == '__main__':
    sys.exit(main())
