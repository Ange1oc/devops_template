# shellcheck shell=bash
# Loaded through BASH_ENV into every non-interactive bash process of the tests; enables xtrace
# into a per-process file without changing wg-network. Traces contain test keys, so
# WGN_COV_DIR is temporary.
if [[ -n ${WGN_COV_DIR-} && -d $WGN_COV_DIR ]]; then
    __wgn_cov_file="$WGN_COV_DIR/trace.$$.$RANDOM"
    # Readable whatever the process umask: traces from containers are created by root.
    (umask 022 && : >> "$__wgn_cov_file")
    exec {__wgn_cov_fd}>> "$__wgn_cov_file"
    BASH_XTRACEFD=$__wgn_cov_fd
    PS4=$'+\x01${BASH_SOURCE[0]-}\x01${LINENO}\x01 '
    set -x
fi
