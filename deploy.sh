#!/bin/bash
set -e
set -o pipefail

# ==============================================================================
# 0. CONSTANTES E LOGS
# ==============================================================================
export GITHUB_REPO_URL="https://github.com/Or4cu1o/chatbot.git"
export DEPLOY_DIR="/opt/chatbot"
export LOG_PATH="/var/log/chatbot-deploy.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "$1"
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $(echo -e "$1" | sed -r 's/\x1B\[[0-9;]*[mK]//g')" >> "$LOG_PATH"
}

catch_error() {
    local exit_code=$1
    local line_number=$2
    log "\n${RED}[FALHA CRÍTICA] O script abortou na linha ${line_number} com erro ${exit_code}.${NC}"
    log "${YELLOW}Verifique o log para detalhes: $LOG_PATH${NC}\n"
}
trap 'catch_error $? $LINENO' ERR

log "${BLUE}=====================================================${NC}"
log "${BLUE}   Assistente de Instalação - Chatbot Stack          ${NC}"
log "${BLUE}=====================================================${NC}\n"

# ==============================================================================
# 1. PERMISSÃO DE SUPER USUÁRIO
# ==============================================================================
if [[ $EUID -ne 0 ]]; then
   log "${RED}ERRO: Este script precisa ser executado como root.${NC}"
   log "Por favor, utilize: sudo su"
   exit 1
fi

REAL_USER=${SUDO_USER:-$USER}
REAL_PRIMARY_GROUP=$(id -gn "$REAL_USER")

# ==============================================================================
# 2. IDENTIDADE DO SISTEMA OPERACIONAL
# ==============================================================================
log "${YELLOW}[1/10] Identificando Sistema Operacional...${NC}"
if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    OS=$ID
    log "Sistema detectado: $PRETTY_NAME"
else
    log "${RED}Nao foi possivel detectar o sistema operacional! OS nao suportado.${NC}"
    exit 1
fi

# ==============================================================================
# 3 e 4. DEPENDÊNCIAS (Verificação e Instalação)
# ==============================================================================
log "\n${YELLOW}[2/10] Verificando e instalando dependências...${NC}"

install_dependencies() {
    local PKG_MANAGER=$1
    local UPDATE_CMD=$2
    local INSTALL_CMD=$3

    log "Atualizando listas de pacotes..."
    $UPDATE_CMD > /dev/null 2>&1

    for cmd in curl git openssl docker ufw; do
        if ! command -v $cmd &> /dev/null; then
            log "Instalando $cmd..."
            if [ "$cmd" == "docker" ]; then
                curl -fsSL https://get.docker.com -o get-docker.sh
                sh get-docker.sh > /dev/null 2>&1
                rm get-docker.sh
            elif [ "$cmd" == "ufw" ] && [[ "$PKG_MANAGER" == "yum" || "$PKG_MANAGER" == "dnf" ]]; then
                $INSTALL_CMD firewalld > /dev/null 2>&1
                systemctl enable firewalld > /dev/null 2>&1
                systemctl start firewalld > /dev/null 2>&1
            else
                $INSTALL_CMD $cmd > /dev/null 2>&1
            fi
        else
            log "Dependência $cmd já instalada."
        fi
    done
}

case $OS in
    ubuntu|debian)
        install_dependencies "apt" "apt-get update -y" "apt-get install -y"
        ;;
    centos|rhel|fedora|rocky|alma)
        install_dependencies "yum" "yum check-update -y" "yum install -y"
        ;;
    *)
        log "${RED}Sistema Operacional $OS não suportado automaticamente.${NC}"
        exit 1
        ;;
esac

if ! docker compose version &> /dev/null; then
    log "${RED}docker compose plugin não encontrado. Por favor instale o docker-compose-plugin.${NC}"
    exit 1
fi

# ==============================================================================
# 5. CLONAGEM DO REPOSITÓRIO
# ==============================================================================
log "\n${YELLOW}[3/10] Clonando repositório base...${NC}"
if [ -d "$DEPLOY_DIR" ]; then
    log "Encontrado diretório anterior. Movendo para backup..."
    rm -rf "${DEPLOY_DIR}.bak"
    mv "$DEPLOY_DIR" "${DEPLOY_DIR}.bak"
