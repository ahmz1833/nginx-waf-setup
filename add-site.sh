#!/bin/bash

# Usage: ./add-site.sh <domain> <backend_url> <mode>
# Modes: 
#   http   -> Only HTTP (Port 80)
#   auto   -> Auto SSL with Let's Encrypt (Port 80 + 443)
#   custom -> Custom SSL provided in ./certs folder

DOMAIN=$1
BACKEND=$2
MODE=$3 

if [[ -z "$DOMAIN" || -z "$BACKEND" || -z "$MODE" ]]; then
    echo "Usage: ./add-site.sh <domain> <backend> <mode>"
    echo "Modes: http | auto | custom"
    echo "Example: ./add-site.sh example.com http://10.0.0.5:3000 auto"
    exit 1
fi

SITE_CONFIG="./sites/${DOMAIN}.conf"

# --- Helper Function: Create Basic HTTP Block ---
generate_http_block() {
cat <<EOF > $SITE_CONFIG
server {
    listen 80;
    server_name $DOMAIN;

    # Include ACME challenge path for Certbot
    include /etc/nginx/snippets/acme-challenge.conf;

    location / {
        proxy_pass $BACKEND;
        include /etc/nginx/snippets/waf-general.conf;
    }
}
EOF
}

# --- Execution Logic ---

if [ "$MODE" == "http" ]; then
    echo "🔹 Setting up HTTP only for $DOMAIN..."
    generate_http_block
    docker-compose exec waf nginx -s reload

elif [ "$MODE" == "custom" ]; then
    echo "🔹 Setting up Custom SSL for $DOMAIN..."
    
    # Verify files exist locally
    if [[ ! -f "./certs/$DOMAIN.crt" || ! -f "./certs/$DOMAIN.key" ]]; then
        echo "❌ Error: $DOMAIN.crt or $DOMAIN.key not found in ./certs/"
        exit 1
    fi

    cat <<EOF > $SITE_CONFIG
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/nginx/certs/$DOMAIN.crt;
    ssl_certificate_key /etc/nginx/certs/$DOMAIN.key;
    include /etc/nginx/snippets/ssl-params.conf;

    location / {
        proxy_pass $BACKEND;
        include /etc/nginx/snippets/waf-general.conf;
    }
}
EOF
    docker-compose exec waf nginx -s reload

elif [ "$MODE" == "auto" ]; then
    echo "🔹 Setting up Auto SSL (Let's Encrypt) for $DOMAIN..."
    
    # 1. Create HTTP config first so Certbot can validate
    generate_http_block
    docker-compose exec waf nginx -s reload
    
    # 2. Request Certificate
    echo "⏳ Requesting certificate..."
    docker-compose run --rm certbot certonly --webroot --webroot-path /var/www/certbot -d $DOMAIN --email admin@$DOMAIN --rsa-key-size 4096 --agree-tos --no-eff-email

    # 3. If successful, switch config to HTTPS
    if [ $? -eq 0 ]; then
        echo "✅ Certificate obtained! Switching to HTTPS..."
        cat <<EOF > $SITE_CONFIG
server {
    listen 80;
    server_name $DOMAIN;
    include /etc/nginx/snippets/acme-challenge.conf;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/nginx/snippets/ssl-params.conf;

    location / {
        proxy_pass $BACKEND;
        include /etc/nginx/snippets/waf-general.conf;
    }
}
EOF
        docker-compose exec waf nginx -s reload
    else
        echo "❌ Error: Certbot failed. Check logs/DNS."
    fi
fi

echo "🚀 Done configuration for $DOMAIN"