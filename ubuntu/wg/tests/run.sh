#!/usr/bin/env bash
# Test runner: tests/run.sh [lint|unit|e2e|systemd|distro|coverage|all]
#
#   lint      shellcheck (skipped when not installed)
#   unit      pure logic, no root and no network
#   e2e       real WireGuard in isolated namespaces; no root needed when the kernel allows
#             unprivileged user namespaces. Needs wg and wg-quick in PATH or WGTOOLS_DIR.
#             The host is not changed: /etc, /opt, /usr/local/bin are covered by overlays.
#   systemd   real systemd + OpenSSH in docker (tests/systemd.sh)
#   distro    e2e inside Ubuntu 22.04 / 26.04 containers (WGN_E2E_BASES)
#   coverage  unit + e2e under coverage measurement; arguments are thresholds for report.py

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(dirname "$HERE")"
rc=0

lint() {
    if ! command -v shellcheck >/dev/null 2>&1; then
        echo 'shellcheck не установлен — lint пропущен'
        return 0
    fi
    (cd "$SRC" && shellcheck -x wg-network install.sh lib/*.sh commands/*.sh completion/*.bash tests/*.sh tests/stubs/* tests/stubs-fw/* tests/coverage/*.sh) &&
        echo 'shellcheck: замечаний нет'
}

unit() {
    bash "$HERE/unit.sh"
}

e2e() {
    [[ -n ${WGTOOLS_DIR-} ]] && export PATH="$WGTOOLS_DIR:$PATH"
    if ! command -v wg >/dev/null || ! command -v wg-quick >/dev/null; then
        echo 'нет wg/wg-quick: установи wireguard-tools или укажи WGTOOLS_DIR — e2e пропущены'
        return 0
    fi
    local -a ns=(unshare --mount --net --fork)
    local work status
    [[ $(id -u) == 0 ]] || ns=(unshare --map-root-user --mount --net --fork)
    work="$(mktemp -d "${TMPDIR:-/tmp}/wgn-e2e.XXXXXX")"
    WGN_E2E_INSIDE=1 WGN_E2E_WORK=$work "${ns[@]}" bash "$HERE/e2e.sh"
    status=$?
    if [[ -z ${WGN_E2E_KEEP-} ]]; then
        chmod -R u+rwx "$work" 2>/dev/null
        rm -rf -- "$work"
    else
        echo "рабочий каталог сохранён: $work"
    fi
    return "$status"
}

systemd_suite() {
    local snap status
    snap="$(mktemp -d "${TMPDIR:-/tmp}/wgn-src.XXXXXX")"
    cp -a "$SRC/." "$snap/"
    WGN_SRC=$snap bash "$snap/tests/systemd.sh"
    status=$?
    rm -rf -- "$snap"
    return "$status"
}

# The e2e suite inside other Ubuntu releases (their own bash, iproute2, wireguard-tools).
distro_e2e() {
    local base rc=0 snap
    command -v docker >/dev/null || { echo 'docker не найден — матрица дистрибутивов пропущена'; return 0; }
    # A copy of the sources: bash reads scripts incrementally, editing them mid-run breaks it.
    snap="$(mktemp -d "${TMPDIR:-/tmp}/wgn-src.XXXXXX")"
    cp -a "$SRC/." "$snap/"
    for base in ${WGN_E2E_BASES:-ubuntu:22.04 ubuntu:26.04}; do
        docker image inspect "wgn-systemd:${base#*:}" >/dev/null 2>&1 ||
            docker build -q --build-arg "BASE=$base" -t "wgn-systemd:${base#*:}" "$HERE/docker" >/dev/null
        echo "== e2e в $base"
        # The work directory is a tmpfs: an overlay upper layer cannot live on the container's overlayfs.
        docker run --rm --privileged --cgroupns=private -v "$snap:/src:ro" --tmpfs /work:exec,mode=1777 -e TMPDIR=/work \
            ${WGN_COV_DIR:+-v "$WGN_COV_DIR:/cov" -e WGN_COV_DIR=/cov -e BASH_ENV=/src/tests/coverage/bash_env.sh} \
            "wgn-systemd:${base#*:}" bash /src/tests/run.sh e2e > "$snap/e2e-${base#*:}.log" 2>&1 || rc=1
        grep -E 'Итог|  FAIL:' "$snap/e2e-${base#*:}.log" || { tail -20 "$snap/e2e-${base#*:}.log"; rc=1; }
    done
    rm -rf -- "$snap"
    return "$rc"
}

# Coverage: unit + e2e under xtrace (through BASH_ENV, the code is unchanged), then the report.
coverage() {
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/wgn-cov.XXXXXX")"
    export WGN_COV_DIR=$dir BASH_ENV="$HERE/coverage/bash_env.sh"
    unit >/dev/null || { echo 'unit-тесты упали'; rc=1; }
    e2e > "$dir/e2e.log" 2>&1 || { tail -40 "$dir/e2e.log"; echo 'e2e-тесты упали'; rc=1; }
    if [[ ${COVERAGE_FULL:-0} == 1 ]]; then
        systemd_suite > "$dir/systemd.log" 2>&1 || { tail -40 "$dir/systemd.log"; rc=1; }
        distro_e2e > "$dir/distro.log" 2>&1 || { tail -40 "$dir/distro.log"; rc=1; }
    fi
    grep -h 'Итог' "$dir"/*.log 2>/dev/null || true
    unset BASH_ENV
    # Traces written by root inside containers must be readable here.
    if [[ ${COVERAGE_FULL:-0} == 1 ]] && command -v docker >/dev/null; then
        docker run --rm -v "$dir:/cov" wgn-systemd:24.04 chmod -R a+rX /cov >/dev/null 2>&1 || true
    fi
    python3 "$HERE/coverage/report.py" "$SRC" "$dir" --json "$HERE/coverage/last.json" "$@" || rc=1
    # WGN_COV_KEEP=1 keeps the traces for another analysis (they contain test secrets).
    if [[ -n ${WGN_COV_KEEP-} ]]; then echo "трассировки: $dir"; else rm -rf -- "$dir"; fi
}

case ${1:-all} in
    lint) lint || rc=1 ;;
    coverage) shift; coverage "$@" ;;
    systemd) systemd_suite || rc=1 ;;
    distro) distro_e2e || rc=1 ;;
    unit) unit || rc=1 ;;
    e2e) e2e || rc=1 ;;
    all)
        lint || rc=1
        unit || rc=1
        e2e || rc=1
        ;;
    *) echo "использование: $0 [lint|unit|e2e|systemd|distro|coverage|all]"; exit 2 ;;
esac
exit "$rc"