fi

git clone -q "$GITHUB_REPO_URL" "$DEPLOY_DIR"
cd "$DEPLOY_DIR"
log "${GREEN}Repositório clonado em $DEPLOY_DIR${NC}"

# ==============================================================================
# 6. ANAMNESE PRE-DEPLOY
# ==============================================================================
log "\n${YELLOW}[4/10] Iniciando anamnese pre-deploy...${NC}"

read -r -p "6.1. Protocolo [http/https] (padrão https): " PROTOCOL
PROTOCOL=${PROTOCOL:-https}
PROTOCOL=$(echo "$PROTOCOL" | tr '[:upper:]' '[:lower:]')

while true; do
    read -r -p "6.2. Qual domínio a ser usado? (ex: local.com) [Obrigatório]: " DOMAIN
    if [ -n "$DOMAIN" ]; then
        break
    else
        echo -e "${RED}O domínio é obrigatório.${NC}"
    fi
done

ADMIN_EMAIL="admin@$DOMAIN"

echo "6.3. Servidor de E-mails para o Typebot e Chatwoot:"
echo "   [1] Implantar Mailpit (servidor interno de e-mails)"
echo "   [2] Usar servidor próprio (SMTP externo)"
read -r -p "Opção interna (1 ou 2) [Padrão: 1]: " MAIL_OPTION
MAIL_OPTION=${MAIL_OPTION:-1}

USE_MAILPIT="s"
if [ "$MAIL_OPTION" == "2" ]; then
    USE_MAILPIT="n"
    log "\n${YELLOW}--- Configuração SMTP Próprio ---${NC}"
    read -r -p "SMTP Host (ex: smtp.gmail.com): " SMTP_HOST
    read -r -p "SMTP Port (ex: 465, 587): " SMTP_PORT
    read -r -p "SMTP Usuario/Email: " SMTP_USER
    read -r -s -p "SMTP Senha: " SMTP_PASS
    echo ""
    read -r -p "Usar conexão Segura/SSL/TLS? (s/n) [Padrão: s]: " SMTP_SECURE_RESP
    [[ "$SMTP_SECURE_RESP" =~ ^[Nn]$ ]] && SMTP_SECURE="false" || SMTP_SECURE="true"
    
    log "\n${GREEN}[Instruções]: Os dados do SMTP externo serão injetados nos arquivos de ambiente do Typebot e Chatwoot.${NC}"
fi

read -r -p "6.4. Deseja implantar o DocOps para visibilidade em tempo real? [S/n]: " RESP_DOCOPS
[[ "$RESP_DOCOPS" =~ ^[Nn]$ ]] && USE_DOCOPS="n" || USE_DOCOPS="s"

echo "6.5. Qual Webserver você irá utilizar como Proxy Reverso?"
echo "   [1] Traefik (Recomendado/Padrão)"
echo "   [2] Apache"
echo "   [3] Nginx"
echo "   [4] Outros"
read -r -p "Opção (1-4) [Padrão: 1]: " WEBSERVER_OPT
WEBSERVER_OPT=${WEBSERVER_OPT:-1}

USE_TRAEFIK_MODULES="s"
case $WEBSERVER_OPT in
    2|3|4)
        USE_TRAEFIK_MODULES="n"
        log "\n${YELLOW}[AVISO] Configuração Manual Necessária (${NC}Apache/Nginx/Outro${YELLOW})${NC}"
        log "Você escolheu um webserver externo. O deploy exportará apenas as portas."
        log "Você deverá configurar o roteamento manualmente. Portas exportadas:"
        log "  - n8n: 5678"
        log "  - chatwoot: 3000"
        log "  - typebot builder: 8080"
        log "  - typebot viewer: 8081"
        log "  - evolution api: 8082"
        log "  - evolution manager: 8083"
        log "  - minio console: 9001"
        log "  - minio api: 9000"
        [[ "$USE_MAILPIT" == "s" ]] && log "  - mailpit: 8025"
        [[ "$USE_DOCOPS" == "s" ]] && log "  - docops: 8888"
        ;;
    *)
        read -r -p "6.5.2.2.1. Deseja implantar o Traefik junto nesta infra, ou usar um Traefik próprio isolado? [1=Junto, 2=Próprio] [Padrão: 1]: " TRAEFIK_MODE
        TRAEFIK_MODE=${TRAEFIK_MODE:-1}
        if [ "$TRAEFIK_MODE" == "2" ]; then
            USE_TRAEFIK_MODULES="custom"
            log "\n${YELLOW}[AVISO] Traefik Externo.${NC}"
            log "As aplicações utilizarão etiquetas (labels) do Traefik."
            log "Certifique-se de que o seu Traefik tem acesso à rede docker 'rede_proxy'"
            log "e que observa corretamente essa rede."
        fi
        ;;
