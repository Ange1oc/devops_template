# shellcheck shell=bash
# Module options and configuration.
#
# A module declares options in mod_options(): opt NAME TYPE DEFAULT 'help' [adv].
# Value precedence: --set KEY=VALUE > config file > profile > default.
# Config files are KEY=VALUE and are never sourced.

declare -gA OPT_TYPE=() OPT_DEFAULT=() OPT_HELP=() OPT_MODULE=() OPT_ADV=() CONF=() CONF_SOURCE=()
declare -ga OPT_ORDER=() SET_OVERRIDES=()
readonly CORE_KEYS=(PROFILE MODULES MODULES_ADD MODULES_SKIP)

# opt NAME TYPE DEFAULT HELP [adv]: adv options are asked by the wizard only in --advanced mode.
opt() {
    local name=$1 type=$2 default=$3 help=$4 flag=${5-}
    is_opt_name "$name" || die "внутренняя ошибка: некорректное имя опции $name"
    [[ -n ${OPT_TYPE[$name]-} ]] && die "внутренняя ошибка: опция $name объявлена дважды (${OPT_MODULE[$name]} и ${CUR_MODULE_LOAD-})"
    OPT_TYPE[$name]=$type OPT_DEFAULT[$name]=$default OPT_HELP[$name]=$help OPT_MODULE[$name]=${CUR_MODULE_LOAD:-core}
    OPT_ADV[$name]=$([[ $flag == adv ]] && printf 1 || printf 0)
    OPT_ORDER+=("$name")
}

# Wizard default: set only when the option has no value yet.
wiz_default() {
    [[ -n ${CONF[$1]+x} ]] || { CONF[$1]=$2; CONF_SOURCE[$1]=wizard; }
}

cfg() {
    [[ -n ${OPT_TYPE[$1]-} ]] || die "внутренняя ошибка: опция $1 не объявлена"
    printf '%s' "${CONF[$1]-${OPT_DEFAULT[$1]}}"
}

cfg_bool() {
    local v
    v="$(cfg "$1")"
    [[ $(to_bool "$v") == 1 ]]
}

# cfg_list NAME ARRAY
cfg_list() {
    local v
    v="$(cfg "$1")"
    split_list "$v" "$2"
}

opt_validate() {
    local name=$1 value=$2 type=${OPT_TYPE[$1]} item
    local -a items=()
    case $type in
        bool) is_bool "$value" ;;
        int) is_uint "$value" ;;
        port) is_port "$value" ;;
        portkeep) [[ $value == keep ]] || is_port "$value" ;;
        string) [[ $value != *$'\n'* ]] ;;
        list) [[ $value != *$'\n'* ]] ;;
        enum:*)
            local -a allowed=()
            IFS=, read -r -a allowed <<< "${type#enum:}"
            in_list "$value" "${allowed[@]}"
            ;;
        user) [[ -z $value ]] || is_username "$value" ;;
        path) [[ -z $value ]] || is_abs_path "$value" ;;
        size) [[ -z $value || $value == auto || $value == 0 ]] || is_size "$value" ;;
        email) [[ -z $value ]] || is_email "$value" ;;
        duration) is_duration "$value" ;;
        timezone) [[ -z $value ]] || is_timezone "$value" ;;
        hostname) [[ -z $value ]] || is_hostname "$value" ;;
        keys)
            [[ -z $value ]] && return 0
            while IFS= read -r item; do [[ -z $item ]] || is_ssh_pubkey "$item" || return 1; done <<< "${value//;/$'\n'}"
            ;;
        ports)
            split_list "$value" items
            for item in "${items[@]}"; do is_port_spec "$item" || return 1; done
            ;;
        cidrs)
            split_list "$value" items
            for item in "${items[@]}"; do is_ip_or_cidr "$item" || return 1; done
            ;;
        users)
            split_list "$value" items
            for item in "${items[@]}"; do is_username "$item" || return 1; done
            ;;
        hostnames)
            split_list "$value" items
            for item in "${items[@]}"; do is_hostname "$item" || return 1; done
            ;;
        *) die "внутренняя ошибка: неизвестный тип опции $type ($name)" ;;
    esac
}

opt_type_hint() {
    case ${OPT_TYPE[$1]} in
        bool) printf 'yes/no' ;;
        portkeep) printf 'порт или keep' ;;
        enum:*) printf '%s' "${OPT_TYPE[$1]#enum:}" | tr ',' '|' ;;
        keys) printf 'публичные ключи через ";"' ;;
        ports) printf 'порты через запятую, напр. 80/tcp,443/udp' ;;
        cidrs) printf 'IP или CIDR через запятую' ;;
        *) printf '%s' "${OPT_TYPE[$1]}" ;;
    esac
}

profile_file() {
    local name=$1 f
    is_name "$name" || die_usage "некорректное имя профиля: $name"
    for f in "$USER_PROFILES_DIR/$name.conf" "$UBB_HOME/profiles/$name.conf"; do
        [[ -f $f ]] && { printf '%s' "$f"; return 0; }
    done
    return 1
}

profiles_list() {
    local f
    for f in "$UBB_HOME"/profiles/*.conf "$USER_PROFILES_DIR"/*.conf; do
        [[ -f $f ]] || continue
        f=${f##*/}
        printf '%s\n' "${f%.conf}"
    done | sort -u
}

