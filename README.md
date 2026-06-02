# DCM

Minimal Docker Compose manager.

`dcm` finds the nearest Compose file, enters that project directory, and runs common Docker Compose tasks through a small CLI or interactive menu.

## Requirements

- Bash
- Docker
- Docker Compose plugin (`docker compose`) or legacy `docker-compose`

Supported Compose file names:

- `compose.yaml`
- `compose.yml`
- `docker-compose.yml`
- `docker-compose.yaml`

## Install

Run directly from GitHub:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/CriDos/docker_compose_manage/main/dcm.sh)
```

Run from the repository:

```bash
chmod +x dcm.sh
./dcm.sh install
```

This installs `dcm` to `/usr/local/bin/dcm`.

To uninstall:

```bash
dcm uninstall
```

## Usage

Interactive mode:

```bash
dcm
```

Direct commands:

```bash
dcm start
dcm stop
dcm restart
dcm reload
dcm update
dcm rebuild
dcm status
dcm logs
dcm shell [service]
dcm prune
dcm destroy
```

## Commands

- `start` - run `docker compose up -d`
- `stop` - run `docker compose down`
- `restart` - restart containers
- `reload` - apply config changes with `up -d --remove-orphans`
- `update` - pull images, then apply changes
- `rebuild` - rebuild and recreate containers
- `status` - show container status
- `logs` - follow logs
- `shell [service]` - open `/bin/bash` or `/bin/sh` in a running service
- `prune` - prune unused Docker objects on the host
- `destroy` - remove project containers, volumes, and local images
- `install` - install the script globally
- `uninstall` - remove the global install

## Sudo

Do not run project commands with `sudo`.

`dcm` does not auto-prefix Docker commands with `sudo`. If Docker is not accessible by your user, fix Docker permissions instead:

```bash
sudo usermod -aG docker "$USER"
newgrp docker
```

`sudo` is used only when installing or uninstalling `/usr/local/bin/dcm`, if that path requires elevated permissions.

If you intentionally need to run a project command as root:

```bash
DCM_ALLOW_ROOT=1 sudo dcm status
```

## License

MIT
