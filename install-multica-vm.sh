#!/usr/bin/env bash
# ============================================================
# install-multica-vm.sh — VM "vm-app" sur ESXi n°2
# Ubuntu 24.04 · Docker + Multica (doc EF-VIRTU-MULTICA v2.5)
#              + OpenWebUI branché sur la VM Ollama
# ============================================================
set -euo pipefail

# --- À ADAPTER ----------------------------------------------
IP_LLM="${IP_LLM:-10.13.1.X}"        # IP de vm-llm (hostname -I sur l'autre VM)
IP_APP=$(hostname -I | awk '{print $1}')
# Images Multica : même nommage que la doc (registry à ajuster
# si tes images sont dans Gitea plutôt que Docker Hub)
MULTICA_VERSION="${MULTICA_VERSION:-v0.6.1}"
# ------------------------------------------------------------

echo "== [1/7] Mise à jour =="
apt update && apt -y full-upgrade
apt -y install curl ufw fail2ban git jq ca-certificates

echo "== [2/7] Docker CE + plugin compose =="
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt update && apt -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker

echo "== [3/7] Stack Multica (compose, cf. doc chapitre 2 et 8) =="
mkdir -p /opt/multica && cd /opt/multica

cat > docker-compose.yml <<EOF
# Stack Multica - ref EF-VIRTU-MULTICA v2.5 (adaptée Ollama local)
# Binds 0.0.0.0 : survit aux changements d'IP (DHCP ecole)
services:
  postgres:
    image: pgvector/pgvector:pg17
    restart: unless-stopped
    environment:
      POSTGRES_USER: multica
      POSTGRES_PASSWORD: change-moi-mot-de-passe-fort
      POSTGRES_DB: multica
    volumes:
      - multica_pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U multica"]
      interval: 10s
      timeout: 5s
      retries: 5

  backend:
    image: multica-backend:${MULTICA_VERSION}
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      DATABASE_URL: postgres://multica:change-moi-mot-de-passe-fort@postgres:5432/multica?sslmode=disable
      PORT: 8080
      APP_ENV: development
      MULTICA_DEV_VERIFICATION_CODE: "420420"
      ALLOW_SIGNUP: "true"
      ALLOWED_EMAILS: alex.falzon@gmail.com
      JWT_SECRET: "$(openssl rand -hex 32)"
      # URLs en IP LAN courante (doc §3.1) - 0.0.0.0 en bind
      FRONTEND_ORIGIN: http://${IP_APP}:14782
      CORS_ALLOWED_ORIGINS: http://${IP_APP}:14782
      MULTICA_APP_URL: http://${IP_APP}:14782
      # Pont vers Ollama (agents locaux)
      OLLAMA_BASE_URL: http://${IP_LLM}:11434
    ports:
      - "0.0.0.0:18231:8080"
    volumes:
      - multica_backend_uploads:/uploads

  frontend:
    image: multica-frontend:${MULTICA_VERSION}
    restart: unless-stopped
    depends_on: [backend]
    environment:
      HOSTNAME: 0.0.0.0
      NEXT_PUBLIC_API_URL: http://${IP_APP}:18231
    ports:
      - "0.0.0.0:14782:3000"

  openwebui:
    image: ghcr.io/open-webui/open-webui:main
    restart: unless-stopped
    environment:
      OLLAMA_BASE_URL: http://${IP_LLM}:11434
      WEBUI_AUTH: "true"
    volumes:
      - openwebui_data:/app/backend/data
    ports:
      - "0.0.0.0:8080:8080"

volumes:
  multica_pgdata:
  multica_backend_uploads:
  openwebui_data:
EOF

docker compose up -d

echo "== [4/7] Pare-feu =="
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 14782/tcp comment "Multica web"
ufw allow 18231/tcp comment "Multica API"
ufw allow 8080/tcp comment "OpenWebUI"
ufw --force enable

echo "== [5/7] Attente des migrations backend =="
for i in $(seq 1 30); do
  if docker logs multica-backend-1 2>&1 | grep -q "port=8080"; then
    echo "Backend démarré (server starting port=8080)"; break
  fi
  sleep 3
done

echo "== [6/7] Vérifications =="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
curl -s -o /dev/null -w "frontend http code : %{http_code}\n" "http://${IP_APP}:14782"
curl -s -o /dev/null -w "openwebui http code : %{http_code}\n" "http://${IP_APP}:8080"
curl -s "http://${IP_LLM}:11434/api/tags" | jq -r '.models[].name' \
  && echo "-> VM-LLM joignable et modèles listés" \
  || echo "!! VM-LLM injoignable : vérifier IP_LLM=${IP_LLM} et ufw sur vm-llm"

echo
echo "============================================================"
echo " VM-APP prête. IP : ${IP_APP}"
echo " Multica   : http://${IP_APP}:14782  (code dev : 420420)"
echo " OpenWebUI : http://${IP_APP}:8080"
echo " Prochaine étape : installer le démon/CLI Multica + OpenCode"
echo " sur vm-llm, créer workspace Easyformer (slug -> prefixe EAS),"
echo " puis le roster (Victor, PMs, Nadia...) cf. doc chapitre 5."
echo "============================================================"
