# Pulp Quadlet — Ansible Role

This directory provides an [Ansible role](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_reuse_roles.html)
that templates and deploys the Pulp Quadlet setup from `../quadlet/` onto a
target host.

This is a companion to the static example in `../quadlet/`. Using the Ansible
approach lets you:

- Drive replica counts, image versions, ports, and paths from inventory vars
- Re-deploy or upgrade by re-running the playbook
- Manage multiple Pulp hosts from one place

## Role: `pulp_quadlet`

### Variables

All variables are defined in `roles/pulp_quadlet/vars/main.yml` with defaults.
The ones marked **required** have no default and must be provided.

| Variable | Default | Description |
|---|---|---|
| `pulp_version` | `latest` | Image tag for `pulp-minimal` and `pulp-web` |
| `image_source` | `quay.io` | Container registry prefix |
| `pulp_port` | `8080` | Host port exposed by `pulp-web` |
| `pulp_host_dir` | `/home/pulp/pulp` | Base directory for settings/assets on host |
| `pulp_api_hostname` | **required** | Public hostname/IP used in `CONTENT_ORIGIN` |
| `pulp_db_host` | **required** | PostgreSQL host |
| `pulp_db_name` | `pulp` | PostgreSQL database name |
| `pulp_db_user` | `pulp` | PostgreSQL user |
| `pulp_db_password` | **required** | PostgreSQL password |
| `pulp_redis_host` | **required** | Redis host |
| `pulp_redis_port` | `6379` | Redis port |
| `pulp_api_replicas` | `2` | Number of `pulp-api@N` instances |
| `pulp_content_replicas` | `2` | Number of `pulp-content@N` instances |
| `pulp_worker_replicas` | `2` | Number of `pulp-worker@N` instances |
| `pulp_gunicorn_timeout` | `90` | Gunicorn request timeout (seconds) |
| `pulp_uid` | `1001` | UID of the `pulp` user on the host |
| `pulp_secret_key` | **required** | Django `SECRET_KEY` |
| `pulp_admin_password` | **required** | Initial Pulp admin password |

### Example playbook

```yaml
- hosts: pulp_servers
  roles:
    - role: pulp_quadlet
      vars:
        pulp_version: "3.70.0"
        pulp_api_hostname: "pulp.example.com"
        pulp_db_host: "db.example.com"
        pulp_db_password: "{{ vault_pulp_db_password }}"
        pulp_redis_host: "redis.example.com"
        pulp_secret_key: "{{ vault_pulp_secret_key }}"
        pulp_admin_password: "{{ vault_pulp_admin_password }}"
        pulp_api_replicas: 4
        pulp_worker_replicas: 3
```

## Comparison with the static approach

| | `images/quadlet/` (static) | `images/quadlet-ansible/` (this) |
|---|---|---|
| Replica count | Edit `Wants=` lines manually | Set `pulp_api_replicas: N` |
| Image version | Edit each `.container` file | Set `pulp_version: "3.x"` |
| Multiple hosts | Copy + edit per host | Inventory + group vars |
| Upgrades | Edit files + `systemctl daemon-reload` | Re-run the playbook |
| Simplicity | No Ansible needed | Requires Ansible control node |
