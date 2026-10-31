# shellcheck shell=bash
# apt and snap: lock waiting, installs, deb822 repositories with key fingerprint verification.

readonly APT_ENV=(DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1)
readonly APT_OPTS=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
APT_UPDATED=0

apt_locked() {
    local f
    for f in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock; do
        [[ -e $f ]] && fuser "$f" >/dev/null 2>&1 && return 0
    done
    return 1
}

# unattended-upgrades may hold the lock for minutes right after boot.
apt_wait() {
    local waited=0 limit=${1:-300}
    while apt_locked; do
        ((waited == 0)) && log_info "apt/dpkg занят другим процессом — жду до ${limit} с"
        ((waited >= limit)) && die_code "$E_BUSY" 'apt/dpkg занят: проверь ps aux | grep -E "apt|dpkg|unattended"'
        sleep 5
        waited=$((waited + 5))
    done
}

apt_update() {
    ((APT_UPDATED)) && [[ ${1-} != --force ]] && return 0
    apt_wait
    run env "${APT_ENV[@]}" apt-get update -q || return 1
    APT_UPDATED=1
}

# Installs only what is missing; pkg=version pins a version and is always passed to apt.
apt_install() {
    local p
    local -a missing=()
    for p in "$@"; do
        pkg_installed "${p%%=*}" && [[ $p != *=* ]] && continue
        missing+=("$p")
    done
    ((${#missing[@]})) || return 0
    apt_update || return 1
    log_info "Устанавливаю пакеты: ${missing[*]}"
    apt_wait
    run env "${APT_ENV[@]}" apt-get install "${APT_OPTS[@]}" --no-install-recommends "${missing[@]}"
}

apt_remove() {
    local p
    local -a present=()
    for p in "$@"; do pkg_installed "$p" && present+=("$p"); done
    ((${#present[@]})) || return 0
    apt_wait
    run env "${APT_ENV[@]}" apt-get remove "${APT_OPTS[@]}" "${present[@]}"
}

apt_upgrade() {
    apt_update || return 1
    apt_wait
    run env "${APT_ENV[@]}" apt-get upgrade "${APT_OPTS[@]}" || return 1
    [[ ${1-} == --autoremove ]] && run env "${APT_ENV[@]}" apt-get autoremove "${APT_OPTS[@]}" --purge
    return 0
}

# Fingerprints of all keys in an ASCII-armored or binary keyring.
key_fingerprints() {
    gpg --batch --quiet --show-keys --with-colons --with-fingerprint "$1" 2>/dev/null | awk -F: '$1 == "fpr" { print $10 }'
}

# apt_repo_add NAME URL SUITE COMPONENTS KEY_URL EXPECTED_FPR
# The key is fetched over TLS and its fingerprint compared with the vendor's before anything is written.
apt_repo_add() {
    local name=$1 url=$2 suite=$3 comps=$4 key_url=$5 fpr=$6
    local keyring="/etc/apt/keyrings/$name.asc" tmp
    tmp="$(make_tmp_dir)"
    install -d -m 755 /etc/apt/keyrings
    if ! fetch_url "$key_url" "$tmp/key"; then
        log_error "не удалось скачать ключ $key_url"
        return 1
    fi
    if ! key_fingerprints "$tmp/key" | grep -qx "$fpr"; then
        log_error "отпечаток ключа $name не совпал с ожидаемым $fpr: $(key_fingerprints "$tmp/key" | tr '\n' ' ')"
        return 1
    fi
    if ! grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$tmp/key"; then
        gpg --batch --quiet --enarmor < "$tmp/key" | sed 's/ARMORED FILE/PUBLIC KEY BLOCK/' > "$tmp/key.asc" && mv "$tmp/key.asc" "$tmp/key"
    fi
    file_write "$keyring" 644 < "$tmp/key"
    # A legacy one-line .list next to the deb822 file would duplicate the source.
    [[ -f /etc/apt/sources.list.d/$name.list ]] && file_remove "/etc/apt/sources.list.d/$name.list"
    file_write "/etc/apt/sources.list.d/$name.sources" 644 <<EOT
Types: deb
URIs: $url
Suites: $suite
Components: $comps
Architectures: $F_ARCH
Signed-By: $keyring
EOT
    [[ ${FILE_CHANGED:-0} == 1 ]] && APT_UPDATED=0
    return 0
}

# HTTPS download with retries; plain http and redirects to http are refused.
fetch_url() {
    local url=$1 dest=$2
    if has_cmd curl; then
        curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 120 -o "$dest" "$url"
    elif has_cmd wget; then
        wget -q --https-only --secure-protocol=TLSv1_2 --tries=3 --timeout=15 -O "$dest" "$url"
    else
        log_error 'нужен curl или wget'
        return 1
    fi
}

snap_usable() {
    has_cmd snap && ((F_HAS_SYSTEMD)) && ((F_CONTAINER == 0))
}

snap_install() {
    local name=$1
    shift
    snap list "$name" >/dev/null 2>&1 && return 0
    run snap install "$@" "$name"
}
