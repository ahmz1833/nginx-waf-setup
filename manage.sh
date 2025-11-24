#!/bin/bash

set -euo pipefail

COMPOSE_CMD="docker-compose"
SITES_DIR="./sites"

usage() {
    cat <<EOF
Usage: ./manage.sh <command> [args]

Commands:
  add <domain> <backend> <mode>   Add or update a site (modes: http | auto | custom)
  remove <domain>                 Remove a site config and reload nginx
  list                            List configured sites
  test-config                     Run 'nginx -t' inside waf container
  reload                          Reload nginx (after testing config)
  setup-cron                      Install daily 3AM nginx reload cron
  help                            Show this help

Examples:
  ./manage.sh add example.com http://10.0.0.5:3000 auto
  ./manage.sh remove example.com
  ./manage.sh list
  ./manage.sh setup-cron
EOF
}

ensure_sites_dir() {
    mkdir -p "$SITES_DIR"
}

cmd_add() {
    if [[ $# -ne 3 ]]; then
        echo "Usage: ./manage.sh add <domain> <backend> <mode>" >&2
        exit 1;
    fi

    local domain="$1"
    local backend="$2"
    local mode="$3"

    ensure_sites_dir
    local site_config="$SITES_DIR/${domain}.conf"

    generate_http_block() {
        cat <<EOF > "$site_config"
server {
    listen 80;
    server_name $domain;

    # Include ACME challenge path for Certbot
    include /etc/nginx/snippets/acme-challenge.conf;

    # Standard logging snippet
    include /etc/nginx/snippets/logging.conf;

    location / {
        proxy_pass $backend;
        include /etc/nginx/snippets/waf-general.conf;
    }
}
EOF
    }

    case "$mode" in
        http)
            echo "🔹 Setting up HTTP only for $domain..."
            generate_http_block
            ;;
        custom)
            echo "🔹 Setting up Custom SSL for $domain..."
            if [[ ! -f "./certs/$domain.crt" || ! -f "./certs/$domain.key" ]]; then
                echo "❌ Error: $domain.crt or $domain.key not found in ./certs/" >&2
                exit 1
            fi
            cat <<EOF > "$site_config"
server {
    listen 80;
    server_name $domain;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $domain;

    ssl_certificate /etc/nginx/certs/$domain.crt;
    ssl_certificate_key /etc/nginx/certs/$domain.key;
    include /etc/nginx/snippets/ssl-params.conf;

    # Standard logging snippet
    include /etc/nginx/snippets/logging.conf;

    location / {
        proxy_pass $backend;
        include /etc/nginx/snippets/waf-general.conf;
    }
}
EOF
            ;;
        auto)
            echo "🔹 Setting up Auto SSL (Let's Encrypt) for $domain..."
            generate_http_block
            echo "⏳ Requesting certificate..."
            $COMPOSE_CMD run --rm --entrypoint certbot certbot certonly --webroot --webroot-path /var/www/certbot -d "$domain" --email "admin@$domain" --rsa-key-size 4096 --agree-tos --no-eff-email || {
                echo "❌ Error: Certbot failed. Check logs/DNS." >&2
                exit 1
            }
            echo "✅ Certificate obtained! Switching to HTTPS..."
            cat <<EOF > "$site_config"
server {
    listen 80;
    server_name $domain;
    include /etc/nginx/snippets/acme-challenge.conf;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $domain;

    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    include /etc/nginx/snippets/ssl-params.conf;

    # Standard logging snippet
    include /etc/nginx/snippets/logging.conf;

    location / {
        proxy_pass $backend;
        include /etc/nginx/snippets/waf-general.conf;
    }
}
EOF
            ;;
        *)
            echo "❌ Unknown mode: $mode (use http | auto | custom)" >&2
            exit 1
            ;;
    esac

    cmd_test_config
    cmd_reload
    echo "🚀 Done configuration for $domain"
}

cmd_remove() {
    if [[ $# -ne 1 ]]; then
        echo "Usage: ./manage.sh remove <domain>" >&2
        exit 1
    fi
    local domain="$1"
    local site_config="$SITES_DIR/${domain}.conf"
    if [[ ! -f "$site_config" ]]; then
        echo "Site config not found: $site_config" >&2
        exit 1
    fi
    rm -f "$site_config"
    echo "🗑️ Removed site config for $domain"
    cmd_test_config
    cmd_reload
}

cmd_list() {
    ensure_sites_dir
    if compgen -G "$SITES_DIR/*.conf" > /dev/null; then
        echo "Configured sites:"
        for f in "$SITES_DIR"/*.conf; do
            basename "${f%.conf}"
        done
    else
        echo "No sites configured yet."
    fi
}

cmd_test_config() {
    echo "🔍 Testing nginx configuration inside waf container..."
    $COMPOSE_CMD exec waf nginx -t
}

cmd_reload() {
    echo "🔁 Reloading nginx inside waf container..."
    $COMPOSE_CMD exec waf nginx -s reload
}

cmd_setup_cron() {
    local compose_file
    compose_file=$(readlink -f docker-compose.yml)
    local compose_dir
    compose_dir=$(dirname "$compose_file")
    local job="0 3 * * * cd $compose_dir && /usr/local/bin/docker-compose exec -T waf nginx -s reload"

    crontab -l 2>/dev/null | grep -F "$job" >/dev/null || {
        (crontab -l 2>/dev/null; echo "$job") | crontab -
        echo "✅ Cron job added successfully."
        return
    }
    echo "👌 Cron job already exists. Skipping."
}

main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        add)           cmd_add "$@" ;;
        remove)        cmd_remove "$@" ;;
        list)          cmd_list "$@" ;;
        test-config)   cmd_test_config "$@" ;;
        reload)        cmd_reload "$@" ;;
        setup-cron)    cmd_setup_cron "$@" ;;
        help|--help|-h) usage ;;
        *)
            echo "Unknown command: $cmd" >&2
            usage
            exit 1
            ;;
    esac
}

main "$@"
