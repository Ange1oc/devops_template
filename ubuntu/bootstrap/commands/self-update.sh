# shellcheck shell=bash

CMD_SUMMARY='обновить ubuntu-bootstrap с GitHub'
CMD_GROUP=maintenance

cmd_usage() {
    cat <<'EOT'
Использование: ubuntu-bootstrap self-update [--ref REF] [--check]

  --ref REF   ветка, тег или commit (по умолчанию тот же, что при установке)
  --check     только показать, есть ли новая версия

Обновляется только программа; конфигурация, состояние и бэкапы не трогаются.
Откат: sudo /opt/ubuntu-bootstrap/install.sh --rollback
EOT
}

cmd_run() {
    local repo ref check=0 latest
    repo="$(install_meta REPO)"
    ref="$(install_meta REF)"
    while (($#)); do
        case $1 in
            --ref) require_arg "$@"; ref=$2; shift 2 ;;
            --check) check=1; shift ;;
            *) die_usage "неизвестный аргумент: $1" ;;
        esac
    done
    [[ -n $repo ]] || die "нет метаданных установки ($UBB_HOME/.install) — установи через install.sh"
    is_github_repo "$repo" && is_git_ref "$ref" || die 'повреждены метаданные установки'
    if ((check)); then
        latest="$(curl -fsSL --proto '=https' --max-time 15 "https://raw.githubusercontent.com/$repo/$ref/ubuntu/bootstrap/VERSION" 2>/dev/null)" || die 'не удалось получить VERSION из репозитория'
        printf 'установлено: %s, в %s@%s: %s\n' "$(ubb_version)" "$repo" "$ref" "$latest"
        [[ $latest == "$(ubb_version)" ]] && log_ok 'обновление не требуется' || log_info 'доступна другая версия: sudo ubuntu-bootstrap self-update'
        return 0
    fi
    exec bash "$UBB_HOME/install.sh" --repo "$repo" --ref "${ref:-main}"
}
