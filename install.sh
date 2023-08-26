#!/bin/bash

HOST=${1:-'dominio'}
#parametros opcionales
PROYECT=${2:-'https://github.com/davem1012/softdent.git'}
#REMOTE='git@gitlab.com:'$(echo $PROYECT | sed -e s#^https://gitlab.com/##)
SERVICE_NUMBER=${3:-'1'}
PATH_INSTALL=$(echo $HOME)
DIR=$(echo $PROYECT | rev | cut -d'/' -f1 | rev | cut -d '.' -f1)$SERVICE_NUMBER
MYSQL_PORT_HOST=${4:-'3306'}
MYSQL_USER=${5:-$DIR}
MYSQL_PASSWORD=${6:-$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 20 ; echo '')}
MYSQL_DATABASE=${7:-$DIR}
MYSQL_ROOT_PASSWORD=${8:-$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 20 ; echo '')}
ADMIN_PASSWORD=${9:-$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 10 ; echo '')}

if [ "$HOST" = "dominio" ]; then
    echo no ha ingresado dominio, vuelva a ejecutar el script agregando un dominio como primer parametro
    exit 1
fi

if [ $SERVICE_NUMBER = '1' ]; then
echo "Actualizando sistema"
apt-get -y update
apt-get -y upgrade

echo "Instalando git"
apt-get -y install git-core

echo "Instalando docker"
apt-get -y install apt-transport-https ca-certificates curl gnupg-agent software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
apt-get -y update
apt-get -y install docker-ce
systemctl start docker
systemctl enable docker

echo "Instalando docker compose"
curl -L "https://github.com/docker/compose/releases/download/1.23.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

echo "Instalando letsencrypt"
apt-get -y install letsencrypt
mkdir $HOME/certs/

echo "Configurando proxy"
docker network create proxynet
mkdir $HOME/proxy
cat << EOF > $HOME/proxy/docker-compose.yml
version: '3'

services:
    proxy:
        image: jwilder/nginx-proxy
        ports:
            - "80:80"
            - "443:443"
        volumes:
            - ./../certs:/etc/nginx/certs
            - /var/run/docker.sock:/tmp/docker.sock:ro
        restart: always
        privileged: true
networks:
    default:
        external:
            name: proxynet

EOF

cd $HOME/proxy
docker-compose up -d

mkdir $HOME/proxy/fpms
fi

echo "Configurando $DIR"

if ! [ -d $HOME/proxy/fpms/$DIR ]; then
echo "Cloning the repository"
rm -rf "$PATH_INSTALL/$DIR"
git clone "$PROYECT" "$PATH_INSTALL/$DIR"

mkdir $HOME/proxy/fpms/$DIR

cat << EOF > $HOME/proxy/fpms/$DIR/default
# Configuración de PHP para Nginx
server {
    listen 80 default_server;
    root /var/www/html/public;
    index index.html index.htm index.php;
    server_name *._;
    charset utf-8;
    server_tokens off;
    location = /favicon.ico {
        log_not_found off;
        access_log off;
    }
    location = /robots.txt {
        log_not_found off;
        access_log off;
    }
    location / {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
    }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass fpm$SERVICE_NUMBER:9000;
    }
    error_page 404 /index.php;
    location ~ /\.ht {
        deny all;
    }
}
EOF

cat << EOF > $PATH_INSTALL/$DIR/docker-compose.yml
version: '3'

services:
    nginx$SERVICE_NUMBER:
        image: rash07/nginx
        working_dir: /var/www/html
        environment:
            VIRTUAL_HOST: $HOST, *.$HOST
        volumes:
            - ./:/var/www/html
            - $HOME/proxy/fpms/$DIR:/etc/nginx/sites-available
        restart: always
    fpm$SERVICE_NUMBER:
        image: rash07/php-fpm:1.0
        working_dir: /var/www/html
        volumes:
            - ./ssh:/root/.ssh
            - ./ssh:/var/www/.ssh
            - ./:/var/www/html
        restart: always
    mariadb$SERVICE_NUMBER:
        image: mariadb:10.5.6
        environment:
            - MYSQL_USER=\${MYSQL_USER}
            - MYSQL_PASSWORD=\${MYSQL_PASSWORD}
            - MYSQL_DATABASE=\${MYSQL_DATABASE}
            - MYSQL_ROOT_PASSWORD=\${MYSQL_ROOT_PASSWORD}
            - MYSQL_PORT_HOST=\${MYSQL_PORT_HOST}
        volumes:
            - mysqldata$SERVICE_NUMBER:/var/lib/mysql
        ports:
            - "\${MYSQL_PORT_HOST}:3306"
        restart: always


networks:
    default:
        external:
            name: proxynet

volumes:
    mysqldata$SERVICE_NUMBER:
        driver: "local"

EOF

cp $PATH_INSTALL/$DIR/.env.example $PATH_INSTALL/$DIR/.env

cat << EOF >> $PATH_INSTALL/$DIR/.env


MYSQL_USER=$MYSQL_USER
MYSQL_PASSWORD=$MYSQL_PASSWORD
MYSQL_DATABASE=$MYSQL_DATABASE
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
MYSQL_PORT_HOST=$MYSQL_PORT_HOST
EOF

echo "Configurando env"
cd "$PATH_INSTALL/$DIR"

sed -i "/DB_DATABASE=/c\DB_DATABASE=$MYSQL_DATABASE" .env
sed -i "/DB_PASSWORD=/c\DB_PASSWORD=$MYSQL_ROOT_PASSWORD" .env
sed -i "/DB_HOST=/c\DB_HOST=mariadb$SERVICE_NUMBER" .env
sed -i "/DB_USERNAME=/c\DB_USERNAME=root" .env
sed -i "/APP_URL_BASE=/c\APP_URL_BASE=$HOST" .env
sed -i '/APP_URL=/c\APP_URL=http://${APP_URL_BASE}' .env
sed -i '/FORCE_HTTPS=/c\FORCE_HTTPS=false' .env
sed -i '/APP_DEBUG=/c\APP_DEBUG=false' .env



echo "Configurando proyecto"
docker-compose up -d
docker-compose exec -T fpm$SERVICE_NUMBER rm composer.lock
docker-compose exec -T fpm$SERVICE_NUMBER composer self-update
docker-compose exec -T fpm$SERVICE_NUMBER composer install
docker-compose exec -T fpm$SERVICE_NUMBER php artisan migrate:refresh --seed
docker-compose exec -T fpm$SERVICE_NUMBER php artisan key:generate
docker-compose exec -T fpm$SERVICE_NUMBER php artisan storage:link

rm $PATH_INSTALL/$DIR/database/seeds/DatabaseSeeder.php
mv $PATH_INSTALL/$DIR/database/seeds/DatabaseSeeder.php.bk $PATH_INSTALL/$DIR/database/seeds/DatabaseSeeder.php

echo "configurando permisos"
chmod -R 777 "$PATH_INSTALL/$DIR/storage/" "$PATH_INSTALL/$DIR/bootstrap/" "$PATH_INSTALL/$DIR/vendor/"




echo "Ruta del proyecto dentro del servidor: $HOME/$DIR"
echo "URL: $HOST"



else
echo "La carpeta $HOME/proxy/fpms/$DIR ya existe"
fi