#!/usr/bin/env bash
#
# Install, update and remove wg-network.
#
#   curl -fsSL https://raw.githubusercontent.com/Ange1oc/devops_template/main/ubuntu/wg/install.sh | sudo bash
#
# The whole body is inside main(), so a truncated download through curl | bash runs nothing.

set -Eeuo pipefail

main() {
    local repo=${WGN_REPO:-Ange1oc/devops_template}
    local ref=${WGN_REF:-main}
    local subdir='ubuntu/wg'
    local install_dir='/opt/wg-network'
    local bin_link='/usr/local/bin/wg-network'
    local completion_link='/etc/bash_completion.d/wg-network'
    local mode=remote local_dir=''

    die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
    info() { printf '==> %s\n' "$*"; }

    usage() {
        cat <<'EOF'
Установка, обновление и удаление wg-network.

  curl -fsSL https://raw.githubusercontent.com/Ange1oc/devops_template/main/ubuntu/wg/install.sh | sudo bash
  curl -fsSL .../install.sh | sudo bash -s -- --ref v2.1.0   ветка, тег или commit
  sudo ./install.sh --local [DIR]                           из локальной копии репозитория
  sudo /opt/wg-network/install.sh --rollback                вернуть предыдущую версию
  sudo /opt/wg-network/install.sh --uninstall               удалить программу (сеть не трогается)

  --repo OWNER/REPO   другой репозиторий (форк)
  Приватный репозиторий: sudo GITHUB_TOKEN=... bash install.sh (нужен curl)
EOF
    }

    # Downloads the repository tarball and prints the path of the unpacked module.
    # The archive's top directory is owner-repo-<short sha>.
    fetch_remote() {
        local url="https://api.github.com/repos/$repo/tarball/$ref"
        local archive="$tmp/src.tar.gz" top
        local -a auth=()
        # The token goes through a header file, not argv: argv is visible to everyone in ps.
        if [[ -n ${GITHUB_TOKEN-} ]]; then
            (umask 077 && printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" > "$tmp/auth.header")
            auth=(--header "@$tmp/auth.header")
        fi

        info "Скачиваю $repo@$ref" >&2
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 "${auth[@]}" -o "$archive" "$url" ||
                die "не удалось скачать $url"
        elif command -v wget >/dev/null 2>&1; then
            [[ -z ${GITHUB_TOKEN-} ]] || die 'для GITHUB_TOKEN нужен curl'
            wget -q --https-only --tries=3 --timeout=15 -O "$archive" "$url" ||
                die "не удалось скачать $url"
        else
            die 'нужен curl или wget'
        fi

        top="$(tar -tzf "$archive" | awk -F/ 'NR == 1 { print $1 }')"
        [[ $top =~ ^[A-Za-z0-9._-]+$ ]] || die 'неожиданная структура архива'
        mkdir -p "$tmp/src"
        tar -xzf "$archive" -C "$tmp/src" --no-same-owner --no-same-permissions "$top/$subdir" ||
            die "в $repo@$ref нет папки $subdir"
        printf '%s' "$tmp/src/$top/$subdir"
    }

    install_tree() {
        local src=$1 staging="$install_dir.new" file

        [[ -f $src/wg-network && -d $src/lib && -d $src/commands ]] || die "$src не похож на wg-network"
        [[ -z $(find "$src" -type l -print -quit) ]] || die 'в исходниках есть симлинки — отказываюсь устанавливать'

        rm -rf "$staging"
        mkdir -p "$staging"
        cp -R "$src/." "$staging/"
        rm -rf "$staging/tests"
        chown -R root:root "$staging"
        find "$staging" -type d -exec chmod 755 {} +
        find "$staging" -type f -exec chmod 644 {} +
        chmod 755 "$staging/wg-network" "$staging/install.sh"

        while IFS= read -r -d '' file; do
            bash -n "$file" || die "синтаксическая ошибка в $file — установка отменена"
        done < <(find "$staging" -type f \( -name '*.sh' -o -name '*.bash' -o -name wg-network \) -print0)
        "$staging/wg-network" version >/dev/null || die 'новая версия не запускается — установка отменена'

        printf 'REPO=%s\nREF=%s\nCOMMIT=%s\nINSTALLED_AT=%s\n' \
            "$repo" "$ref" "$commit" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$staging/.install"

        if [[ -d $install_dir ]]; then
            rm -rf "$install_dir.old"
            mv "$install_dir" "$install_dir.old"
        fi
        mv "$staging" "$install_dir"
        link_files
    }

    has_systemd() {
        [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1
    }

    link_files() {
        local unit
        ln -sfn "$install_dir/wg-network" "$bin_link"
        if [[ -d ${completion_link%/*} ]]; then
            ln -sfn "$install_dir/completion/wg-network.bash" "$completion_link"
        fi
        has_systemd || return 0
        for unit in wg-network-reresolve.service wg-network-reresolve.timer; do
            install -m 644 "$install_dir/systemd/$unit" "/etc/systemd/system/$unit"
        done
        systemctl daemon-reload
        systemctl enable --quiet --now wg-network-reresolve.timer || info 'не удалось включить wg-network-reresolve.timer'
    }

    rollback() {
        [[ -d $install_dir.old ]] || die 'предыдущей версии нет'
        rm -rf "$install_dir.new"
        mv "$install_dir" "$install_dir.new"
        mv "$install_dir.old" "$install_dir"
        mv "$install_dir.new" "$install_dir.old"
        link_files
        info "Откат выполнен: $("$bin_link" --version | sed -n 1p)"
    }

    uninstall() {
        local f
        if has_systemd; then
            systemctl disable --quiet --now wg-network-reresolve.timer 2>/dev/null || true
            rm -f /etc/systemd/system/wg-network-reresolve.service /etc/systemd/system/wg-network-reresolve.timer
            for f in /etc/systemd/system/wg-quick@*.service.d/wg-network.conf; do
                [[ -f $f ]] || continue
                rm -f "$f"
                rmdir "${f%/*}" 2>/dev/null || true
            done
            systemctl daemon-reload
        fi
        rm -f "$bin_link" "$completion_link"
        rm -rf "$install_dir" "$install_dir.old" "$install_dir.new"
        info 'wg-network удалён. Интерфейсы продолжают работать: конфиги /etc/wireguard/*.conf самодостаточны.'
        info 'Состояние (ключи, peer, снимки) оставлено в /etc/wireguard/wg-network.'
    }

    while (($#)); do
        case $1 in
            --ref) [[ -n ${2-} ]] || die '--ref требует значение'; ref=$2; shift 2 ;;
            --repo) [[ -n ${2-} ]] || die '--repo требует значение'; repo=$2; shift 2 ;;
            --local)
                mode=local
                if [[ -n ${2-} && $2 != --* ]]; then
                    local_dir=$2
                    shift
                fi
                shift
                ;;
            --rollback) mode=rollback; shift ;;
            --uninstall) mode=uninstall; shift ;;
            -h | --help) usage; exit 0 ;;
            *) die "неизвестный аргумент: $1" ;;
        esac
    done

    [[ ${EUID:-$(id -u)} -eq 0 ]] || die 'нужны права root: запусти через sudo'
    ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))) || die 'нужен bash 4.4 или новее'
    [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "некорректный --repo: $repo"
    [[ $ref =~ ^[A-Za-z0-9._/-]+$ && $ref != *..* ]] || die "некорректный --ref: $ref"

    # Two concurrent installs would corrupt /opt/wg-network.new.
    local lockdir=/run/lock
    [[ -d $lockdir ]] || lockdir=/tmp
    exec 9> "$lockdir/wg-network-install.lock"
    flock -n 9 || die 'уже выполняется другая установка wg-network'

    case $mode in
        rollback) rollback; return ;;
        uninstall) uninstall; return ;;
    esac

    local tmp src commit=''
    tmp="$(mktemp -d)"
    # shellcheck disable=SC2064  # tmp is local: expand it now
    trap "rm -rf '$tmp'" EXIT

    if [[ $mode == local ]]; then
        src="$(cd "${local_dir:-$(dirname "${BASH_SOURCE[0]}")}" && pwd)"
        commit="local-$(git -C "$src" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    else
        src="$(fetch_remote)"
        commit="$(basename "$(dirname "$(dirname "$src")")")"
        commit=${commit##*-}
    fi

    install_tree "$src"
    info "Установлено: $("$bin_link" --version | sed -n 1p) ($commit) -> $bin_link"
    if [[ -f /etc/wireguard/wg-network/role.env ]]; then
        info 'Найдено состояние прежней версии: оно будет перенесено при первом запуске (sudo wg-network status)'
    elif compgen -G '/etc/wireguard/wg-network/*/node.env' >/dev/null; then
        info 'Состояние сети не менялось. Проверка: sudo wg-network doctor'
    else
        info 'Дальше: sudo wg-network help'
    fi
}

main "$@"
