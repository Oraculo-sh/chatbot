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
# 2. IDENTIDADE DO SISTEMA OPERACIONAL E HARDWARE
# ==============================================================================
log "\n${YELLOW}[1/10] Identificando Sistema Operacional...${NC}"
if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    OS_NAME=$PRETTY_NAME
    OS=$ID
else
    log "${RED}Nao foi possivel detectar o sistema operacional! OS nao suportado.${NC}"
    exit 1
fi

HOSTNAME=$(hostname)
CPU=$(nproc)
RAM=$(free -h | awk '/^Mem:/ {print $2}')
SWAP=$(free -h | awk '/^Swap:/ {print $2}')
IP_LOCAL=$(hostname -I | awk '{print $1}')
IP_PUBLICO=$(curl -sc /dev/null --max-time 3 ifconfig.me || echo "N/A")

echo "OS: $OS_NAME"
echo "HOSTNAME: $HOSTNAME"
echo "CPU: $CPU vCPUs"
echo "RAM: $RAM"
echo "SWAP: $SWAP"
echo "IP LOCAL: $IP_LOCAL"
echo "IP PUBLICO: $IP_PUBLICO"
echo ""

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
if [[ "$1" == "--local" ]]; then
    log "Modo de desenvolvimento ativado (--local). Ignorando download do GitHub..."
    DEPLOY_DIR="$PWD"
else
    if [ -d "$DEPLOY_DIR" ]; then
        log "Encontrado diretório anterior. Movendo para backup..."
        rm -rf "${DEPLOY_DIR}.bak"
        mv "$DEPLOY_DIR" "${DEPLOY_DIR}.bak"
    fi

    max_retries=3
    count=0
    while [ $count -lt $max_retries ]; do
        log "Baixando arquivos do repositório (Tentativa $((count+1))/$max_retries)..."
        if git clone -q "$GITHUB_REPO_URL" "$DEPLOY_DIR"; then
            log "${GREEN}Repositório clonado em $DEPLOY_DIR${NC}"
            break
        fi
        count=$((count + 1))
        [ $count -eq $max_retries ] && { log "${RED}Falha ao clonar o repositório após várias tentativas.${NC}"; exit 1; }
        sleep 2
    done
    cd "$DEPLOY_DIR"
fi

# ==============================================================================
# 6. ANAMNESE PRE-DEPLOY
# ==============================================================================
log "\n${YELLOW}[4/10] Iniciando anamnese pre-deploy...${NC}"

