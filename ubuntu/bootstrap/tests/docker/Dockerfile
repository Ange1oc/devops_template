# Test image imitating a stock Ubuntu Server: systemd as PID 1, openssh-server, ufw, sudo, unattended-upgrades.
ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}
ARG UBUNTU_VERSION
ENV DEBIAN_FRONTEND=noninteractive container=docker
RUN apt-get update && apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus kmod iproute2 iputils-ping ca-certificates curl gnupg \
        openssh-server openssh-client sudo ufw iptables nftables python3 procps psmisc \
        apt-utils unattended-upgrades less vim-tiny rsyslog \
    && if apt-cache show kcov >/dev/null 2>&1; then apt-get install -y --no-install-recommends kcov; fi \
    && rm -rf /var/lib/apt/lists/* \
    && systemctl mask getty@tty1.service getty-static.service systemd-logind.service \
       console-getty.service systemd-udevd.service systemd-udev-trigger.service \
       systemd-networkd.service systemd-resolved.service e2scrub_reap.service \
    && rm -f /etc/ssh/ssh_host_*_key* \
    && mkdir -p /run/sshd
# The root password is known to the tests: they verify password login is impossible after hardening.
RUN echo 'root:rootpass' | chpasswd
STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd", "--system"]
