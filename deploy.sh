#!/bin/bash
set -e
set -o pipefail

# ==============================================================================
# IDENTIDADE E VARIÁVEIS GLOBAIS
# ==============================================================================
REAL_USER=${SUDO_USER:-$USER}
REAL_PRIMARY_GROUP=$(id -gn "$REAL_USER")

export GITHUB_REPO_URL="https://github.com/Or4cu1o/chatbot.git"
export DEPLOY_DIR="/opt/chatbot"
export LOG_PATH="/var/log/chatbot-deploy.log"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==============================================================================
# FUNÇÕES DE APOIO
# ==============================================================================
log() {
    echo -e "$1"
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $(echo "$1" | sed -r 's/\x1B\[[0-9;]*[mK]//g')" >> "$LOG_PATH"
}

catch_error() {
    local exit_code=$1
    local line_number=$2
    log "\n${RED}[FALHA CRÍTICA] O script abortou na linha ${line_number} (Código de saída: ${exit_code}).${NC}"
    log "${YELLOW}Verifique o log para detalhes: $LOG_PATH${NC}\n"
}
trap 'catch_error $? $LINENO' ERR

# ==============================================================================
# 1. PREPARAÇÃO DO AMBIENTE
# ==============================================================================
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Execute como root (sudo su).${NC}"
   exit 1
fi

log "${BLUE}=====================================================${NC}"
log "${BLUE}   Orquestrador de Compilação - Chatbot Stack        ${NC}"
log "${BLUE}=====================================================${NC}\n"

# Instalação de dependências silenciada
apt-get update -qq && apt-get install -y -qq git curl openssl sed > /dev/null 2>&1

if [ -d "$DEPLOY_DIR" ]; then
    rm -rf "${DEPLOY_DIR}.bak"
    mv "$DEPLOY_DIR" "${DEPLOY_DIR}.bak"
fi

log "${YELLOW}Clonando matriz de infraestrutura...${NC}"
git clone -q "$GITHUB_REPO_URL" "$DEPLOY_DIR"
cd "$DEPLOY_DIR"

# ==============================================================================
# 2. ANAMNESE (COLETA DE DADOS)
# ==============================================================================
read -p "1. Domínio principal (ex: local.com): " DOMAIN
read -p "2. Protocolo [http/https]: " PROTOCOL
PROTOCOL=${PROTOCOL:-http}

USE_MAILPIT="n"
read -p "3. Instalar Mailpit? [S/n]: " RESP; [[ "$RESP" =~ ^[Ss]$ || -z "$RESP" ]] && USE_MAILPIT="s"

USE_DOCOPS="n"
read -p "4. Instalar DocOps? [S/n]: " RESP; [[ "$RESP" =~ ^[Ss]$ || -z "$RESP" ]] && USE_DOCOPS="s"

USE_TRAEFIK="n"
if [[ "$PROTOCOL" == "https" ]]; then
    USE_TRAEFIK="s"
    log "${BLUE}HTTPS detectado. Traefik será incluído na síntese como Proxy Reverso.${NC}"
else
    read -p "5. Usar Traefik como Proxy (mesmo em HTTP)? [s/N]: " RESP; [[ "$RESP" =~ ^[Ss]$ ]] && USE_TRAEFIK="s"
fi

# ==============================================================================
# 3. MOTOR DE SÍNTESE YAML (O CORAÇÃO DO NOVO MÉTODO)
# ==============================================================================
log "\n${YELLOW}Iniciando síntese do manifesto final...${NC}"

# Começamos com a base
COMPOSE_FILES=("-f" "docker/base-chatbot.yml")

# Adicionamos os módulos baseados na escolha
if [[ "$USE_TRAEFIK" == "s" ]]; then
    if [[ "$PROTOCOL" == "https" ]]; then
        COMPOSE_FILES+=("-f" "docker/module-traefik-ssl.yml" "-f" "docker/module-chatbot-ssl.yml")
        [[ "$USE_MAILPIT" == "s" ]] && COMPOSE_FILES+=("-f" "docker/module-mailpit-ssl.yml")
        [[ "$USE_DOCOPS" == "s" ]] && COMPOSE_FILES+=("-f" "docker/module-monitor-ssl.yml")
    else
        COMPOSE_FILES+=("-f" "docker/module-traefik-http.yml" "-f" "docker/module-chatbot-http.yml")
        [[ "$USE_MAILPIT" == "s" ]] && COMPOSE_FILES+=("-f" "docker/module-mailpit-http.yml")
        [[ "$USE_DOCOPS" == "s" ]] && COMPOSE_FILES+=("-f" "docker/module-monitor-http.yml")
    fi
