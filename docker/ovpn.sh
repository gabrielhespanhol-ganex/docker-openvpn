#!/usr/bin/env bash
set -Eeuo pipefail

readonly OPENVPN_DIR=/etc/openvpn
readonly EASYRSA_PKI=/etc/openvpn/pki
readonly CLIENT_DIR=/etc/openvpn/clients
readonly CA_CN='Ganex OpenVPN DCO CA'
readonly CA_CERT_DAYS=7300
readonly SERVER_CERT_DAYS=3650
readonly CLIENT_CERT_DAYS=3650
readonly CRL_DAYS=3650

VPN_PORT="${VPN_PORT:-1194}"
VPN_INTERFACE="${VPN_INTERFACE:-ovpn0}"
VPN_SUBNET="${VPN_SUBNET:-10.8.0.0}"
VPN_NETMASK="${VPN_NETMASK:-255.255.255.0}"
VPN_DNS_1="${VPN_DNS_1:-1.1.1.1}"
VPN_DNS_2="${VPN_DNS_2:-1.0.0.1}"
VPN_TUN_MTU="${VPN_TUN_MTU:-1400}"
MAX_CLIENTS="${MAX_CLIENTS:-25}"
SERVER_CN="${VPN_ENDPOINT:-}"

export EASYRSA_PKI VPN_PORT VPN_INTERFACE VPN_SUBNET VPN_NETMASK
export VPN_DNS_1 VPN_DNS_2 VPN_TUN_MTU MAX_CLIENTS SERVER_CN

required() {
    local name
    for name in "$@"; do
        [[ -n "${!name:-}" ]] || {
            echo "Variavel obrigatoria ausente: $name" >&2
            exit 1
        }
    done
}

valid_name() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || {
        echo "Nome invalido: ${1:-vazio}" >&2
        exit 1
    }
}

valid_endpoint() {
    local endpoint="${1:-}"
    [[ "$endpoint" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,251}[A-Za-z0-9]$ ]] || {
        echo "VPN_ENDPOINT invalido: ${endpoint:-vazio}" >&2
        exit 1
    }
}

run_easyrsa() {
    local log_file
    log_file="$(mktemp)"
    if ! easyrsa --batch "$@" > "$log_file" 2>&1; then
        cat "$log_file" >&2
        rm -f "$log_file"
        return 1
    fi
    rm -f "$log_file"
}

certificate_summary() {
    local label="$1" cn="$2" cert="$3" days="$4"
    local created expires
    created="$(openssl x509 -in "$cert" -noout -startdate | cut -d= -f2-)"
    expires="$(openssl x509 -in "$cert" -noout -enddate | cut -d= -f2-)"
    printf '\n%s criado sem senha.\n' "$label"
    printf 'CN: %s\n' "$cn"
    printf 'Emitido em: %s\n' "$created"
    printf 'Expira em: %s\n' "$expires"
    printf 'Validade configurada: %s dias (10 anos)\n' "$days"
}

render() {
    required VPN_ENDPOINT VPN_PORT VPN_INTERFACE VPN_SUBNET VPN_NETMASK VPN_DNS_1 VPN_DNS_2 VPN_TUN_MTU MAX_CLIENTS SERVER_CN
    valid_endpoint "$VPN_ENDPOINT"
    valid_name "$VPN_INTERFACE"
    sed \
        -e "s|@VPN_PORT@|$VPN_PORT|g" \
        -e "s|@VPN_INTERFACE@|$VPN_INTERFACE|g" \
        -e "s|@VPN_SUBNET@|$VPN_SUBNET|g" \
        -e "s|@VPN_NETMASK@|$VPN_NETMASK|g" \
        -e "s|@VPN_DNS_1@|$VPN_DNS_1|g" \
        -e "s|@VPN_DNS_2@|$VPN_DNS_2|g" \
        -e "s|@VPN_TUN_MTU@|$VPN_TUN_MTU|g" \
        -e "s|@MAX_CLIENTS@|$MAX_CLIENTS|g" \
        -e "s|@SERVER_CN@|$SERVER_CN|g" \
        /opt/openvpn/openvpn.conf.template > "$OPENVPN_DIR/openvpn.conf"
    chmod 0644 "$OPENVPN_DIR/openvpn.conf"
    echo "Configuracao criada em $OPENVPN_DIR/openvpn.conf"
}

