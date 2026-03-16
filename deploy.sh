#!/bin/bash
set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

DEPLOY_DIR="/opt/chatbot"
REPO_URL="https://github.com/Or4cu1o/chatbot.git"

echo -e "${BLUE}=====================================================${NC}"
echo -e "${BLUE}   Assistente de Instalação - Infraestrutura Chatbot ${NC}"
echo -e "${BLUE}=====================================================${NC}\n"

# ==============================================================================
# 1. AUDITORIA DE PRIVILÉGIOS E SO
# ==============================================================================
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERRO] Este script requer privilégios de superusuário (root). Execute com sudo.${NC}"
   exit 1
fi
echo -e "${GREEN}[OK] Privilégios de root detectados.${NC}"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    echo -e "${GREEN}[OK] Sistema Operacional detectado: $PRETTY_NAME${NC}"
else
    echo -e "${RED}[ERRO] Não foi possível identificar o Sistema Operacional.${NC}"
    exit 1
fi

# ==============================================================================
# 2. RESOLUÇÃO DE DEPENDÊNCIAS (BASE E DOCKER)
# ==============================================================================
echo -e "\n${YELLOW}Auditando dependências base (git, curl, openssl)...${NC}"
DEPENDENCIES=("git" "curl" "openssl")
for dep in "${DEPENDENCIES[@]}"; do
    if ! command -v $dep &> /dev/null; then
        echo -e "${YELLOW}Instalando pacote ausente: $dep...${NC}"
        if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
            apt-get update -qq && apt-get install -y -qq $dep
        elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "fedora" ]]; then
            yum install -y -q $dep
        else
            echo -e "${RED}[ERRO] Gerenciador de pacotes não suportado. Instale $dep manualmente.${NC}"
            exit 1
        fi
    fi
done
echo -e "${GREEN}[OK] Dependências base operacionais.${NC}"

if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}Docker Engine não encontrado. Iniciando instalação oficial...${NC}"
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    systemctl enable --now docker
    echo -e "${GREEN}[OK] Docker Engine instalado.${NC}"
fi

if ! docker compose version &> /dev/null; then
    echo -e "${YELLOW}Docker Compose V2 não detectado. Instalando plugin...${NC}"
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        apt-get update -qq && apt-get install -y -qq docker-compose-plugin
    elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "fedora" ]]; then
        yum install -y -q docker-compose-plugin
    fi
    echo -e "${GREEN}[OK] Docker Compose V2 operacional.${NC}"
fi

# ==============================================================================
# 3. PROVISIONAMENTO DO REPOSITÓRIO
# ==============================================================================
if [ -d "$DEPLOY_DIR" ]; then
    echo -e "${YELLOW}[AVISO] O diretório $DEPLOY_DIR já existe. Fazendo backup para $DEPLOY_DIR.bak_$(date +%s)${NC}"
    mv "$DEPLOY_DIR" "${DEPLOY_DIR}.bak_$(date +%s)"
fi
echo -e "\n${YELLOW}Clonando repositório matriz...${NC}"
git clone -q "$REPO_URL" "$DEPLOY_DIR"
cd "$DEPLOY_DIR"
echo -e "${GREEN}[OK] Repositório clonado em $DEPLOY_DIR.${NC}\n"

# ==============================================================================
# 4. ANAMNESE DE CONFIGURAÇÃO
# ==============================================================================
echo -e "${BLUE}--- Coleta de Parâmetros de Infraestrutura ---${NC}"

read -p "1. Qual protocolo será utilizado? [http/HTTPS]: " PROTOCOL_INPUT
PROTOCOL=${PROTOCOL_INPUT:-https}
PROTOCOL=$(echo "$PROTOCOL" | tr '[:upper:]' '[:lower:]')

while [[ -z "$DOMAIN" ]]; do
    read -p "2. Qual o domínio principal a ser utilizado? (Obrigatório, ex: seudominio.com.br): " DOMAIN
done

ADMIN_EMAIL="admin@$DOMAIN"
if [[ "$PROTOCOL" == "https" ]]; then
    read -p "2.1. Informe um e-mail válido para a emissão do SSL Let's Encrypt [$ADMIN_EMAIL]: " EMAIL_INPUT
    ADMIN_EMAIL=${EMAIL_INPUT:-$ADMIN_EMAIL}
fi

read -p "3. Deseja implantar o servidor interno Mailpit para e-mails transacionais? [S/n]: " USE_MAILPIT
USE_MAILPIT=${USE_MAILPIT:-s}
if [[ "$USE_MAILPIT" =~ ^[Nn]$ ]]; then
    echo -e "${YELLOW}Você optou por um servidor SMTP externo.${NC}"
    read -p "   - SMTP Host: " SMTP_HOST
    read -p "   - SMTP Port: " SMTP_PORT
    read -p "   - SMTP User: " SMTP_USER
    read -s -p "   - SMTP Pass: " SMTP_PASS
    echo ""
