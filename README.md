# OpenVPN 2.7 com DCO em Docker

Implementacao de OpenVPN full tunnel IPv4 para Amazon Linux 2023. O host utiliza o modulo `ovpn` e executa um unico container com OpenVPN 2.7.5 e DCO.

O servidor nao realiza build local. A imagem pronta e baixada do Docker Hub durante o `make init`.

## Componentes

- Amazon Linux 2023 com kernel 6.18;
- modulo `ovpn` oficial ou `OpenVPN/ovpn-backports`;
- Docker Engine e Docker Compose;
- imagem `ganexcloud/openvpn-dco:2.7.5`;
- Alpine Linux 3.24.1;
- OpenVPN 2.7.5;
- Easy-RSA 3.2.5;
- UDP/1194;
- full tunnel exclusivamente IPv4;
- PKI, configuracao e clientes persistidos no host.

## Requisitos da EC2

- Amazon Linux 2023;
- arquitetura `x86_64` ou `aarch64`;
- Elastic IP associado a EC2;
- registro DNS apontando para o Elastic IP;
- subnet publica com rota para um Internet Gateway;
- Security Group permitindo entrada UDP/1194;
- acesso SSH ou SSM;
- acesso de saida ao GitHub, aos repositorios do Amazon Linux e ao Docker Hub.

O Source/Destination Check pode permanecer habilitado porque a saida dos clientes utiliza NAT/MASQUERADE.

## Instalacao do host

Baixe somente o instalador:

```bash
curl -fsSLo setup.sh \
  https://raw.githubusercontent.com/ganexcloud/docker-openvpn/master/setup.sh
sudo bash setup.sh
```

O `setup.sh`:

1. valida o Amazon Linux 2023;
2. instala Docker, Compose, kernel e dependencias de compilacao;
3. instala ou compila o modulo `ovpn` oficial;
4. habilita o encaminhamento IPv4;
5. cria `/opt/openvpn-dco`;
6. baixa `Makefile`, `compose.yaml` e `.env.example`;
7. cria o `.env` inicial sem sobrescrever configuracoes existentes;
8. instala o servico persistente de firewall.

O script nao instala Docker Buildx porque nenhum build e realizado no servidor.

### Reinicializacao do kernel

Quando um novo kernel for instalado, o script encerrara solicitando reinicializacao:

```bash
sudo reboot
```

Depois de reconectar, execute novamente o mesmo instalador:

```bash
sudo /opt/openvpn-dco/setup.sh
```

O processo e idempotente. O segundo ciclo compila o `ovpn-backports` somente se o modulo nao estiver disponivel no kernel.

Quando o instalador for executado com `sudo` por um usuario comum, reabra a sessao antes de utilizar o Docker para que a associacao ao grupo `docker` seja aplicada.

## Configuracao

Entre no diretorio da aplicacao:

```bash
cd /opt/openvpn-dco
```

Edite o `.env`:

```bash
vi .env
```

A unica configuracao que obrigatoriamente precisa ser revisada em cada implantacao e o dominio publico da VPN. As demais opcoes ja possuem valores padrao, mas continuam disponiveis para customizacao:

```dotenv
# Obrigatorio
VPN_ENDPOINT=vpn.ganex.com.br

# Imagem
OPENVPN_IMAGE=ganexcloud/openvpn-dco:2.7.5

# Servico
VPN_PORT=1194
VPN_INTERFACE=ovpn0
VPN_TUN_MTU=1400
MAX_CLIENTS=25

# Rede IPv4
VPN_SUBNET=10.8.0.0
VPN_NETMASK=255.255.255.0
VPN_CIDR=10.8.0.0/24

# DNS do full tunnel
VPN_DNS_1=1.1.1.1
VPN_DNS_2=1.0.0.1

# PKI
CA_CN=${VPN_ENDPOINT}
SERVER_CN=${VPN_ENDPOINT}
CA_CERT_DAYS=7300
SERVER_CERT_DAYS=3650
CLIENT_CERT_DAYS=3650
CRL_DAYS=3650
```

O valor deve ser somente o dominio, sem `https://`, porta ou caminho. O DNS deve apontar para o Elastic IP da EC2.

Por padrao:

- CN da CA: acompanha `VPN_ENDPOINT` por meio de `CA_CN=${VPN_ENDPOINT}`;
- CN do servidor: acompanha automaticamente `VPN_ENDPOINT` por meio de `SERVER_CN=${VPN_ENDPOINT}`;
- CN do cliente: o username informado em `make add-client`;
- rede VPN: `10.8.0.0/24`;
- DNS dos clientes: `1.1.1.1` e `1.0.0.1`;
- interface DCO: `ovpn0`;
- MTU: `1400`;
- limite inicial: 25 clientes.