init_pki() {
    required VPN_ENDPOINT SERVER_CN
    valid_endpoint "$VPN_ENDPOINT"
    [[ ! -e "$EASYRSA_PKI/ca.crt" ]] || {
        echo "A PKI ja existe; a inicializacao nao sera repetida." >&2
        exit 1
    }
    if [[ -d "$EASYRSA_PKI" ]] && find "$EASYRSA_PKI" -mindepth 1 -print -quit | grep -q .; then
        echo "$EASYRSA_PKI contem dados; inicializacao cancelada." >&2
        exit 1
    fi

    mkdir -p "$OPENVPN_DIR" "$CLIENT_DIR"
    chmod 0755 "$OPENVPN_DIR"
    chmod 0700 "$CLIENT_DIR"

    export EASYRSA_BATCH=1
    export EASYRSA_REQ_CN="$CA_CN"
    export EASYRSA_CA_EXPIRE="$CA_CERT_DAYS"
    export EASYRSA_CERT_EXPIRE="$SERVER_CERT_DAYS"
    export EASYRSA_CRL_DAYS="$CRL_DAYS"

    run_easyrsa init-pki
    chmod 0755 "$EASYRSA_PKI"
    run_easyrsa build-ca nopass
    run_easyrsa build-server-full "$SERVER_CN" nopass
    run_easyrsa gen-crl
    openvpn --genkey tls-crypt "$EASYRSA_PKI/tls-crypt.key"

    chmod 0700 "$EASYRSA_PKI/private"
    chmod 0600 "$EASYRSA_PKI/private/ca.key" \
        "$EASYRSA_PKI/private/$SERVER_CN.key" \
        "$EASYRSA_PKI/tls-crypt.key"
    chmod 0644 "$EASYRSA_PKI/ca.crt" \
        "$EASYRSA_PKI/issued/$SERVER_CN.crt" \
        "$EASYRSA_PKI/crl.pem"

    render
    certificate_summary "Certificado do servidor" "$SERVER_CN" \
        "$EASYRSA_PKI/issued/$SERVER_CN.crt" "$SERVER_CERT_DAYS"
}

create_client() {
    local name="${1:-}" temp_cert
    required VPN_ENDPOINT VPN_PORT SERVER_CN VPN_TUN_MTU
    valid_endpoint "$VPN_ENDPOINT"
    valid_name "$name"
    [[ -f "$EASYRSA_PKI/ca.crt" ]] || {
        echo "PKI nao inicializada." >&2
        exit 1
    }
    [[ ! -e "$EASYRSA_PKI/issued/$name.crt" ]] || {
        echo "Cliente $name ja existe." >&2
        exit 1
    }

    export EASYRSA_BATCH=1
    export EASYRSA_CERT_EXPIRE="$CLIENT_CERT_DAYS"
    run_easyrsa build-client-full "$name" nopass

    temp_cert="$(mktemp)"
    openssl x509 -in "$EASYRSA_PKI/issued/$name.crt" -out "$temp_cert"
    umask 077
    {
        printf '%s\n' client 'dev tun' 'proto udp4' "remote $VPN_ENDPOINT $VPN_PORT" \
            'resolv-retry infinite' nobind 'remote-cert-tls server' \
            "verify-x509-name $SERVER_CN name" 'tls-version-min 1.2' \
            'data-ciphers AES-128-GCM:AES-256-GCM:?CHACHA20-POLY1305' \
            'allow-compression no' "tun-mtu $VPN_TUN_MTU" \
            'setenv opt block-outside-dns' 'verb 3' '<ca>'
        cat "$EASYRSA_PKI/ca.crt"
        printf '%s\n' '</ca>' '<cert>'
        cat "$temp_cert"
        printf '%s\n' '</cert>' '<key>'
        cat "$EASYRSA_PKI/private/$name.key"
        printf '%s\n' '</key>' '<tls-crypt>'
        cat "$EASYRSA_PKI/tls-crypt.key"
        printf '%s\n' '</tls-crypt>'
    } > "$CLIENT_DIR/$name.ovpn"
    rm -f "$temp_cert"

    chmod 0600 "$CLIENT_DIR/$name.ovpn"
    if [[ "${LOCAL_UID:-}" =~ ^[0-9]+$ && "${LOCAL_GID:-}" =~ ^[0-9]+$ ]]; then
        chown "$LOCAL_UID:$LOCAL_GID" "$CLIENT_DIR/$name.ovpn"
    fi

    certificate_summary "Certificado do cliente" "$name" \
        "$EASYRSA_PKI/issued/$name.crt" "$CLIENT_CERT_DAYS"
    echo "Perfil criado: $CLIENT_DIR/$name.ovpn"
}

