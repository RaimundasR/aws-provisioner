#!/bin/bash

set -e

# Load Vault token automatically if available
# if [[ -f "$HOME/.vault.env" ]]; then
#   source "$HOME/.vault.env"
# fi

CONFIG_FILE="config/infra.config.json"
export AWS_PROFILE=ec2_micro_provisioner
DNS_FILE="terraform/cloudflare/dns.tfvars.json"
INSTANCES_FILE_IP="terraform/aws/instance_ips.json"


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
#   echo "💛 VAULT_TOKEN in script is: $VAULT_TOKEN"
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
#   echo "🚹 Cleaning up config JSON files..."
#   rm -f config/*.json
# }

function generate_inventory() {
  IP="$1"
  USER=$(get_config_value ssh_user)
  KEY_PATH=$(get_config_value private_key_path)

  echo "Using SSH user: $USER"
  echo "Using SSH key: $KEY_PATH"
  echo "Using IP: $IP"

  DETECTED_PYTHON=$(ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no "$USER@$IP" \
    "command -v python3.12 || command -v python3.10 || command -v python3 || echo '/usr/bin/python3'")

  echo "Detected Python interpreter: $DETECTED_PYTHON"

  cat <<EOF > inventory.ini
[microk8s]
$IP ansible_user=$USER ansible_ssh_private_key_file=$KEY_PATH ansible_python_interpreter=$DETECTED_PYTHON
EOF

  echo "Generated inventory.ini:"
  cat inventory.ini
}

function wait_for_ssh() {
  IP="$1"
  USER=$(get_config_value ssh_user)
  KEY_PATH=$(get_config_value private_key_path)

  echo "⏳ Waiting for SSH to be available on $IP..."

  for attempt in {1..30}; do
    if ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$USER@$IP" "echo 'SSH OK'" 2>/dev/null; then
      echo "✅ SSH is ready on $IP"
      return
    else
      echo "⏳ SSH not ready yet (attempt $attempt/30)..."
      sleep 10
    fi
  done

  echo "❌ ERROR: SSH failed to connect after multiple attempts."
  exit 1
}


function save_instance_ip() {
  echo "💾 Saving AWS instance IP..."

  if [[ ! -f "$INSTANCES_FILE_IP" ]]; then
    echo '{}' > "$INSTANCES_FILE_IP"
  fi

  # ✨ Fetch IP from new Terraform output "instance_ips"
  IP=$(terraform -chdir=terraform/aws output -json instance_ips | jq -r --arg name "$INSTANCE_NAME" '.[$name] // empty')

  if [[ -z "$IP" ]]; then
    echo "⚠️ No IP found after Terraform apply."
    return
  fi

  TMP=$(mktemp)
  jq --arg name "$INSTANCE_NAME" --arg ip "$IP" '. + {($name): $ip}' "$INSTANCES_FILE_IP" > "$TMP" && mv "$TMP" "$INSTANCES_FILE_IP"

  echo "✅ Saved IP for $INSTANCE_NAME: $IP"
}


function save_instance_tfvars() {
  echo "💾 Updating Terraform instance.tfvars.json for $INSTANCE_NAME"

  INSTANCE_TFVARS_FILE="terraform/aws/instance.tfvars.json"

  if [[ ! -f "$INSTANCE_TFVARS_FILE" ]]; then
    echo '{"instances": {}}' > "$INSTANCE_TFVARS_FILE"
  fi

  AMI=$(get_config_value ami)
  INSTANCE_TYPE=$(get_config_value instance_type)
  KEY_NAME=$(get_config_value key_name)

  TMP=$(mktemp)
  jq --arg name "$INSTANCE_NAME" \
     --arg ami "$AMI" \
     --arg instance_type "$INSTANCE_TYPE" \
     --arg key_name "$KEY_NAME" \
     '.instances |= . + {($name): {"ami": $ami, "instance_type": $instance_type, "key_name": $key_name}}' \
     "$INSTANCE_TFVARS_FILE" > "$TMP" && mv "$TMP" "$INSTANCE_TFVARS_FILE"

  echo "✅ Saved instance $INSTANCE_NAME to $INSTANCE_TFVARS_FILE"
}



