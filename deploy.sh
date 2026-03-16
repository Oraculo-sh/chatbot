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

# 1. Analisa e identifica se tem permissão de super usuário
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERRO] Este script requer privilégios de superusuário (root). Execute com sudo.${NC}"
   exit 1
fi
echo -e "${GREEN}[OK] Privilégios de root detectados.${NC}"

# 2. Analisa e identifica o sistema operacional
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    echo -e "${GREEN}[OK] Sistema Operacional detectado: $PRETTY_NAME${NC}"
else
    echo -e "${RED}[ERRO] Não foi possível identificar o Sistema Operacional.${NC}"
    exit 1
fi

# 3 & 4. Analisa e verifica/instala dependências
DEPENDENCIES=("git" "curl" "openssl" "jq")
echo -e "${YELLOW}Verificando dependências base...${NC}"
for dep in "${DEPENDENCIES[@]}"; do
    if ! command -v $dep &> /dev/null; then
        echo -e "${YELLOW}Instalando $dep...${NC}"
        if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
            apt-get update -qq && apt-get install -y -qq $dep
        elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "fedora" ]]; then
            yum install -y -q $dep
        else
            echo -e "${RED}[ERRO] Gerenciador de pacotes não suportado para instalação automática. Instale $dep manualmente.${NC}"
            exit 1
        fi
    fi
done

# Verificação específica do Docker
if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}Docker não encontrado. Iniciando instalação oficial...${NC}"
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    systemctl enable --now docker
fi

# 5. Clona o repositório
if [ -d "$DEPLOY_DIR" ]; then
    echo -e "${YELLOW}[AVISO] O diretório $DEPLOY_DIR já existe. Fazendo backup para $DEPLOY_DIR.bak_$(date +%s)${NC}"
    mv "$DEPLOY_DIR" "${DEPLOY_DIR}.bak_$(date +%s)"
fi
echo -e "${YELLOW}Clonando repositório...${NC}"
git clone -q "$REPO_URL" "$DEPLOY_DIR"
cd "$DEPLOY_DIR"
echo -e "${GREEN}[OK] Repositório clonado em $DEPLOY_DIR.${NC}\n"

# 6. Processo de Anamnese Pre-deploy
echo -e "${BLUE}--- Anamnese de Configuração ---${NC}"

# 6.1 Protocolo
read -p "1. Qual protocolo será utilizado? [http/HTTPS]: " PROTOCOL_INPUT
PROTOCOL=${PROTOCOL_INPUT:-https}
PROTOCOL=$(echo "$PROTOCOL" | tr '[:upper:]' '[:lower:]')

# 6.2 Domínio
while [[ -z "$DOMAIN" ]]; do
    read -p "2. Qual o domínio principal a ser utilizado? (Obrigatório, ex: seudominio.com.br): " DOMAIN
done

# Coleta de e-mail (necessário para HTTPS/Traefik)
ADMIN_EMAIL="admin@$DOMAIN"
if [[ "$PROTOCOL" == "https" ]]; then
    read -p "2.1. Informe um e-mail válido para a emissão do SSL Let's Encrypt [$ADMIN_EMAIL]: " EMAIL_INPUT
    ADMIN_EMAIL=${EMAIL_INPUT:-$ADMIN_EMAIL}
fi

# 6.3 Mailpit
read -p "3. Deseja implantar o servidor interno Mailpit para e-mails? [S/n]: " USE_MAILPIT
USE_MAILPIT=${USE_MAILPIT:-s}
if [[ "$USE_MAILPIT" =~ ^[Nn]$ ]]; then
    echo -e "${YELLOW}Você optou por um servidor SMTP próprio.${NC}"
    read -p "   - SMTP Host: " SMTP_HOST
    read -p "   - SMTP Port: " SMTP_PORT
    read -p "   - SMTP User: " SMTP_USER
    read -s -p "   - SMTP Pass: " SMTP_PASS
    echo ""
fi

# 6.4 DocOps
read -p "4. Deseja implantar o DocOps para monitoramento Docker em tempo real? [S/n]: " USE_DOCOPS
USE_DOCOPS=${USE_DOCOPS:-s}