while true; do
    echo ""
    echo "4.1. Qual Webserver você irá utilizar como Proxy Reverso?"
    echo "   [1] Traefik (Recomendado/Padrão)"
    echo "   [2] Apache"
    echo "   [3] Nginx"
    echo "   [4] Outros"
    read -r -p "> Selecione uma Opção (1-4) [Padrão: 1]: " WEBSERVER_OPT
    WEBSERVER_OPT=${WEBSERVER_OPT:-1}

    USE_TRAEFIK_MODULES="s"
    if [[ "$WEBSERVER_OPT" == "1" ]]; then
        echo ""
        echo "4.1.1. [Apenas Traefik] Deseja implantar o Traefik agora ou usar um já existente?"
        echo "   [1] Implantar Traefik junto nesta infra"
        echo "   [2] Usar Traefik já existente (Externo)"
        read -r -p "> Selecione uma Opção (1-2) [Padrão: 1]: " TRAEFIK_MODE
        TRAEFIK_MODE=${TRAEFIK_MODE:-1}
        if [[ "$TRAEFIK_MODE" == "2" ]]; then
            USE_TRAEFIK_MODULES="custom"
        fi
    else
        USE_TRAEFIK_MODULES="n"
        echo ""
        log "\n${YELLOW}4.1.2-4 [AVISO] Configuração Manual Necessária (Apache/Nginx/Outro)${NC}"
        echo "Você escolheu um webserver externo. O deploy exportará apenas as portas."
        echo "Você deverá configurar o roteamento manualmente. Portas exportadas:"
        echo "  - n8n: 3001"
        echo "  - chatwoot: 3000"
        echo "  - typebot-builder: 3002"
        echo "  - typebot-viewer: 3003"
        echo "  - evolution-api: 3005"
        echo "  - evolution-manager: 3004"
        echo "  - minio-console: 9001"
        echo "  - minio-api: 9000"
        echo "  - mail-chatbot: 8025"
        echo "  - monitor: 8000"
        echo ""
        read -r -p "Pressione ENTER para prosseguir..."
    fi

    echo ""
    echo "4.2. Qual domínio principal será usado? [Obrigatório]"
    while true; do
        read -r -p "Digite um domínio valido (ex: domain.com): " DOMAIN
        if [ -n "$DOMAIN" ]; then
            break
        else
            echo -e "${RED}O domínio é obrigatório.${NC}"
        fi
    done

    ADMIN_EMAIL="admin@$DOMAIN"
    echo ""
    
    while true; do
        echo "4.3. Qual Protocolo será usado para o domínio $DOMAIN?"
        echo "   [1] HTTP (Sem criptografia, inseguro)"
        echo "   [2] HTTPS (Requer certificado SSL/TLS)"
        read -r -p "> Selecione uma Opção (1-2) [Padrão: 2]: " OPT_PROTO
        OPT_PROTO=${OPT_PROTO:-2}
        
        if [[ "$OPT_PROTO" == "1" ]]; then
            echo ""
            echo "4.3.1. [AVISO] Confirmar uso de protocolo inseguro?"
            echo "   [1] NÃO"
            echo "   [2] SIM"
            read -r -p "> Selecione uma Opção (1-2) [Padrão: 1]: " OPT_INSECURE
            OPT_INSECURE=${OPT_INSECURE:-1}
            if [[ "$OPT_INSECURE" == "2" ]]; then
                PROTOCOL="http"
                SSL_MODE="none"
                break
            fi
        else
            PROTOCOL="https"
            echo ""
            echo "4.3.2. Como o certificado SSL será gerenciado?"
            echo "   [1] Local (Automático - Let's Encrypt)"
            echo "   [2] Externo (Cloudflare Flexible / AWS / DigitalOcean)"
            echo "   [3] Híbrido (Cloudflare Full/Strict)"
            echo "   [4] Manual (Informar diretório)"
            read -r -p "> Selecione uma Opção (1-4) [Padrão: 1]: " SSL_MODE_OPT
            SSL_MODE_OPT=${SSL_MODE_OPT:-1}
            
            if [[ "$SSL_MODE_OPT" == "1" ]]; then
                SSL_MODE="local"
                echo ""
                echo "4.3.2.1.1. Qual o e-mail para avisos do Let's Encrypt?"
                read -r -p "> Digite um e-mail valido (padrão: ${ADMIN_EMAIL}): " LETSENCRYPT_EMAIL
                LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL:-$ADMIN_EMAIL}
                
                echo ""
                echo "4.3.2.1.2. O DNS do domínio $DOMAIN já aponta para este IP? (s/n):"
                echo "   [1] SIM # prossegue normalmente"
                echo "   [2] NÃO # avisa que o Let's Encrypt falhará e lista os apontamentos necessários."
                read -r -p "> Selecione uma Opção (1-2) [Padrão: 1]: " DNS_OK_OPT
                DNS_OK_OPT=${DNS_OK_OPT:-1}
                if [[ "$DNS_OK_OPT" == "2" ]]; then
                    echo ""
                    log "${YELLOW}4.3.2.1.2.2 [AVISO] Realize os apontamentos nativos para os seguintes domínios, caso contrário o Let's Encrypt falhará:${NC}"
                    echo ""
                    echo "  - n8n.${DOMAIN}"
                    echo "  - chatwoot.${DOMAIN}"
                    echo "  - builder-typebot.${DOMAIN}"
                    echo "  - viewer-typebot.${DOMAIN}"
                    echo "  - api-evolution.${DOMAIN}"
                    echo "  - manager-evolution.${DOMAIN}"
                    echo "  - console-minio.${DOMAIN}"
                    echo "  - s3-minio.${DOMAIN}"
                    echo "  - mail-chatbot.${DOMAIN} (Se optar pelo Mailpit)"
                    echo "  - monitor.${DOMAIN} (Se optar pelo DocOps)"
                    echo ""
                    read -r -p "Pressione ENTER para prosseguir ciente..."
                fi
            elif [[ "$SSL_MODE_OPT" == "2" ]]; then
                SSL_MODE="external"
            elif [[ "$SSL_MODE_OPT" == "3" ]]; then
                SSL_MODE="hybrid"
                echo ""
                echo "4.3.2.3.1. Como deseja obter o certificado de origem?"
                echo "   [1] Gerar auto-assinado pelo script"
                echo "   [2] Colar \"Cloudflare Origin Certificate\""
                echo "   [3] Usar Let's Encrypt"
                read -r -p "> Selecione uma Opção (1-3) [Padrão: 3]: " HYBRID_OPT
            else
                SSL_MODE="manual"
                echo ""
                echo "4.3.2.4.a. Caminho completo do Certificado (.crt/.pem):"
                read -r -p "> " SSL_CRT_PATH
                echo "4.3.2.4.b. Caminho completo da Chave Privada (.key):"
                read -r -p "> " SSL_KEY_PATH
            fi
            break
        fi
    done

    echo ""
    while true; do
        echo "4.4. Servidor de E-mails:"
        echo "   [1] Implantar Mailpit"
        echo "   [2] Usar servidor próprio (SMTP externo)"
        read -r -p "> Selecione uma Opção (1-2) [Padrão: 1]: " MAIL_OPTION
        MAIL_OPTION=${MAIL_OPTION:-1}

        USE_MAILPIT="s"
        if [[ "$MAIL_OPTION" == "2" ]]; then
            USE_MAILPIT="n"
            echo ""
            log "${YELLOW}--- 4.4.1. Configuração SMTP Externo ---${NC}"
            read -r -p "SMTP Host: " SMTP_HOST
            read -r -p "SMTP Port: " SMTP_PORT
            read -r -p "SMTP Usuario: " SMTP_USER
            read -r -s -p "SMTP Senha: " SMTP_PASS
            echo ""
            read -r -p "Usar SSL/TLS? (s/n) [Padrão: s]: " SMTP_SECURE_RESP
            [[ "$SMTP_SECURE_RESP" =~ ^[Nn]$ ]] && SMTP_SECURE="false" || SMTP_SECURE="true"
            
            echo ""
            echo "4.4.1.1. Confirma as configurações de SMTP?"
            echo "   [1] SIM (Prosseguir)"
            echo "   [2] NÃO (Reiniciar 4.4)"
            read -r -p "> Selecione uma Opção (1-2) [Padrão: 1]: " CONFIRM_SMTP
            if [[ "${CONFIRM_SMTP:-1}" == "1" ]]; then
                break
            fi
        else
            break
        fi
    done

    echo ""
    echo "4.5. Deseja implantar o DocOps para visibilidade em tempo real?"
    echo "   [1] SIM"
    echo "   [2] NÃO"
    read -r -p "> Selecione uma Opção (1-2) [Padrão: 1]: " DOCOPS_OPT
    if [[ "${DOCOPS_OPT:-1}" == "2" ]]; then
        USE_DOCOPS="n"
    else
        USE_DOCOPS="s"
    fi

    # ==============================================================================
    # 7. CONFIRMAÇÃO DE DADOS MESTRE
    # ==============================================================================
    log "\n${YELLOW}[5/10] Resumo das Respostas...${NC}"
    echo "--------------------------------------------------------"
    
    WEBSERVER_STR="Traefik"
    if [[ "$USE_TRAEFIK_MODULES" == "custom" ]]; then
        WEBSERVER_STR="Traefik (Externo)"
    elif [[ "$USE_TRAEFIK_MODULES" == "n" ]]; then
        WEBSERVER_STR="Externo Manual (Apache/Nginx/Outros)"
    fi
    echo "Webserver: $WEBSERVER_STR"
    echo "Domínio: $DOMAIN"
    
    PROTO_STR="HTTP"
    if [[ "$PROTOCOL" == "https" ]]; then
        if [[ "$SSL_MODE" == "local" ]]; then PROTO_STR="HTTPS (Local Let's Encrypt)"
        elif [[ "$SSL_MODE" == "external" ]]; then PROTO_STR="HTTPS (Externo Flexible)"
        elif [[ "$SSL_MODE" == "hybrid" ]]; then PROTO_STR="HTTPS (Híbrido Origin)"
        else PROTO_STR="HTTPS (Manual)"; fi
    fi
    echo "Protocolo: $PROTO_STR"
    echo ""
    if [[ "$USE_MAILPIT" == "n" ]]; then
        echo "SMTP: Externo"
        echo "  Host: $SMTP_HOST"
        echo "  Port: $SMTP_PORT"
        echo "  Usuario: $SMTP_USER"
        echo "  Senha: ***"
        echo "  Usar SSL/TLS?: $([[ "$SMTP_SECURE" == "true" ]] && echo "Sim" || echo "Não")"
    else
        echo "SMTP: Mailpit Implantado"
    fi
    echo ""
    echo "DocOps: $([[ "$USE_DOCOPS" == "s" ]] && echo "Implantado" || echo "Não")"
    echo "--------------------------------------------------------"
    echo ""
    
    echo "5. Confirma que as configurações estão corretas para prosseguir?"
    echo "   [1] SIM (Iniciar Deploy)"
    echo "   [2] NÃO (Reiniciar Anamnese)"
    read -r -p "> Selecione uma Opção (1-2) [Padrão: 1]: " FINAL_CONFIRM
    
    if [[ "${FINAL_CONFIRM:-1}" == "1" ]]; then
        break
    else
        log "\n${RED}Reiniciando Anamnese a pedido do usuário...${NC}\n"
    fi
