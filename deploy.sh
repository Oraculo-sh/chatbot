#!/bin/bash
set -e

# ==============================================================================
# VARIÁVEIS GLOBAIS DE AMBIENTE
# ==============================================================================
export GITHUB_REPO_URL="https://github.com/Or4cu1o/chatbot.git"
export DEPLOY_DIR="/opt/chatbot"
export LOG_PATH="/var/log/chatbot-deploy.log"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ==============================================================================
# MOTOR DE LOGS E SAÍDA
# ==============================================================================
# Cria o arquivo de log e blinda as permissões (apenas root pode ler)
touch "$LOG_PATH"
chmod 600 "$LOG_PATH"

log() {
    echo -e "$1"
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $(echo "$1" | sed -r 's/\x1B\[[0-9;]*[mK]//g')" >> "$LOG_PATH"
}

error() {
    log "${RED}[ERRO] $1${NC}"
    exit 1
}

log "${BLUE}=====================================================${NC}"
log "${BLUE}   Assistente de Instalação - Infraestrutura Chatbot ${NC}"
log "${BLUE}=====================================================${NC}\n"

# ==============================================================================
# 1. AUDITORIA DE PRIVILÉGIOS E SO
# ==============================================================================
if [[ $EUID -ne 0 ]]; then
   error "Este script requer privilégios de superusuário (root). Execute 'sudo su' antes de iniciar."
fi
log "${GREEN}[OK] Privilégios de root validados.${NC}"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    log "${GREEN}[OK] Sistema Operacional: $PRETTY_NAME${NC}"
else
    error "Não foi possível identificar o Sistema Operacional."
fi

# ==============================================================================
# 2. RESOLUÇÃO DE DEPENDÊNCIAS
# ==============================================================================
log "\n${YELLOW}Auditando dependências base (git, curl, openssl)...${NC}"
DEPENDENCIES=("git" "curl" "openssl")
for dep in "${DEPENDENCIES[@]}"; do
    if ! command -v $dep &> /dev/null; then
        log "Instalando pacote ausente: $dep..."
        if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
            apt-get update -qq && apt-get install -y -qq $dep
        elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "fedora" ]]; then
            yum install -y -q $dep
        else
            error "Gerenciador de pacotes não suportado. Instale $dep manualmente."
        fi
    fi
done

if ! command -v docker &> /dev/null; then
    log "${YELLOW}Docker Engine não encontrado. Iniciando instalação oficial...${NC}"
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh >> "$LOG_PATH" 2>&1
    systemctl enable --now docker
    log "${GREEN}[OK] Docker Engine instalado.${NC}"
fi

if ! docker compose version &> /dev/null; then
    log "${YELLOW}Docker Compose V2 não detectado. Instalando plugin...${NC}"
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        apt-get update -qq && apt-get install -y -qq docker-compose-plugin
    elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "fedora" ]]; then
        yum install -y -q docker-compose-plugin
    fi
    log "${GREEN}[OK] Docker Compose V2 operacional.${NC}"
fi

# ==============================================================================
# 3. PROVISIONAMENTO DO REPOSITÓRIO E PATCHES TÁTICOS
# ==============================================================================
if [ -d "$DEPLOY_DIR" ]; then
    BACKUP_DIR="${DEPLOY_DIR}.bak_$(date +%s)"
    log "${YELLOW}[AVISO] Diretório $DEPLOY_DIR existente. Movendo para $BACKUP_DIR${NC}"
    mv "$DEPLOY_DIR" "$BACKUP_DIR"
fi

log "\n${YELLOW}Clonando repositório matriz...${NC}"
git clone -q "$GITHUB_REPO_URL" "$DEPLOY_DIR"
cd "$DEPLOY_DIR"

log "${GREEN}[OK] Repositório clonado e patches aplicados.${NC}\n"

# ==============================================================================
# 4. ANAMNESE DE CONFIGURAÇÃO (VALIDAÇÃO ESTRITA)
# ==============================================================================
log "${BLUE}--- Coleta de Parâmetros de Infraestrutura ---${NC}"

# Loop de Protocolo
valid_protocols=("http" "https")
PROTOCOL=""
while [[ ! " ${valid_protocols[*]} " =~ " ${PROTOCOL} " ]]; do
    read -p "1. Qual protocolo será utilizado? [http/https]: " PROTOCOL_INPUT
    PROTOCOL=$(echo "${PROTOCOL_INPUT:-https}" | tr '[:upper:]' '[:lower:]')
done

# Loop de Domínio
DOMAIN=""
while [[ -z "$DOMAIN" ]]; do
    read -p "2. Qual o domínio principal a ser utilizado? (Obrigatório, ex: local.com): " DOMAIN
done

ADMIN_EMAIL="admin@$DOMAIN"
if [[ "$PROTOCOL" == "https" ]]; then
    read -p "2.1. Informe um e-mail para a emissão do SSL Let's Encrypt [$ADMIN_EMAIL]: " EMAIL_INPUT
    ADMIN_EMAIL=${EMAIL_INPUT:-$ADMIN_EMAIL}
fi

# Loop Mailpit
USE_MAILPIT=""
while [[ ! "$USE_MAILPIT" =~ ^[SsNn]$ ]]; do
    read -p "3. Deseja implantar o servidor interno Mailpit? [S/n]: " USE_MAILPIT
    USE_MAILPIT=${USE_MAILPIT:-s}
done

if [[ "$USE_MAILPIT" =~ ^[Nn]$ ]]; then
    log "${YELLOW}Você optou por um servidor SMTP externo.${NC}"
    read -p "   - SMTP Host: " SMTP_HOST
    read -p "   - SMTP Port: " SMTP_PORT
    read -p "   - SMTP User: " SMTP_USER
    read -s -p "   - SMTP Pass: " SMTP_PASS
    echo ""
