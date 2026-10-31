# shellcheck shell=bash
# Filesystem layout. UBB_SYSROOT (tests only) moves state, backups and logs into a sandbox.

SYSROOT=${UBB_SYSROOT-}
readonly CONF_DIR="$SYSROOT/etc/ubuntu-bootstrap"
readonly CONF_FILE="$CONF_DIR/bootstrap.conf"
readonly USER_MODULES_DIR="$CONF_DIR/modules.d"
readonly USER_PROFILES_DIR="$CONF_DIR/profiles.d"
readonly STATE_DIR="$SYSROOT/var/lib/ubuntu-bootstrap"
readonly RUNS_DIR="$STATE_DIR/runs"
readonly MOD_STATE_DIR="$STATE_DIR/modules"
readonly PENDING_FILE="$STATE_DIR/pending.env"
readonly LOCK_FILE="$STATE_DIR/.lock"
readonly BACKUP_ROOT="$SYSROOT/var/backups/ubuntu-bootstrap"
readonly LOG_DIR="$SYSROOT/var/log/ubuntu-bootstrap"
readonly RECOVER_UNIT='ubuntu-bootstrap-recover.service'

ubb_version() {
    local v
    v="$(cat "$UBB_HOME/VERSION" 2>/dev/null)" || v=unknown
    printf '%s' "$v"
}

install_meta() {
    kv_get "$UBB_HOME/.install" "$1"
}

state_dirs_init() {
    local d
    for d in "$CONF_DIR" "$STATE_DIR" "$RUNS_DIR" "$MOD_STATE_DIR" "$BACKUP_ROOT" "$LOG_DIR"; do
        [[ -d $d ]] || install -d -m 700 "$d"
    done
}