done

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

# Lógica de SSL Avançada (Exportando vars capturadas na anamnese avançada do UX)
echo "SSL_MODE=$SSL_MODE" >> .env
[[ "$SSL_MODE" == "local" ]] && echo "LETSENCRYPT_EMAIL=$LETSENCRYPT_EMAIL" >> .env
[[ "$SSL_MODE" == "hybrid" ]] && echo "HYBRID_OPT=$HYBRID_OPT" >> .env
[[ "$SSL_MODE" == "manual" ]] && echo "SSL_CRT_PATH=$SSL_CRT_PATH" >> .env
[[ "$SSL_MODE" == "manual" ]] && echo "SSL_KEY_PATH=$SSL_KEY_PATH" >> .env

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
log "${GREEN}Permissões ajustadas com sucesso para o usuário ${REAL_USER}.${NC}"

log "\n${YELLOW}[10/10] Baixando imagens em grupos para proteger a integridade da rede...${NC}"

log "-> Lote 1/5 [Núcleo Automação]: n8n e PostgreSQL (Base Pesada)..."
docker compose pull n8n-chatbot postgres-chatbot

log "-> Lote 2/5 [Núcleo CRM]: Chatwoot (Base Pesada c/ Camadas Compartilhadas)..."
docker compose pull chatwoot-rails chatwoot-sidekiq chatwoot-web