Ao alterar a rede, mantenha `VPN_SUBNET`, `VPN_NETMASK` e `VPN_CIDR` representando a mesma faixa. `VPN_CIDR` e utilizado pelo firewall do host, enquanto subnet e netmask sao utilizados pelo OpenVPN.

## Inicializacao

### 1. Criar configuracao e certificados

```bash
make init
```

O comando:

- valida o `.env` e o Docker;
- executa o pull da imagem publicada;
- cria a CA sem senha;
- cria o certificado e a chave do servidor sem senha;
- cria a CRL e a chave `tls-crypt`;
- gera a configuracao do OpenVPN;
- informa CN, data de emissao, expiracao e validade do certificado.

Por padrao, os certificados do servidor e dos clientes possuem validade de 3650 dias, equivalente a dez anos. O certificado do servidor inclui o dominio em `subjectAltName` (SAN). A CA possui validade de 7300 dias para nao encerrar a cadeia antes desses certificados. Esses prazos podem ser alterados no `.env`.

O `make init` e destinado a primeira inicializacao e recusa substituir uma PKI existente.

### 2. Iniciar o servidor

```bash
make start
```

O comando aplica o encaminhamento e o NAT, carrega o modulo `ovpn`, inicia o container sem build local e confirma nos logs que o DCO foi ativado.

### 3. Criar um cliente

```bash
make add-client
```

Informe somente o username:

```text
Username: usuario.ganex
```

O cliente e criado sem senha e com validade de 3650 dias. Ao final, o comando informa a data de emissao, a data de expiracao e o caminho do perfil:

```text
download-configs/usuario.ganex.ovpn
```

## Comandos operacionais

```bash
make start
make stop
make restart
make status
make logs
make add-client
make list-clients
make revoke-client
make remove-client
make help
```

### Revogacao

Revogar o certificado mantendo os arquivos locais:

```bash
make revoke-client
```

Revogar o certificado e remover os arquivos do cliente:

```bash
make remove-client
```

## Persistencia

Os dados ficam no host:

```text
/opt/openvpn-dco/openvpn-data/conf/openvpn.conf
/opt/openvpn-dco/openvpn-data/conf/pki/
/opt/openvpn-dco/openvpn-data/conf/clients/
/opt/openvpn-dco/download-configs/
```

O volume `openvpn-data/conf` e montado como `/etc/openvpn` dentro do container. Certificados, chaves, CRL e perfis permanecem no mesmo container e estrutura persistente da implementacao.

## Imagem Docker

A imagem padrao e:

```text
ganexcloud/openvpn-dco:2.7.5
```

O `Dockerfile`, o template do servidor e o entrypoint permanecem no repositorio para a construcao externa da imagem. O servidor de VPN recebe somente os arquivos de runtime e executa `docker compose pull`.

Para trocar permanentemente o repositorio ou a tag, configure no `.env`:

```dotenv
OPENVPN_IMAGE=ganexcloud/openvpn-dco:2.7.5
```

Antes da primeira inicializacao, o novo valor sera usado automaticamente pelo `make init`. Em uma instalacao ja inicializada, atualize sem recriar a PKI:

```bash
docker compose --env-file .env pull openvpn
make restart
```

## Atualizacao do kernel

O modulo `ovpn` e vinculado ao kernel em execucao. Depois de uma atualizacao de kernel, execute novamente:

```bash
sudo /opt/openvpn-dco/setup.sh
```

Se solicitado, reinicie e repita o comando. O instalador recompilara o `ovpn-backports` para o kernel em uso.

## Verificacoes rapidas

```bash
uname -r
modinfo ovpn
lsmod | grep '^ovpn'
docker compose version
cd /opt/openvpn-dco && make status
```

Nos logs do servidor devem aparecer mensagens equivalentes a:

```text
DCO device ovpn0 opened
Initialization Sequence Completed
```

## Observacoes

- A VPN utiliza somente IPv4 (`udp4`) e nao distribui rotas ou enderecos IPv6.
- O full tunnel e aplicado por `redirect-gateway def1`.
- Compressao, `fragment`, cifras legadas ou `disable-dco` nao devem ser adicionados.
- A porta UDP/1194 precisa estar liberada no Security Group.
- A chave da CA nao possui senha para permitir a operacao automatizada solicitada; proteja o diretorio `openvpn-data` e seus backups.
