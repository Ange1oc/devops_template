# shellcheck shell=bash

CMD_SUMMARY='список модулей, зависимости и опции'
CMD_GROUP=inspect
CMD_ROOT=0

cmd_usage() {
    cat <<'EOT'
Использование: ubuntu-bootstrap modules [--options] [MODULE]

  без аргументов   таблица модулей: группа, набор по умолчанию, зависимости
  MODULE           подробно об одном модуле и его опциях
  --options        все опции всех модулей (имя, тип, умолчание, описание)
EOT
}

print_module_options() {
    local m=$1 name
    for name in "${OPT_ORDER[@]}"; do
        [[ ${OPT_MODULE[$name]} == "$m" ]] || continue
        printf '  %-28s %-26s %s\n' "$name" "[$(opt_type_hint "$name")] ${OPT_DEFAULT[$name]:-—}" "${OPT_HELP[$name]}"
    done
}

cmd_run() {
    local m first=1 all_opts=0
    [[ ${1-} == --options ]] && { all_opts=1; shift; }
    if ((OPT_JSON)); then
        printf '['
        for m in "${MOD_ALL[@]}"; do
            ((first)) || printf ','
            first=0
            printf '{"name":%s,"summary":%s,"group":%s,"default":%s,"deps":%s,"after":%s}' \
                "$(json_str "$m")" "$(json_str "${MOD_SUMMARY_OF[$m]}")" "$(json_str "${MOD_GROUP_OF[$m]}")" \
                "$(in_list "$m" "${MOD_DEFAULT_SET[@]}" && printf true || printf false)" \
                "$(json_str "${MOD_DEPS_OF[$m]}")" "$(json_str "${MOD_AFTER_OF[$m]}")"
        done
        printf ']\n'
        return 0
    fi
    if [[ -n ${1-} ]]; then
        m=$1
        [[ -n ${MOD_FILE_OF[$m]-} ]] || die "неизвестный модуль: $m"
        printf '%s%s%s — %s\n' "$C_BOLD" "$m" "$C_RESET" "${MOD_SUMMARY_OF[$m]}"
        printf '  группа: %s; зависимости: %s; после: %s; в контейнере: %s\n  файл: %s\n' \
            "${MOD_GROUP_OF[$m]}" "${MOD_DEPS_OF[$m]:-—}" "${MOD_AFTER_OF[$m]:-—}" \
            "$([[ ${MOD_CONTAINER_OF[$m]} == 1 ]] && echo да || echo нет)" "${MOD_FILE_OF[$m]}"
        printf '\nОпции:\n'
        print_module_options "$m"
        return 0
    fi
    if ((all_opts)); then
        for m in "${MOD_ALL[@]}"; do
            printf '\n%s[%s]%s %s\n' "$C_BOLD" "$m" "$C_RESET" "${MOD_SUMMARY_OF[$m]}"
            print_module_options "$m"
        done
        return 0
    fi
    printf '%-12s %-9s %-8s %-18s %s\n' МОДУЛЬ ГРУППА ДЕФОЛТ ЗАВИСИМОСТИ ОПИСАНИЕ
    for m in "${MOD_ALL[@]}"; do
        printf '%-12s %-9s %-8s %-18s %s\n' "$m" "${MOD_GROUP_OF[$m]}" \
            "$(in_list "$m" "${MOD_DEFAULT_SET[@]}" && echo да || echo -)" "${MOD_DEPS_OF[$m]:--}" "${MOD_SUMMARY_OF[$m]}"
    done
    printf '\nПодробнее: ubuntu-bootstrap modules <модуль>;  все опции: ubuntu-bootstrap modules --options\n'
}