else
    # Mapeamento Direto de Portas
    COMPOSE_FILES+=("-f" "docker/module-chatbot-ports.yml")
    [[ "$USE_MAILPIT" == "s" ]] && COMPOSE_FILES+=("-f" "docker/module-mailpit-port.yml")
    [[ "$USE_DOCOPS" == "s" ]] && COMPOSE_FILES+=("-f" "docker/module-monitor-port.yml")
fi

# GERAÇÃO DO DOCKER-COMPOSE.YML ÚNICO
# O comando 'config' do docker compose mescla os arquivos e resolve as interpolações
# Geramos o arquivo temporariamente para limpar o lixo de metadados depois
docker compose "${COMPOSE_FILES[@]}" config > docker-compose.yml.tmp

# Limpeza: Removemos as configurações de 'name' e 'pather' que o 'config' adiciona e que podem conflitar
grep -v "name: chatbot" docker-compose.yml.tmp > docker-compose.yml
rm docker-compose.yml.tmp

log "${GREEN}[OK] Manifesto 'docker-compose.yml' sintetizado com sucesso na raiz.${NC}"

# ==============================================================================
# 5. MOTOR DE INJEÇÃO E GERAÇÃO DE CREDENCIAIS
# ==============================================================================
log "\n${YELLOW}Forjando matriz de segurança e costurando variáveis de ambiente...${NC}"

POSTGRES_ROOT_PASS=$(openssl rand -hex 12)
REDIS_PASS=$(openssl rand -hex 12)
MINIO_PASS=$(openssl rand -hex 16)
DB_PASS_EVOLUTION=$(openssl rand -hex 10)
DB_PASS_N8N=$(openssl rand -hex 10)
DB_PASS_CHATWOOT=$(openssl rand -hex 10)
DB_PASS_TYPEBOT=$(openssl rand -hex 10)
ENCRYPTION_KEY=$(openssl rand -hex 24)
RUNNERS_AUTH_TOKEN=$(openssl rand -hex 24)

RAW_HASH=$(htpasswd -nB admin 2>/dev/null || echo "admin:\$apr1\$H6uskkkW\$IgXLP6ewTrSuBkTrqE8wj/")
TRAEFIK_AUTH=$(echo "$RAW_HASH" | sed 's/\$/\$\$/g')

EVO_API_KEY=$(openssl rand -hex 16)
TYPEBOT_SECRET=$(openssl rand -base64 24)
CHATWOOT_SECRET=$(openssl rand -hex 32)

IS_SECURE="false"
[[ "$PROTOCOL" == "https" ]] && IS_SECURE="true"

# Clonagem dos Templates
cp .env.example .env
cp envs/evolution.env.example envs/evolution.env
cp envs/typebot.env.example envs/typebot.env
cp envs/chatwoot.env.example envs/chatwoot.env
cp envs/n8n.env.example envs/n8n.env

# Injeção Mestra
sed -i "s|PROTOCOL=.*|PROTOCOL=$PROTOCOL|g" .env
sed -i "s|DOMAIN=.*|DOMAIN=$DOMAIN|g" .env
sed -i "s|ADMIN_EMAIL=.*|ADMIN_EMAIL=$ADMIN_EMAIL|g" .env
sed -i "s|TRAEFIK_AUTH=.*|TRAEFIK_AUTH=$TRAEFIK_AUTH|g" .env
sed -i "s|POSTGRES_ROOT_PASS=.*|POSTGRES_ROOT_PASS=$POSTGRES_ROOT_PASS|g" .env
sed -i "s|REDIS_PASS=.*|REDIS_PASS=$REDIS_PASS|g" .env
sed -i "s|MINIO_ROOT_PASS=.*|MINIO_ROOT_PASS=$MINIO_PASS|g" .env
sed -i "s|DB_PASS_EVOLUTION=.*|DB_PASS_EVOLUTION=$DB_PASS_EVOLUTION|g" .env
sed -i "s|DB_PASS_N8N=.*|DB_PASS_N8N=$DB_PASS_N8N|g" .env
sed -i "s|DB_PASS_CHATWOOT=.*|DB_PASS_CHATWOOT=$DB_PASS_CHATWOOT|g" .env
sed -i "s|DB_PASS_TYPEBOT=.*|DB_PASS_TYPEBOT=$DB_PASS_TYPEBOT|g" .env
sed -i "s|ENCRYPTION_KEY=.*|ENCRYPTION_KEY=$ENCRYPTION_KEY|g" .env
sed -i "s|RUNNERS_AUTH_TOKEN=.*|RUNNERS_AUTH_TOKEN=$RUNNERS_AUTH_TOKEN|g" .env

