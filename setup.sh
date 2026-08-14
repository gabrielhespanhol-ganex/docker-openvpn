#!/usr/bin/env bash
set -Eeuo pipefail

readonly INSTALL_DIR=/opt/openvpn-dco
readonly REPOSITORY_RAW_URL="${OPENVPN_DCO_RAW_URL:-https://raw.githubusercontent.com/ganexcloud/docker-openvpn/master}"
readonly COMPOSE_VERSION=v5.4.0
readonly OVPN_BACKPORTS_REPOSITORY=https://github.com/OpenVPN/ovpn-backports.git
readonly OVPN_BACKPORTS_REF=ovpn-net-next/main-7.1.0-rc3-2026080300
readonly OVPN_BACKPORTS_DIR=/usr/local/src/ovpn-backports

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Execute este script como root: sudo bash setup.sh" >&2
        exit 1
    fi
}

check_operating_system() {
    source /etc/os-release
    if [[ "${ID:-}" != amzn || "${VERSION_ID:-}" != 2023 ]]; then
        echo "Sistema suportado: Amazon Linux 2023." >&2
        exit 1
    fi
}

install_packages() {
    if ! command -v curl >/dev/null 2>&1; then
        dnf install -y curl-minimal
    fi

    dnf install -y \
        docker \
        ethtool \
        gcc \
        git \
        grubby \
        iproute \
        iptables-nft \
        make \
        openssl \
        procps-ng \
        tar \
        elfutils-libelf-devel \
        kernel6.18 \
        kernel6.18-modules-extra

    systemctl enable --now docker
}

install_compose() {
    local arch asset temp_dir
    if docker compose version >/dev/null 2>&1; then
        return
    fi

    case "$(uname -m)" in
        x86_64) arch=x86_64 ;;
        aarch64) arch=aarch64 ;;
        *) echo "Arquitetura nao suportada pelo Docker Compose." >&2; exit 1 ;;
    esac

    asset="docker-compose-linux-$arch"
    temp_dir="$(mktemp -d)"
    curl -fsSL \
        "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/$asset" \
        -o "$temp_dir/$asset"
    curl -fsSL \
        "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/$asset.sha256" \
        -o "$temp_dir/$asset.sha256"
    (cd "$temp_dir" && sha256sum -c "$asset.sha256")
    install -d -m 0755 /usr/local/lib/docker/cli-plugins
    install -m 0755 "$temp_dir/$asset" /usr/local/lib/docker/cli-plugins/docker-compose
    rm -rf "$temp_dir"
}

ensure_running_kernel() {
    local installed_kernel running_kernel
    installed_kernel="$(rpm -q kernel6.18 --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -n 1)"
    running_kernel="$(uname -r)"

    if [[ "$running_kernel" == "$installed_kernel" ]]; then
        return
    fi

    if [[ -f "/boot/vmlinuz-$installed_kernel" ]]; then
        grubby --set-default "/boot/vmlinuz-$installed_kernel"
    fi

    echo
    echo "O kernel $installed_kernel foi instalado, mas o servidor utiliza $running_kernel."
    echo "Reinicie a EC2 e execute novamente este mesmo script:"
    echo "  sudo reboot"
    echo "  sudo /opt/openvpn-dco/setup.sh"
    exit 20
}

install_ovpn_module() {
    local kernel_release
    kernel_release="$(uname -r)"

    if modprobe ovpn >/dev/null 2>&1; then
        return
    fi

    echo "O modulo ovpn nao esta no pacote do kernel; compilando o ovpn-backports oficial."
    dnf install -y \
        "kernel6.18-devel-$kernel_release" \
        "kernel6.18-headers-$kernel_release"

    install -d -m 0755 "$(dirname "$OVPN_BACKPORTS_DIR")"
    if [[ ! -d "$OVPN_BACKPORTS_DIR/.git" ]]; then
        git clone --depth 1 --branch "$OVPN_BACKPORTS_REF" \
            "$OVPN_BACKPORTS_REPOSITORY" "$OVPN_BACKPORTS_DIR"
    else
        git -C "$OVPN_BACKPORTS_DIR" fetch --depth 1 origin \
            "refs/tags/$OVPN_BACKPORTS_REF:refs/tags/$OVPN_BACKPORTS_REF"
        git -C "$OVPN_BACKPORTS_DIR" checkout --detach "$OVPN_BACKPORTS_REF"
    fi

    make -C "$OVPN_BACKPORTS_DIR" clean
    make -C "$OVPN_BACKPORTS_DIR"
    make -C "$OVPN_BACKPORTS_DIR" install
    depmod -a
    modprobe ovpn
}

