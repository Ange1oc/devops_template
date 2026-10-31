# shellcheck shell=bash
# Bash completion: commands from commands/, modules from modules/, profiles from profiles/.

_ubuntu_bootstrap() {
    local cur=${COMP_WORDS[COMP_CWORD]} prev=${COMP_WORDS[COMP_CWORD - 1]} home words='' i
    local -a pos=()
    home="$(dirname "$(readlink -f "$(command -v ubuntu-bootstrap)")")" || return
    for ((i = 1; i < COMP_CWORD; i++)); do
        case ${COMP_WORDS[i]} in
            -p | --profile | -c | --config | -s | --set | --only | --skip) ((i++)) ;;
            -*) ;;
            *) pos+=("${COMP_WORDS[i]}") ;;
        esac
    done
    case $prev in
        -p | --profile) words="$(cd "$home/profiles" && for f in *.conf; do printf '%s ' "${f%.conf}"; done)" ;;
        --only | --skip) words="$(cd "$home/modules" && for f in *.sh; do printf '%s ' "${f%.sh}"; done)" ;;
        -s | --set) words="$(grep -hoE '^\s+opt [A-Z0-9_]+' "$home"/modules/*.sh | awk '{ printf "%s= ", $2 }')" ;;
        -c | --config) mapfile -t COMPREPLY < <(compgen -f -- "$cur"); return ;;
    esac
    if [[ -z $words ]]; then
        if ((${#pos[@]} == 0)); then
            words="help $(cd "$home/commands" && for f in *.sh; do printf '%s ' "${f%.sh}"; done) --profile --config --set --only --skip --dry-run --yes --force --json --quiet"
        else
            case ${pos[0]} in
                modules) words="--options $(cd "$home/modules" && for f in *.sh; do printf '%s ' "${f%.sh}"; done)" ;;
                profiles) words="$(cd "$home/profiles" && for f in *.conf; do printf '%s ' "${f%.conf}"; done)" ;;
                config) words='show validate get set init path' ;;
                rollback) words="--pending --last --module $(find /var/lib/ubuntu-bootstrap/runs -mindepth 1 -maxdepth 1 -printf '%f ' 2>/dev/null)" ;;
                history) words="$(find /var/lib/ubuntu-bootstrap/runs -mindepth 1 -maxdepth 1 -printf '%f ' 2>/dev/null)" ;;
                apply) words='--reapply --profile --set --only --skip --yes --keep-going' ;;
                status | audit) words='--all --json' ;;
                wizard) words='--advanced' ;;
                self-update) words='--ref --check' ;;
            esac
        fi
    fi
    mapfile -t COMPREPLY < <(compgen -W "$words" -- "$cur")
}

complete -F _ubuntu_bootstrap ubuntu-bootstrap
