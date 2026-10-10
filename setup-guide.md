# BIND9 + OpenCart on Ubuntu: step-by-step

Two routes. Pick **one**, since both want port 80 and port 53 on the same machine.

- **Route A: Manual** (BIND9 + Apache/MySQL installed directly on Ubuntu)
- **Route B: Docker** (`playbook.yml` builds everything as containers)

Values used throughout:

| Item | Value |
|---|---|
| Host IP | `192.168.56.101` |
| DNS zone | `ccdc.local` |
| OpenCart | 4.0.2.3 at `/var/www/html/opencart` |
| DB / user | `opencart_db` / `opencart_user` |

---

## Route A: Manual install

### Part 1: BIND9 (DNS)

**1. Install and start it**

```bash
sudo apt update
sudo apt install -y bind9 bind9utils bind9-doc
sudo systemctl enable --now bind9
sudo systemctl status bind9 --no-pager
```

You want `active (running)`.

**2. Declare the zone**

```bash
sudo tee -a /etc/bind/named.conf.local > /dev/null <<'EOF'
zone "ccdc.local" {
    type master;
    file "/etc/bind/db.ccdc.local";
};
EOF
```

**3. Create the zone file**

```bash
sudo tee /etc/bind/db.ccdc.local > /dev/null <<'EOF'
$TTL 604800
@   IN  SOA ccdc.local. admin.ccdc.local. (
            2          ; serial (bump on every edit)
            604800     ; refresh
            86400      ; retry
            2419200    ; expire
            604800 )   ; negative cache TTL
@   IN  NS  ccdc.local.
@   IN  A   192.168.56.101
www IN  A   192.168.56.101
EOF
```

The quoted `'EOF'` stops the shell from expanding `$TTL`.

**4. Check the config before restarting** (a typo here would take DNS down)

```bash
sudo named-checkconf
sudo named-checkzone ccdc.local /etc/bind/db.ccdc.local
```

Both should print nothing or `OK`.

**5. Restart and test**

```bash
sudo systemctl restart bind9
dig @localhost ccdc.local +short
dig @localhost www.ccdc.local +short
```

Both should return `192.168.56.101`. Use `dig @localhost` rather than `ping`, because `.local` is reserved for mDNS and some resolvers won't send it to your DNS server.

---

### Part 2: OpenCart (Apache + MySQL + PHP)

**1. Install packages**

```bash
sudo apt install -y unzip rsync apache2 mysql-server php libapache2-mod-php \
  php-mysql php-curl php-zip php-xml php-gd php-mbstring php-intl php-cli php-soap
sudo systemctl enable --now apache2 mysql
```

The service name is lowercase `mysql`, since systemd unit names are case-sensitive.

**2. Create the database**

Change `YourStrongPasswordHere` first.

```bash
sudo mysql <<'EOF'
CREATE DATABASE opencart_db DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'opencart_user'@'localhost' IDENTIFIED BY 'YourStrongPasswordHere';
GRANT ALL PRIVILEGES ON opencart_db.* TO 'opencart_user'@'localhost';
FLUSH PRIVILEGES;
EOF
```

**3. Download and unpack OpenCart**

```bash
cd /tmp
wget https://github.com/opencart/opencart/releases/download/4.0.2.3/opencart-4.0.2.3.zip
unzip -q opencart-4.0.2.3.zip -d /tmp/oc
UP="$(find /tmp/oc -maxdepth 3 -type d -name upload | head -1)"
echo "$UP"
```

`find` locates the `upload` folder wherever the zip puts it. The `echo` should print a path. If it prints nothing, the unzip failed.

**4. Copy it into the web root and set up config files**

```bash
sudo mkdir -p /var/www/html/opencart
sudo rsync -a "$UP"/ /var/www/html/opencart/
cd /var/www/html/opencart
sudo cp config-dist.php config.php
sudo cp admin/config-dist.php admin/config.php
sudo chown -R www-data:www-data /var/www/html/opencart
sudo chmod -R 755 /var/www/html/opencart
```

OpenCart needs `config.php` files to exist and be writable by Apache so the installer can fill them in. `www-data` is the user Apache runs as.

**5. Create the Apache virtual host**

```bash
sudo tee /etc/apache2/sites-available/opencart.conf > /dev/null <<'EOF'
<VirtualHost *:80>
    ServerAdmin admin@ccdc.local
    DocumentRoot /var/www/html/opencart/
    ServerName www.ccdc.local
    ServerAlias ccdc.local

    <Directory /var/www/html/opencart/>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog ${APACHE_LOG_DIR}/opencart_error.log
    CustomLog ${APACHE_LOG_DIR}/opencart_access.log combined
</VirtualHost>
EOF
```

`AllowOverride All` lets OpenCart's `.htaccess` work, which is why `rewrite` is enabled next. The quoted `'EOF'` keeps `${APACHE_LOG_DIR}` literal so Apache fills it in, not your shell.

**6. Enable it and restart Apache**

```bash
sudo a2ensite opencart.conf
sudo a2enmod rewrite
sudo a2dissite 000-default.conf
sudo apachectl configtest
sudo systemctl restart apache2
```

`configtest` should say `Syntax OK`.

**7. Finish in the browser**

1. Open `http://192.168.56.101/install`
2. Accept the license, then check that all requirements pass.
3. Database: host `localhost`, user `opencart_user`, your password, database `opencart_db`.
4. Set your admin username, password and email.

**8. Delete the installer** (OpenCart won't load until you do)

```bash
sudo rm -rf /var/www/html/opencart/install
```

**9. Verify**

```bash
curl -I http://192.168.56.101
```

Expect `HTTP/1.1 200 OK`. The admin panel is at `http://192.168.56.101/admin/`.

---

## Route B: Docker (playbook)

This does everything above automatically, as containers: OpenCart, MariaDB, and BIND9.

**1. Free up ports 80 and 53** if you did Route A first:

```bash
sudo systemctl disable --now apache2 bind9
```

**2. Set the passwords.** Open `playbook.yml` and change the three `ChangeMe-*` values near the top.

**3. Run it**

```bash
sudo apt install -y ansible
ansible-playbook playbook.yml -K
```

The first run takes a few minutes while it builds the OpenCart image.

**4. Verify**

```bash
sudo docker ps
dig @192.168.56.101 www.ccdc.local +short
curl -I http://192.168.56.101
```

**If OpenCart doesn't come up**

```bash
cd /opt/stack && sudo docker compose logs opencart
```

**Editing DNS later:** change the zone in `playbook.yml`, bump `zone_serial`, and rerun the playbook.
