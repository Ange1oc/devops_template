# shellcheck shell=bash
# Paths, defaults and interface selection.
#
# Defaults can be overridden in /etc/default/wg-network (KEY=VALUE, parsed, never sourced):
#   DEFAULT_INTERFACE=wg0
#   DEFAULT_HUB_ADDRESS=10.50.0.1/24
#   DEFAULT_PORT=51820
#   DEFAULT_KEEPALIVE=25
#   CONFIRM_TIMEOUT=120        seconds to confirm a change before it is rolled back
#   AUTO_APPLY=ask             ask | hot | never
#   SNAPSHOT_KEEP=30
#   LOCK_WAIT=30
#   RERESOLVE_AFTER=135        seconds without a handshake before an endpoint is resolved again

readonly WGN_CONFIG_FILE='/etc/default/wg-network'
readonly WG_DIR='/etc/wireguard'
readonly WGN_ROOT="$WG_DIR/wg-network"
readonly WGN_BACKUP_ROOT='/var/backups/wg-network'
readonly SYSTEMD_DIR='/etc/systemd/system'
readonly SCHEMA_VERSION=2

DEFAULT_INTERFACE='wg0'
DEFAULT_HUB_ADDRESS='10.50.0.1/24'
DEFAULT_PORT='51820'
DEFAULT_KEEPALIVE='25'
CONFIRM_TIMEOUT='120'
AUTO_APPLY='ask'
SNAPSHOT_KEEP='30'
LOCK_WAIT='30'
RERESOLVE_AFTER='135'

readonly NODE_KEYS=(SCHEMA ROLE NAME ADDRESS ADDRESS6 LISTEN_PORT ENDPOINT MTU TABLE FORWARD NAT FIREWALL_PORT CREATED_AT)
readonly PEER_KEYS=(PUBLIC_KEY PSK ADDRESS ADDRESS6 ROUTES ENDPOINT KEEPALIVE ENABLED PENDING COMMENT CREATED_AT UPDATED_AT)

config_load() {
    local key value
    local -A conf=()
    kv_load "$WGN_CONFIG_FILE" conf

    # Keys used by earlier versions.
    if [[ -n ${conf[DEFAULT_HUB_IP]-} && -z ${conf[DEFAULT_HUB_ADDRESS]-} ]]; then
        conf[DEFAULT_HUB_ADDRESS]="${conf[DEFAULT_HUB_IP]}/${conf[DEFAULT_PREFIX]:-24}"
    fi
    [[ -n ${conf[WG_INTERFACE]-} && -z ${conf[DEFAULT_INTERFACE]-} ]] && conf[DEFAULT_INTERFACE]=${conf[WG_INTERFACE]}

    for key in DEFAULT_INTERFACE DEFAULT_HUB_ADDRESS DEFAULT_PORT DEFAULT_KEEPALIVE CONFIRM_TIMEOUT AUTO_APPLY SNAPSHOT_KEEP LOCK_WAIT RERESOLVE_AFTER; do
        value=${conf[$key]-}
        [[ -n $value ]] && printf -v "$key" '%s' "$value"
    done

    is_iface "$DEFAULT_INTERFACE" || die "$WGN_CONFIG_FILE: некорректный DEFAULT_INTERFACE"
    is_iface_cidr4 "$DEFAULT_HUB_ADDRESS" || die "$WGN_CONFIG_FILE: некорректный DEFAULT_HUB_ADDRESS"
    is_port "$DEFAULT_PORT" || die "$WGN_CONFIG_FILE: некорректный DEFAULT_PORT"
    is_keepalive "$DEFAULT_KEEPALIVE" || die "$WGN_CONFIG_FILE: некорректный DEFAULT_KEEPALIVE"
    is_uint "$CONFIRM_TIMEOUT" || die "$WGN_CONFIG_FILE: некорректный CONFIRM_TIMEOUT"
    [[ $AUTO_APPLY =~ ^(ask|hot|never)$ ]] || die "$WGN_CONFIG_FILE: AUTO_APPLY должен быть ask, hot или never"
    is_uint "$SNAPSHOT_KEEP" && ((SNAPSHOT_KEEP >= 1)) || die "$WGN_CONFIG_FILE: некорректный SNAPSHOT_KEEP"
    is_uint "$LOCK_WAIT" || die "$WGN_CONFIG_FILE: некорректный LOCK_WAIT"
    is_uint "$RERESOLVE_AFTER" || die "$WGN_CONFIG_FILE: некорректный RERESOLVE_AFTER"
    [[ -n ${OPT_CONFIRM_TIMEOUT-} ]] && CONFIRM_TIMEOUT=$OPT_CONFIRM_TIMEOUT
    return 0
}

iface_use() {
    is_iface "$1" || die_usage "некорректное имя интерфейса: $1"
    IFACE=$1
    st_paths "$WGN_ROOT/$IFACE"
    # The lock lives outside the state directory so that restoring a snapshot cannot replace it.
    ST_LOCK="$WGN_ROOT/.lock.$IFACE"
    LIVE_CONF="$WG_DIR/$IFACE.conf"
    UNIT="wg-quick@$IFACE.service"
    DROPIN_DIR="$SYSTEMD_DIR/wg-quick@$IFACE.service.d"
    DROPIN="$DROPIN_DIR/wg-network.conf"
}

# State paths relative to a directory: the real one or the --dry-run sandbox.
st_paths() {
    ST_DIR=$1
    ST_NODE="$ST_DIR/node.env"
    ST_KEY="$ST_DIR/private.key"
    ST_PEERS="$ST_DIR/peers.d"
    ST_SNAPSHOTS="$ST_DIR/snapshots"
    ST_RENDERED="$ST_DIR/rendered.sha256"
    ST_TX="$ST_DIR/tx.env"
    ST_PENDING="$ST_DIR/pending.env"
    ST_PENDING_CONF="$ST_DIR/pending.prev.conf"
}

managed_ifaces() {
    local f
    for f in "$WGN_ROOT"/*/node.env; do
        [[ -f $f ]] || continue
        f=${f%/node.env}
        printf '%s\n' "${f##*/}"
    done
}

# -i IFACE, otherwise the only managed interface, otherwise DEFAULT_INTERFACE.
iface_resolve() {
    local -a list=()
    if [[ -n ${OPT_IFACE-} ]]; then
        iface_use "$OPT_IFACE"
        return
    fi
    mapfile -t list < <(managed_ifaces)
    case ${#list[@]} in
        0) iface_use "$DEFAULT_INTERFACE" ;;
        1) iface_use "${list[0]}" ;;
        *)
            if [[ " ${list[*]} " == *" $DEFAULT_INTERFACE "* ]]; then
                iface_use "$DEFAULT_INTERFACE"
            else
                die_usage "управляется несколько интерфейсов (${list[*]}): укажи -i IFACE"
            fi
            ;;
    esac
}

install_meta() {
    kv_get "$WGN_HOME/.install" "$1"
}

wgn_version() {
    local v
    v="$(cat "$WGN_HOME/VERSION" 2>/dev/null)" || v=unknown
    printf '%s' "$v"
}