esac

# ==============================================================================
# 7. CONFIRMAÇÃO DE DADOS
# ==============================================================================
log "\n${YELLOW}[5/10] Resumo das Respostas...${NC}"
echo "--------------------------------------------------------"
echo "Dominio: $DOMAIN"
echo "Protocolo: $PROTOCOL"
echo "Mailpit: $([[ "$USE_MAILPIT" == "s" ]] && echo "Sim" || echo "Não (SMTP Externo)")"
echo "DocOps: $([[ "$USE_DOCOPS" == "s" ]] && echo "Sim" || echo "Não")"
echo "Webserver: $([[ "$USE_TRAEFIK_MODULES" == "n" ]] && echo "Externo Manual" || echo "Traefik")"
echo "--------------------------------------------------------"

read -r -p "7. Confirma que as configurações estão corretas para prosseguir? [S/n]: " RESP_CONFIRM
if [[ "$RESP_CONFIRM" =~ ^[Nn]$ ]]; then
    log "${RED}Deploy abortado pelo usuário.${NC}"
    exit 0
fi

# ==============================================================================
# 8. GERAÇÃO DOS ARQUIVOS DE AMBIENTE (.env)
# ==============================================================================
log "\n${YELLOW}[6/10] Montando arquivos vazios e gerando credenciais randômicas (.env)...${NC}"

POSTGRES_ROOT_USER="postgres"
POSTGRES_ROOT_PASS=$(openssl rand -hex 12)
POSTGRES_ROOT_DB="postgres"
REDIS_PASS=$(openssl rand -hex 12)
MINIO_PASS=$(openssl rand -hex 16)
DB_PASS_EVOLUTION=$(openssl rand -hex 10)
DB_PASS_N8N=$(openssl rand -hex 10)
DB_PASS_CHATWOOT=$(openssl rand -hex 10)
DB_PASS_TYPEBOT=$(openssl rand -hex 10)
ENCRYPTION_KEY=$(openssl rand -hex 24)
RUNNERS_AUTH_TOKEN=$(openssl rand -hex 24)
EVO_API_KEY=$(openssl rand -hex 16)
TYPEBOT_SECRET=$(openssl rand -base64 24 | tr -d '\n')
CHATWOOT_SECRET=$(openssl rand -hex 32)
TRAEFIK_AUTH="admin:\$\$apr1\$\$H6uskkkW\$\$IgXLP6ewTrSuBkTrqE8wj/" # admin:admin (default)

IS_SECURE="false"; [[ "$PROTOCOL" == "https" ]] && IS_SECURE="true"

# Copiando exemplos
cp .env.example .env
cp envs/evolution.env.example envs/evolution.env
cp envs/typebot.env.example envs/typebot.env
cp envs/chatwoot.env.example envs/chatwoot.env
cp envs/n8n.env.example envs/n8n.env

# Export para config do compose
export DOMAIN PROTOCOL ADMIN_EMAIL POSTGRES_ROOT_USER POSTGRES_ROOT_PASS POSTGRES_ROOT_DB
export DB_PASS_EVOLUTION DB_PASS_N8N DB_PASS_CHATWOOT DB_PASS_TYPEBOT REDIS_PASS
export ENCRYPTION_KEY RUNNERS_AUTH_TOKEN MINIO_ROOT_USER="minioadmin" MINIO_ROOT_PASS="$MINIO_PASS"

