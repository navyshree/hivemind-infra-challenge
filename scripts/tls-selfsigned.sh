#!/usr/bin/env bash
#
# Generate a self-signed certificate, import it into ACM, and print the ARN.
#
# Why this exists: a publicly trusted certificate needs a domain, and this
# exercise owns none. Rather than leave TLS as a paragraph describing what we
# would have done, this makes the HTTPS path real — a genuine TLS listener with
# a modern policy, terminating real encrypted connections. The only thing it
# cannot supply is a signature from a CA that browsers already trust, so clients
# must skip verification or trust this certificate explicitly.
#
# ACM charges nothing for imported certificates; only Private CA is billed.
#
# The printed ARN embeds the AWS account id, which is why it is printed rather
# than written into a committed file. Apply it with:
#
#   ARN=$(scripts/tls-selfsigned.sh)
#   kubectl kustomize k8s/overlays/tls \
#     | sed "s|REPLACE-ME|${ARN}|" \
#     | kubectl apply -f -

set -euo pipefail

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}"
NAMESPACE="${NAMESPACE:-hivemind-greeter}"
DAYS="${DAYS:-365}"

# Put the load balancer's own hostname in the SAN so the only thing wrong with
# the certificate is the issuer, not the name. A client that trusts this CA
# validates the hostname cleanly.
ALB="$(kubectl -n "${NAMESPACE}" get ingress hivemind-greeter \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"

SAN="DNS:hivemind-greeter,DNS:*.${REGION}.elb.amazonaws.com"
if [ -n "${ALB}" ]; then
  SAN="DNS:${ALB},${SAN}"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" \
  -days "${DAYS}" -subj "/CN=hivemind-greeter" \
  -addext "subjectAltName=${SAN}" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth" \
  2>/dev/null

aws acm import-certificate \
  --region "${REGION}" \
  --certificate "fileb://${WORK}/cert.pem" \
  --private-key "fileb://${WORK}/key.pem" \
  --tags Key=Project,Value=hivemind-greeter Key=ManagedBy,Value=script \
  --query CertificateArn --output text
