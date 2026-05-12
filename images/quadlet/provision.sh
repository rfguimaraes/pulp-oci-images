#!/usr/bin/env bash
# Provisions a Fedora VM with the Pulp quadlet stack for local testing.
# Postgres and Redis run as plain Podman containers (no external server needed).
set -euo pipefail

# sudo -u inherits the cwd; /home/vagrant is not readable by other users.
cd /

QUADLET_SRC=/vagrant/quadlet
PULP_UID=1001
PULP_HOME=/home/pulp
PULP_DIR=$PULP_HOME/pulp
ADMIN_PASSWORD=password

# ---------------------------------------------------------------------------
# System setup (as root)
# ---------------------------------------------------------------------------

dnf install -y podman openssl

id pulp &>/dev/null || useradd --uid $PULP_UID --create-home pulp
loginctl enable-linger pulp
sleep 2  # wait for the systemd user instance to start

# ---------------------------------------------------------------------------
# Helper: run a command as the pulp user with a proper user session env
# ---------------------------------------------------------------------------
as_pulp() {
    sudo -u pulp \
        HOME=$PULP_HOME \
        XDG_RUNTIME_DIR=/run/user/$PULP_UID \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$PULP_UID/bus" \
        "$@"
}

# ---------------------------------------------------------------------------
# Directories and credentials
# ---------------------------------------------------------------------------

as_pulp mkdir -p $PULP_DIR/assets/{bin,certs,nginx}

# Fernet key for encrypted database fields (no external packages needed)
as_pulp python3 -c "
import base64, os
print(base64.urlsafe_b64encode(os.urandom(32)).decode())
" > $PULP_DIR/assets/certs/database_fields.symmetric.key

# EC key pair for container registry token auth
as_pulp openssl ecparam -name prime256v1 -genkey -noout \
    -out $PULP_DIR/assets/certs/container_auth_private_key.pem
as_pulp openssl ec \
    -in  $PULP_DIR/assets/certs/container_auth_private_key.pem \
    -pubout \
    -out $PULP_DIR/assets/certs/container_auth_public_key.pem

# ---------------------------------------------------------------------------
# settings.py
# ---------------------------------------------------------------------------

SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(50))")

sed \
    -e "s|SECRET_KEY = \"<.*>\"|SECRET_KEY = \"${SECRET_KEY}\"|" \
    -e 's|"http://<your-pulp-host>:8080"|"http://localhost:8080"|g' \
    -e 's|"HOST": "<db-host>"|"HOST": "pulp-postgres"|' \
    -e 's|"PASSWORD": "<db-password>"|"PASSWORD": "'"$ADMIN_PASSWORD"'"|' \
    -e 's|REDIS_HOST = "<redis-host>"|REDIS_HOST = "pulp-redis"|' \
    "$QUADLET_SRC/assets/settings.py.example" \
    > $PULP_DIR/assets/settings.py
chown pulp:pulp $PULP_DIR/assets/settings.py

# ---------------------------------------------------------------------------
# Nginx assets
# ---------------------------------------------------------------------------

as_pulp cp "$QUADLET_SRC/assets/bin/nginx.sh" $PULP_DIR/assets/bin/
chmod +x $PULP_DIR/assets/bin/nginx.sh
as_pulp cp "$QUADLET_SRC/assets/nginx/nginx.conf.template" $PULP_DIR/assets/nginx/

# ---------------------------------------------------------------------------
# Quadlet units
# ---------------------------------------------------------------------------

as_pulp mkdir -p $PULP_HOME/.config/containers/systemd \
                 $PULP_HOME/.config/systemd/user

# Remove any stale pulp.target from the quadlet generator directory (wrong location).
rm -f $PULP_HOME/.config/containers/systemd/pulp.target

as_pulp cp "$QUADLET_SRC/systemd/quadlets/"* $PULP_HOME/.config/containers/systemd/
as_pulp cp "$QUADLET_SRC/systemd/user/"*     $PULP_HOME/.config/systemd/user/

# Set the admin password in the oneshot container unit
sed -i "s|PULP_DEFAULT_ADMIN_PASSWORD=<your-admin-password>|PULP_DEFAULT_ADMIN_PASSWORD=$ADMIN_PASSWORD|" \
    $PULP_HOME/.config/containers/systemd/pulp-set-init-password.container

# ---------------------------------------------------------------------------
# Start Pulp
# ---------------------------------------------------------------------------

as_pulp systemctl --user daemon-reload

# Create the pulpnet network so postgres/redis can join it before Pulp starts.
as_pulp systemctl --user start pulpnet-network.service

# Postgres and Redis run on pulpnet so Pulp containers can reach them by name.
as_pulp podman run -d --replace --name pulp-postgres \
    -e POSTGRES_USER=pulp \
    -e POSTGRES_PASSWORD=$ADMIN_PASSWORD \
    -e POSTGRES_DB=pulp \
    --network pulpnet \
    docker.io/library/postgres:16

as_pulp podman run -d --replace --name pulp-redis \
    --network pulpnet \
    docker.io/library/redis:latest

as_pulp systemctl --user start pulp.target

echo "Waiting for Pulp API (migrations run first, allow ~3 min)..."
for i in $(seq 1 60); do
    if as_pulp curl -sf http://localhost:8080/pulp/api/v3/status/ > /dev/null 2>&1; then
        echo ""
        echo "=== Pulp is up! ==="
        as_pulp curl -s http://localhost:8080/pulp/api/v3/status/ | python3 -m json.tool
        echo ""
        echo "API:      http://localhost:8080/pulp/api/v3/"
        echo "Username: admin  Password: $ADMIN_PASSWORD"
        exit 0
    fi
    printf "."
    sleep 5
done

echo ""
echo "WARNING: Pulp did not become ready within 5 minutes."
echo "Check logs with:  vagrant ssh -c 'sudo -u pulp journalctl --user -u pulp.target'"
exit 1