function update_dns_from_instance() {
  echo "Updating DNS records from instance IP..."

  if [[ ! -f "$INSTANCES_FILE_IP" ]]; then
    echo "❌ $INSTANCES_FILE_IP not found."
    exit 1
  fi

  IP=$(jq -r --arg name "$INSTANCE_NAME" '.[$name]' "$INSTANCES_FILE_IP")

  if [[ "$IP" == "null" || -z "$IP" ]]; then
    echo "❌ Instance $INSTANCE_NAME not found in $INSTANCES_FILE_IP"
    exit 1
  fi

  if [[ -z "$DOMAIN" ]]; then
    echo "❌ DOMAIN variable is empty, cannot update DNS."
    exit 1
  fi

  if [[ ! -f "$DNS_FILE" ]]; then
    echo '{"dns_records": []}' > "$DNS_FILE"
  fi

  # Check if domain already exists (optional safety)
  DOMAIN_EXISTS=$(jq -r --arg name "$DOMAIN" '.dns_records[]? | select(.name == $name) | .name' "$DNS_FILE")

  if [[ "$DOMAIN_EXISTS" == "$DOMAIN" ]]; then
    echo "ℹ️ Domain $DOMAIN already exists in DNS file, updating IP..."
    TMP=$(mktemp)
    jq --arg name "$DOMAIN" --arg content "$IP" '
      .dns_records |= map(if .name == $name then .content = $content else . end)
    ' "$DNS_FILE" > "$TMP" && mv "$TMP" "$DNS_FILE"
  else
    echo "➕ Adding new domain $DOMAIN → $IP to DNS records"
    TMP=$(mktemp)
    jq --arg name "$DOMAIN" --arg content "$IP" '
      .dns_records += [{"name": $name, "content": $content}]
    ' "$DNS_FILE" > "$TMP" && mv "$TMP" "$DNS_FILE"
  fi

  echo "✅ DNS updated: $DOMAIN → $IP"
}

function remove_instance_from_instances_file() {
  echo "🧹 Removing instance $INSTANCE_NAME from local IP and DNS files..."

  # Remove IP from instance_ips.json
  if [[ -f "$INSTANCES_FILE_IP" ]]; then
    TMP=$(mktemp)
    jq "del(.\"$INSTANCE_NAME\")" "$INSTANCES_FILE_IP" > "$TMP" && mv "$TMP" "$INSTANCES_FILE_IP"
    echo "✅ Removed $INSTANCE_NAME from $INSTANCES_FILE_IP"
  fi

  # Remove domain from dns.tfvars.json
  if [[ -f "$DNS_FILE" ]]; then
    TMP=$(mktemp)
    jq --arg domain "$DOMAIN" '.dns_records |= map(select(.name != $domain))' "$DNS_FILE" > "$TMP" && mv "$TMP" "$DNS_FILE"
    echo "✅ Removed $DOMAIN from $DNS_FILE"
  fi
}


function apply_dns() {
  echo "🌐 Applying DNS changes to Cloudflare..."

  cd terraform/cloudflare
  terraform init -input=false
  terraform apply -auto-approve \
    -var-file=../../config/infra.config.json \
    -var-file=dns.tfvars.json
  cd ../..

  echo "✅ DNS changes applied to Cloudflare."
}



