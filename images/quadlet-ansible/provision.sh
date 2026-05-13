#!/usr/bin/env bash
# Provisions a Fedora VM with the Pulp quadlet stack via the Ansible role.
# Postgres and Redis run as Podman containers on the same network as Pulp.
set -euo pipefail

# sudo -u inherits the cwd; /home/vagrant is not readable by other users.
cd /

ANSIBLE_SRC=/vagrant/quadlet-ansible
PULP_UID=1001
PULP_HOME=/home/pulp
PULP_DIR=$PULP_HOME/pulp
ADMIN_PASSWORD=password

# ---------------------------------------------------------------------------
# System setup (as root)
# ---------------------------------------------------------------------------

dnf install -y podman openssl ansible-core

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
# Credentials (generated before Ansible runs so certs are in place)
# ---------------------------------------------------------------------------

as_pulp mkdir -p $PULP_DIR/assets/{bin,certs,nginx}

as_pulp python3 -c "
import base64, os
print(base64.urlsafe_b64encode(os.urandom(32)).decode())
" > $PULP_DIR/assets/certs/database_fields.symmetric.key
chown pulp:pulp $PULP_DIR/assets/certs/database_fields.symmetric.key

as_pulp openssl ecparam -name prime256v1 -genkey -noout \
    -out $PULP_DIR/assets/certs/container_auth_private_key.pem
as_pulp openssl ec \
    -in  $PULP_DIR/assets/certs/container_auth_private_key.pem \
    -pubout \
    -out $PULP_DIR/assets/certs/container_auth_public_key.pem

# ---------------------------------------------------------------------------
# Create network and start Postgres + Redis on it before Ansible runs Pulp
# ---------------------------------------------------------------------------

as_pulp podman network create pulpnet 2>/dev/null || true

as_pulp podman run -d --replace --name pulp-postgres \
    -e POSTGRES_USER=pulp \
    -e POSTGRES_PASSWORD=$ADMIN_PASSWORD \
    -e POSTGRES_DB=pulp \
    --network pulpnet \
    docker.io/library/postgres:16

as_pulp podman run -d --replace --name pulp-redis \
    --network pulpnet \
    docker.io/library/redis:latest

# ---------------------------------------------------------------------------
# Run the Ansible role
# ---------------------------------------------------------------------------

SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(50))")

cat > /tmp/pulp-inventory.ini << EOF
localhost ansible_connection=local ansible_python_interpreter=/usr/bin/python3
EOF

cat > /tmp/pulp-playbook.yml << EOF
---
- hosts: localhost
  become: true
  roles:
    - role: pulp_quadlet
  vars:
    pulp_secret_key: "${SECRET_KEY}"
    pulp_api_hostname: "localhost"
    pulp_db_host: "pulp-postgres"
    pulp_db_password: "${ADMIN_PASSWORD}"
    pulp_redis_host: "pulp-redis"
    pulp_admin_password: "${ADMIN_PASSWORD}"
EOF

ANSIBLE_ROLES_PATH=$ANSIBLE_SRC/roles \
    ansible-playbook -i /tmp/pulp-inventory.ini /tmp/pulp-playbook.yml

# ---------------------------------------------------------------------------
# Wait for Pulp API
# ---------------------------------------------------------------------------

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
echo "Check logs with:  vagrant ssh -c 'sudo -u pulp journalctl --user -xe --no-pager'"
exit 1