sed -i "s|VITE_EVOLUTION_API_URL=.*|VITE_EVOLUTION_API_URL=${PROTOCOL}://api-evolution.${DOMAIN}|g" envs/evolution.env
sed -i "s|SERVER_URL=.*|SERVER_URL=${PROTOCOL}://api-evolution.${DOMAIN}|g" envs/evolution.env
sed -i "s|VITE_EVOLUTION_API_KEY=.*|VITE_EVOLUTION_API_KEY=$EVO_API_KEY|g" envs/evolution.env
sed -i "s|AUTHENTICATION_API_KEY=.*|AUTHENTICATION_API_KEY=$EVO_API_KEY|g" envs/evolution.env
sed -i "s|S3_SECRET_KEY=.*|S3_SECRET_KEY=$MINIO_PASS|g" envs/evolution.env
sed -i "s|WEBHOOK_GLOBAL_URL=.*|WEBHOOK_GLOBAL_URL='${PROTOCOL}://n8n.${DOMAIN}/webhook/evolution-router'|g" envs/evolution.env
sed -i "s|CHATWOOT_IMPORT_DATABASE_CONNECTION_URI=.*|CHATWOOT_IMPORT_DATABASE_CONNECTION_URI=postgresql://chatwoot_user:${DB_PASS_CHATWOOT}@postgres-chatbot:5432/chatwoot_db?sslmode=disable|g" envs/evolution.env

sed -i "s|SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$CHATWOOT_SECRET|g" envs/chatwoot.env
sed -i "s|FRONTEND_URL=.*|FRONTEND_URL=${PROTOCOL}://chatwoot.${DOMAIN}|g" envs/chatwoot.env
sed -i "s|FORCE_SSL=.*|FORCE_SSL=$IS_SECURE|g" envs/chatwoot.env
sed -i "s|MAILER_SENDER_EMAIL=.*|MAILER_SENDER_EMAIL=notifications@${DOMAIN}|g" envs/chatwoot.env
sed -i "s|SMTP_DOMAIN=.*|SMTP_DOMAIN=${DOMAIN}|g" envs/chatwoot.env
sed -i "s|AWS_SECRET_ACCESS_KEY=.*|AWS_SECRET_ACCESS_KEY=$MINIO_PASS|g" envs/chatwoot.env

sed -i "s|ENCRYPTION_SECRET=.*|ENCRYPTION_SECRET=$TYPEBOT_SECRET|g" envs/typebot.env
sed -i "s|NEXTAUTH_URL=.*|NEXTAUTH_URL=${PROTOCOL}://builder-typebot.${DOMAIN}|g" envs/typebot.env
sed -i "s|NEXT_PUBLIC_VIEWER_URL=.*|NEXT_PUBLIC_VIEWER_URL=${PROTOCOL}://viewer-typebot.${DOMAIN}|g" envs/typebot.env
sed -i "s|ADMIN_EMAIL=.*|ADMIN_EMAIL=$ADMIN_EMAIL|g" envs/typebot.env
sed -i "s|NEXT_PUBLIC_SMTP_FROM=.*|NEXT_PUBLIC_SMTP_FROM=notifications@${DOMAIN}|g" envs/typebot.env
sed -i "s|S3_SECRET_KEY=.*|S3_SECRET_KEY=$MINIO_PASS|g" envs/typebot.env
sed -i "s|S3_PUBLIC_CUSTOM_DOMAIN=.*|S3_PUBLIC_CUSTOM_DOMAIN=${PROTOCOL}://console-minio.${DOMAIN}|g" envs/typebot.env

sed -i "s|N8N_SECURE_COOKIE=.*|N8N_SECURE_COOKIE=$IS_SECURE|g" envs/n8n.env

if [[ "$USE_MAILPIT" =~ ^[Nn]$ ]]; then
    sed -i "s|SMTP_HOST=.*|SMTP_HOST=$SMTP_HOST|g" envs/typebot.env envs/chatwoot.env
    sed -i "s|SMTP_PORT=.*|SMTP_PORT=$SMTP_PORT|g" envs/typebot.env envs/chatwoot.env
    sed -i "s|SMTP_USERNAME=.*|SMTP_USERNAME=$SMTP_USER|g" envs/typebot.env envs/chatwoot.env
    sed -i "s|SMTP_PASSWORD=.*|SMTP_PASSWORD=$SMTP_PASS|g" envs/typebot.env envs/chatwoot.env
    sed -i "s|SMTP_SECURE=.*|SMTP_SECURE=$IS_SECURE|g" envs/typebot.env
    sed -i "s|SMTP_IGNORE_TLS=.*|SMTP_IGNORE_TLS=false|g" envs/typebot.env
    sed -i "s|SMTP_ADDRESS=.*|SMTP_ADDRESS=$SMTP_HOST|g" envs/chatwoot.env