function create() {
  echo "🔧 Reading config from $CONFIG_FILE..."
  REGION=$(get_config_value region)

  echo "🚀 Preparing Terraform instance config for: $INSTANCE_NAME"

  # Save or update terraform/aws/instance.tfvars.json
  save_instance_tfvars

  echo "🚀 Running Terraform apply in region: $REGION"
  cd terraform/aws
  terraform init -input=false
  terraform apply -auto-approve \
    -var-file=../../config/infra.config.json \
    -var-file=instance.tfvars.json
  cd ../..

  # Save the instance IP after terraform apply
  save_instance_ip

  echo "🔍 Fetching public IP for $INSTANCE_NAME..."
  IP=$(jq -r --arg name "$INSTANCE_NAME" '.[$name]' "$INSTANCES_FILE_IP")

  echo "🌐 Instance IP: $IP"

  if [[ -z "$IP" || "$IP" == "null" ]]; then
    echo "❌ Failed to get IP for instance $INSTANCE_NAME"
    exit 1
  fi

  echo "⏳ Waiting before SSH..."
  sleep 60

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
    
    # Update local dns.tfvars.json
    update_dns_from_instance
    
    # 🌐 Apply DNS changes to Cloudflare
    echo "🌐 Applying DNS changes to Cloudflare..."
    cd terraform/cloudflare
    terraform init -input=false
    terraform apply -auto-approve \
      -var-file=../../config/infra.config.json \
      -var-file=dns.tfvars.json
    cd ../..
    echo "✅ DNS changes applied to Cloudflare."
  fi 
}

function destroy_tool_only() {
  echo "🔧 Destroying tool-specific resources for: $TOOL_ID"

  if [[ ! -f "$INSTANCES_FILE_IP" ]]; then
    echo "❌ $INSTANCES_FILE_IP not found."
    exit 1
  fi

  IP=$(jq -r --arg name "$INSTANCE_NAME" '.[$name]' "$INSTANCES_FILE_IP")

  if [[ -z "$IP" || "$IP" == "null" ]]; then
    echo "❌ Failed to find IP for $INSTANCE_NAME in $INSTANCES_FILE_IP"
    exit 1
  fi

  generate_inventory "$IP"

  echo "🧹 Running Ansible to uninstall tool '$TOOL_ID' from $INSTANCE_NAME"
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
      echo "⚠️ $DNS_FILE not found, skipping DNS removal"
    fi

    echo "🌐 Applying updated DNS to Cloudflare..."
    cd terraform/cloudflare
    terraform init -input=false
    terraform apply -auto-approve \
      -var-file=../../config/infra.config.json \
      -var-file=dns.tfvars.json
    cd ../..
    echo "✅ DNS changes applied"
  fi

  echo "✅ Tool '$TOOL_ID' resources removed from $INSTANCE_NAME."
}


function destroy() {
  echo "🔥 Destroying instance $INSTANCE_NAME from instance.tfvars.json..."

  INSTANCE_TFVARS_FILE="terraform/aws/instance.tfvars.json"

  if [[ ! -f "$INSTANCE_TFVARS_FILE" ]]; then
    echo "❌ instance.tfvars.json not found! Cannot destroy."
    exit 1
  fi

  # Remove instance from terraform/aws/instance.tfvars.json
  TMP=$(mktemp)
  jq --arg name "$INSTANCE_NAME" 'del(.instances[$name])' "$INSTANCE_TFVARS_FILE" > "$TMP" && mv "$TMP" "$INSTANCE_TFVARS_FILE"

  echo "🧹 Updated instance.tfvars.json to remove $INSTANCE_NAME"

  cd terraform/aws
  terraform init -input=false

  terraform apply -auto-approve \
    -var-file=../../config/infra.config.json \
    -var-file=instance.tfvars.json
  cd ../..

  # Remove from local files (IP and DNS)
  remove_instance_from_instances_file

  # 🌐 Apply changes to Cloudflare DNS
  echo "🌐 Applying DNS changes to Cloudflare..."
  cd terraform/cloudflare
  terraform init -input=false
  terraform apply -auto-approve \
    -var-file=../../config/infra.config.json \
    -var-file=dns.tfvars.json
  cd ../..

  echo "🧹 Cleaning up local inventory.ini"
  rm -f inventory.ini

  echo "✅ Instance $INSTANCE_NAME destroyed and DNS cleaned up"
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
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$INSTANCE_NAME" ]]; then
  echo "❌ --name is required."
  exit 1
fi

case "$ACTION" in
  create)
    create
    ;;
  delete)
    if [[ "$DESTROY_TOOL_ONLY" == true ]]; then
      destroy_tool_only
    else
      destroy
    fi
    ;;
  *)
    echo "❌ Invalid action: $ACTION"
    exit 1
    ;;
esac
