#!/bin/bash
# Pterodactyl Install Script (Debian 12/13)
# Run as root: bash install_pterodactyl.sh

set -e

### CONFIG ###
FQDN="panel.Domain"   # <- Deine Domain fürs Panel
EMAIL="" # <- E-Mail für Let's Encrypt
DB_PASS="" # Passwort für MariaDB
### UPDATE & BASICS ###
apt update && apt upgrade -y
apt install -y curl wget sudo unzip git gnupg lsb-release ca-certificates apt-transport-https software-properties-common

### INSTALL MARIADB ###
apt install -y mariadb-server mariadb-client
systemctl enable --now mariadb

mysql -u root <<MYSQL_SECURE
CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
CREATE DATABASE panel;
GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
MYSQL_SECURE

### INSTALL REDIS ###
apt install -y redis-server
systemctl enable --now redis-server

### INSTALL PHP + DEPENDENCIES ###
apt install -y lsb-release ca-certificates apt-transport-https software-properties-common
add-apt-repository ppa:ondrej/php -y
apt update
apt install -y php8.2 php8.2-cli php8.2-gd php8.2-mysql php8.2-pdo php8.2-mbstring php8.2-bcmath php8.2-xml php8.2-curl php8.2-zip php8.2-fpm

### INSTALL COMPOSER ###
cd /tmp && curl -sS https://getcomposer.org/installer | php
mv composer.phar /usr/local/bin/composer

### INSTALL NODEJS (für Wings + Queue Worker) ###
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

### INSTALL PANEL ###
mkdir -p /var/www/pterodactyl && cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz && rm panel.tar.gz

cp .env.example .env
sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=${DB_PASS}/" .env

composer install --no-dev --optimize-autoloader
php artisan key:generate --force
php artisan migrate --seed --force

chown -R www-data:www-data /var/www/pterodactyl

### CONFIGURE NGINX ###
apt install -y nginx certbot python3-certbot-nginx
cat > /etc/nginx/sites-available/pterodactyl.conf <<NGINX
server {
    listen 80;
    server_name ${FQDN};
    root /var/www/pterodactyl/public;

    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
}
NGINX

ln -s /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/
nginx -t && systemctl restart nginx

certbot --nginx -d ${FQDN} --non-interactive --agree-tos -m ${EMAIL}

### SETUP SYSTEMD QUEUE WORKER ###
cat > /etc/systemd/system/pteroq.service <<SERVICE
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --sleep=3 --tries=3

[Install]
WantedBy=multi-user.target
SERVICE

systemctl enable --now pteroq

### INSTALL WINGS ###
mkdir -p /etc/pterodactyl
curl -Lo /usr/local/bin/wings https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64
chmod +x /usr/local/bin/wings

cat > /etc/systemd/system/wings.service <<SERVICE
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=600
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
SERVICE

### INSTALL DOCKER (für Wings) ###
apt install -y docker.io docker-compose-plugin
systemctl enable --now docker

systemctl enable --now wings

### DONE ###
echo "====================================================="
echo "Pterodactyl Panel installiert: https://${FQDN}" 
echo "MySQL DB: panel | User: pterodactyl | Pass: ${DB_PASS}" 
echo "Wings läuft als Service: systemctl status wings"
echo "====================================================="