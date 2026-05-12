# Pulp with Podman Quadlets

This directory provides an example of running Pulp as a **rootless Podman**
service managed by **systemd Quadlets** — as an alternative to the
Docker Compose setup in `images/compose/`.

The key differences from the Compose setup are:

- All containers run as a dedicated `pulp` system user (rootless Podman)
- systemd manages the full lifecycle: startup ordering, restarts, dependencies
- Scalable: `pulp-api@`, `pulp-content@`, and `pulp-worker@` are
  [instantiated units](https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html#Description)
  — run as many instances as needed
- Pulp artifact storage uses a named Podman volume (`pulp`), declared as a Quadlet
- The Podman container network (`pulpnet`) is also declared as a Quadlet

## Architecture

```
systemd (user scope, pulp user)
│
└── pulp.target                      ← top-level: start everything
    ├── pulp-volume.service          ← auto-generated from pulp.volume (Podman named volume)
    ├── pulpnet-network.service      ← auto-generated from pulpnet.network
    ├── pulp-migration.service       ← one-shot: DB migrations
    ├── pulp-signing-key.service     ← one-shot: register GPG signing service in Pulp
    ├── pulp-set-init-password.service  ← one-shot: set admin password on first boot
    ├── pulp-web.service             ← nginx reverse proxy (PublishPort 8080)
    ├── pulp-apis.target
    │   ├── pulp-api@1.service
    │   └── pulp-api@2.service  (scale by adding more instances)
    ├── pulp-contents.target
    │   ├── pulp-content@1.service
    │   └── pulp-content@2.service
    └── pulp-workers.target
        ├── pulp-worker@1.service
        └── pulp-worker@2.service
```

## Prerequisites

- A RHEL/Fedora host (Quadlet ships with Podman ≥ 4.4 via
  `podman-systemd` or the `quadlet` package)
- Podman installed
- A dedicated `pulp` user with a fixed UID (e.g. 1001) and **lingering
  enabled** so its user services survive logout:

  ```sh
  sudo useradd --uid 1001 --system --create-home pulp
  sudo loginctl enable-linger pulp
  ```

- The `pulp` UID must map to container UID 700 (the Pulp image user).
  The quadlets use `UserNS=keep-id:uid=700,gid=700` for this mapping.

## Directory layout

```
images/quadlet/
├── assets/
│   ├── bin/
│   │   └── nginx.sh                    ← nginx startup script (resolves nameserver)
│   ├── nginx/
│   │   └── nginx.conf.template         ← nginx config (uses $NAMESERVER, $pulp_api, $pulp_content)
│   └── settings.py.example             ← Pulp Django settings (copy and edit)
└── systemd/
    ├── quadlets/                        → copy to ~/.config/containers/systemd/
    │   ├── pulpnet.network
    │   ├── pulp.volume
    │   ├── pulp.target
    │   ├── pulp-migration.container
    │   ├── pulp-signing-key.container
    │   ├── pulp-set-init-password.container
    │   ├── pulp-api@.container
    │   ├── pulp-content@.container
    │   ├── pulp-worker@.container
    │   └── pulp-web.container
    └── user/                            → copy to ~/.config/systemd/user/
        ├── pulp-apis.target
        ├── pulp-contents.target
        └── pulp-workers.target
```

## Setup

### 1. Copy assets and settings

As the `pulp` user:

```sh
mkdir -p ~/pulp/assets/{bin,certs,nginx}

# Copy assets
cp images/quadlet/assets/bin/* ~/pulp/assets/bin/
cp images/quadlet/assets/nginx/nginx.conf.template ~/pulp/assets/nginx/

# Copy and fill in settings
cp images/quadlet/assets/settings.py.example ~/pulp/assets/settings.py
# Edit the file and replace all <placeholder> values
```

### 2. Install systemd units

As the `pulp` user:

```sh
mkdir -p ~/.config/containers/systemd ~/.config/systemd/user

cp images/quadlet/systemd/quadlets/* ~/.config/containers/systemd/
cp images/quadlet/systemd/user/*      ~/.config/systemd/user/
```

### 3. Scaling

The example targets ship with 2 instances each. To change the number of
instances, edit the `Wants=` lines in `pulp-apis.target`, `pulp-contents.target`,
and `pulp-workers.target`, and the `After=` lines in `pulp-web.container`.

When using an Ansible role to generate these files, you can template the
replica count automatically.

### 4. Start Pulp

As the `pulp` user:

```sh
systemctl --user daemon-reload
systemctl --user enable --now pulp.target
```

Follow the logs:

```sh
journalctl --user -fu pulp.target
```

Check status:

```sh
systemctl --user status pulp.target
```

## Testing locally

The Compose setup in `images/compose/` is fully self-contained: one
`podman-compose up` starts everything. The Quadlet setup differs in that
**Postgres and Redis are not included** — they are expected to already be
running (as they would be in production). For local testing, start them
as plain Podman containers first.

### Quickstart with Vagrant

The easiest way to test is with the included `Vagrantfile`, which spins up a
Fedora 40 VM and provisions everything automatically:

```sh
cd images/quadlet
vagrant up        # ~3-5 min; API is up when provisioning finishes
curl http://localhost:8080/pulp/api/v3/status/   # forwarded to the VM

vagrant ssh       # log into the VM
sudo -u pulp journalctl --user -fu pulp.target   # follow logs

vagrant destroy   # tear everything down
```

Supports VirtualBox and libvirt providers. Requires Vagrant ≥ 2.3.

### Manual steps (on an existing Fedora/RHEL host)

```sh
podman run -d --name pulp-postgres \
  -e POSTGRES_USER=pulp \
  -e POSTGRES_PASSWORD=password \
  -e POSTGRES_DB=pulp \
  --network host \
  docker.io/library/postgres:16

podman run -d --name pulp-redis \
  --network host \
  docker.io/library/redis:latest
```

`--network host` lets the Pulp containers reach them at `127.0.0.1`.

### 2. Generate credentials and certs

```sh
mkdir -p ~/pulp/assets/certs

# Symmetric key for encrypted database fields
python3 -c "
from cryptography.fernet import Fernet
print(Fernet.generate_key().decode())
" > ~/pulp/assets/certs/database_fields.symmetric.key

# EC key pair for container registry token auth
openssl ecparam -name prime256v1 -genkey -noout \
  -out ~/pulp/assets/certs/container_auth_private_key.pem
openssl ec -in ~/pulp/assets/certs/container_auth_private_key.pem \
  -pubout -out ~/pulp/assets/certs/container_auth_public_key.pem
```

### 3. Configure settings.py for localhost

```sh
cp images/quadlet/assets/settings.py.example ~/pulp/assets/settings.py
```

Edit `~/pulp/assets/settings.py` and replace all `<placeholder>` values:

```python
SECRET_KEY     = "<generate with the command in the file>"
CONTENT_ORIGIN = "http://localhost:8080"
TOKEN_SERVER   = "http://localhost:8080/token/"
DATABASES      = {"default": {"HOST": "127.0.0.1", "PASSWORD": "password", ...}}
REDIS_HOST     = "127.0.0.1"
```

Also add `DATABASES_FIELDS_SYMMETRIC_KEY = "/etc/pulp/certs/database_fields.symmetric.key"`.

### 4. Copy assets and quadlet units

```sh
mkdir -p ~/pulp/assets/{bin,nginx}
cp images/quadlet/assets/bin/nginx.sh ~/pulp/assets/bin/
cp images/quadlet/assets/nginx/nginx.conf.template ~/pulp/assets/nginx/

mkdir -p ~/.config/containers/systemd ~/.config/systemd/user
cp images/quadlet/systemd/quadlets/* ~/.config/containers/systemd/
cp images/quadlet/systemd/user/*      ~/.config/systemd/user/
```

### 5. Start the stack

```sh
systemctl --user daemon-reload
systemctl --user start pulp.target
```

### 6. Smoke test

```sh
# Migration runs first; wait until the API is up
until curl -sf http://localhost:8080/pulp/api/v3/status/ > /dev/null; do
  sleep 3
done
curl -s http://localhost:8080/pulp/api/v3/status/ | python3 -m json.tool
```

### Tear down

```sh
systemctl --user stop pulp.target
podman volume rm systemd-pulp   # named volume created by pulp.volume
podman stop pulp-postgres pulp-redis
podman rm pulp-postgres pulp-redis
```

### Validate unit syntax without running

To check that the quadlet files parse correctly without starting anything:

```sh
systemd-analyze verify ~/.config/containers/systemd/pulp.target
```

## Notes on the nginx alias approach

Each `pulp-api@N` container registers the alias `pulp_api` on the `pulpnet`
network. Podman's built-in DNS resolves `pulp_api` to all matching containers,
and nginx re-resolves it every 10 seconds using `resolver $NAMESERVER valid=10s`.
This gives round-robin load balancing without an external load balancer.

The same applies to `pulp_content` for `pulp-content@N` instances.

Under Podman the `/etc/resolv.conf` nameserver list can include unreachable
entries; `nginx.sh` therefore picks only the first nameserver entry.

## SELinux

The `:z` volume option on bind-mounted host paths (settings, certs, assets)
relabels them automatically so rootless Podman containers can access them on
SELinux-enforcing systems. The named `pulp` volume is managed entirely by
Podman and needs no special labelling.
