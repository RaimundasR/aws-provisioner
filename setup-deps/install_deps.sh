#!/bin/bash

set -e

detect_os() {
  UNAME=$(uname)
  if [[ "$UNAME" == "Darwin" ]]; then
    echo "macOS"
  elif [[ "$UNAME" == "Linux" ]]; then
    echo "Linux"
  else
    echo "Unsupported"
  fi
}

install_common_packages() {
  echo "📦 Installing core tools: jq, curl, unzip, git..."

  case "$1" in
    "macOS")
      brew install jq curl unzip git
      ;;

    "Linux")
      if command -v apt &>/dev/null; then
        sudo apt update
        sudo apt install -y jq curl unzip git
      elif command -v yum &>/dev/null; then
        sudo yum install -y jq curl unzip git
      else
        echo "❌ Unsupported Linux package manager"
        exit 1
      fi
      ;;
  esac
}

install_terraform() {
  echo "📦 Installing Terraform..."

  LATEST_VERSION=$(curl -s https://checkpoint-api.hashicorp.com/v1/check/terraform | jq -r .current_version)
  echo "🌐 Latest Terraform version: $LATEST_VERSION"

  case "$1" in
    "macOS")
      brew tap hashicorp/tap
      brew install hashicorp/tap/terraform
      ;;

    "Linux")
      TEMP_DIR=$(mktemp -d)
      cd "$TEMP_DIR"
      ARCH=$(uname -m)
      if [[ "$ARCH" == "x86_64" ]]; then
        ARCH="amd64"
      elif [[ "$ARCH" == "aarch64" ]]; then
        ARCH="arm64"
      fi

      curl -Lo terraform.zip "https://releases.hashicorp.com/terraform/${LATEST_VERSION}/terraform_${LATEST_VERSION}_linux_${ARCH}.zip"
      unzip terraform.zip
      sudo mv terraform /usr/local/bin/
      cd -
      rm -rf "$TEMP_DIR"
      ;;

    *)
      echo "❌ Unsupported OS for Terraform install"
      exit 1
      ;;
  esac

  echo "✅ Terraform installed: $(terraform -version | head -n1)"
}

install_ansible() {
  echo "📦 Installing Ansible..."

  case "$1" in
    "macOS")
      brew install ansible
      ;;

    "Linux")
      if command -v apt &>/dev/null; then
        sudo apt update
        sudo apt install -y software-properties-common
        sudo add-apt-repository --yes --update ppa:ansible/ansible
        sudo apt install -y ansible
      elif command -v yum &>/dev/null; then
        sudo yum install -y epel-release
        sudo yum install -y ansible
      else
        echo "❌ Unsupported Linux package manager for Ansible"
        exit 1
      fi
      ;;
  esac

  echo "✅ Ansible installed: $(ansible --version | head -n1)"
}

install_docker() {
  echo "📦 Installing Docker..."

  case "$1" in
    "macOS")
      brew install --cask docker
      echo "🚨 Please open the Docker app manually to complete setup on macOS."
      ;;

    "Linux")
      if command -v apt &>/dev/null; then
        sudo apt update
        sudo apt install -y ca-certificates curl gnupg lsb-release
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
          $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt update
        sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        sudo usermod -aG docker "$USER"
      elif command -v yum &>/dev/null; then
        sudo yum install -y yum-utils
        sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        sudo yum install -y docker-ce docker-ce-cli containerd.io
        sudo systemctl enable --now docker
        sudo usermod -aG docker "$USER"
      else
        echo "❌ Unsupported Linux distro for Docker install"
        exit 1
      fi
      ;;
  esac

  echo "✅ Docker installed: $(docker --version)"
}

### MAIN FLOW

OS=$(detect_os)
if [[ "$OS" == "Unsupported" ]]; then
  echo "❌ Unsupported OS: $(uname)"
  exit 1
fi

echo "🧠 Detected OS: $OS"

install_common_packages "$OS"
install_terraform "$OS"
install_ansible "$OS"
install_docker "$OS"

echo "🎉 All tools installed successfully!"