fi

read -p "4. Deseja implantar o DocOps para monitoramento Docker em tempo real? [S/n]: " USE_DOCOPS
USE_DOCOPS=${USE_DOCOPS:-s}

echo -e "5. Qual Webserver/Proxy Reverso será utilizado?"
echo "   1) Traefik (Recomendado - Isolamento automático)"
echo "   2) Nginx / Apache / Outros (Exige mapeamento manual de portas)"
read -p "   Sua escolha [1]: " WEBSERVER_CHOICE
WEBSERVER_CHOICE=${WEBSERVER_CHOICE:-1}

USE_TRAEFIK="n"
DEPLOY_TRAEFIK="n"
if [[ "$WEBSERVER_CHOICE" == "1" ]]; then
    USE_TRAEFIK="s"
    read -p "   5.1. Deseja que o script instale e configure o Traefik agora? [S/n]: " DEPLOY_TRAEFIK
    DEPLOY_TRAEFIK=${DEPLOY_TRAEFIK:-s}
fi

echo -e "\n${BLUE}--- Resumo da Implantação ---${NC}"
echo "Domínio: $DOMAIN ($PROTOCOL)"
echo "Admin Email: $ADMIN_EMAIL"
echo "Mailpit Interno: $USE_MAILPIT | DocOps: $USE_DOCOPS | Traefik: $DEPLOY_TRAEFIK"
read -p "Validar e iniciar implantação? [S/n]: " CONFIRM
CONFIRM=${CONFIRM:-s}
if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
    echo "Operação abortada pelo usuário."
    exit 0
fi

# ==============================================================================
# 5. MOTOR DE INJEÇÃO E GERAÇÃO DE CREDENCIAIS
# ==============================================================================
echo -e "\n${YELLOW}Forjando matriz de segurança e costurando variáveis de ambiente...${NC}"

# Entropia Core
POSTGRES_ROOT_PASS=$(openssl rand -hex 12)
REDIS_PASS=$(openssl rand -hex 12)
MINIO_PASS=$(openssl rand -hex 16)
DB_PASS_EVOLUTION=$(openssl rand -hex 10)
DB_PASS_N8N=$(openssl rand -hex 10)
DB_PASS_CHATWOOT=$(openssl rand -hex 10)
DB_PASS_TYPEBOT=$(openssl rand -hex 10)
ENCRYPTION_KEY=$(openssl rand -hex 24)
RUNNERS_AUTH_TOKEN=$(openssl rand -hex 24)

# Hash Traefik (Tratamento de escape de caracteres)
RAW_HASH=$(htpasswd -nB admin 2>/dev/null || echo "admin:\$apr1\$H6uskkkW\$IgXLP6ewTrSuBkTrqE8wj/")
TRAEFIK_AUTH=$(echo "$RAW_HASH" | sed 's/\$/\$\$/g')

# Tokens de Aplicação
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

# Injeção Raiz
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

# Injeção Evolution API
sed -i "s|VITE_EVOLUTION_API_URL=.*|VITE_EVOLUTION_API_URL=${PROTOCOL}://api-evolution.${DOMAIN}|g" envs/evolution.env
sed -i "s|SERVER_URL=.*|SERVER_URL=${PROTOCOL}://api-evolution.${DOMAIN}|g" envs/evolution.env
sed -i "s|VITE_EVOLUTION_API_KEY=.*|VITE_EVOLUTION_API_KEY=$EVO_API_KEY|g" envs/evolution.env
sed -i "s|AUTHENTICATION_API_KEY=.*|AUTHENTICATION_API_KEY=$EVO_API_KEY|g" envs/evolution.env
sed -i "s|S3_SECRET_KEY=.*|S3_SECRET_KEY=$MINIO_PASS|g" envs/evolution.env
sed -i "s|WEBHOOK_GLOBAL_URL=.*|WEBHOOK_GLOBAL_URL='${PROTOCOL}://n8n.${DOMAIN}/webhook/evolution-router'|g" envs/evolution.env
sed -i "s|CHATWOOT_IMPORT_DATABASE_CONNECTION_URI=.*|CHATWOOT_IMPORT_DATABASE_CONNECTION_URI=postgresql://chatwoot_user:${DB_PASS_CHATWOOT}@postgres-chatbot:5432/chatwoot_db?sslmode=disable|g" envs/evolution.env

# Injeção Chatwoot
sed -i "s|SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$CHATWOOT_SECRET|g" envs/chatwoot.env
sed -i "s|FRONTEND_URL=.*|FRONTEND_URL=${PROTOCOL}://chatwoot.${DOMAIN}|g" envs/chatwoot.env
sed -i "s|FORCE_SSL=.*|FORCE_SSL=$IS_SECURE|g" envs/chatwoot.env
sed -i "s|MAILER_SENDER_EMAIL=.*|MAILER_SENDER_EMAIL=notifications@${DOMAIN}|g" envs/chatwoot.env
sed -i "s|SMTP_DOMAIN=.*|SMTP_DOMAIN=${DOMAIN}|g" envs/chatwoot.env
sed -i "s|AWS_SECRET_ACCESS_KEY=.*|AWS_SECRET_ACCESS_KEY=$MINIO_PASS|g" envs/chatwoot.env