configure_host() {
    printf '%s\n' 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-openvpn-dco.conf
    sysctl -q -w net.ipv4.ip_forward=1
    printf '%s\n' ovpn > /etc/modules-load.d/openvpn-dco.conf

    modprobe tun
    [[ -c /dev/net/tun ]] || {
        echo "Dispositivo /dev/net/tun nao encontrado." >&2
        exit 1
    }
    modinfo ovpn >/dev/null
}

download_runtime_files() {
    local file file_url temp_dir install_user install_group current_setup
    temp_dir="$(mktemp -d)"
    install -d -m 0755 "$INSTALL_DIR"

    current_setup="$(readlink -f "$0")"
    if [[ "$current_setup" != "$INSTALL_DIR/setup.sh" ]]; then
        install -m 0755 "$current_setup" "$INSTALL_DIR/setup.sh"
    fi

    for file in Makefile compose.yaml .env.example; do
        file_url="$REPOSITORY_RAW_URL/$file"
        if ! curl -fsSL "$file_url" -o "$temp_dir/$file"; then
            echo "Falha ao baixar $file." >&2
            echo "URL: $file_url" >&2
            echo "Confirme se os arquivos de runtime foram publicados no GitHub." >&2
            rm -rf "$temp_dir"
            exit 1
        fi
        install -m 0644 "$temp_dir/$file" "$INSTALL_DIR/$file"
    done

    if [[ ! -f "$INSTALL_DIR/.env" ]]; then
        install -m 0644 "$INSTALL_DIR/.env.example" "$INSTALL_DIR/.env"
    fi

    rm -rf "$temp_dir"

    install_user="${SUDO_USER:-root}"
    [[ "$install_user" == root ]] || id "$install_user" >/dev/null 2>&1 || install_user=root
    install_group="$(id -gn "$install_user")"
    chown "$install_user:$install_group" "$INSTALL_DIR" \
        "$INSTALL_DIR/setup.sh" \
        "$INSTALL_DIR/Makefile" \
        "$INSTALL_DIR/compose.yaml" \
        "$INSTALL_DIR/.env.example" \
        "$INSTALL_DIR/.env"

    if [[ "$install_user" != root ]]; then
        usermod -aG docker "$install_user"
    fi
}

install_firewall_service() {
    printf '%s\n' \
        '[Unit]' \
        'Description=Firewall OpenVPN DCO' \
        'Wants=network-online.target' \
        'After=docker.service network-online.target' \
        'ConditionPathExists=/opt/openvpn-dco/.env' \
        '' \
        '[Service]' \
        'Type=oneshot' \
        'RemainAfterExit=yes' \
        'ExecStart=/usr/bin/make -s -C /opt/openvpn-dco firewall' \
        '' \
        '[Install]' \
        'WantedBy=multi-user.target' \
        > /etc/systemd/system/openvpn-dco-firewall.service
    systemctl daemon-reload
    systemctl enable openvpn-dco-firewall.service
}

show_next_steps() {
    echo
    echo "Setup do host concluido."
    echo "Docker Compose: $(docker compose version --short)"
    echo "Modulo DCO: $(modinfo -F version ovpn)"
    echo
    echo "Proximos passos:"
    echo "  cd $INSTALL_DIR"
    echo "  vi .env"
    echo "  make init"
    echo "  make start"
    if [[ "${SUDO_USER:-root}" != root ]]; then
        echo
        echo "Reabra a sessao antes de executar o Makefile para atualizar o grupo docker."
    fi
}

main() {
    require_root
    check_operating_system
    install_packages
    install_compose
    download_runtime_files
    ensure_running_kernel
    install_ovpn_module
    configure_host
    install_firewall_service
    show_next_steps
}

main "$@"