config_merge_file() {
    local file=$1 source=$2 key
    local -A kv=()
    kv_load "$file" kv || die "$file: ожидается формат KEY=VALUE, одна пара в строке"
    for key in "${!kv[@]}"; do
        CONF[$key]=${kv[$key]} CONF_SOURCE[$key]=$source
    done
}

# Build the configuration: profile -> file -> --set. Requires module options to be loaded.
# The profile comes from --profile, else from PROFILE= in the file.
config_load() {
    local kv key value profile=''
    CONF=() CONF_SOURCE=()
    [[ -n ${OPT_CONFIG_FILE-} ]] && { [[ -f $OPT_CONFIG_FILE ]] || die "нет файла конфига $OPT_CONFIG_FILE"; }
    local file=${OPT_CONFIG_FILE:-$CONF_FILE}
    profile=${OPT_PROFILE-}
    if [[ -z $profile && -f $file ]]; then
        profile="$(kv_get "$file" PROFILE)"
    fi
    if [[ -n $profile ]]; then
        local pf
        pf="$(profile_file "$profile")" || die "профиль не найден: $profile (см. ubuntu-bootstrap profiles)"
        config_merge_file "$pf" "profile:$profile"
        CONF[PROFILE]=$profile
    fi
    [[ -f $file ]] && config_merge_file "$file" "file:$file"
    for kv in "${SET_OVERRIDES[@]}"; do
        key=${kv%%=*} value=${kv#*=}
        is_opt_name "$key" || die_usage "--set: некорректное имя опции '$key'"
        CONF[$key]=$value CONF_SOURCE[$key]=cli
    done
    [[ -n ${OPT_PROFILE-} ]] && CONF[PROFILE]=$OPT_PROFILE
    config_validate
}

config_validate() {
    local key value
    for key in "${!CONF[@]}"; do
        value=${CONF[$key]}
        if in_list "$key" "${CORE_KEYS[@]}"; then
            case $key in
                PROFILE) [[ -z $value ]] || is_name "$value" || die "конфиг: некорректный PROFILE=$value" ;;
                MODULES | MODULES_ADD | MODULES_SKIP)
                    local -a items=()
                    local m
                    split_list "$value" items
                    for m in "${items[@]}"; do
                        [[ -n ${MOD_SUMMARY_OF[$m]-} ]] || die "конфиг: $key — неизвестный модуль '$m' (см. ubuntu-bootstrap modules)"
                    done
                    ;;
            esac
            continue
        fi
        [[ -n ${OPT_TYPE[$key]-} ]] || die "конфиг: неизвестная опция $key (источник: ${CONF_SOURCE[$key]}). Список: ubuntu-bootstrap config options"
        opt_validate "$key" "$value" || die "конфиг: $key=$value — ожидается $(opt_type_hint "$key") (источник: ${CONF_SOURCE[$key]})"
    done
}

# Modules from the config: MODULES (full list) or the default set, then + MODULES_ADD - MODULES_SKIP.
config_modules() {
    local -n _cm_out=$1
    local -a add=() skip=() base=()
    local m
    _cm_out=()
    if [[ -n ${CONF[MODULES]-} ]]; then
        split_list "${CONF[MODULES]}" base
    else
        base=("${MOD_DEFAULT_SET[@]}")
    fi
    split_list "${CONF[MODULES_ADD]-}" add
    split_list "${CONF[MODULES_SKIP]-}" skip
    for m in "${base[@]}" "${add[@]}"; do
        in_list "$m" "${skip[@]}" && continue
        in_list "$m" "${_cm_out[@]}" || _cm_out+=("$m")
    done
}

# config_save FILE MODULE...: core keys, then every option of the listed modules with its help text.
config_save() {
    local file=$1 name m
    local -a mods=()
    shift
    mods=("$@")
    {
        printf '# ubuntu-bootstrap %s — %s\n# Формат: KEY=VALUE, файл не исполняется. Пустое значение = умолчание модуля.\n\n' "$(ubb_version)" "$(now_iso)"
        if [[ -n ${CONF[PROFILE]-} ]]; then printf 'PROFILE=%s\n' "${CONF[PROFILE]}"; fi
        printf 'MODULES=%s\n' "$(join_by , "${mods[@]}")"
        for m in "${mods[@]}"; do
            printf '\n# [%s] %s\n' "$m" "${MOD_SUMMARY_OF[$m]-}"
            for name in "${OPT_ORDER[@]}"; do
                [[ ${OPT_MODULE[$name]} == "$m" ]] || continue
                printf '# %s (%s)\n%s=%s\n' "${OPT_HELP[$name]}" "$(opt_type_hint "$name")" "$name" "$(cfg "$name")"
            done
        done
    } | file_write "$file" 600
}

# config_save_explicit FILE: only the keys that are explicitly set (config set).
config_save_explicit() {
    local file=$1 key
    {
        printf '# ubuntu-bootstrap — обновлено %s\n' "$(now_iso)"
        for key in "${CORE_KEYS[@]}" "${OPT_ORDER[@]}"; do
            if [[ -n ${CONF[$key]+x} ]]; then printf '%s=%s\n' "$key" "${CONF[$key]}"; fi
        done
    } | file_write "$file" 600
}