# Injeções via sed 
sed -i "s|^PROTOCOL=.*|PROTOCOL=$PROTOCOL|g" .env
sed -i "s|^DOMAIN=.*|DOMAIN=$DOMAIN|g" .env
sed -i "s|^ADMIN_EMAIL=.*|ADMIN_EMAIL=$ADMIN_EMAIL|g" .env
sed -i "s|^TRAEFIK_AUTH=.*|TRAEFIK_AUTH=$TRAEFIK_AUTH|g" .env
sed -i "s|^POSTGRES_ROOT_USER=.*|POSTGRES_ROOT_USER=$POSTGRES_ROOT_USER|g" .env
sed -i "s|^POSTGRES_ROOT_PASS=.*|POSTGRES_ROOT_PASS=$POSTGRES_ROOT_PASS|g" .env
sed -i "s|^POSTGRES_ROOT_DB=.*|POSTGRES_ROOT_DB=$POSTGRES_ROOT_DB|g" .env
sed -i "s|^REDIS_PASS=.*|REDIS_PASS=$REDIS_PASS|g" .env
sed -i "s|^MINIO_ROOT_USER=.*|MINIO_ROOT_USER=minioadmin|g" .env
sed -i "s|^MINIO_ROOT_PASS=.*|MINIO_ROOT_PASS=$MINIO_PASS|g" .env
sed -i "s|^DB_PASS_EVOLUTION=.*|DB_PASS_EVOLUTION=$DB_PASS_EVOLUTION|g" .env
sed -i "s|^DB_PASS_N8N=.*|DB_PASS_N8N=$DB_PASS_N8N|g" .env
sed -i "s|^DB_PASS_CHATWOOT=.*|DB_PASS_CHATWOOT=$DB_PASS_CHATWOOT|g" .env
sed -i "s|^DB_PASS_TYPEBOT=.*|DB_PASS_TYPEBOT=$DB_PASS_TYPEBOT|g" .env
sed -i "s|^ENCRYPTION_KEY=.*|ENCRYPTION_KEY=$ENCRYPTION_KEY|g" .env
sed -i "s|^RUNNERS_AUTH_TOKEN=.*|RUNNERS_AUTH_TOKEN=$RUNNERS_AUTH_TOKEN|g" .env

# Variáveis dependentes
# Evolution
sed -i "s|^VITE_EVOLUTION_API_URL=.*|VITE_EVOLUTION_API_URL=${PROTOCOL}://api-evolution.${DOMAIN}|g" envs/evolution.env
sed -i "s|^SERVER_URL=.*|SERVER_URL=${PROTOCOL}://api-evolution.${DOMAIN}|g" envs/evolution.env
sed -i "s|^VITE_EVOLUTION_API_KEY=.*|VITE_EVOLUTION_API_KEY=$EVO_API_KEY|g" envs/evolution.env
sed -i "s|^AUTHENTICATION_API_KEY=.*|AUTHENTICATION_API_KEY=$EVO_API_KEY|g" envs/evolution.env
sed -i "s|^S3_SECRET_KEY=.*|S3_SECRET_KEY=$MINIO_PASS|g" envs/evolution.env
sed -i "s|^WEBHOOK_GLOBAL_URL=.*|WEBHOOK_GLOBAL_URL='${PROTOCOL}://n8n.${DOMAIN}/webhook/evolution-router'|g" envs/evolution.env
sed -i "s|^CHATWOOT_IMPORT_DATABASE_CONNECTION_URI=.*|CHATWOOT_IMPORT_DATABASE_CONNECTION_URI=postgresql://chatwoot_user:${DB_PASS_CHATWOOT}@postgres-chatbot:5432/chatwoot_db?sslmode=disable|g" envs/evolution.env

# Chatwoot
sed -i "s|^SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$CHATWOOT_SECRET|g" envs/chatwoot.env
sed -i "s|^FRONTEND_URL=.*|FRONTEND_URL=${PROTOCOL}://chatwoot.${DOMAIN}|g" envs/chatwoot.env
sed -i "s|^FORCE_SSL=.*|FORCE_SSL=$IS_SECURE|g" envs/chatwoot.env
sed -i "s|^MAILER_SENDER_EMAIL=.*|MAILER_SENDER_EMAIL=notifications@${DOMAIN}|g" envs/chatwoot.env
sed -i "s|^SMTP_DOMAIN=.*|SMTP_DOMAIN=${DOMAIN}|g" envs/chatwoot.env
sed -i "s|^AWS_SECRET_ACCESS_KEY=.*|AWS_SECRET_ACCESS_KEY=$MINIO_PASS|g" envs/chatwoot.env

