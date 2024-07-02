#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# shellcheck disable=SC2164

# Instalación de dependencias y creación del usuario

# Dependencies

if [ ! "$(command -v podman)" ]; then
    zypper in -y podman systemd-container podman-docker
    zypper in -y --no-recommends docker-compose
fi

# User setup
USER_NAME="bitwarden"

if ! id -u "${USER_NAME}" &>/dev/null; then
    useradd -Uc "${USER_NAME} Management" -md /opt/"${USER_NAME}" -G docker "${USER_NAME}"
    loginctl enable-linger "${USER_NAME}"
else
    userdel -rf ${USER_NAME}
    groupdel ${USER_NAME}
    useradd -Uc "${USER_NAME} Management" -md /opt/"${USER_NAME}" -G docker "${USER_NAME}"
    loginctl enable-linger "${USER_NAME}"
fi

machinectl shell "${USER_NAME}"@ /bin/bash -c "
set -x
    cp -R /usr/share/containers \$HOME/.config/
    sed -i '0,/\"journald\"/s,,\"k8s-file\",' \$HOME/.config/containers/containers.conf
    systemctl enable --now --user podman.socket podman-auto-update.service
    podman context create default --docker host=unix://\$XDG_RUNTIME_DIR/podman/podman.sock

    # Bitwarden setup
    VERSION=\"2024.6.1\"
    curl -L https://github.com/bitwarden/server/releases/download/v\"\$VERSION\"/docker-stub-US.zip -o docker-stub.zip
    unzip docker-stub.zip -d bwdata && rm -f docker-stub.zip
    cd bwdata

    # Environment variables
    env_file=\"./env/global.override.env\"
    DOMAIN=bw.com

    # Generate random passwords and keys
    RANDOM_DATABASE_PASSWORD=\$(openssl rand -base64 18)
    IDENTITY_CERT_PASSWORD=\$(openssl rand -base64 18)
    IDENTITY_KEY=\$(openssl rand -base64 18)
    OIDCIDENTITYCLIENTKEY=\$(openssl rand -base64 18)
    DUO_AKEY=\$(openssl rand -base64 18)

    # Static installation IDs and keys
    INSTALL_ID=e3085061-e550-4793-98e7-b18c0111651f
    INSTALL_KEY=3ZapVgHf2KFL8TaYzY7d

    # Update the environment variables using sed
    sed -i \"s|https://.*|https://\$DOMAIN|\" \$env_file
    sed -i \"s|RANDOM_DATABASE_PASSWORD|\$RANDOM_DATABASE_PASSWORD|\" \$env_file
    sed -i \"s|IDENTITY_CERT_PASSWORD|\$IDENTITY_CERT_PASSWORD|\" \$env_file
    sed -i \"s|RANDOM_IDENTITY_KEY|\$IDENTITY_KEY|\" \$env_file
    sed -i \"s|oidcIdentityClientKey=.*|oidcIdentityClientKey=\$OIDCIDENTITYCLIENTKEY|\" \$env_file
    sed -i \"s|RANDOM_DUO_AKEY|\$DUO_AKEY|\" \$env_file
    sed -i \"s|00000000-0000-0000-0000-000000000000|\$INSTALL_ID|\" \$env_file
    sed -i \"s|SECRET_INSTALLATION_KEY|\$INSTALL_KEY|\" \$env_file
    sed -i \"s|adminSettings__admins=.*|adminSettings__admins=wdorrejo@dni.gob.do|\" \$env_file
    sed -i \"s|replyToEmail=.*|replyToEmail=notificaciones@losrabakuko.com|\" \$env_file
    sed -i \"s|smtp__host=.*|smtp__host=losrabakuko.com|\" \$env_file
    sed -i \"s|smtp__username=.*|smtp__username=notificaciones@losrabakuko.com|\" \$env_file
    sed -i \"s|smtp__password=.*|smtp__password=x64Kaq6cV0rp+duN|\" \$env_file

    # Generate a .pfx certificate file for the identity container
    cd identity
    openssl req -x509 -newkey rsa:4096 -sha256 -nodes -keyout identity.key -out identity.crt -subj \"/CN=Bitwarden IdentityServer\" -days 10950
    openssl pkcs12 -export -out identity.pfx -inkey identity.key -in identity.crt -passout pass:\"\$IDENTITY_CERT_PASSWORD\"
    cd \"\$OLDPWD\"

    # Generate Self-Signed Certificate
    mkdir -p ./ssl/\"\$DOMAIN\"
    openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days 365 \
        -keyout ./ssl/\"\$DOMAIN\"/private.key \
        -out ./ssl/\"\$DOMAIN\"/certificate.crt \
        -subj \"/C=US/ST=New York/L=New York/O=Company Name/OU=Bitwarden/CN=\$DOMAIN\" \
        -reqexts SAN -extensions SAN \
        -config <(cat /etc/ssl/openssl.cnf <(printf '[SAN]\\nsubjectAltName=DNS:%s\\nbasicConstraints=CA:true' \"\$DOMAIN\"))

    # WebServer Variables setup
    nginx_file=./nginx/default.conf
    sed -i \"s|bitwarden.example.com|\$DOMAIN|g\" \$nginx_file
    sed -i \"/listen \\[::\\]/d\" \$nginx_file
    sed -i \"s|listen 8443 ssl http2;|listen 8443 ssl;\n  http2 on;|\" \$nginx_file



    # Database Variable Setup
    mssql_file=./env/mssql.override.env
    sed -i \"s|RANDOM_DATABASE_PASSWORD|\$RANDOM_DATABASE_PASSWORD|\" \$mssql_file

    # App-ID env
    appid_file=./web/app-id.json
    sed -i \"s|bitwarden.example.com|\$DOMAIN|\" \$appid_file

    # UID env
    uid_file=./env/uid.env
    cat >\$uid_file <<EOL
LOCAL_UID=\$(id -u)
LOCAL_GID=\$(id -g)
EOL

set -x
    # # Set Docker-Compose Port
    compose_file=./docker/docker-compose.yml
    sed -i \"s|80|8080|\" \$compose_file
    sed -i \"s|443|8443|\" \$compose_file
"

machinectl shell "${USER_NAME}"@
podman compose -f docker/docker-compose.yml up -d