# Injeção Typebot
sed -i "s|ENCRYPTION_SECRET=.*|ENCRYPTION_SECRET=$TYPEBOT_SECRET|g" envs/typebot.env
sed -i "s|NEXTAUTH_URL=.*|NEXTAUTH_URL=${PROTOCOL}://builder-typebot.${DOMAIN}|g" envs/typebot.env
sed -i "s|NEXT_PUBLIC_VIEWER_URL=.*|NEXT_PUBLIC_VIEWER_URL=${PROTOCOL}://viewer-typebot.${DOMAIN}|g" envs/typebot.env
sed -i "s|ADMIN_EMAIL=.*|ADMIN_EMAIL=$ADMIN_EMAIL|g" envs/typebot.env
sed -i "s|NEXT_PUBLIC_SMTP_FROM=.*|NEXT_PUBLIC_SMTP_FROM=notifications@${DOMAIN}|g" envs/typebot.env
sed -i "s|S3_SECRET_KEY=.*|S3_SECRET_KEY=$MINIO_PASS|g" envs/typebot.env
sed -i "s|S3_PUBLIC_CUSTOM_DOMAIN=.*|S3_PUBLIC_CUSTOM_DOMAIN=${PROTOCOL}://console-minio.${DOMAIN}|g" envs/typebot.env

# Injeção n8n
sed -i "s|N8N_SECURE_COOKIE=.*|N8N_SECURE_COOKIE=$IS_SECURE|g" envs/n8n.env

# Lógica SMTP Condicional
if [[ "$USE_MAILPIT" =~ ^[Nn]$ ]]; then
    sed -i "s|SMTP_HOST=.*|SMTP_HOST=$SMTP_HOST|g" envs/typebot.env envs/chatwoot.env
    sed -i "s|SMTP_PORT=.*|SMTP_PORT=$SMTP_PORT|g" envs/typebot.env envs/chatwoot.env
    sed -i "s|SMTP_USERNAME=.*|SMTP_USERNAME=$SMTP_USER|g" envs/typebot.env envs/chatwoot.env
    sed -i "s|SMTP_PASSWORD=.*|SMTP_PASSWORD=$SMTP_PASS|g" envs/typebot.env envs/chatwoot.env
    sed -i "s|SMTP_SECURE=.*|SMTP_SECURE=$IS_SECURE|g" envs/typebot.env
    sed -i "s|SMTP_IGNORE_TLS=.*|SMTP_IGNORE_TLS=false|g" envs/typebot.env
    sed -i "s|SMTP_ADDRESS=.*|SMTP_ADDRESS=$SMTP_HOST|g" envs/chatwoot.env
fi

# ==============================================================================
# 6. CONFIGURAÇÃO DE REDE E FIREWALL
# ==============================================================================
echo -e "\n${YELLOW}Garantindo isolamento de rede e permissões...${NC}"
chmod +x init-databases.sh

if ! docker network ls | grep -q "rede_proxy"; then
    docker network create rede_proxy
    echo -e "${GREEN}[OK] Rede Docker 'rede_proxy' instanciada.${NC}"
fi

if command -v ufw &> /dev/null; then
    echo -e "${YELLOW}Ajustando regras de firewall UFW...${NC}"
    ufw allow 80/tcp > /dev/null 2>&1
    ufw allow 443/tcp > /dev/null 2>&1
    ufw reload > /dev/null 2>&1 || true
fi

# ==============================================================================
# 7. ORQUESTRAÇÃO DOS MÓDULOS E DEPLOY
# ==============================================================================
echo -e "\n${YELLOW}Sintetizando comando de implantação...${NC}"
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

echo -e "\n${GREEN}Iniciando *pull* de imagens e alocação de contêineres...${NC}"
eval "$COMPOSE_CMD pull"
eval "$COMPOSE_CMD up -d"

# ==============================================================================
# 8. ARTEFATOS FINAIS
# ==============================================================================
echo -e "\n${YELLOW}Gerando binários de rotina...${NC}"
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

echo -e "\n${BLUE}=====================================================${NC}"
echo -e "${GREEN}   Operação Concluída com Sucesso.${NC}"
echo -e "${BLUE}=====================================================${NC}"
echo "Diretório base: $DEPLOY_DIR"
echo "O ambiente foi ativado. As credenciais sensíveis geradas estão salvas em:"
echo "- $DEPLOY_DIR/.env"
echo "- $DEPLOY_DIR/envs/"