# Typebot
sed -i "s|^ENCRYPTION_SECRET=.*|ENCRYPTION_SECRET=$TYPEBOT_SECRET|g" envs/typebot.env
sed -i "s|^NEXTAUTH_URL=.*|NEXTAUTH_URL=${PROTOCOL}://builder-typebot.${DOMAIN}|g" envs/typebot.env
sed -i "s|^NEXT_PUBLIC_VIEWER_URL=.*|NEXT_PUBLIC_VIEWER_URL=${PROTOCOL}://viewer-typebot.${DOMAIN}|g" envs/typebot.env
sed -i "s|^ADMIN_EMAIL=.*|ADMIN_EMAIL=$ADMIN_EMAIL|g" envs/typebot.env
sed -i "s|^NEXT_PUBLIC_SMTP_FROM=.*|NEXT_PUBLIC_SMTP_FROM=notifications@${DOMAIN}|g" envs/typebot.env
sed -i "s|^S3_SECRET_KEY=.*|S3_SECRET_KEY=$MINIO_PASS|g" envs/typebot.env
sed -i "s|^S3_PUBLIC_CUSTOM_DOMAIN=.*|S3_PUBLIC_CUSTOM_DOMAIN=${PROTOCOL}://console-minio.${DOMAIN}|g" envs/typebot.env
sed -i "s|^SMTP_AUTH_DISABLED=.*|SMTP_AUTH_DISABLED=false|g" envs/typebot.env

# N8n
sed -i "s|^N8N_SECURE_COOKIE=.*|N8N_SECURE_COOKIE=$IS_SECURE|g" envs/n8n.env

# Lógica Mailpit vs Custom
if [[ "$USE_MAILPIT" == "n" ]]; then
    sed -i "s|^SMTP_HOST=.*|SMTP_HOST=$SMTP_HOST|g" envs/typebot.env envs/chatwoot.env
    sed -i "s|^SMTP_PORT=.*|SMTP_PORT=$SMTP_PORT|g" envs/typebot.env envs/chatwoot.env
    sed -i "s|^SMTP_USERNAME=.*|SMTP_USERNAME=$SMTP_USER|g" envs/typebot.env envs/chatwoot.env
    sed -i "s|^SMTP_PASSWORD=.*|SMTP_PASSWORD=$SMTP_PASS|g" envs/typebot.env envs/chatwoot.env
    sed -i "s|^SMTP_SECURE=.*|SMTP_SECURE=$SMTP_SECURE|g" envs/typebot.env
    sed -i "s|^SMTP_IGNORE_TLS=.*|SMTP_IGNORE_TLS=false|g" envs/typebot.env
    sed -i "s|^SMTP_ADDRESS=.*|SMTP_ADDRESS=$SMTP_HOST|g" envs/chatwoot.env
fi

# ==============================================================================
# 9. REDE PROXY E FIREWALL LIMITS
# ==============================================================================
log "\n${YELLOW}[7/10] Processando ambiente de rede e permissões...${NC}"
chmod +x init-databases.sh

if ! docker network ls | grep -q "rede_proxy"; then
    log "Criando rede_proxy do Docker..."
    docker network create rede_proxy
else
    log "A rede Docker 'rede_proxy' já existe."
fi

if command -v ufw &> /dev/null; then
    log "Configurando e ativando UFW firewall..."
    ufw allow 22/tcp > /dev/null 2>&1
    ufw allow 80/tcp > /dev/null 2>&1
    ufw allow 443/tcp > /dev/null 2>&1
    ufw --force enable > /dev/null 2>&1 || true
    ufw reload > /dev/null 2>&1 || true
elif command -v firewall-cmd &> /dev/null; then
    log "Configurando e ativando Firewalld..."
    firewall-cmd --permanent --add-port=22/tcp > /dev/null 2>&1
    firewall-cmd --permanent --add-port=80/tcp > /dev/null 2>&1
    firewall-cmd --permanent --add-port=443/tcp > /dev/null 2>&1
    
    # Garantindo que o daemon está habilitado e rodando
    systemctl enable firewalld > /dev/null 2>&1 || true
    systemctl start firewalld > /dev/null 2>&1 || true
    
    firewall-cmd --reload > /dev/null 2>&1 || true
