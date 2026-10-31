# shellcheck shell=bash
# Bash completion: command names come from commands/, options from each command's parser.

_wg_network() {
    local cur=${COMP_WORDS[COMP_CWORD]} home words='' file i
    local global='--interface --dry-run --apply --no-apply --yes --force --wait-confirm --confirm-timeout --diff --quiet --no-color --help'
    local -a pos=()
    home="$(dirname "$(readlink -f "$(command -v wg-network)")")" || return

    for ((i = 1; i < COMP_CWORD; i++)); do
        case ${COMP_WORDS[i]} in
            -i | --interface | --confirm-timeout) ((i++)) ;;
            -*) ;;
            *) pos+=("${COMP_WORDS[i]}") ;;
        esac
    done

    case ${COMP_WORDS[COMP_CWORD - 1]} in
        -i | --interface)
            words="$(find /etc/wireguard/wg-network -mindepth 2 -maxdepth 2 -name node.env -printf '%h\n' 2>/dev/null | sed 's|.*/||')"
            mapfile -t COMPREPLY < <(compgen -W "$words" -- "$cur")
            return
            ;;
    esac

    if ((${#pos[@]} == 0)); then
        # A prefix shared by several commands ("peer add", "peer list") completes as the group.
        words="help $(cd "$home/commands" && for f in *.sh; do
            f=${f%.sh}
            set -- "${f%%-*}"-*.sh
            if [[ $f == *-* ]] && (($# > 1)); then echo "${f%%-*}"; else echo "$f"; fi
        done | sort -u)"
        [[ $cur == -* ]] && words=$global
    elif ((${#pos[@]} == 1)) && compgen -G "$home/commands/${pos[0]}-*.sh" >/dev/null; then
        words="$(cd "$home/commands" && for f in "${pos[0]}"-*.sh; do f=${f%.sh}; printf '%s ' "${f#*-}"; done)"
    else
        file="$home/commands/${pos[0]}-${pos[1]-}.sh"
        [[ -f $file ]] || file="$home/commands/${pos[0]}.sh"
        [[ -f $file ]] && words="$(grep -oE '^\s+--[a-z0-9-]+( \|)?' "$file" | tr -d ' |' | sort -u)"
        words+=" $global"
    fi
    mapfile -t COMPREPLY < <(compgen -W "$words" -- "$cur")
}

complete -F _wg_network wg-network
