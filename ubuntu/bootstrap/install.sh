#!/usr/bin/env bash
#
# Install, update, roll back or remove ubuntu-bootstrap. Safe for `curl | bash`: the whole body is
# inside main(), so a truncated download executes nothing. Only HTTPS/TLS 1.2+ is used; release tags
# are verified against SHA256SUMS (and its GPG signature when UBB_SIGNING_KEY_FPR is set); every file
# passes `bash -n`; the install directory is swapped atomically.

set -Eeuo pipefail

main() {
    local repo=${UBB_REPO:-Ange1oc/devops_template}
    local ref=${UBB_REF:-main}
    local subdir='ubuntu/bootstrap'
    local install_dir='/opt/ubuntu-bootstrap'
    local bin_link='/usr/local/bin/ubuntu-bootstrap'
    local completion_link='/etc/bash_completion.d/ubuntu-bootstrap'
    local unit='ubuntu-bootstrap-recover.service'
    local signing_key_fpr=${UBB_SIGNING_KEY_FPR:-}
    local mode=remote local_dir='' sha256='' run_after=0 purge=0 require_sig=0

    die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
    info() { printf '==> %s\n' "$*" >&2; }

    usage() {
        cat <<'EOT'
Установка, обновление, откат и удаление ubuntu-bootstrap.

  curl -fsSL https://raw.githubusercontent.com/Ange1oc/devops_template/main/ubuntu/bootstrap/install.sh | sudo bash
  curl -fsSL .../install.sh | sudo bash -s -- --ref ubuntu-bootstrap-v1.0.0   релиз (проверка SHA256SUMS)
  curl -fsSL .../install.sh | sudo bash -s -- --ref <commit sha>              воспроизводимо
  curl -fsSL .../install.sh | sudo bash -s -- --run                           установить и сразу запустить мастер
  sudo ./install.sh --local                                                   из локальной копии репозитория
  sudo /opt/ubuntu-bootstrap/install.sh --rollback                            вернуть предыдущую версию
  sudo /opt/ubuntu-bootstrap/install.sh --uninstall [--purge]                 удалить (--purge: и состояние/конфиг)

Опции: --ref REF | --repo OWNER/REPO | --sha256 HASH | --require-signature | --run | --local [DIR] | --rollback | --uninstall [--purge]
Переменные: UBB_REPO, UBB_REF, UBB_SIGNING_KEY_FPR (отпечаток ключа подписи релизов), GITHUB_TOKEN (приватный репозиторий)
EOT
    }

    download() {
        local url=$1 dest=$2
        local -a auth=()
        [[ -n ${GITHUB_TOKEN-} ]] && auth=(--header "Authorization: Bearer $GITHUB_TOKEN")
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 300 "${auth[@]}" -o "$dest" "$url"
        elif command -v wget >/dev/null 2>&1; then
            wget -q --https-only --secure-protocol=TLSv1_2 --tries=3 --timeout=15 "${auth[@]}" -O "$dest" "$url"
        else
            die 'нужен curl или wget'
        fi
    }

    # Release tag ubuntu-bootstrap-vX.Y.Z: tarball and SHA256SUMS from GitHub Releases.
    fetch_release() {
        local tag=$1 ver=${1#ubuntu-bootstrap-v} sums base
        base="https://github.com/$repo/releases/download/$tag"
        download "$base/ubuntu-bootstrap-$ver.tar.gz" "$tmp/src.tar.gz" || return 1
        download "$base/SHA256SUMS" "$tmp/SHA256SUMS" || die "у релиза $tag нет SHA256SUMS"
        sums="$(awk -v f="ubuntu-bootstrap-$ver.tar.gz" '$2 == f { print $1 }' "$tmp/SHA256SUMS")"
        [[ -n $sums ]] || die 'SHA256SUMS не содержит записи об архиве'
        [[ $(sha256sum "$tmp/src.tar.gz" | cut -d' ' -f1) == "$sums" ]] || die 'SHA256 архива не совпадает с SHA256SUMS — установка отменена'
        info 'SHA256 архива совпадает с SHA256SUMS'
        if [[ -n $signing_key_fpr ]] || ((require_sig)); then
            download "$base/SHA256SUMS.asc" "$tmp/SHA256SUMS.asc" || die 'у релиза нет подписи SHA256SUMS.asc'
            [[ -n $signing_key_fpr ]] || die '--require-signature: не задан UBB_SIGNING_KEY_FPR'
            command -v gpg >/dev/null || die 'для проверки подписи нужен gpg'
            local gh="$tmp/gnupg"
            mkdir -p "$gh" && chmod 700 "$gh"
            gpg --homedir "$gh" --batch --quiet --keyserver hkps://keys.openpgp.org --recv-keys "$signing_key_fpr" 2>/dev/null ||
                die "не удалось получить ключ $signing_key_fpr"
            gpg --homedir "$gh" --batch --status-fd 1 --verify "$tmp/SHA256SUMS.asc" "$tmp/SHA256SUMS" 2>/dev/null |
                grep -q "VALIDSIG $signing_key_fpr" || die 'подпись SHA256SUMS не прошла проверку'
            info 'подпись релиза проверена'
        fi
        mkdir -p "$tmp/src"
        tar -xzf "$tmp/src.tar.gz" -C "$tmp/src" --no-same-owner --no-same-permissions || die 'повреждённый архив'
        printf '%s' "$tmp/src/ubuntu-bootstrap"
    }

    # Repository archive for a branch, tag or commit; with GITHUB_TOKEN via the API (private repos).
    fetch_archive() {
        local url top
        if [[ -n ${GITHUB_TOKEN-} ]]; then url="https://api.github.com/repos/$repo/tarball/$ref"; else url="https://github.com/$repo/archive/$ref.tar.gz"; fi
        info "Скачиваю $repo@$ref"
        download "$url" "$tmp/src.tar.gz" || die "не удалось скачать $url"
        if [[ -n $sha256 ]]; then
            [[ $(sha256sum "$tmp/src.tar.gz" | cut -d' ' -f1) == "$sha256" ]] || die 'SHA256 архива не совпадает с --sha256 — установка отменена'
            info 'SHA256 архива совпадает'
        fi
        top="$(tar -tzf "$tmp/src.tar.gz" | awk -F/ 'NR == 1 { print $1 }')"
        [[ $top =~ ^[A-Za-z0-9._-]+$ ]] || die 'неожиданная структура архива'
        mkdir -p "$tmp/src"
        tar -xzf "$tmp/src.tar.gz" -C "$tmp/src" --no-same-owner --no-same-permissions "$top/$subdir" || die "в $repo@$ref нет папки $subdir"
        printf '%s' "$tmp/src/$top/$subdir"
    }

    install_tree() {
        local src=$1 staging="$install_dir.new" file
        [[ -f $src/ubuntu-bootstrap && -d $src/lib && -d $src/modules && -d $src/commands ]] || die "$src не похож на ubuntu-bootstrap"
        # tests/ is not installed and may hold kcov reports with symlinks.
        [[ -z $(find "$src" -path "$src/tests" -prune -o -type l -print -quit) ]] || die 'в исходниках есть симлинки — отказываюсь устанавливать'
        rm -rf "$staging"
        mkdir -p "$staging"
        cp -R "$src/." "$staging/"
        rm -rf "$staging/tests" "$staging/.git"
        chown -R root:root "$staging"
        find "$staging" -type d -exec chmod 755 {} +
        find "$staging" -type f -exec chmod 644 {} +
        chmod 755 "$staging/ubuntu-bootstrap" "$staging/install.sh"
        while IFS= read -r -d '' file; do
            bash -n "$file" || die "синтаксическая ошибка в $file — установка отменена"
        done < <(find "$staging" -type f \( -name '*.sh' -o -name '*.bash' -o -name ubuntu-bootstrap \) -print0)
        "$staging/ubuntu-bootstrap" --no-color version >/dev/null || die 'новая версия не запускается — установка отменена'
        printf 'REPO=%s\nREF=%s\nCOMMIT=%s\nINSTALLED_AT=%s\n' "$repo" "$ref" "$commit" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$staging/.install"
        if [[ -d $install_dir ]]; then
            rm -rf "$install_dir.old"
            mv "$install_dir" "$install_dir.old"
        fi
        mv "$staging" "$install_dir"
        link_files
    }

    has_systemd() { [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; }

    link_files() {
        ln -sfn "$install_dir/ubuntu-bootstrap" "$bin_link"
        [[ -d ${completion_link%/*} ]] && ln -sfn "$install_dir/completion/ubuntu-bootstrap.bash" "$completion_link"
        has_systemd || return 0
        install -m 644 "$install_dir/systemd/$unit" "/etc/systemd/system/$unit"
        systemctl daemon-reload
        systemctl enable --quiet "$unit" 2>/dev/null || info "не удалось включить $unit"
    }

    rollback() {
        [[ -d $install_dir.old ]] || die 'предыдущей версии нет'
        rm -rf "$install_dir.new"
        mv "$install_dir" "$install_dir.new"
        mv "$install_dir.old" "$install_dir"
        mv "$install_dir.new" "$install_dir.old"
        link_files
        info "Откат выполнен: $("$bin_link" --no-color version | head -1)"
    }

    uninstall() {
        if has_systemd; then
            systemctl disable --quiet "$unit" 2>/dev/null || true
            rm -f "/etc/systemd/system/$unit"
            systemctl daemon-reload
        fi
        rm -f "$bin_link" "$completion_link"
        rm -rf "$install_dir" "$install_dir.old" "$install_dir.new"
        if ((purge)); then
            rm -rf /etc/ubuntu-bootstrap /var/lib/ubuntu-bootstrap /var/log/ubuntu-bootstrap /var/backups/ubuntu-bootstrap
            info 'ubuntu-bootstrap, конфигурация, состояние, логи и бэкапы удалены. Настроенные сервисы продолжают работать.'
        else
            info 'ubuntu-bootstrap удалён. Конфигурация и бэкапы оставлены в /etc/ubuntu-bootstrap, /var/lib/ubuntu-bootstrap, /var/backups/ubuntu-bootstrap.'
        fi
    }

    while (($#)); do
        case $1 in
            --ref) [[ -n ${2-} ]] || die '--ref требует значение'; ref=$2; shift 2 ;;
            --repo) [[ -n ${2-} ]] || die '--repo требует значение'; repo=$2; shift 2 ;;
            --sha256) [[ ${2-} =~ ^[0-9a-f]{64}$ ]] || die '--sha256 требует 64 hex-символа'; sha256=$2; shift 2 ;;
            --require-signature) require_sig=1; shift ;;
            --run) run_after=1; shift ;;
            --local)
                mode=local
                if [[ -n ${2-} && $2 != --* ]]; then local_dir=$2; shift; fi
                shift
                ;;
            --rollback) mode=rollback; shift ;;
            --uninstall) mode=uninstall; shift ;;
            --purge) purge=1; shift ;;
            -h | --help) usage; exit 0 ;;
            *) die "неизвестный аргумент: $1" ;;
        esac
    done

    [[ ${EUID:-$(id -u)} -eq 0 ]] || die 'нужны права root: запусти через sudo'
    ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))) || die 'нужен bash 4.4 или новее'
    [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "некорректный --repo: $repo"
    [[ $ref =~ ^[A-Za-z0-9._/-]+$ && $ref != *..* ]] || die "некорректный --ref: $ref"

    case $mode in
        rollback) rollback; return ;;
        uninstall) uninstall; return ;;
    esac

    local tmp src commit=''
    tmp="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT

    if [[ $mode == local ]]; then
        src="$(cd "${local_dir:-$(dirname "${BASH_SOURCE[0]}")}" && pwd)"
        commit="local-$(git -C "$src" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    elif [[ $ref == ubuntu-bootstrap-v* ]] && src="$(fetch_release "$ref")"; then
        commit="release"
    else
        src="$(fetch_archive)"
        commit="$(basename "$(dirname "$(dirname "$src")")")"
        commit=${commit##*-}
        [[ ${#commit} -ge 40 ]] && commit=${commit:0:12}
    fi

    install_tree "$src"
    info "Установлено: $("$bin_link" --no-color version | head -1) ($commit) -> $bin_link"
    if ((run_after)); then
        exec "$bin_link" wizard
    elif [[ -f /etc/ubuntu-bootstrap/bootstrap.conf ]]; then
        info 'Конфигурация уже есть. Проверить и применить: sudo ubuntu-bootstrap plan && sudo ubuntu-bootstrap apply'
    else
        info 'Дальше: sudo ubuntu-bootstrap wizard   (или: sudo ubuntu-bootstrap apply --profile minimal --set ADMIN_USER=deploy --set ADMIN_SSH_KEYS="ssh-ed25519 ..." --yes)'
    fi
}

main "$@"
