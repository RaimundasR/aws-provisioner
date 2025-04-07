# AWS MicroK8s Provisioner with Ansible and Terraform

This project provisions a MicroK8s instance on AWS, installs tools (like Jenkins or Podinfo) with Ansible roles, and manages DNS records via Cloudflare using Terraform.

---

## 🔧 What It Does

- **Creates AWS EC2 instance**
- **Installs MicroK8s and FluxCD** via Ansible
- **Installs selected tools (e.g., Jenkins, Podinfo)**
- **Creates and destroys Cloudflare DNS records**
- **Cleans up instances and resources easily**

---

## 🏗️ Project Structure

```
.
├── runner.sh                       # Main CLI for managing infrastructure
├── terraform/
│   ├── aws/                        # EC2 provisioning logic
│   └── cloudflare/                # DNS record logic
├── config/
│   └── infra.config.json          # AWS key, region, user config
├── ansible/
│   ├── playbook/
│   │   ├── playbook.yml           # Base installer: MicroK8s + FluxCD
│   │   ├── install_tool.yml       # Tool installer (runs role service-<tool>)
│   │   └── uninstall_tool.yml     # Tool remover
│   └── roles/
│       ├── service-<tool>         # Tool-specific logic
│       ├── common-*               # Shared modules like microk8s, fluxcd
│       └── service-tool-installer # Template-based tool installation
└── setup-deps/
    └── install_deps.sh            # Optional: installs Ansible/Terraform locally
```

---

## 🚀 How It Works

### Provision New Environment (MicroK8s + FluxCD only)
```bash
./runner.sh -a create --name myenv
```
This:
- Launches EC2 using Terraform
- Waits for SSH
- Installs MicroK8s + FluxCD using `playbook.yml`

### Provision with a Tool (e.g., Podinfo or Jenkins)
```bash
./runner.sh -a create --name myenv --domain mytool.dev --tool podinfo
```
This:
- Provisions EC2 and installs MicroK8s if needed
- Installs only the specified tool via `install_tool.yml`
- Creates a DNS record `mytool.dev` pointing to EC2 IP

### Destroy Entire Environment
```bash
./runner.sh -a delete --name myenv --domain mytool.dev
```
This:
- Removes the EC2 instance
- Deletes associated Cloudflare DNS record

### Destroy Only a Tool
```bash
./runner.sh -a delete --name myenv --domain mytool.dev -t podinfo --destroy
```
This:
- Leaves EC2/MicroK8s intact
- Deletes only the selected tool via `uninstall_tool.yml`
- Cleans up its DNS record

---

## 🧠 Notes
- The Ansible inventory is dynamically generated using EC2's IP
- SSH availability is automatically waited on
- Tools must have a corresponding `roles/service-<tool>` directory
- Terraform config is split per-provider for clarity

---

## ✅ Requirements
- `jq`, `ansible`, `terraform`, `ssh`
- AWS credentials configured (via `infra.config.json`)
- Cloudflare API credentials (via `infra.config.json`)

---

## 💡 Tip
Use the `--destroy` flag with `-t` to cleanly remove tools without wiping your cluster.

```bash
./runner.sh --name myenv --domain app.dev -t jenkins --destroy
```

---


