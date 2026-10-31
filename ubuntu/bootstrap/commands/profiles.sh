# shellcheck shell=bash

CMD_SUMMARY='список профилей и их содержимое'
CMD_GROUP=inspect
CMD_ROOT=0

cmd_usage() {
    cat <<'EOT'
Использование: ubuntu-bootstrap profiles [NAME]

Профиль — файл KEY=VALUE с набором модулей (MODULES=) и значениями опций.
Встроенные лежат в profiles/, свои — в /etc/ubuntu-bootstrap/profiles.d/<имя>.conf.
EOT
}

cmd_run() {
    local p f
    if [[ -n ${1-} ]]; then
        f="$(profile_file "$1")" || die "профиль не найден: $1"
        printf '# %s\n' "$f"
        cat "$f"
        return 0
    fi
    for p in $(profiles_list); do
        f="$(profile_file "$p")"
        printf '%s%-10s%s %s\n' "$C_BOLD" "$p" "$C_RESET" "$(grep -m1 '^# ' "$f" | sed 's/^# //')"
        printf '           модули: %s\n' "$(kv_get "$f" MODULES)"
    done
}
