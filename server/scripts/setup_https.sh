#!/bin/bash
# Per-region: install nginx + certbot + certbot-dns-cloudflare,
# issue Let's Encrypt cert via DNS-01 challenge, configure nginx
# as a reverse proxy from https://$DOMAIN -> http://127.0.0.1:8443
# (where cloak-api-server.py listens), enable + start.
#
# Args:
#   $1 = domain (e.g. cloak-de1.cloakvpn.ai)
#   $2 = cloudflare API token (Zone:DNS:Edit on cloakvpn.ai)
#
# Idempotent — re-running on a clean install is safe.

set -euo pipefail

DOMAIN="${1:?usage: $0 <domain> <cf_token>}"
CF_TOKEN="${2:?usage: $0 <domain> <cf_token>}"

echo "==> Installing nginx + certbot stack..."
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    nginx \
    certbot \
    python3-certbot-dns-cloudflare \
    >/dev/null

# Open UFW for HTTPS (Hetzner cloud firewall already opened, this is the
# server-side OS firewall; both must allow).
echo "==> Opening ufw 443/tcp..."
ufw allow 443/tcp >/dev/null 2>&1 || true

echo "==> Writing Cloudflare credentials for certbot..."
install -m 700 -d /etc/letsencrypt/cloudflare
cat > /etc/letsencrypt/cloudflare/credentials.ini <<EOF
# Cloudflare API token used by certbot-dns-cloudflare for DNS-01 challenge.
# Restricted to Zone:DNS:Edit on cloakvpn.ai. Rotate via Cloudflare
# dashboard if compromised.
dns_cloudflare_api_token = ${CF_TOKEN}
EOF
chmod 600 /etc/letsencrypt/cloudflare/credentials.ini

echo "==> Issuing Let's Encrypt cert for $DOMAIN..."
# --non-interactive + --agree-tos + --register-unsafely-without-email is OK
# for ops boxes (we get expiry warnings on the renewal cron anyway). Email
# can be added later via certbot register --update-registration --email ...
if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
    certbot certonly \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        --dns-cloudflare \
        --dns-cloudflare-credentials /etc/letsencrypt/cloudflare/credentials.ini \
        --dns-cloudflare-propagation-seconds 30 \
        -d "$DOMAIN" \
        --quiet
    echo "    cert issued"
else
    echo "    cert already exists — skipping issuance"
fi

echo "==> Writing nginx vhost..."
# Reverse proxy: 443 (TLS) -> 127.0.0.1:8443 (cloak-api-server.py).
# Note: cloak-api-server's port is misleadingly named "8443" but it's
# plain HTTP. Renaming the port would break iOS-side cached configs;
# leaving as-is and just terminating TLS in nginx.
cat > /etc/nginx/sites-available/cloak-api.conf <<NGX
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    # Modern TLS only (Mozilla "intermediate" 2023). iOS 13+ supports all.
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    # HSTS (1 year, no preload — preload is opt-in via separate process)
    add_header Strict-Transport-Security "max-age=31536000" always;

    # Limit request body — provisioning POST is ~1KB JSON. 16KB is plenty,
    # blocks accidental large uploads.
    client_max_body_size 16k;

    # Modest timeouts — provisioning takes 3-8s server-side, so 30s
    # is comfortable headroom.
    proxy_connect_timeout 10s;
    proxy_send_timeout    30s;
    proxy_read_timeout    30s;

    location / {
        proxy_pass http://127.0.0.1:8443;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
NGX

ln -sf /etc/nginx/sites-available/cloak-api.conf /etc/nginx/sites-enabled/cloak-api.conf

# Drop the default "Welcome to nginx" site so reviewers / probers don't see it.
rm -f /etc/nginx/sites-enabled/default

echo "==> nginx -t..."
nginx -t

echo "==> Reloading nginx + enabling auto-start..."
systemctl enable nginx >/dev/null 2>&1 || true
systemctl reload nginx || systemctl restart nginx

# certbot's snap install enables a renewal timer by default; the apt
# install needs explicit verification. Ensure the timer is active.
echo "==> Verifying renewal timer..."
systemctl enable certbot.timer >/dev/null 2>&1 || true
systemctl start certbot.timer >/dev/null 2>&1 || true

# Add a reload hook so renewed certs trigger nginx reload.
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOK'
#!/bin/sh
# Reload nginx whenever certbot installs a renewed cert.
systemctl reload nginx
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

echo "==> Verifying..."
curl -sS --max-time 10 "https://${DOMAIN}/api/v1/health" || echo "health check failed (expected if cloak-api-server isn't responding to /api/v1/health)"
echo
echo "DONE for $DOMAIN"