fi

# ==============================================================================
# 10. GERAÇÃO DO DOCKER-COMPOSE.YML
# ==============================================================================
log "\n${YELLOW}[8/10] Construindo docker-compose.yml via parse textual...${NC}"

cp models/base-chatbot.yml docker-compose.yml

inject_core_service() {
    local model="$1"
    if [ ! -f "$model" ]; then return; fi
    # Extrai tudo entre services: e a proxima raiz
    local block
    block=$(awk '/^services:/ {flag=1; next} flag && /^[a-z]+:/ {flag=0} flag {print}' "$model")
    if [ -n "$block" ]; then
        # Injeta logo antes de 'postgres-chatbot:'
        awk -v b="$block" '
            /^  postgres-chatbot:/ { print b; print; next }
            { print }
        ' docker-compose.yml > tmp.yml && mv tmp.yml docker-compose.yml
    fi
    # Injeta volumes auxiliares (se houver, caindo no final do arquivo na root volumes:)
    local vblock
    vblock=$(awk '/^volumes:/ {flag=1; next} flag && /^[a-z]+:/ {flag=0} flag {print}' "$model")
    if [ -n "$vblock" ]; then
        echo "$vblock" >> docker-compose.yml
    fi
}

inject_service_properties() {
    local model="$1"
    if [ ! -f "$model" ]; then return; fi
    local services
    services=$(grep -E '^  [a-zA-Z0-9_-]+:' "$model" | tr -d ': ')
    for srv in $services; do
        local block
        block=$(awk -v s="  $srv:" '$0 == s {flag=1; next} flag && /^  [a-zA-Z0-9_-]+:/ {flag=0; next} flag {print}' "$model")
        if [ -n "$block" ]; then
            awk -v s="  $srv:" -v b="$block" '
                $0 == s { print; print b; next }
                { print }
            ' docker-compose.yml > tmp.yml && mv tmp.yml docker-compose.yml
        fi
    done
}

# 1. Injetar serviços nativos inteiros
if [[ "$USE_TRAEFIK_MODULES" == "s" || "$USE_TRAEFIK_MODULES" == "custom" ]]; then
    if [[ "$PROTOCOL" == "https" ]]; then
        [[ "$USE_TRAEFIK_MODULES" == "s" ]] && inject_core_service "models/model-traefik-ssl.yml"
        [[ "$USE_MAILPIT" == "s" ]] && inject_core_service "models/model-mailpit-ssl.yml"
        [[ "$USE_DOCOPS" == "s" ]] && inject_core_service "models/model-monitor-ssl.yml"
    else
        [[ "$USE_TRAEFIK_MODULES" == "s" ]] && inject_core_service "models/model-traefik-http.yml"
        [[ "$USE_MAILPIT" == "s" ]] && inject_core_service "models/model-mailpit-http.yml"
        [[ "$USE_DOCOPS" == "s" ]] && inject_core_service "models/model-monitor-http.yml"
    fi
else
    [[ "$USE_MAILPIT" == "s" ]] && inject_core_service "models/model-mailpit-port.yml"
    [[ "$USE_DOCOPS" == "s" ]] && inject_core_service "models/model-monitor-port.yml"
fi

# 2. Injetar sub-properties (portas ou labels TLS) dentro das raízes pré-existentes
if [[ "$USE_TRAEFIK_MODULES" == "s" || "$USE_TRAEFIK_MODULES" == "custom" ]]; then
    if [[ "$PROTOCOL" == "https" ]]; then
        inject_service_properties "models/model-chatbot-ssl.yml"
    else
        inject_service_properties "models/model-chatbot-http.yml"
    fi
else
    inject_service_properties "models/model-chatbot-ports.yml"
fi

log "${GREEN}docker-compose.yml montado nativamente com sucesso.${NC}"

# ==============================================================================
# FINALIZAÇÃO
# ==============================================================================

log "\n${YELLOW}[9/10] Preparando permissões dos arquivos finais...${NC}"
chown -R "$REAL_USER":"$REAL_PRIMARY_GROUP" "$DEPLOY_DIR"
chown "$REAL_USER":"$REAL_PRIMARY_GROUP" "$LOG_PATH"

