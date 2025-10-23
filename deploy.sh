#!/usr/bin/env bash
# ==================================================
# 🚀 Hybrid Automated Deployment Script (POSIX-compliant)
# Author: Eng-Babs (HNG DevOps Stage 1)
# Automates Git clone, SSH setup, Docker deployment, and NGINX proxy
# ==================================================

set -e  # Exit on error

LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'echo "❌ Script failed at line $LINENO"; exit 1' ERR

echo ""
echo "=========================================="
echo "🚀 Starting Hybrid Automated Deployment"
echo "=========================================="
echo ""

# === Step 1: Collect Parameters ===
read -p "Enter your Git repository URL: " GIT_URL
read -p "Enter your Personal Access Token (leave blank if public): " PAT
read -p "Enter branch name (default: main): " BRANCH
read -p "Enter remote server username: " SSH_USER
read -p "Enter remote server IP address: " SERVER_IP
read -p "Enter SSH private key path (e.g., ~/.ssh/key.pem): " SSH_KEY
read -p "Enter app internal port (e.g., 3000): " APP_PORT
read -p "Configure NGINX reverse proxy? (yes/no): " CONFIGURE_NGINX

BRANCH=${BRANCH:-main}
SSH_KEY="${SSH_KEY/#\~/$HOME}"  # Expand tilde

echo ""
echo "📦 Step 2: Cloning or Updating Repository"
REPO_NAME=$(basename -s .git "$GIT_URL")
LOCAL_REPO_DIR="$PWD/$REPO_NAME"

if [[ -n "$PAT" ]]; then
  AUTH_URL=$(echo "$GIT_URL" | sed "s#https://#https://$PAT@#")
else
  AUTH_URL=$GIT_URL
fi

if [ -d "$LOCAL_REPO_DIR" ]; then
  cd "$LOCAL_REPO_DIR"
  git fetch origin "$BRANCH"
  git checkout "$BRANCH"
  git pull origin "$BRANCH"
else
  git clone -b "$BRANCH" "$AUTH_URL"
  cd "$LOCAL_REPO_DIR"
fi

echo "✅ Repository ready at $(pwd)"

# === Step 3: Verify Dockerfile / Compose ===
if [ ! -f "Dockerfile" ] && [ ! -f "docker-compose.yml" ]; then
  echo "❌ No Dockerfile or docker-compose.yml found!"
  exit 1
fi
echo "✅ Docker configuration found."

# === Step 4: SSH Connection Check ===
echo ""
echo "🔐 Step 4: Testing SSH connection..."
if [ ! -f "$SSH_KEY" ]; then
  echo "❌ SSH key not found at $SSH_KEY"
  exit 1
fi

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" \
  "echo '✅ SSH connection successful on $(hostname)'" || {
  echo "❌ SSH connection failed. Check credentials."
  exit 1
}

# === Step 5: Prepare Remote Environment ===
echo ""
echo "⚙️ Step 5: Preparing remote environment..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" bash <<EOF
set -e
sudo apt-get update -y
sudo apt-get install -y docker.io docker-compose nginx
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker $SSH_USER || true
echo "✅ Docker and NGINX installed successfully."
EOF

# === Step 6: Deploy Dockerized Application ===
echo ""
echo "🐳 Step 6: Deploying Dockerized Application"

REMOTE_DIR="/home/$SSH_USER/app_deploy"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" "mkdir -p $REMOTE_DIR"

echo "📤 Transferring project files (excluding .git and deploy_*.log)..."
cd "$LOCAL_REPO_DIR" || { echo "❌ Local repo not found at $LOCAL_REPO_DIR"; exit 1; }

tar czf - --exclude='.git' --exclude='deploy_*.log' . | \
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" \
"cd $REMOTE_DIR && tar xzf -"

echo "✅ Files transferred successfully!"

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" bash <<EOF
set -e
cd $REMOTE_DIR
if [ -f docker-compose.yml ]; then
  echo "📦 Using docker-compose..."
  sudo docker-compose down || true
  sudo docker-compose up -d --build
else
  APP_NAME=\$(basename "\$(pwd)")
  echo "🐳 Using single Dockerfile build..."
  sudo docker stop "\$APP_NAME" || true
  sudo docker rm "\$APP_NAME" || true
  sudo docker build -t "\$APP_NAME" .
  sudo docker run -d -p $APP_PORT:$APP_PORT --name "\$APP_NAME" "\$APP_NAME"
fi
echo "✅ Docker deployment successful!"
sudo docker ps
EOF

# === Step 7: Configure NGINX Reverse Proxy ===
if [[ "$CONFIGURE_NGINX" =~ ^(yes|y|Y)$ ]]; then
  echo ""
  echo "🌐 Step 7: Configuring NGINX reverse proxy..."
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" bash <<EOF
  set -e
  sudo bash -c "cat > /etc/nginx/sites-available/app.conf" <<NGINXCONF
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINXCONF
  sudo ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/app.conf
  sudo nginx -t && sudo systemctl reload nginx
  echo "✅ NGINX configured successfully."
EOF
else
  echo "🛑 Skipping NGINX setup."
fi

# === Step 8: Validate Deployment ===
echo ""
echo "🧪 Step 8: Validating deployment..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" bash <<EOF
set -e
sudo systemctl status docker | grep active
sudo docker ps
curl -I http://localhost:$APP_PORT || echo "⚠️ Local curl test failed, verify manually."
EOF
echo "✅ Validation completed!"

# === Step 9: Completion ===
echo ""
echo "🎉 Deployment completed successfully!"
echo "🌍 Access your app at: http://$SERVER_IP"
echo "📜 Logs saved in: $LOG_FILE"
echo "==========================================="

# === Step 10: Cleanup Option ===
if [[ "$1" == "--cleanup" ]]; then
  echo "🧹 Cleaning up deployment..."
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" bash <<EOF
  sudo docker stop app_deploy || true
  sudo docker rm app_deploy || true
  sudo rm -rf ~/app_deploy /etc/nginx/sites-enabled/app.conf
  sudo systemctl reload nginx
EOF
  echo "✅ Cleanup complete."
fi
