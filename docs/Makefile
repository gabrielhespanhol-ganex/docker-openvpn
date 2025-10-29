# This makefile help users to use and maintain OpenVPN server configs.
# All variables are defined on .env file, see .env.example to display options.

# Script
SHELL:=/bin/bash
ifneq (,$(wildcard ./.env))
    include .env
    export
endif

.PHONY: help
help:
	@echo Use:
	@echo '  start: To start a OpenVPN server'
	@echo '  stop: To stop a OpenVPN server'
	@echo '  init-config: Generate a initial config'
	@echo '  add-client: Add a new client'
	@echo '  revoke-client: Revoke keys but maintain files'
	@echo '  remove-client: Revoke and remove client keys'
	@echo '  list-clients: List clients'
	@echo '  send-credential: Send credential zip file to email address'
	@echo ''

# Install Docker and docker-compose
.PHONY: install-docker
install-docker:
	@yum install -y docker
	@service docker start
	@systemctl enable docker.service
	@curl -L https://github.com/docker/compose/releases/download/v2.5.0/docker-compose-`uname -s`-`uname -m` | tee /usr/local/bin/docker-compose > /dev/null
	@chmod +x /usr/local/bin/docker-compose
	@ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
	@echo "Docker installed with sucess!"

# Generate initial configs
.PHONY: init-config
init-config:
	@mkdir -p ${OPENVPN_ROOTDIR}; \
	cd ${OPENVPN_ROOTDIR}; \
	if [[ -d "openvpn-data/" ]]; then echo "Directory openvpn-data already exists, impossible to continue."; exit 1; fi
	wget -q https://raw.githubusercontent.com/ganexcloud/docker-openvpn/master/docs/docker-compose.yml; \
	docker-compose run --rm openvpn ovpn_genconfig -u udp://${OPENVPN_ADDRESS} -s ${OPENVPN_SERVER_SUBNET} -r ${OPENVPN_ROUTE} -p ${OPENVPN_PUSH} -n ${OPENVPN_DNSSERVER}; \
	docker-compose run --rm -e EASYRSA_BATCH=1 -e EASYRSA_REQ_CN=${OPENVPN_ADDRESS} -e EASYRSA_CA_EXPIRE="${KEY_EXPIRE}" -e EASYRSA_CERT_EXPIRE="${KEY_EXPIRE}" -e EASYRSA_REQ_COUNTRY="${KEY_COUNTRY}" -e KEY_PROVINCE="${EASYRSA_REQ_PROVINCE}" -e EASYRSA_REQ_CITY="${KEY_CITY}" -e EASYRSA_REQ_ORG="${KEY_ORG}" -e EASYRSA_REQ_EMAIL="${KEY_EMAIL}" -e EASYRSA_REQ_OU="${KEY_OU}" openvpn ovpn_initpki nopass
	@echo "OpenVPN configurations created with sucess!"

# Start OpenVPN
.PHONY: start
start:
	@cd ${OPENVPN_ROOTDIR}
	@docker-compose up -d
	@echo "OpenVPN started!"

# Stop OpenVPN
.PHONY: stop
stop: 
	@cd ${OPENVPN_ROOTDIR}
	@docker-compose down
	@echo "OpenVPN stopped!"

# Create client configs
.PHONY: add-client
add-client:
	@read -p "Username: " USERNAME; \
	cd ${OPENVPN_ROOTDIR}; \
	mkdir -p download-configs; \
	docker-compose run --rm openvpn bash -c "export EASYRSA_CERT_EXPIRE=3650 && easyrsa build-client-full $${USERNAME} nopass"; \
	docker-compose run --rm openvpn ovpn_getclient $${USERNAME} > download-configs/$${USERNAME}.ovpn; \
	echo ${README} > /tmp/README.md; \
	zip -jqr download-configs/$${USERNAME}.zip download-configs/$${USERNAME}.ovpn /tmp/README.md; \
	echo  -n "Send zip file with credentials to email? [y/N] " && read SEND_EMAIL; \
	if [[ $$SEND_EMAIL =~ ^[Yy]$$ ]]; then \
		read -p "Email address: " EMAIL; \
		if [[ ! -f "send-email.py" ]]; then wget -q https://raw.githubusercontent.com/ganexcloud/docker-openvpn/master/tools/send-email.py; fi; \
		python3 send-email.py $${SMTP_HOST} $${SMTP_PORT} $${SMTP_USER} $${SMTP_PASSWORD} $${SMTP_TLS_ENABLED} $${USERNAME} $${EMAIL_FROM} $${EMAIL} 2> /dev/null; \
		if [[ $? -eq 0 ]]; then \
			echo "Email was sent successfully!" ;\
		else \
			echo "There was a problem sending the email, check your smtp settings." ;\
			exit 1 ;\
		fi ;\
	else \
		echo "Credentials created with success, the zip file with credentials are on ${OPENVPN_ROOTDIR}/download-configs/$${USERNAME}.zip" ;\
	fi ;\

# Revoke client
.PHONY: revoke-client
revoke-client:
	@read -p "Username: " USERNAME; \
	cd ${OPENVPN_ROOTDIR} ; \
	docker-compose run --rm openvpn ovpn_revokeclient $${USERNAME}; \
	echo "Client $${USERNAME} revoked with success!"

# Remove client
.PHONY: remove-client
remove-client:
	@read -p "Username: " USERNAME; \
	cd ${OPENVPN_ROOTDIR} ; \
	docker-compose run --rm openvpn ovpn_revokeclient $${USERNAME} remove; \
	echo "Client $${USERNAME} removed with success!"

# List clients
.PHONY: list-clients
list-clients:
	@cd ${OPENVPN_ROOTDIR} ; \
	docker-compose run --rm openvpn ovpn_listclients

# Send credentials
.PHONY: send-credential
send-credential:
	@read -p "Username: " USERNAME; \
	read -p "Email address: " EMAIL; \
	if [[ ! -f "send-email.py" ]]; then wget -q https://raw.githubusercontent.com/ganexcloud/docker-openvpn/master/tools/send-email.py; fi; \
	python3 send-email.py $${SMTP_HOST} $${SMTP_PORT} $${SMTP_USER} $${SMTP_PASSWORD} $${SMTP_TLS_ENABLED} $${USERNAME} $${EMAIL_FROM} $${EMAIL}; \
	if [[ $? -eq 0 ]]; then \
		echo "Email was sent successfully!" ;\
	else \
		echo "There was a problem sending the email, check your smtp settings." ;\
		exit 1 ;\
	fi ;\