log "-> Lote 3/5 [Núcleo Builder]: Typebot (Base Pesada c/ Camadas Compartilhadas)..."
docker compose pull builder-typebot viewer-typebot

log "-> Lote 4/5 [Data & APIs]: Evolution, Redis e MinIO (Serviços Leves)..."
docker compose pull api-evolution manager-evolution redis-chatbot minio-chatbot

log "-> Lote 5/5 [Opcionais]: Proxy e Ferramentas (Micro-serviços)..."
OPTIONAL_SERVICES=""
[[ "$USE_TRAEFIK_MODULES" == "s" ]] && OPTIONAL_SERVICES="traefik-router"
[[ "$USE_MAILPIT" == "s" ]] && OPTIONAL_SERVICES="$OPTIONAL_SERVICES mailpit-chatbot"
[[ "$USE_DOCOPS" == "s" ]] && OPTIONAL_SERVICES="$OPTIONAL_SERVICES docops"

if [ -n "$OPTIONAL_SERVICES" ]; then
    # shellcheck disable=SC2086
    docker compose pull $OPTIONAL_SERVICES
fi

# Preparando o banco de dados (as imagens já estão cacheadas agrupadas, logo não quebra a tela)
log "\nProcessando as instâncias estruturais..."
docker compose run --rm chatwoot-rails bundle exec rails db:chatwoot_prepare
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