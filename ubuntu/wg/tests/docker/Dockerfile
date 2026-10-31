# Test node with a real systemd as PID 1: wg-quick@, systemd-run, drop-ins, journald, OpenSSH.
# Used by tests/systemd.sh. Containers run --privileged (systemd needs it in docker) but in
# their own network, mount and cgroup namespaces, so the host is not changed.
ARG BASE=ubuntu:24.04
FROM ${BASE}
ENV DEBIAN_FRONTEND=noninteractive container=docker
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      systemd systemd-sysv dbus iproute2 iptables wireguard-tools python3 procps kmod \
      ca-certificates util-linux iputils-ping openssh-server openssh-client sudo curl \
 && apt-get clean && rm -rf /var/lib/apt/lists/* \
 && find /etc/systemd/system /lib/systemd/system -path '*.wants/*' \
      \( -name '*getty*' -o -name '*udev*' -o -name 'systemd-resolved*' -o -name 'systemd-networkd*' \) -delete 2>/dev/null; true
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