log "\n${YELLOW}[10/10] Preparando banco de dados do Chatwoot e exportando instruções...${NC}"
# Chatwoot DB Prepare
docker compose run --rm chatwoot-rails bundle exec rails db:chatwoot_prepare 2>&1 | tee -a "$LOG_PATH"

# Geração de Instruções de Acesso
INSTRUCTIONS_FILE="${DEPLOY_DIR}/instrucoes_acesso.txt"

cat <<EOF > "$INSTRUCTIONS_FILE"
=========================================================
      INSTRUÇÕES DE ACESSO E APONTAMENTOS DNS
=========================================================

Crie os seguintes apontamentos DNS (Tipo A) direcionando para o IP do seu servidor:

Automação (n8n):           ${PROTOCOL}://n8n.${DOMAIN}
Atendimento (Chatwoot):    ${PROTOCOL}://chatwoot.${DOMAIN}
Criação (Typebot Builder): ${PROTOCOL}://builder-typebot.${DOMAIN}
Motor (Typebot Viewer):    ${PROTOCOL}://viewer-typebot.${DOMAIN}
API de Mensageria:         ${PROTOCOL}://api-evolution.${DOMAIN}
Gestão de Mensageria:      ${PROTOCOL}://manager-evolution.${DOMAIN}
Painel S3 (MinIO):         ${PROTOCOL}://console-minio.${DOMAIN}
API S3 (MinIO):            ${PROTOCOL}://s3-minio.${DOMAIN}
EOF

if [[ "$USE_MAILPIT" == "s" ]]; then
    echo "E-mail Interno (Mailpit):  ${PROTOCOL}://mail-chatbot.${DOMAIN}" >> "$INSTRUCTIONS_FILE"
fi

if [[ "$USE_DOCOPS" == "s" ]]; then
    echo "Monitor Docker (DocOps):   ${PROTOCOL}://monitor.${DOMAIN}" >> "$INSTRUCTIONS_FILE"
fi

cat <<EOF >> "$INSTRUCTIONS_FILE"

---------------------------------------------------------
                  DADOS PARA ACESSO
---------------------------------------------------------
[Evolution API]
  URL: $(grep "^SERVER_URL=" "${DEPLOY_DIR}/envs/evolution.env" | cut -d= -f2-)
  KEY: $EVO_API_KEY
  (Acesse o Evolution Manager e insira estes dados)

[Typebot]
  E-mail Admin Inicial: $ADMIN_EMAIL
  (Utilizado no Typebot Builder)

[MinIO Console - S3]
  Acesso: ${PROTOCOL}://console-minio.${DOMAIN}
  Usuario: minioadmin
  Senha (MINIO_ROOT_PASS): $MINIO_PASS

[PostgreSQL Root]
  Senha (POSTGRES_ROOT_PASS): $POSTGRES_ROOT_PASS

[Redis]
  Senha (REDIS_PASS): $REDIS_PASS
EOF

chown "$REAL_USER":"$REAL_PRIMARY_GROUP" "$INSTRUCTIONS_FILE"


{
    echo -e "\n================ CREDENCIAIS GERADAS ================"
    echo "Dominio: $DOMAIN"
    echo "PostgreSQL Root: $POSTGRES_ROOT_PASS"
    echo "Redis: $REDIS_PASS"
    echo "MinIO Root/S3: $MINIO_PASS"
    echo "Evolution API Key: $EVO_API_KEY"
    echo "Arquivo de instrucoes gerado em: $INSTRUCTIONS_FILE"
    echo "====================================================="
} >> "$LOG_PATH"

log "\n${GREEN}[OK] Script gerado pronto!${NC}"
log "${BLUE}=====================================================${NC}"
log "A matriz de configuração foi concluída."
log "Instruções completas e URLs foram salvas no arquivo:"
log "${YELLOW}$INSTRUCTIONS_FILE${NC}"
log ""
log "Ao terminar de configurar o DNS, execute o comando abaixo"
log "para iniciar toda a infraestrutura:"
log "${YELLOW}docker compose up -d${NC}"
log "====================================================="