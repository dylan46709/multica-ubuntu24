#!/usr/bin/env bash
# ============================================================
# install-ollama-vm.sh — VM "vm-llm" sur ESXi n°1
# Ubuntu 24.04 · Ollama exposé sur le réseau d'école
# Rôle : servir les modèles locaux (agents Multica + OpenWebUI)
# ============================================================
set -euo pipefail

# --- À ADAPTER : modèles exacts (tags Ollama) ----------------
# Vérifie les tags avec :  ollama search qwen3
MODELS="${MODELS:-qwen3:4b qwen3:9b gpt-oss:20b}"
# qwen3:4b      ~3 Go RAM   -> tests / agents légers
# qwen3:9b      ~8 Go RAM   -> correction / tickets
# gpt-oss:20b   ~15 Go RAM  -> très bonne qualité / chef Victor, relecture Nadia
# ------------------------------------------------------------

echo "== [1/6] Mise à jour du système =="
apt update && apt -y full-upgrade
apt -y install curl ufw fail2ban htop nvtop jq

echo "== [2/6] Installation d'Ollama =="
curl -fsSL https://ollama.com/install.sh | sh

echo "== [3/6] Ollama écoute sur toutes les interfaces (0.0.0.0) =="
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf <<'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_NUM_PARALLEL=2"
Environment="OLLAMA_MAX_LOADED_MODELS=2"
Environment="OLLAMA_KEEP_ALIVE=30m"
EOF
systemctl daemon-reload
systemctl enable --now ollama
systemctl restart ollama

echo "== [4/6] Pare-feu : n'ouvrir que le réseau local =="
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow from 172.16.20.0/16 to any port 11434 proto tcp comment "Ollama LAN ecole"
ufw --force enable

echo "== [5/6] Téléchargement des modèles (long : 20-30 Go) =="
for m in $MODELS; do
  echo "--- pull $m ---"
  ollama pull "$m"
done

echo "== [6/6] Test =="
IP_LLM=$(hostname -I | awk '{print $1}')
ollama list
echo
curl -s "http://${IP_LLM}:11434/api/generate" -d '{
  "model": "qwen3:4b",
  "prompt": "Reponds en un mot : OK ?",
  "stream": false
}' | jq -r '.response' || true

echo
echo "============================================================"
echo " VM-LLM prête. IP : ${IP_LLM}"
echo " Sur la VM app, régler : OLLAMA_BASE_URL=http://${IP_LLM}:11434"
echo " Garder 2 modèles max chargés (RAM). Plus tard : installer"
echo " OpenCode ici pour les agents : opencode auth login, puis"
echo ' modèle "ollama/qwen3:4b" dans la fiche agent Multica.'
echo "============================================================"