fi

# Loop DocOps
USE_DOCOPS=""
while [[ ! "$USE_DOCOPS" =~ ^[SsNn]$ ]]; do
    read -p "4. Deseja implantar o DocOps para monitoramento? [S/n]: " USE_DOCOPS
    USE_DOCOPS=${USE_DOCOPS:-s}
done

# Loop Webserver (Design Pterodactyl)
done_ws=false
while [ "$done_ws" == false ]; do
    echo -e "\n5. Qual Webserver/Proxy Reverso será utilizado?"
    echo "   [1] Traefik (Recomendado - Isolamento automático)"
    echo "   [2] Nginx / Apache / Outros (Mapeamento manual)"
    read -p "   Sua escolha [1-2]: " WEBSERVER_CHOICE
    WEBSERVER_CHOICE=${WEBSERVER_CHOICE:-1}

    if [[ "$WEBSERVER_CHOICE" == "1" || "$WEBSERVER_CHOICE" == "2" ]]; then
        done_ws=true
    else
        log "${RED}Opção inválida. Selecione 1 ou 2.${NC}"
    fi
done

USE_TRAEFIK="n"
DEPLOY_TRAEFIK="n"
if [[ "$WEBSERVER_CHOICE" == "1" ]]; then
    USE_TRAEFIK="s"
    read -p "   5.1. Deseja que o script instale e configure o Traefik agora? [S/n]: " DEPLOY_TRAEFIK
    DEPLOY_TRAEFIK=${DEPLOY_TRAEFIK:-s}
fi

log "\n${BLUE}--- Resumo da Implantação ---${NC}"
log "Domínio: $DOMAIN ($PROTOCOL)"
log "Admin Email: $ADMIN_EMAIL"
log "Mailpit Interno: $USE_MAILPIT | DocOps: $USE_DOCOPS | Traefik: $DEPLOY_TRAEFIK"

CONFIRM=""
while [[ ! "$CONFIRM" =~ ^[SsNn]$ ]]; do
    read -p "Validar e iniciar implantação? [S/n]: " CONFIRM
    CONFIRM=${CONFIRM:-s}
done

if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
    log "Operação abortada pelo usuário."
    exit 0
fi

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
TYPEBOT_SECRET=$(openssl rand -hex 16)
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
# 7. ORQUESTRAÇÃO DOS MÓDULOS E DEPLOY
# ==============================================================================
log "\n${YELLOW}Sintetizando comando de implantação...${NC}"
COMPOSE_CMD="docker compose -f docker-compose.yml"

if [[ "$USE_TRAEFIK" =~ ^[Ss]$ ]]; then
    if [[ "$PROTOCOL" == "https" ]]; then
        COMPOSE_CMD="$COMPOSE_CMD -f docker/module-chatbot-ssl.yml"
        [[ "$DEPLOY_TRAEFIK" =~ ^[Ss]$ ]] && COMPOSE_CMD="$COMPOSE_CMD -f docker/module-traefik-ssl.yml"
    else
        COMPOSE_CMD="$COMPOSE_CMD -f docker/module-chatbot-http.yml"
        [[ "$DEPLOY_TRAEFIK" =~ ^[Ss]$ ]] && COMPOSE_CMD="$COMPOSE_CMD -f docker/module-traefik-http.yml"
    fi
else
    COMPOSE_CMD="$COMPOSE_CMD -f docker/module-chatbot-ports.yml"
fi

if [[ "$USE_MAILPIT" =~ ^[Ss]$ ]]; then
    if [[ "$USE_TRAEFIK" =~ ^[Nn]$ ]]; then
        COMPOSE_CMD="$COMPOSE_CMD -f docker/module-mailpit-port.yml"
    elif [[ "$PROTOCOL" == "https" ]]; then
         COMPOSE_CMD="$COMPOSE_CMD -f docker/module-mailpit-ssl.yml"
    else
         COMPOSE_CMD="$COMPOSE_CMD -f docker/module-mailpit-http.yml"
    fi
fi

if [[ "$USE_DOCOPS" =~ ^[Ss]$ ]]; then
    if [[ "$USE_TRAEFIK" =~ ^[Nn]$ ]]; then
        COMPOSE_CMD="$COMPOSE_CMD -f docker/module-monitor-port.yml"
    elif [[ "$PROTOCOL" == "https" ]]; then
         COMPOSE_CMD="$COMPOSE_CMD -f docker/module-monitor-ssl.yml"
    else
         COMPOSE_CMD="$COMPOSE_CMD -f docker/module-monitor-http.yml"
    fi
fi

log "\n${GREEN}Iniciando *pull* de imagens e alocação de contêineres...${NC}"
eval "$COMPOSE_CMD pull" >> "$LOG_PATH" 2>&1
eval "$COMPOSE_CMD up -d" >> "$LOG_PATH" 2>&1

# ==============================================================================
# 8. ARTEFATOS FINAIS
# ==============================================================================
log "\n${YELLOW}Gerando binários de rotina...${NC}"
cat <<EOF > start.sh
#!/bin/bash
cd $DEPLOY_DIR
$COMPOSE_CMD up -d
EOF
chmod +x start.sh

cat <<EOF > stop.sh
#!/bin/bash
cd $DEPLOY_DIR
$COMPOSE_CMD down
EOF
chmod +x stop.sh

log "\n${BLUE}=====================================================${NC}"
log "${GREEN}   Operação Concluída com Sucesso.${NC}"
log "${BLUE}=====================================================${NC}"
log "Diretório base: $DEPLOY_DIR"
log "Para visualizar as senhas geradas e os detalhes de acesso:"
log "${YELLOW}cat $LOG_PATH${NC}"
log "====================================================="