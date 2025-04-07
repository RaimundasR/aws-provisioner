#!/bin/bash

set -e


# Load Vault token automatically if available
# if [[ -f "$HOME/.vault.env" ]]; then
#   source "$HOME/.vault.env"
# fi

CONFIG_FILE="config/infra.config.json"
export AWS_PROFILE=ec2_micro_provisioner
DNS_FILE="terraform/cloudflare/dns.tfvars.json"

DOMAIN=""
INSTANCE_NAME=""
TOOL_ID=""
DESTROY_TOOL_ONLY=false
ACTION=""

# Extract value from JSON config
function get_config_value() {
  jq -r ".$1" "$CONFIG_FILE"
}

# function vault_login() {
#   echo "📛 VAULT_TOKEN in script is: $VAULT_TOKEN"
#   if [[ -z "$VAULT_TOKEN" ]]; then
#     echo "❌ VAULT_TOKEN is not set. Please export it before running."
#     exit 1
#   fi
#   echo "🔐 Using provided Vault token"
# }

# function download_config_from_vault() {
#   SECRET_PATH="k8s/infra.config.json"

#   echo "📥 Downloading Vault secret '$SECRET_PATH'..."
#   vault_login

#   # ✅ Your secret is directly under .data
#   vault kv get -format=json "$SECRET_PATH" \
#     | jq '.data' \
#     > "$CONFIG_FILE"

#   echo "✅ Config downloaded to $CONFIG_FILE"

#   SSH_USER=$(jq -r '.ssh_user' "$CONFIG_FILE")
#   SSH_KEY=$(jq -r '.private_key_path' "$CONFIG_FILE")

#   if [[ "$SSH_USER" == "null" || -z "$SSH_USER" ]]; then
#     echo "❌ Missing or invalid 'ssh_user' in Vault config"
#     exit 1
#   fi
#   if [[ "$SSH_KEY" == "null" || -z "$SSH_KEY" ]]; then
#     echo "❌ Missing or invalid 'private_key_path' in Vault config"
#     exit 1
#   fi

#   echo "🧩 ssh_user: $SSH_USER"
#   echo "🧩 private_key_path: $SSH_KEY"
# }


# function cleanup_configs() {
#   echo "🧹 Cleaning up config JSON files..."
#   rm -f config/*.json
# }

function generate_inventory() {
  IP="$1"
  USER=$(get_config_value ssh_user)
  KEY_PATH=$(get_config_value private_key_path)

  echo "🔎 Using SSH user: $USER"
  echo "🔑 Using SSH key: $KEY_PATH"
  echo "🌐 Using IP: $IP"

  # Attempt to auto-detect the Python interpreter used by Ansible
  DETECTED_PYTHON=$(ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no "$USER@$IP" \
    "command -v python3.12 || command -v python3.10 || command -v python3 || echo '/usr/bin/python3'")

  echo "🐍 Detected Python interpreter: $DETECTED_PYTHON"

  cat <<EOF > inventory.ini
[microk8s]
$IP ansible_user=$USER ansible_ssh_private_key_file=$KEY_PATH ansible_python_interpreter=$DETECTED_PYTHON
EOF

  echo "📄 Generated inventory.ini:"
  cat inventory.ini
}

function wait_for_ssh() {
  IP="$1"
  USER=$(get_config_value ssh_user)
  KEY_PATH=$(get_config_value private_key_path)
  echo "⏳ Waiting for SSH to be available on $IP..."
  until ssh -o StrictHostKeyChecking=no -i "$KEY_PATH" "$USER@$IP" 'echo "SSH is ready"' 2>/dev/null; do
    echo "🔁 Still waiting for SSH on $IP..."
    sleep 5
  done
  echo "✅ SSH is ready!"
}

function create() {
  echo "🔧 Reading config from $CONFIG_FILE..."
  REGION=$(get_config_value region)

  echo "🚀 Running Terraform for AWS in region: $REGION with instance name: $INSTANCE_NAME"
  cd terraform/aws
  terraform init -input=false
  terraform apply -auto-approve \
    -var-file=../../config/infra.config.json \
    -var="instance_name=$INSTANCE_NAME"
  cd ../..

  echo "🔍 Fetching public IP from terraform output..."
  IP=$(terraform -chdir=terraform/aws output -raw instance_ip)
  echo "🌐 Instance IP: $IP"

  echo "⏳ Waiting a bit before attempting SSH..."
  sleep 30

  generate_inventory "$IP"
  wait_for_ssh "$IP"

  echo "🔧 Running base playbook for MicroK8s + FluxCD..."
  ANSIBLE_CONFIG=ansible/playbook/ansible.cfg \
  ansible-playbook -i inventory.ini ansible/playbook/playbook.yml \
    -e "instance_name=$INSTANCE_NAME domain=$DOMAIN"

  if [[ -n "$TOOL_ID" && -n "$DOMAIN" ]]; then
    echo "🔧 Installing tool: $TOOL_ID"
    ANSIBLE_CONFIG=ansible/playbook/ansible.cfg \
    ansible-playbook -i inventory.ini ansible/playbook/install_tool.yml \
      -e "tool_id=$TOOL_ID instance_name=$INSTANCE_NAME domain=$DOMAIN"

    echo "🌍 Appending $DOMAIN → $IP to dns.tfvars.json"

    # Ensure JSON file exists and is valid
    if [[ ! -f "$DNS_FILE" || ! $(jq -e . "$DNS_FILE" 2>/dev/null) ]]; then
      echo '{"dns_records": []}' > "$DNS_FILE"
    fi

    # Merge domain entry without overwriting others
    TMP=$(mktemp)
    jq --arg name "$DOMAIN" --arg content "$IP" \
      '.dns_records |= (map(select(.name != $name)) + [{"name": $name, "content": $content}])' \
      "$DNS_FILE" > "$TMP" && mv "$TMP" "$DNS_FILE"

    echo "✅ Ensured $DOMAIN is present in $DNS_FILE"

    echo "🌍 Running Terraform for Cloudflare"
    cd terraform/cloudflare
    terraform init -input=false
    terraform apply -auto-approve \
      -var-file="../../config/infra.config.json" \
      -var-file="dns.tfvars.json"
    cd ../..

    echo "✅ Tool '$TOOL_ID' installed + DNS setup for $DOMAIN"
  else
    echo "✅ Infrastructure for instance '$INSTANCE_NAME' created"
  fi

  # Call re-enabled cleanup
  # cleanup_configs
}

