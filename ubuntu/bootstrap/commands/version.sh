# shellcheck shell=bash

CMD_SUMMARY='версия и источник установки'
CMD_GROUP=maintenance
CMD_ROOT=0

cmd_usage() { echo 'Использование: ubuntu-bootstrap version'; }

cmd_run() {
    if ((OPT_JSON)); then
        printf '{"version":%s,"home":%s,"repo":%s,"ref":%s,"commit":%s,"installed_at":%s}\n' \
            "$(json_str "$(ubb_version)")" "$(json_str "$UBB_HOME")" "$(json_str "$(install_meta REPO)")" \
            "$(json_str "$(install_meta REF)")" "$(json_str "$(install_meta COMMIT)")" "$(json_str "$(install_meta INSTALLED_AT)")"
        return 0
    fi
    printf 'ubuntu-bootstrap %s\n' "$(ubb_version)"
    printf '  каталог:   %s\n' "$UBB_HOME"
    if [[ -f $UBB_HOME/.install ]]; then
        printf '  источник:  %s@%s (%s)\n  установлен: %s\n' "$(install_meta REPO)" "$(install_meta REF)" "$(install_meta COMMIT)" "$(install_meta INSTALLED_AT)"
    else
        printf '  источник:  локальная копия (не через install.sh)\n'
    fi
}
