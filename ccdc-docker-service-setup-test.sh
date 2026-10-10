#!/usr/bin/env bash
# Automates Route A: BIND9 + OpenCart (Apache/MySQL/PHP) directly on Ubuntu.
# Usage: sudo bash setup-manual.sh
# Override defaults with env vars, e.g.: sudo HOST_IP=192.168.56.102 bash setup-manual.sh
set -euo pipefail

# ---------- settings ----------
HOST_IP="${HOST_IP:-192.168.56.101}"
DOMAIN="${DOMAIN:-ccdc.local}"
OC_VERSION="${OC_VERSION:-4.0.2.3}"
OC_DIR="/var/www/html/opencart"
DB_NAME="opencart_db"
DB_USER="opencart_user"
CRED_FILE="/root/lab-credentials.txt"

log() { echo -e "\n==> $*"; }

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }

# ---------- credentials (generated once, reused on reruns) ----------
if [[ -f "$CRED_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CRED_FILE"
else
  DB_PASS="$(openssl rand -hex 12)"
  OC_ADMIN_PASS="$(openssl rand -hex 8)"
  umask 077
  cat > "$CRED_FILE" <<EOF
DB_PASS=$DB_PASS
OC_ADMIN_PASS=$OC_ADMIN_PASS
EOF
fi

# ---------- packages ----------
log "Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y bind9 bind9utils bind9-doc \
  unzip rsync wget apache2 mysql-server php libapache2-mod-php \
  php-mysql php-curl php-zip php-xml php-gd php-mbstring php-intl php-cli php-soap
systemctl enable --now apache2 mysql bind9

# ---------- BIND9 ----------
log "Configuring BIND9 zone for $DOMAIN"
if ! grep -q "zone \"$DOMAIN\"" /etc/bind/named.conf.local; then
  cat >> /etc/bind/named.conf.local <<EOF
zone "$DOMAIN" {
    type master;
    file "/etc/bind/db.$DOMAIN";
};
EOF
fi

cat > "/etc/bind/db.$DOMAIN" <<EOF
\$TTL 604800
@   IN  SOA $DOMAIN. admin.$DOMAIN. (
            $(date +%s)  ; serial
            604800       ; refresh
            86400        ; retry
            2419200      ; expire
            604800 )     ; negative cache TTL
@   IN  NS  $DOMAIN.
@   IN  A   $HOST_IP
www IN  A   $HOST_IP
EOF

named-checkconf
named-checkzone "$DOMAIN" "/etc/bind/db.$DOMAIN"
systemctl restart bind9

# ---------- MySQL ----------
log "Creating database and user"
mysql <<EOF
CREATE DATABASE IF NOT EXISTS $DB_NAME DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

# ---------- OpenCart files ----------
if grep -q "define('DB_HOSTNAME', 'localhost')" "$OC_DIR/config.php" 2>/dev/null; then
  log "OpenCart already installed, skipping download and installer"
else
  log "Downloading OpenCart $OC_VERSION"
  TMP="$(mktemp -d)"
  wget -q -O "$TMP/oc.zip" "https://github.com/opencart/opencart/releases/download/$OC_VERSION/opencart-$OC_VERSION.zip"
  unzip -q "$TMP/oc.zip" -d "$TMP/oc"
  UP="$(find "$TMP/oc" -maxdepth 3 -type d -name upload | head -1)"
  [[ -n "$UP" ]] || { echo "Could not find the upload folder in the zip"; exit 1; }

  mkdir -p "$OC_DIR"
  rsync -a "$UP"/ "$OC_DIR"/
  cp "$OC_DIR/config-dist.php" "$OC_DIR/config.php"
  cp "$OC_DIR/admin/config-dist.php" "$OC_DIR/admin/config.php"
  chown -R www-data:www-data "$OC_DIR"
  chmod -R 755 "$OC_DIR"
  rm -rf "$TMP"
fi

# ---------- Apache ----------
log "Configuring Apache virtual host"
cat > /etc/apache2/sites-available/opencart.conf <<EOF
<VirtualHost *:80>
    ServerAdmin admin@$DOMAIN
    DocumentRoot $OC_DIR/
    ServerName www.$DOMAIN
    ServerAlias $DOMAIN

    <Directory $OC_DIR/>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/opencart_error.log
    CustomLog \${APACHE_LOG_DIR}/opencart_access.log combined
</VirtualHost>
EOF

a2ensite opencart.conf
a2enmod rewrite
a2dissite 000-default.conf || true
apachectl configtest
systemctl restart apache2

# ---------- OpenCart installer (CLI) ----------
if [[ -d "$OC_DIR/install" ]]; then
  log "Running OpenCart CLI installer"
  if (cd "$OC_DIR" && sudo -u www-data php install/cli_install.php install \
        --db_hostname localhost --db_username "$DB_USER" --db_password "$DB_PASS" \
        --db_database "$DB_NAME" --db_driver mysqli --db_port 3306 \
        --username admin --password "$OC_ADMIN_PASS" \
        --email "admin@$DOMAIN" --http_server "http://$HOST_IP/"); then
    rm -rf "$OC_DIR/install"
  else
    echo "CLI installer failed. Finish in the browser at http://$HOST_IP/install"
    echo "  DB host: localhost  DB user: $DB_USER  DB name: $DB_NAME"
    echo "  DB password is in $CRED_FILE"
  fi
fi

# ---------- summary ----------
log "Done"
echo "Shop:   http://$HOST_IP/"
echo "Admin:  http://$HOST_IP/admin/   (user: admin)"
echo "Creds:  $CRED_FILE"
echo "DNS:    dig @localhost www.$DOMAIN +short"