function destroy_tool_only() {
  echo "🔧 Destroying tool-specific resources for: $TOOL_ID"
  IP=$(terraform -chdir=terraform/aws output -raw instance_ip)

  generate_inventory "$IP"

  ANSIBLE_CONFIG=ansible/playbook/ansible.cfg \
  ansible-playbook -i inventory.ini ansible/playbook/uninstall_tool.yml \
    -e "tool_id=$TOOL_ID instance_name=$INSTANCE_NAME"

  if [[ -n "$DOMAIN" ]]; then
    echo "📉 Removing $DOMAIN from dns.tfvars.json"

    if [[ -f "$DNS_FILE" ]]; then
      TMP=$(mktemp)
      jq --arg domain "$DOMAIN" \
        '.dns_records |= map(select(.name != $domain))' \
        "$DNS_FILE" > "$TMP" && mv "$TMP" "$DNS_FILE"
      echo "✅ Updated $DNS_FILE without $DOMAIN"
    else
      echo "⚠️ dns.tfvars.json not found, skipping DNS removal"
    fi

    echo "🌍 Applying updated Terraform to remove DNS"
    cd terraform/cloudflare
    terraform init -input=false
    terraform apply -auto-approve \
      -var-file="../../config/infra.config.json" \
      -var-file="dns.tfvars.json"
    cd ../..
  fi

  echo "✅ Tool '$TOOL_ID' resources removed."
}

function destroy() {
  if [[ -n "$TOOL_ID" && -n "$DOMAIN" ]]; then
    echo "🔧 Destroying tool-specific resources for: $TOOL_ID"
    IP=$(terraform -chdir=terraform/aws output -raw instance_ip)

    generate_inventory "$IP"

    ANSIBLE_CONFIG=ansible/playbook/ansible.cfg \
    ansible-playbook -i inventory.ini ansible/playbook/uninstall_tool.yml \
      -e "tool_id=$TOOL_ID instance_name=$INSTANCE_NAME"

    echo "📉 Removing $DOMAIN from dns.tfvars.json"
    if [[ -f "$DNS_FILE" ]]; then
      TMP=$(mktemp)
      jq --arg domain "$DOMAIN" \
        '.dns_records |= map(select(.name != $domain))' \
        "$DNS_FILE" > "$TMP" && mv "$TMP" "$DNS_FILE"
      echo "✅ Updated $DNS_FILE without $DOMAIN"
    else
      echo "⚠️ dns.tfvars.json not found, skipping DNS removal"
    fi

    echo "🌍 Applying updated Terraform to remove DNS"
    cd terraform/cloudflare
    terraform init -input=false
    terraform apply -auto-approve \
      -var-file="../../config/infra.config.json" \
      -var-file="dns.tfvars.json"
    cd ../..

    echo "✅ Tool '$TOOL_ID' resources removed."
  fi

  echo "🔥 Destroying EC2 instance using Terraform..."
  cd terraform/aws
  terraform destroy -auto-approve \
    -var-file=../../config/infra.config.json \
    -var="instance_name=$INSTANCE_NAME"
  cd ../..

  echo "🧹 Cleaning up local inventory..."
  rm -f inventory.ini

  echo "✅ Teardown complete."
}


# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--action)
      ACTION="$2"
      shift 2
      ;;
    --name)
      INSTANCE_NAME="$2"
      shift 2
      ;;
    --domain)
      DOMAIN="$2"
      shift 2
      ;;
    -t|--tool)
      TOOL_ID="$2"
      shift 2
      ;;
    --destroy)
      DESTROY_TOOL_ONLY=true
      shift
      ;;
    *)
      echo "❌ Unknown option: $1"
      echo "Usage: $0 -a [create|delete] --name <instance_name> [--domain example.com] [-t tool_id] [--destroy]"
      exit 1
      ;;
  esac
done

if [[ -z "$INSTANCE_NAME" ]]; then
  echo "❌ --name is required."
  echo "Usage: $0 -a [create|delete] --name <instance_name> [--domain example.com] [-t tool_id] [--destroy]"
  exit 1
fi

if [[ "$DESTROY_TOOL_ONLY" == true && -n "$TOOL_ID" ]]; then
  destroy_tool_only
  exit 0
fi

case "$ACTION" in
  create)
    create
    ;;
  delete)
    destroy
    ;;
  *)
    echo "❌ Invalid action: $ACTION"
    echo "Usage: $0 -a [create|delete] --name <instance_name> [--domain example.com] [-t tool_id] [--destroy]"
    exit 1
    ;;
esac