# 6.5 Webserver
echo -e "5. Qual Webserver/Proxy Reverso será utilizado?"
echo "   1) Traefik (Recomendado)"
echo "   2) Nginx"
echo "   3) Apache"
echo "   4) Outro"
read -p "   Sua escolha [1]: " WEBSERVER_CHOICE
WEBSERVER_CHOICE=${WEBSERVER_CHOICE:-1}

USE_TRAEFIK="n"
DEPLOY_TRAEFIK="n"
if [[ "$WEBSERVER_CHOICE" == "1" ]]; then
    USE_TRAEFIK="s"
    read -p "   5.1. Deseja que o script instale e configure o Traefik agora? [S/n]: " DEPLOY_TRAEFIK
    DEPLOY_TRAEFIK=${DEPLOY_TRAEFIK:-s}
    if [[ "$DEPLOY_TRAEFIK" =~ ^[Nn]$ ]]; then
        echo -e "${YELLOW}[NOTA] O ambiente utilizará as labels do Traefik, mas o roteador deve ser gerenciado por você na 'rede_proxy'.${NC}"
    fi
else
    echo -e "\n${YELLOW}[ATENÇÃO] Configuração manual exigida.${NC}"
    echo "Como você escolheu não usar o Traefik nativo, os serviços apenas exporão as seguintes portas locais:"
    echo " - n8n: 3001"
    echo " - Chatwoot: 3000"
    echo " - Typebot Builder: 3002"
    echo " - Typebot Viewer: 3003"
    echo " - Evolution API: 3005"
    echo " - Evolution Frontend: 3004"
    echo " - MinIO (API/Console): 9000 / 9001"
    echo "Você deverá mapear essas portas no seu Nginx/Apache para os respectivos subdomínios."
    read -p "Ciente? Pressione ENTER para continuar..."
fi

# 7. Confirmação
echo -e "\n${BLUE}--- Resumo da Implantação ---${NC}"
echo "Protocolo: $PROTOCOL"
echo "Domínio: $DOMAIN"
echo "Admin Email: $ADMIN_EMAIL"
echo "Usar Mailpit interno: $USE_MAILPIT"
echo "Usar DocOps: $USE_DOCOPS"
echo "Traefik integrado: $DEPLOY_TRAEFIK"
read -p "Tudo correto? Iniciar implantação? [S/n]: " CONFIRM
CONFIRM=${CONFIRM:-s}
if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
    echo "Operação abortada."
    exit 0
fi

# ==============================================================================
# 8. MOTOR DE INJEÇÃO E GERAÇÃO DE CREDENCIAIS
# ==============================================================================
echo -e "\n${YELLOW}Forjando matriz de segurança e costurando variáveis de ambiente...${NC}"

# 8.1 Geração de Entropia (Senhas e Tokens Core)
POSTGRES_ROOT_PASS=$(openssl rand -hex 12)
REDIS_PASS=$(openssl rand -hex 12)
MINIO_PASS=$(openssl rand -hex 16)
DB_PASS_EVOLUTION=$(openssl rand -hex 10)
DB_PASS_N8N=$(openssl rand -hex 10)
DB_PASS_CHATWOOT=$(openssl rand -hex 10)
DB_PASS_TYPEBOT=$(openssl rand -hex 10)
ENCRYPTION_KEY=$(openssl rand -hex 24)
RUNNERS_AUTH_TOKEN=$(openssl rand -hex 24)

# 8.2 Hash do Traefik (Tratamento para evitar quebra de escape de caracteres no sed)
RAW_HASH=$(htpasswd -nB admin 2>/dev/null || echo "admin:\$apr1\$H6uskkkW\$IgXLP6ewTrSuBkTrqE8wj/")
TRAEFIK_AUTH=$(echo "$RAW_HASH" | sed 's/\$/\$\$/g')

# 8.3 Tokens e Secrets das Aplicações
EVO_API_KEY=$(openssl rand -hex 16)
TYPEBOT_SECRET=$(openssl rand -hex 16)
CHATWOOT_SECRET=$(openssl rand -hex 32)

# 8.4 Lógica de Protocolo
IS_SECURE="false"
[[ "$PROTOCOL" == "https" ]] && IS_SECURE="true"

# 8.5 Clonagem dos Templates
cp .env.example .env
cp envs/evolution.env.example envs/evolution.env
cp envs/typebot.env.example envs/typebot.env
cp envs/chatwoot.env.example envs/chatwoot.env
cp envs/n8n.env.example envs/n8n.env

