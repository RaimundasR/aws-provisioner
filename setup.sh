#!/bin/bash

set -e

CONFIG_FILE="terraform/infra.config.json"

# Extract value from JSON config
function get_config_value() {
  jq -r ".$1" "$CONFIG_FILE"
}

function create() {
  echo "🔧 Reading config from $CONFIG_FILE..."
  REGION=$(get_config_value region)
  KEY_PATH=$(get_config_value private_key_path)
  USER=ec2-user

  echo "🚀 Running terraform in region: $REGION"
  cd terraform
  terraform init -input=false
  terraform apply -auto-approve -var-file=infra.config.json
  cd ..

  echo "🔍 Fetching public IP from terraform output..."
  IP=$(terraform -chdir=terraform output -raw instance_ip)
  echo "🌐 Instance IP: $IP"

  echo "📦 Generating Ansible inventory..."
  cat <<EOF > inventory.ini
[microk8s]
$IP ansible_user=$USER ansible_ssh_private_key_file=$KEY_PATH
EOF

  echo "🔧 Running Ansible playbook to install MicroK8s..."
  ansible-playbook -i inventory.ini ansible/playbook.yaml

  echo "✅ MicroK8s node setup complete!"
}

function destroy() {
  echo "🔥 Destroying EC2 instance using terraform..."
  cd terraform
  terraform destroy -auto-approve -var-file=infra.config.json
  cd ..

  echo "🧹 Cleaning up local inventory..."
  rm -f inventory.ini
  echo "✅ Teardown complete."
}

# Parse command-line arguments
while getopts "a:" opt; do
  case "$opt" in
    a)
      if [[ $OPTARG == "create" ]]; then
        create
      elif [[ $OPTARG == "delete" ]]; then
        destroy
      else
        echo "❌ Invalid action: $OPTARG"
        echo "Usage: $0 -a [create|delete]"
        exit 1
      fi
      ;;
    *)
      echo "Usage: $0 -a [create|delete]"
      exit 1
      ;;
  esac
done