fi

# Salvando credenciais críticas no LOG com segurança
echo -e "\n================ CREDENCIAIS GERADAS ================" >> "$LOG_PATH"
echo "Dominio: $DOMAIN" >> "$LOG_PATH"
echo "PostgreSQL Root: $POSTGRES_ROOT_PASS" >> "$LOG_PATH"
echo "Redis: $REDIS_PASS" >> "$LOG_PATH"
echo "MinIO Root/S3: $MINIO_PASS" >> "$LOG_PATH"
echo "Evolution API Key: $EVO_API_KEY" >> "$LOG_PATH"
echo "=====================================================" >> "$LOG_PATH"

# ==============================================================================
# 6. CONFIGURAÇÃO DE REDE E FIREWALL
# ==============================================================================
log "\n${YELLOW}Garantindo isolamento de rede e permissões...${NC}"
chmod +x init-databases.sh

if ! docker network ls | grep -q "rede_proxy"; then
    docker network create rede_proxy
    log "${GREEN}[OK] Rede Docker 'rede_proxy' instanciada.${NC}"
fi

if command -v ufw &> /dev/null; then
    log "${YELLOW}Ajustando regras de firewall UFW...${NC}"
    ufw allow 80/tcp > /dev/null 2>&1
    ufw allow 443/tcp > /dev/null 2>&1
    ufw reload > /dev/null 2>&1 || true
fi

# ==============================================================================
# 5. EXECUÇÃO DA INFRAESTRUTURA
# ==============================================================================
log "\n${GREEN}Iniciando deploy via manifesto consolidado...${NC}"

docker compose pull 2>&1 | tee -a "$LOG_PATH"

log "\n${YELLOW}Preparando banco de dados do Chatwoot...${NC}"
docker compose run --rm chatwoot-rails bundle exec rails db:chatwoot_prepare 2>&1 | tee -a "$LOG_PATH"

docker compose up -d 2>&1 | tee -a "$LOG_PATH"

# ==============================================================================
# 6. FINALIZAÇÃO E PERMISSÕES
# ==============================================================================
log "\n${YELLOW}Ajustando propriedade dos arquivos para $REAL_USER...${NC}"
chown -R "$REAL_USER":"$REAL_PRIMARY_GROUP" "$DEPLOY_DIR"
chown "$REAL_USER":"$REAL_PRIMARY_GROUP" "$LOG_PATH"
chmod +x init-databases.sh

log "\n${BLUE}=====================================================${NC}"
log "${GREEN}   Implantação Finalizada com Sucesso.${NC}"
log "${BLUE}=====================================================${NC}"
log "Agora você pode usar comandos nativos como:"
log "${YELLOW}docker compose ps${NC} ou ${YELLOW}docker compose logs -f${NC}"
log "====================================================="
log "Diretório base: $DEPLOY_DIR"

log "\n${YELLOW}================ APONTAMENTOS DNS E URLs =================${NC}"
log "Crie os apontamentos (Tipo A) no seu provedor de domínio"
log "direcionando os subdomínios abaixo para o IP deste servidor."
log "----------------------------------------------------------"
log "Automação (n8n):           ${PROTOCOL}://n8n.${DOMAIN}"
log "Atendimento (Chatwoot):    ${PROTOCOL}://chatwoot.${DOMAIN}"
log "Criação (Typebot Builder): ${PROTOCOL}://builder-typebot.${DOMAIN}"
log "Motor (Typebot Viewer):    ${PROTOCOL}://viewer-typebot.${DOMAIN}"
log "API de Mensageria:         ${PROTOCOL}://api-evolution.${DOMAIN}"
log "Gestão de Mensageria:      ${PROTOCOL}://manager-evolution.${DOMAIN}"
log "Painel S3 (MinIO):         ${PROTOCOL}://console-minio.${DOMAIN}"
log "API S3 (Endpoint MinIO):   ${PROTOCOL}://s3-minio.${DOMAIN}"

if [[ "$USE_MAILPIT" =~ ^[Ss]$ ]]; then
    log "E-mail Interno (Mailpit):  ${PROTOCOL}://mail-chatbot.${DOMAIN}"
fi

if [[ "$USE_DOCOPS" =~ ^[Ss]$ ]]; then
    log "Monitor Docker (DocOps):   ${PROTOCOL}://monitor.${DOMAIN}"
fi
log "==========================================================\n"

log "Para visualizar as senhas dos bancos e chaves das APIs geradas:"
log "${YELLOW}cat $LOG_PATH${NC}"
log "====================================================="