# ------------------------------------------------------------------------------
# 8.6 INJEÇÃO: .env Principal (Raiz)
# ------------------------------------------------------------------------------
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

# ------------------------------------------------------------------------------
# 8.7 INJEÇÃO: Evolution API
# ------------------------------------------------------------------------------
sed -i "s|VITE_EVOLUTION_API_URL=.*|VITE_EVOLUTION_API_URL=${PROTOCOL}://api-evolution.${DOMAIN}|g" envs/evolution.env
sed -i "s|SERVER_URL=.*|SERVER_URL=${PROTOCOL}://api-evolution.${DOMAIN}|g" envs/evolution.env
sed -i "s|VITE_EVOLUTION_API_KEY=.*|VITE_EVOLUTION_API_KEY=$EVO_API_KEY|g" envs/evolution.env
sed -i "s|AUTHENTICATION_API_KEY=.*|AUTHENTICATION_API_KEY=$EVO_API_KEY|g" envs/evolution.env
sed -i "s|S3_SECRET_KEY=.*|S3_SECRET_KEY=$MINIO_PASS|g" envs/evolution.env
# Correção do Link do Webhook para o n8n
sed -i "s|WEBHOOK_GLOBAL_URL=.*|WEBHOOK_GLOBAL_URL='${PROTOCOL}://n8n.${DOMAIN}/webhook/evolution-router'|g" envs/evolution.env
# Correção da string de conexão com o banco do Chatwoot
sed -i "s|CHATWOOT_IMPORT_DATABASE_CONNECTION_URI=.*|CHATWOOT_IMPORT_DATABASE_CONNECTION_URI=postgresql://chatwoot_user:${DB_PASS_CHATWOOT}@postgres-chatbot:5432/chatwoot_db?sslmode=disable|g" envs/evolution.env

# ------------------------------------------------------------------------------
# 8.8 INJEÇÃO: Chatwoot
# ------------------------------------------------------------------------------
sed -i "s|SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$CHATWOOT_SECRET|g" envs/chatwoot.env
sed -i "s|FRONTEND_URL=.*|FRONTEND_URL=${PROTOCOL}://chatwoot.${DOMAIN}|g" envs/chatwoot.env
sed -i "s|FORCE_SSL=.*|FORCE_SSL=$IS_SECURE|g" envs/chatwoot.env
sed -i "s|MAILER_SENDER_EMAIL=.*|MAILER_SENDER_EMAIL=notifications@${DOMAIN}|g" envs/chatwoot.env
sed -i "s|SMTP_DOMAIN=.*|SMTP_DOMAIN=${DOMAIN}|g" envs/chatwoot.env
sed -i "s|AWS_SECRET_ACCESS_KEY=.*|AWS_SECRET_ACCESS_KEY=$MINIO_PASS|g" envs/chatwoot.env

# ------------------------------------------------------------------------------
# 8.9 INJEÇÃO: Typebot
# ------------------------------------------------------------------------------
sed -i "s|ENCRYPTION_SECRET=.*|ENCRYPTION_SECRET=$TYPEBOT_SECRET|g" envs/typebot.env
sed -i "s|NEXTAUTH_URL=.*|NEXTAUTH_URL=${PROTOCOL}://builder-typebot.${DOMAIN}|g" envs/typebot.env
sed -i "s|NEXT_PUBLIC_VIEWER_URL=.*|NEXT_PUBLIC_VIEWER_URL=${PROTOCOL}://viewer-typebot.${DOMAIN}|g" envs/typebot.env
sed -i "s|ADMIN_EMAIL=.*|ADMIN_EMAIL=$ADMIN_EMAIL|g" envs/typebot.env
sed -i "s|NEXT_PUBLIC_SMTP_FROM=.*|NEXT_PUBLIC_SMTP_FROM=notifications@${DOMAIN}|g" envs/typebot.env
sed -i "s|S3_SECRET_KEY=.*|S3_SECRET_KEY=$MINIO_PASS|g" envs/typebot.env
sed -i "s|S3_PUBLIC_CUSTOM_DOMAIN=.*|S3_PUBLIC_CUSTOM_DOMAIN=${PROTOCOL}://console-minio.${DOMAIN}|g" envs/typebot.env