revoke_client() {
    local name="${1:-}" remove_files="${2:-}"
    valid_name "$name"
    [[ -f "$EASYRSA_PKI/issued/$name.crt" ]] || {
        echo "Cliente nao encontrado: $name" >&2
        exit 1
    }
    export EASYRSA_BATCH=1
    export EASYRSA_CRL_DAYS="$CRL_DAYS"
    run_easyrsa revoke "$name"
    run_easyrsa gen-crl
    chmod 0644 "$EASYRSA_PKI/crl.pem"
    if [[ "$remove_files" == remove ]]; then
        rm -f "$EASYRSA_PKI/private/$name.key" \
            "$EASYRSA_PKI/reqs/$name.req" \
            "$EASYRSA_PKI/issued/$name.crt" \
            "$CLIENT_DIR/$name.ovpn"
    fi
    echo "Cliente revogado: $name"
}

list_clients() {
    [[ -f "$EASYRSA_PKI/index.txt" ]] || {
        echo "PKI nao inicializada." >&2
        exit 1
    }
    printf '%-12s %s\n' STATUS CLIENTE
    local cert name code status
    for cert in "$EASYRSA_PKI"/issued/*.crt; do
        [[ -e "$cert" ]] || continue
        name="$(basename "$cert" .crt)"
        [[ "$name" == "$SERVER_CN" ]] && continue
        code="$(awk -F '\t' -v cn="/CN=$name" '$6 == cn { print $1; exit }' "$EASYRSA_PKI/index.txt")"
        case "$code" in
            V) status=VALIDO ;;
            R) status=REVOGADO ;;
            E) status=EXPIRADO ;;
            *) status=INVALIDO ;;
        esac
        printf '%-12s %s\n' "$status" "$name"
    done
}

run_server() {
    required VPN_ENDPOINT SERVER_CN VPN_INTERFACE
    valid_endpoint "$VPN_ENDPOINT"
    openvpn --version | grep -q '\[DCO\]' || {
        echo "OpenVPN sem DCO." >&2
        exit 1
    }
    [[ -d /sys/module/ovpn ]] || {
        echo "Modulo ovpn nao carregado no host." >&2
        exit 1
    }
    for file in "$OPENVPN_DIR/openvpn.conf" \
        "$EASYRSA_PKI/ca.crt" \
        "$EASYRSA_PKI/issued/$SERVER_CN.crt" \
        "$EASYRSA_PKI/private/$SERVER_CN.key" \
        "$EASYRSA_PKI/crl.pem" \
        "$EASYRSA_PKI/tls-crypt.key"; do
        [[ -r "$file" ]] || {
            echo "Arquivo ausente: $file" >&2
            exit 1
        }
    done
    grep -Eiq '^[[:space:]]*(compress|comp-lzo|fragment|disable-dco)([[:space:]]|$)' "$OPENVPN_DIR/openvpn.conf" \
        && { echo "Configuracao incompativel com DCO." >&2; exit 1; }
    exec openvpn --config "$OPENVPN_DIR/openvpn.conf"
}

case "${1:-run}" in
    init) init_pki ;;
    render) render ;;
    client) create_client "${2:-}" ;;
    revoke) revoke_client "${2:-}" "${3:-}" ;;
    list) list_clients ;;
    version) openvpn --version ;;
    run) run_server ;;
    *) echo "Uso: ovpn {init|render|client|revoke|list|version|run}" >&2; exit 2 ;;
esac
