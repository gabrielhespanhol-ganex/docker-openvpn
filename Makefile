SHELL := /bin/bash
.SHELLFLAGS := -Eeuo pipefail -c
.ONESHELL:
.DEFAULT_GOAL := help

ifneq (,$(wildcard ./.env))
include .env
export
endif

OPENVPN_IMAGE ?= ganexcloud/openvpn-dco:2.7.5
VPN_INTERFACE := ovpn0
VPN_CIDR := 10.8.0.0/24
COMPOSE := docker compose --env-file .env

export OPENVPN_IMAGE

.PHONY: help init start stop restart add-client revoke-client remove-client list-clients logs status firewall check-env check-docker check-pki

help:
	@echo "Uso:"
	@echo "  init:          Baixa a imagem e cria a configuracao e a PKI"
	@echo "  start:         Inicia o servidor OpenVPN com DCO"
	@echo "  stop:          Para o servidor OpenVPN"
	@echo "  restart:       Reinicia o servidor OpenVPN"
	@echo "  add-client:    Cria um cliente sem senha"
	@echo "  revoke-client: Revoga um cliente e mantem seus arquivos"
	@echo "  remove-client: Revoga e remove os arquivos do cliente"
	@echo "  list-clients:  Lista os clientes"
	@echo "  logs:          Acompanha os logs do servidor"
	@echo "  status:        Exibe o estado do container"

init: check-env check-docker
	@test ! -e openvpn-data/conf/pki/ca.crt || { echo "A PKI ja existe; make init nao sera repetido."; exit 1; }
	@mkdir -p openvpn-data/conf download-configs
	@$(COMPOSE) pull openvpn
	@$(COMPOSE) run --rm --no-deps openvpn init
	@test -f openvpn-data/conf/pki/ca.crt || { echo "A PKI nao foi criada."; exit 1; }
	@test -f "openvpn-data/conf/pki/issued/$(VPN_ENDPOINT).crt" || { echo "O certificado do servidor nao foi criado."; exit 1; }
	@echo
	@echo "Configuracao inicial concluida. Proximo passo: make start"

start: check-env check-docker check-pki firewall
	@priv=sudo; [[ $$EUID -eq 0 ]] && priv='';
	@$$priv modprobe ovpn
	@$(COMPOSE) up -d --no-build openvpn
	@ready=0
	@for attempt in $$(seq 1 15); do
		logs="$$( $(COMPOSE) logs --no-color openvpn 2>&1 )"
		if echo "$$logs" | grep -q 'Initialization Sequence Completed'; then ready=1; break; fi
		sleep 1
	done
	@if [[ $$ready -ne 1 ]]; then echo "$$logs"; echo "OpenVPN nao inicializou."; exit 1; fi
	@if ! echo "$$logs" | grep -Eqi '(DCO device|ovpn-dco device|DCO version)'; then echo "$$logs"; echo "DCO nao confirmado."; exit 1; fi
	@echo "OpenVPN iniciado com DCO."

stop: check-env check-docker
	@$(COMPOSE) down
	@echo "OpenVPN parado."

restart: stop
	@$(MAKE) start

add-client: check-env check-docker check-pki
	@read -rp "Username: " username
	@if [[ ! "$$username" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$$ ]]; then echo "Username invalido."; exit 1; fi
	@$(COMPOSE) run --rm --no-deps -e LOCAL_UID=$$(id -u) -e LOCAL_GID=$$(id -g) openvpn client "$$username"
	@mkdir -p download-configs
	@cp "openvpn-data/conf/clients/$$username.ovpn" "download-configs/$$username.ovpn"
	@chmod 0600 "download-configs/$$username.ovpn"
	@echo "Credencial criada em download-configs/$$username.ovpn"

revoke-client: check-env check-docker check-pki
	@read -rp "Username: " username
	@if [[ ! "$$username" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$$ ]]; then echo "Username invalido."; exit 1; fi
	@$(COMPOSE) run --rm --no-deps openvpn revoke "$$username"

remove-client: check-env check-docker check-pki
	@read -rp "Username: " username
	@if [[ ! "$$username" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$$ ]]; then echo "Username invalido."; exit 1; fi
	@$(COMPOSE) run --rm --no-deps openvpn revoke "$$username" remove
	@rm -f "download-configs/$$username.ovpn"

list-clients: check-env check-docker check-pki
	@$(COMPOSE) run --rm --no-deps openvpn list

logs: check-env check-docker
	@$(COMPOSE) logs -f openvpn

status: check-env check-docker
	@$(COMPOSE) ps openvpn

firewall:
	@priv=sudo; [[ $$EUID -eq 0 ]] && priv=''
	@$$priv sysctl -q -w net.ipv4.ip_forward=1
	@egress=$$(ip -4 route show default | awk '{print $$5; exit}')
	@test -n "$$egress" || { echo "Interface IPv4 de saida nao encontrada."; exit 1; }
	@chain=FORWARD
	@$$priv iptables -nL DOCKER-USER >/dev/null 2>&1 && chain=DOCKER-USER
	@$$priv iptables -C $$chain -i "$(VPN_INTERFACE)" -o "$$egress" -s "$(VPN_CIDR)" -j ACCEPT 2>/dev/null || \
		$$priv iptables -I $$chain 1 -i "$(VPN_INTERFACE)" -o "$$egress" -s "$(VPN_CIDR)" -j ACCEPT
	@$$priv iptables -C $$chain -i "$$egress" -o "$(VPN_INTERFACE)" -d "$(VPN_CIDR)" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
		$$priv iptables -I $$chain 1 -i "$$egress" -o "$(VPN_INTERFACE)" -d "$(VPN_CIDR)" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
	@$$priv iptables -t nat -C POSTROUTING -s "$(VPN_CIDR)" -o "$$egress" -j MASQUERADE 2>/dev/null || \
		$$priv iptables -t nat -A POSTROUTING -s "$(VPN_CIDR)" -o "$$egress" -j MASQUERADE

check-env:
	@if [[ ! -f .env ]]; then echo "Arquivo .env ausente. Copie .env.example para .env."; exit 1; fi
	@if [[ -z "$(VPN_ENDPOINT)" ]]; then echo "Defina VPN_ENDPOINT no arquivo .env."; exit 1; fi
	@if [[ ! "$(VPN_ENDPOINT)" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,251}[A-Za-z0-9]$$ ]]; then echo "VPN_ENDPOINT invalido: $(VPN_ENDPOINT)"; exit 1; fi

check-docker:
	@command -v docker >/dev/null 2>&1 || { echo "Docker nao instalado. Execute primeiro o setup.sh."; exit 1; }
	@docker compose version >/dev/null 2>&1 || { echo "Docker Compose nao instalado. Execute primeiro o setup.sh."; exit 1; }
	@docker info >/dev/null 2>&1 || { echo "Docker indisponivel. Confirme o servico e o acesso ao grupo docker."; exit 1; }

check-pki:
	@test -f openvpn-data/conf/pki/ca.crt || { echo "PKI nao encontrada. Execute primeiro: make init"; exit 1; }
