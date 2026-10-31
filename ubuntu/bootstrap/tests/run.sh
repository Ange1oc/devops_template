#!/usr/bin/env bash
# Test runner: tests/run.sh [lint|unit|e2e|coverage|all] [-- e2e arguments]
#
#   lint      shellcheck (local binary or docker koalaman/shellcheck)
#   unit      pure logic, no root, no network, no system changes
#   e2e       scenarios in Ubuntu containers with systemd (UBUNTU_VERSIONS="22.04 24.04 26.04")
#   coverage  unit + e2e under kcov in an Ubuntu 26.04 container; summary in tests/.coverage-summary.txt
#
# The host is never modified: everything runs in containers.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(dirname "$HERE")"
rc=0

lint() {
    local -a files=()
    mapfile -t files < <(cd "$SRC" && ls ubuntu-bootstrap install.sh lib/*.sh commands/*.sh modules/*.sh completion/*.bash tests/*.sh)
    if command -v shellcheck >/dev/null 2>&1; then
        (cd "$SRC" && shellcheck -x -S style "${files[@]}")
    elif command -v docker >/dev/null 2>&1; then
        docker run --rm -v "$SRC:/src:ro" -w /src koalaman/shellcheck:stable -x -S style "${files[@]}"
    else
        echo 'нет shellcheck и docker — lint пропущен'
        return 0
    fi && echo 'shellcheck: замечаний нет'
}

unit() { bash "$HERE/unit.sh"; }

e2e() { bash "$HERE/e2e.sh" "$@"; }

coverage() { bash "$HERE/e2e.sh" --coverage --version 26.04 "$@"; }

cmd=${1:-all}
shift || true
[[ ${1-} == -- ]] && shift
case $cmd in
    lint) lint || rc=1 ;;
    unit) unit || rc=1 ;;
    e2e) e2e "$@" || rc=1 ;;
    coverage) coverage "$@" || rc=1 ;;
    all)
        lint || rc=1
        unit || rc=1
        e2e "$@" || rc=1
        ;;
    *) echo "использование: $0 [lint|unit|e2e|coverage|all] [-- аргументы e2e]"; exit 2 ;;
esac
exit "$rc"