# ------------------------------------------------------------------------------
# 8.10 INJEÇÃO: n8n
# ------------------------------------------------------------------------------
sed -i "s|N8N_SECURE_COOKIE=.*|N8N_SECURE_COOKIE=$IS_SECURE|g" envs/n8n.env

# ------------------------------------------------------------------------------
# 8.11 TRATAMENTO DE SMTP (Mailpit interno vs Servidor Próprio)
# ------------------------------------------------------------------------------
if [[ "$USE_MAILPIT" =~ ^[Nn]$ ]]; then
    # Injeta credenciais customizadas no Typebot
    sed -i "s|SMTP_HOST=.*|SMTP_HOST=$SMTP_HOST|g" envs/typebot.env
    sed -i "s|SMTP_PORT=.*|SMTP_PORT=$SMTP_PORT|g" envs/typebot.env
    sed -i "s|SMTP_USERNAME=.*|SMTP_USERNAME=$SMTP_USER|g" envs/typebot.env
    sed -i "s|SMTP_PASSWORD=.*|SMTP_PASSWORD=$SMTP_PASS|g" envs/typebot.env
    sed -i "s|SMTP_SECURE=.*|SMTP_SECURE=$IS_SECURE|g" envs/typebot.env
    sed -i "s|SMTP_IGNORE_TLS=.*|SMTP_IGNORE_TLS=false|g" envs/typebot.env

    # Injeta credenciais customizadas no Chatwoot
    sed -i "s|SMTP_ADDRESS=.*|SMTP_ADDRESS=$SMTP_HOST|g" envs/chatwoot.env
    sed -i "s|SMTP_PORT=.*|SMTP_PORT=$SMTP_PORT|g" envs/chatwoot.env
    sed -i "s|SMTP_USERNAME=.*|SMTP_USERNAME=$SMTP_USER|g" envs/chatwoot.env
    sed -i "s|SMTP_PASSWORD=.*|SMTP_PASSWORD=$SMTP_PASS|g" envs/chatwoot.env
fi

# 9. Configuração de Rede, Permissões e Firewall
echo -e "${YELLOW}Preparando infraestrutura local...${NC}"
chmod +x init-databases.sh

if ! docker network ls | grep -q "rede_proxy"; then
    docker network create rede_proxy
    echo "Rede 'rede_proxy' criada."
fi

if command -v ufw &> /dev/null; then
    echo "Configurando UFW Firewall..."
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw reload > /dev/null 2>&1 || true
fi

# 10. Costura Dinâmica dos Módulos Compose e Implantação
echo -e "${YELLOW}Montando matriz do Docker Compose...${NC}"
COMPOSE_CMD="docker compose -f docker-compose.yml"

if [[ "$USE_TRAEFIK" =~ ^[Ss]$ ]]; then
    # Se usa traefik, acopla o módulo chatbot apropriado
    if [[ "$PROTOCOL" == "https" ]]; then
        COMPOSE_CMD="$COMPOSE_CMD -f docker/module-chatbot-ssl.yml"
    else
        COMPOSE_CMD="$COMPOSE_CMD -f docker/module-chatbot-http.yml"
    fi
    
    # Se o traefik for deployado por nós
    if [[ "$DEPLOY_TRAEFIK" =~ ^[Ss]$ ]]; then
        if [[ "$PROTOCOL" == "https" ]]; then
            COMPOSE_CMD="$COMPOSE_CMD -f docker/module-traefik-ssl.yml"
        else
            COMPOSE_CMD="$COMPOSE_CMD -f docker/module-traefik-http.yml"
        fi
    fi
else
    # Se não usa traefik, usa mapeamento de portas puro
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

echo -e "\n${GREEN}Iniciando contêineres...${NC}"
eval "$COMPOSE_CMD pull"
eval "$COMPOSE_CMD up -d"

# 11. Geração dos Helper Scripts
echo -e "${YELLOW}Gerando scripts administrativos...${NC}"
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
echo -e "${GREEN}   Deploy finalizado com sucesso!${NC}"
echo -e "${BLUE}=====================================================${NC}"
echo "Ambiente instalado em: $DEPLOY_DIR"
echo "Utilize ./start.sh e ./stop.sh dentro do diretório para gerenciar os serviços."