# shellcheck shell=bash

CMD_SUMMARY='показать конфиг (секреты скрыты)'
CMD_GROUP=diag
CMD_READONLY=1

cmd_usage() {
    cat <<'EOF'
Использование: wg-network [-i IFACE] show [--candidate] [--reveal]

  --candidate  конфиг, который будет записан при следующем apply (по умолчанию — действующий)
  --reveal     не скрывать PrivateKey и PresharedKey
EOF
}

cmd_run() {
    local candidate=0 reveal=0 file
    while (($#)); do
        case $1 in
            --candidate) candidate=1; shift ;;
            --reveal) reveal=1; shift ;;
            *) die_unknown_arg "$1" ;;
        esac
    done
    require_managed
    if ((candidate)); then
        plan_build
        file=$PLAN_CANDIDATE
    else
        file=$LIVE_CONF
        [[ -f $file ]] || die "$LIVE_CONF отсутствует"
    fi
    if ((reveal)); then
        cat "$file"
    else
        sed -E 's/^((PrivateKey|PresharedKey)[[:space:]]*=[[:space:]]*).*/\1(скрыто, --reveal)/' "$file"
    fi
}
