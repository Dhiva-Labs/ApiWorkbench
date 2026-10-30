#!/bin/sh
# Regenerates the TLS fixtures the network tests use. They are test-only
# material (the keys protect nothing) with a very long validity so the
# tests never start failing because a certificate expired.
#
#   ca.pem                       the test certificate authority
#   server.pem / server.key      localhost, 127.0.0.1 and ::1, signed by the CA
#   client.pem / client.key      client certificate (CN=ApiWorkbench Test Client)
#   client-enc.key               the same key, encrypted with "keypass"
#   client.p12                   client cert + key + CA as a PFX, password "pfxpass"
#   client-legacy.p12            the same with the pre-OpenSSL-3 algorithms
#   client-nopass.p12            the same with an empty password
#   rogue-ca.pem                 an unrelated CA the server does not trust
#   rogue-client.pem / .key      a client certificate signed by rogue-ca
#
# The CA keys are deleted at the end: nothing else needs to be issued.
#
# Usage: sh generate.sh   (needs openssl 3)
set -eu
cd "$(dirname "$0")"
DAYS=36500
SUBJ=/O=ApiWorkbench\ Tests

openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem \
  -days $DAYS -subj "$SUBJ/CN=ApiWorkbench Test CA" \
  -addext basicConstraints=critical,CA:TRUE \
  -addext keyUsage=critical,keyCertSign,cRLSign

openssl req -x509 -newkey rsa:2048 -nodes -keyout rogue-ca.key -out rogue-ca.pem \
  -days $DAYS -subj "$SUBJ/CN=Rogue CA" \
  -addext basicConstraints=critical,CA:TRUE \
  -addext keyUsage=critical,keyCertSign,cRLSign

issue() { # name ca-prefix subject extfile
  openssl req -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.csr" -subj "$3"
  openssl x509 -req -in "$1.csr" -CA "$2.pem" -CAkey "$2.key" -CAcreateserial \
    -out "$1.pem" -days $DAYS -sha256 -extfile "$4"
  rm -f "$1.csr"
}

cat > server.ext <<'EXT'
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1
EXT
cat > client.ext <<'EXT'
basicConstraints=CA:FALSE
keyUsage=digitalSignature
extendedKeyUsage=clientAuth
EXT

issue server ca "$SUBJ/CN=localhost" server.ext
issue client ca "$SUBJ/CN=ApiWorkbench Test Client" client.ext
issue rogue-client rogue-ca "$SUBJ/CN=Rogue Client" client.ext

openssl pkcs8 -topk8 -in client.key -out client-enc.key -v2 aes-256-cbc \
  -passout pass:keypass
openssl pkcs12 -export -inkey client.key -in client.pem -certfile ca.pem \
  -out client.p12 -passout pass:pfxpass
openssl pkcs12 -export -legacy -inkey client.key -in client.pem -certfile ca.pem \
  -out client-legacy.p12 -passout pass:pfxpass
openssl pkcs12 -export -inkey client.key -in client.pem -certfile ca.pem \
  -out client-nopass.p12 -passout pass:

rm -f ca.srl rogue-ca.srl ca.key rogue-ca.key rogue-client.csr server.ext client.ext
