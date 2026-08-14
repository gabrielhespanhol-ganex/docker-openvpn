# syntax=docker/dockerfile:1.7
ARG ALPINE_VERSION=3.24.1

FROM alpine:${ALPINE_VERSION}
ARG OPENVPN_VERSION=2.7.5-r0
ARG EASYRSA_VERSION=3.2.5-r0

RUN apk add --no-cache \
      bash \
      "easy-rsa=${EASYRSA_VERSION}" \
      "openvpn=${OPENVPN_VERSION}" \
      openssl \
    && ln -s /usr/share/easy-rsa/easyrsa /usr/local/bin/easyrsa \
    && openvpn --version | grep -q '\[DCO\]'

ENV OPENVPN=/etc/openvpn \
    EASYRSA=/usr/share/easy-rsa \
    EASYRSA_PKI=/etc/openvpn/pki

COPY config/openvpn.conf.template /opt/openvpn/openvpn.conf.template
COPY docker/ovpn.sh /usr/local/bin/ovpn
RUN chmod 0755 /usr/local/bin/ovpn

VOLUME ["/etc/openvpn"]
EXPOSE 1194/udp
ENTRYPOINT ["ovpn"]
CMD ["run"]
