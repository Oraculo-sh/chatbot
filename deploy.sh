#!/bin/bash
set -e
set -o pipefail

# ==============================================================================
# 0. CONSTANTES E LOGS
# ==============================================================================
export GITHUB_REPO_URL="https://github.com/Or4cu1o/chatbot.git"
export DEPLOY_DIR="/opt/chatbot"
export LOG_PATH="/var/log/chatbot-deploy.log"
DEPLOY_START_TIME=$(date +%s)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ------------------------------------------------------------------------------
# log()     — imprime + grava no log (strips ANSI para o arquivo)
# log_ok()  — linha de sucesso verde
# log_info()— linha de informação ciano
# log_warn()— linha de aviso amarelo (não aborta)
# ------------------------------------------------------------------------------
log() {
    echo -e "$1"
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $(echo -e "$1" | sed -r 's/\x1B\[[0-9;]*[mK]//g')" >> "$LOG_PATH"
}

log_ok()   { log "${GREEN}  ✔ $1${NC}"; }
log_info() { log "${CYAN}  ➜ $1${NC}"; }
log_warn() { log "${YELLOW}  ⚠ $1${NC}"; }

# ------------------------------------------------------------------------------
# set_env_var — atualiza variável no .env via sed. Se não existir, adiciona.
# Uso: set_env_var "VARIAVEL" "valor" "arquivo"
# ------------------------------------------------------------------------------
set_env_var() {
    local key="$1"
    local value="$2"
    local file="$3"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|g" "$file"
    else
        echo "${key}=${value}" >> "$file"
    fi
}

# ------------------------------------------------------------------------------
# cleanup — remove arquivos temporários ao sair (sucesso ou falha)
# ------------------------------------------------------------------------------
cleanup() {
    rm -f "${DEPLOY_DIR}"/tmp.*.yml 2>/dev/null || true
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# catch_error — captura falhas críticas e registra linha + código de saída
# ------------------------------------------------------------------------------
catch_error() {
    local exit_code=$1
    local line_number=$2
    if [[ "$exit_code" -ne 0 ]]; then
        log "\n${RED}[FALHA CRÍTICA] O script abortou na linha ${line_number} com erro ${exit_code}.${NC}"
        log "${YELLOW}Verifique o log para detalhes: $LOG_PATH${NC}\n"
    fi
}
trap 'catch_error $? $LINENO' ERR

# ==============================================================================
# 1. BANNER INICIAL
# ==============================================================================
print_banner() {
    log "${BLUE}=====================================================${NC}"
    log "${BLUE}   Assistente de Instalação - Chatbot Stack          ${NC}"
    log "${BLUE}=====================================================${NC}\n"
}

# ==============================================================================
# 2. PERMISSÃO DE SUPER USUÁRIO
# ==============================================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
       log "${RED}ERRO: Este script precisa ser executado como root.${NC}"
       log "Por favor, utilize: sudo su"
       exit 1
    fi

    REAL_USER=${SUDO_USER:-$USER}
    REAL_PRIMARY_GROUP=$(id -gn "$REAL_USER")
}

# ==============================================================================
# 3. IDENTIDADE DO SISTEMA OPERACIONAL E HARDWARE
# ==============================================================================
detect_system() {
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
    IP_PUBLICO=$(curl -sc /dev/null --max-time 5 ifconfig.me 2>/dev/null || echo "N/A")
    DISK_FREE_GB=$(df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}')

    echo "OS: $OS_NAME"
    echo "HOSTNAME: $HOSTNAME"
    echo "CPU: $CPU vCPUs"
    echo "RAM: $RAM"
    echo "SWAP: $SWAP"
    echo "IP LOCAL: $IP_LOCAL"
    echo "IP PUBLICO: $IP_PUBLICO"
    echo "DISCO LIVRE: ${DISK_FREE_GB}GB"
    echo ""

    # Aviso de espaço insuficiente (mínimo recomendado: 10 GB)
    if [[ "$DISK_FREE_GB" -lt 10 ]]; then
        log_warn "Espaço em disco baixo (${DISK_FREE_GB}GB livre). Recomendado: mínimo 10GB para as imagens Docker."
    fi
}

# ==============================================================================
# 4. DEPENDÊNCIAS (Verificação e Instalação)
# ==============================================================================
install_dependencies() {
    local PKG_MANAGER=$1
    local UPDATE_CMD=$2
    local INSTALL_CMD=$3

    log_info "Atualizando listas de pacotes..."
    eval "$UPDATE_CMD" > /dev/null 2>&1

    for cmd in curl git openssl docker ufw; do
        if ! command -v "$cmd" &> /dev/null; then
            log_info "Instalando $cmd..."
            if [ "$cmd" == "docker" ]; then
                curl -fsSL https://get.docker.com -o get-docker.sh
                sh get-docker.sh > /dev/null 2>&1
                rm -f get-docker.sh
            elif [ "$cmd" == "ufw" ] && [[ "$PKG_MANAGER" == "yum" || "$PKG_MANAGER" == "dnf" ]]; then
                $INSTALL_CMD firewalld > /dev/null 2>&1
                systemctl enable firewalld > /dev/null 2>&1
                systemctl start firewalld > /dev/null 2>&1
            else
                $INSTALL_CMD "$cmd" > /dev/null 2>&1
            fi
            log_ok "$cmd instalado."
        else
            log_info "Dependência $cmd já instalada."
        fi
    done
}

check_dependencies() {
    log "\n${YELLOW}[2/10] Verificando e instalando dependências...${NC}"

    case $OS in
        ubuntu|debian)
            install_dependencies "apt" "apt-get update -y" "apt-get install -y"
            ;;
        centos|rhel|fedora|rocky|alma)
            install_dependencies "yum" "yum check-update -y || true" "yum install -y"
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
    log_ok "Todas as dependências verificadas."
}

# ==============================================================================
# 5. CLONAGEM DO REPOSITÓRIO
# ==============================================================================
clone_repository() {
    log "\n${YELLOW}[3/10] Clonando repositório base...${NC}"
    if [[ "$1" == "--local" ]]; then
        log_info "Modo de desenvolvimento ativado (--local). Ignorando download do GitHub..."
        DEPLOY_DIR="$PWD"
    else
        # Verificando conectividade antes de tentar clonar
        if ! curl -sfo /dev/null --max-time 5 https://github.com; then
            log "${RED}Sem acesso à internet. Verifique a conectividade e tente novamente.${NC}"
            exit 1
        fi

        if [ -d "$DEPLOY_DIR" ]; then
            log_info "Encontrado diretório anterior. Movendo para backup..."
            rm -rf "${DEPLOY_DIR}.bak"
            mv "$DEPLOY_DIR" "${DEPLOY_DIR}.bak"
        fi

        local max_retries=3
        local count=0
        while [ $count -lt $max_retries ]; do
            log_info "Baixando arquivos do repositório (Tentativa $((count+1))/$max_retries)..."
            if git clone -q "$GITHUB_REPO_URL" "$DEPLOY_DIR"; then
                log_ok "Repositório clonado em $DEPLOY_DIR"
                break
            fi
            count=$((count + 1))
            if [ $count -eq $max_retries ]; then
                log "${RED}Falha ao clonar o repositório após várias tentativas.${NC}"
                exit 1
            fi
            sleep 2
        done
        cd "$DEPLOY_DIR"
    fi
}

# ==============================================================================
# 6. ANAMNESE PRE-DEPLOY
# ==============================================================================
run_anamnesis() {
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
            read -r -p "Digite um domínio valido (ex: domain.com ou chatbot.local): " DOMAIN
            if [[ -z "$DOMAIN" ]]; then
                echo -e "${RED}O domínio é obrigatório.${NC}"
            elif [[ "$DOMAIN" == "local" || "$DOMAIN" =~ \.local$ ]]; then
                break
            elif [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]; then
                echo -e "${RED}Formato inválido. Use um domínio como: example.com, sub.example.com.br ou chatbot.local${NC}"
            else
                break
            fi
        done

        ADMIN_EMAIL="admin@$DOMAIN"
        echo ""

        # Inicializar variáveis de protocolo com valores padrão
        PROTOCOL="https"
        SSL_MODE="local"
        LETSENCRYPT_EMAIL=""
        HYBRID_OPT=""
        SSL_CRT_PATH=""
        SSL_KEY_PATH=""

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
                    HYBRID_OPT=${HYBRID_OPT:-3}
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
}

# ==============================================================================
# 8. GERAÇÃO DOS ARQUIVOS DE AMBIENTE (.env)
# ==============================================================================
generate_env_files() {
    log "\n${YELLOW}[6/10] Montando arquivos vazios e gerando credenciais randômicas (.env)...${NC}"

    log_info "Gerando credenciais criptográficas aleatórias..."
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
    log_ok "Credenciais geradas (PostgreSQL, Redis, MinIO, Evolution, Typebot, Chatwoot, n8n)."

    IS_SECURE="false"; [[ "$PROTOCOL" == "https" ]] && IS_SECURE="true"

    # Copiando exemplos
    log_info "Copiando arquivos de exemplo (.env.example → .env)..."
    cp .env.example .env
    cp envs/evolution.env.example envs/evolution.env
    cp envs/typebot.env.example envs/typebot.env
    cp envs/chatwoot.env.example envs/chatwoot.env
    cp envs/n8n.env.example envs/n8n.env
    log_ok "Arquivos base copiados (5 arquivos)."

    # Export para config do compose
    export DOMAIN PROTOCOL ADMIN_EMAIL POSTGRES_ROOT_USER POSTGRES_ROOT_PASS POSTGRES_ROOT_DB
    export DB_PASS_EVOLUTION DB_PASS_N8N DB_PASS_CHATWOOT DB_PASS_TYPEBOT REDIS_PASS
    export ENCRYPTION_KEY RUNNERS_AUTH_TOKEN MINIO_ROOT_USER="minioadmin" MINIO_ROOT_PASS="$MINIO_PASS"

    # Injeções via set_env_var (idempotente — seguro para re-execuções)
    log_info "Injetando credenciais no .env global..."
    set_env_var "PROTOCOL"          "$PROTOCOL"          .env
    set_env_var "DOMAIN"            "$DOMAIN"            .env
    set_env_var "ADMIN_EMAIL"       "$ADMIN_EMAIL"       .env
    set_env_var "TRAEFIK_AUTH"      "$TRAEFIK_AUTH"      .env
    set_env_var "POSTGRES_ROOT_USER" "$POSTGRES_ROOT_USER" .env
    set_env_var "POSTGRES_ROOT_PASS" "$POSTGRES_ROOT_PASS" .env
    set_env_var "POSTGRES_ROOT_DB"  "$POSTGRES_ROOT_DB"  .env
    set_env_var "REDIS_PASS"        "$REDIS_PASS"        .env
    set_env_var "MINIO_ROOT_USER"   "minioadmin"         .env
    set_env_var "MINIO_ROOT_PASS"   "$MINIO_PASS"        .env
    set_env_var "DB_PASS_EVOLUTION" "$DB_PASS_EVOLUTION" .env
    set_env_var "DB_PASS_N8N"       "$DB_PASS_N8N"       .env
    set_env_var "DB_PASS_CHATWOOT"  "$DB_PASS_CHATWOOT"  .env
    set_env_var "DB_PASS_TYPEBOT"   "$DB_PASS_TYPEBOT"   .env
    set_env_var "ENCRYPTION_KEY"    "$ENCRYPTION_KEY"    .env
    set_env_var "RUNNERS_AUTH_TOKEN" "$RUNNERS_AUTH_TOKEN" .env

    # Lógica de SSL Avançada (idempotente via set_env_var)
    set_env_var "SSL_MODE" "$SSL_MODE" .env
    [[ "$SSL_MODE" == "local" ]]  && set_env_var "LETSENCRYPT_EMAIL" "$LETSENCRYPT_EMAIL" .env
    [[ "$SSL_MODE" == "hybrid" ]] && set_env_var "HYBRID_OPT"        "$HYBRID_OPT"        .env
    if [[ "$SSL_MODE" == "manual" ]]; then
        set_env_var "SSL_CRT_PATH" "$SSL_CRT_PATH" .env
        set_env_var "SSL_KEY_PATH" "$SSL_KEY_PATH" .env
    fi
    log_ok ".env global configurado (domínio: $DOMAIN | protocolo: $PROTOCOL | SSL: $SSL_MODE)."

    # Variáveis dependentes por serviço
    log_info "Configurando envs/evolution.env..."
    sed -i "s|^VITE_EVOLUTION_API_URL=.*|VITE_EVOLUTION_API_URL=${PROTOCOL}://api-evolution.${DOMAIN}|g" envs/evolution.env
    sed -i "s|^SERVER_URL=.*|SERVER_URL=${PROTOCOL}://api-evolution.${DOMAIN}|g"                         envs/evolution.env
    sed -i "s|^VITE_EVOLUTION_API_KEY=.*|VITE_EVOLUTION_API_KEY=$EVO_API_KEY|g"                          envs/evolution.env
    sed -i "s|^AUTHENTICATION_API_KEY=.*|AUTHENTICATION_API_KEY=$EVO_API_KEY|g"                          envs/evolution.env
    sed -i "s|^S3_SECRET_KEY=.*|S3_SECRET_KEY=$MINIO_PASS|g"                                             envs/evolution.env
    sed -i "s|^WEBHOOK_GLOBAL_URL=.*|WEBHOOK_GLOBAL_URL='${PROTOCOL}://n8n.${DOMAIN}/webhook/evolution-router'|g" envs/evolution.env
    log_ok "evolution.env configurado."

    log_info "Configurando envs/chatwoot.env..."
    sed -i "s|^SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$CHATWOOT_SECRET|g"                              envs/chatwoot.env
    sed -i "s|^FRONTEND_URL=.*|FRONTEND_URL=${PROTOCOL}://chatwoot.${DOMAIN}|g"                    envs/chatwoot.env
    sed -i "s|^FORCE_SSL=.*|FORCE_SSL=$IS_SECURE|g"                                                envs/chatwoot.env
    sed -i "s|^MAILER_SENDER_EMAIL=.*|MAILER_SENDER_EMAIL=notifications@${DOMAIN}|g"              envs/chatwoot.env
    sed -i "s|^SMTP_DOMAIN=.*|SMTP_DOMAIN=${DOMAIN}|g"                                             envs/chatwoot.env
    sed -i "s|^AWS_SECRET_ACCESS_KEY=.*|AWS_SECRET_ACCESS_KEY=$MINIO_PASS|g"                       envs/chatwoot.env
    log_ok "chatwoot.env configurado."

    log_info "Configurando envs/typebot.env..."
    sed -i "s|^ENCRYPTION_SECRET=.*|ENCRYPTION_SECRET=$TYPEBOT_SECRET|g"                                     envs/typebot.env
    sed -i "s|^NEXTAUTH_URL=.*|NEXTAUTH_URL=${PROTOCOL}://builder-typebot.${DOMAIN}|g"                       envs/typebot.env
    sed -i "s|^NEXT_PUBLIC_VIEWER_URL=.*|NEXT_PUBLIC_VIEWER_URL=${PROTOCOL}://viewer-typebot.${DOMAIN}|g"    envs/typebot.env
    sed -i "s|^ADMIN_EMAIL=.*|ADMIN_EMAIL=$ADMIN_EMAIL|g"                                                     envs/typebot.env
    sed -i "s|^NEXT_PUBLIC_SMTP_FROM=.*|NEXT_PUBLIC_SMTP_FROM=notifications@${DOMAIN}|g"                     envs/typebot.env
    sed -i "s|^S3_SECRET_KEY=.*|S3_SECRET_KEY=$MINIO_PASS|g"                                                 envs/typebot.env
    sed -i "s|^S3_PUBLIC_CUSTOM_DOMAIN=.*|S3_PUBLIC_CUSTOM_DOMAIN=${PROTOCOL}://console-minio.${DOMAIN}|g"   envs/typebot.env
    sed -i "s|^SMTP_AUTH_DISABLED=.*|SMTP_AUTH_DISABLED=false|g"                                              envs/typebot.env
    log_ok "typebot.env configurado."

    log_info "Configurando envs/n8n.env..."
    sed -i "s|^N8N_SECURE_COOKIE=.*|N8N_SECURE_COOKIE=$IS_SECURE|g" envs/n8n.env
    log_ok "n8n.env configurado."

    # Lógica Mailpit vs Custom
    if [[ "$USE_MAILPIT" == "n" ]]; then
        log_info "Aplicando configurações de SMTP externo (Typebot e Chatwoot)..."
        sed -i "s|^SMTP_HOST=.*|SMTP_HOST=$SMTP_HOST|g"         envs/typebot.env envs/chatwoot.env
        sed -i "s|^SMTP_PORT=.*|SMTP_PORT=$SMTP_PORT|g"         envs/typebot.env envs/chatwoot.env
        sed -i "s|^SMTP_USERNAME=.*|SMTP_USERNAME=$SMTP_USER|g" envs/typebot.env envs/chatwoot.env
        sed -i "s|^SMTP_PASSWORD=.*|SMTP_PASSWORD=$SMTP_PASS|g" envs/typebot.env envs/chatwoot.env
        sed -i "s|^SMTP_SECURE=.*|SMTP_SECURE=$SMTP_SECURE|g"   envs/typebot.env
        sed -i "s|^SMTP_IGNORE_TLS=.*|SMTP_IGNORE_TLS=false|g"  envs/typebot.env
        sed -i "s|^SMTP_ADDRESS=.*|SMTP_ADDRESS=$SMTP_HOST|g"   envs/chatwoot.env
        log_ok "SMTP externo configurado ($SMTP_HOST:$SMTP_PORT)."
    else
        log_info "SMTP: Mailpit interno será usado (sem configuração adicional necessária)."
    fi

    log_ok "Todos os arquivos de ambiente configurados com sucesso."
}

# ==============================================================================
# 9. REDE PROXY E FIREWALL LIMITS
# ==============================================================================
setup_network() {
    log "\n${YELLOW}[7/10] Processando ambiente de rede e permissões...${NC}"
    chmod +x init-databases.sh

    if ! docker network ls --format '{{.Name}}' | grep -q '^rede_proxy$'; then
        log_info "Criando rede_proxy do Docker..."
        docker network create rede_proxy
        log_ok "Rede 'rede_proxy' criada."
    else
        log_info "A rede Docker 'rede_proxy' já existe."
    fi

    if command -v ufw &> /dev/null; then
        log_info "Configurando e ativando UFW firewall..."
        ufw allow 22/tcp  > /dev/null 2>&1
        ufw allow 80/tcp  > /dev/null 2>&1
        ufw allow 443/tcp > /dev/null 2>&1
        ufw --force enable > /dev/null 2>&1 || true
        ufw reload         > /dev/null 2>&1 || true
        log_ok "UFW configurado (22, 80, 443)."
    elif command -v firewall-cmd &> /dev/null; then
        log_info "Configurando e ativando Firewalld..."
        firewall-cmd --permanent --add-port=22/tcp  > /dev/null 2>&1
        firewall-cmd --permanent --add-port=80/tcp  > /dev/null 2>&1
        firewall-cmd --permanent --add-port=443/tcp > /dev/null 2>&1

        # Garantindo que o daemon está habilitado e rodando
        systemctl enable firewalld > /dev/null 2>&1 || true
        systemctl start  firewalld > /dev/null 2>&1 || true

        firewall-cmd --reload > /dev/null 2>&1 || true
        log_ok "Firewalld configurado (22, 80, 443)."
    fi
}

# ==============================================================================
# 10. GERAÇÃO DO DOCKER-COMPOSE.YML
# ==============================================================================
inject_core_service() {
    local model="$1"
    if [ ! -f "$model" ]; then return; fi
    # Extrai tudo entre services: e a proxima raiz (chave de nível 0)
    local block
    block=$(awk '/^services:/ {flag=1; next} flag && /^[a-zA-Z]/ {flag=0} flag {print}' "$model")
    if [ -n "$block" ]; then
        local tmpfile
        tmpfile=$(mktemp "${DEPLOY_DIR}/tmp.XXXXXX.yml")
        # Injeta logo antes de 'postgres-chatbot:'
        awk -v b="$block" '
            /^  postgres-chatbot:/ { print b; print; next }
            { print }
        ' docker-compose.yml > "$tmpfile" && mv "$tmpfile" docker-compose.yml
    fi
    # Injeta volumes auxiliares (se houver, na root volumes:)
    local vblock
    vblock=$(awk '/^volumes:/ {flag=1; next} flag && /^[a-zA-Z]/ {flag=0} flag {print}' "$model")
    if [ -n "$vblock" ]; then
        echo "$vblock" >> docker-compose.yml
    fi
}

inject_service_properties() {
    local model="$1"
    if [ ! -f "$model" ]; then return; fi

    local services
    services=$(grep -E '^  [a-zA-Z0-9_-]+:' "$model" | sed 's/:.*//' | sed 's/^  //')

    for srv in $services; do
        # Extrai as propriedades a injetar (labels:, ports:, etc.) do model
        local new_props
        new_props=$(awk -v s="  $srv:" '
            $0 == s  { flag=1; next }
            flag && /^  [a-zA-Z0-9_-]+:/ { flag=0 }
            flag { print }
        ' "$model")

        [ -z "$new_props" ] && continue

        local tmpfile
        tmpfile=$(mktemp "${DEPLOY_DIR}/tmp.XXXXXX.yml")

        # Lógica de buffer:
        # - Ao entrar no bloco do serviço alvo, acumula todas as suas linhas em buf[]
        # - Ao detectar o fim do bloco (próximo serviço de nível 2 ou chave raiz),
        #   descarrega buf[] + new_props antes de imprimir a linha que encerrou o bloco.
        # Isso garante que as propriedades ficam DENTRO do serviço correto.
        awk -v header="  ${srv}:" -v props="$new_props" '
            BEGIN { inside=0; buflen=0 }

            # Detecta o início do serviço alvo
            $0 == header {
                inside=1
                buf[buflen++] = $0
                next
            }

            inside {
                # Fim do bloco: próximo serviço de nível 2 (^  word:) ou raiz (^word)
                if (/^  [a-zA-Z0-9_-]+:/ || /^[a-zA-Z#]/) {
                    # Descarrega o buffer acumulado do serviço atual
                    for (i = 0; i < buflen; i++) print buf[i]
                    # Injeta as novas propriedades ao final do bloco
                    print props
                    # Limpa o buffer e sai do modo inside
                    buflen=0
                    inside=0
                    print
                    next
                }
                buf[buflen++] = $0
                next
            }

            { print }

            END {
                # Último serviço do arquivo (sem linha seguinte para disparar o flush)
                if (inside) {
                    for (i = 0; i < buflen; i++) print buf[i]
                    print props
                }
            }
        ' docker-compose.yml > "$tmpfile" && mv "$tmpfile" docker-compose.yml
    done
}

build_compose() {
    log "\n${YELLOW}[8/10] Construindo docker-compose.yml via parse textual...${NC}"

    cp models/base-chatbot.yml docker-compose.yml

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

    # 3. Validação do YAML final antes de prosseguir
    log_info "Validando docker-compose.yml gerado..."
    if docker compose config --quiet 2>/dev/null; then
        log_ok "docker-compose.yml montado e validado com sucesso."
    else
        log_warn "docker-compose.yml gerado, mas a validação de sintaxe reportou avisos. Verifique antes de subir os containers."
    fi
}

# ==============================================================================
# 11. PERMISSÕES DOS ARQUIVOS FINAIS
# ==============================================================================
set_permissions() {
    log "\n${YELLOW}[9/10] Preparando permissões dos arquivos finais...${NC}"
    chown -R "$REAL_USER":"$REAL_PRIMARY_GROUP" "$DEPLOY_DIR"
    chown "$REAL_USER":"$REAL_PRIMARY_GROUP" "$LOG_PATH"
    log_ok "Permissões ajustadas com sucesso para o usuário ${REAL_USER}."
}

# ==============================================================================
# 12. DOWNLOAD DE IMAGENS EM LOTES
# Cada lote é protegido por até 3 tentativas automáticas com espera entre elas.
# Se todas falharem, o usuário pode optar por pular o lote e tentar manualmente.
# ==============================================================================

pull_with_retry() {
    local label="$1"
    shift
    local max_retries=3
    local wait_secs=10
    local count=0

    while [ $count -lt $max_retries ]; do
        count=$((count + 1))
        log "   [Tentativa $count/$max_retries] docker compose pull $*"
        if docker compose pull "$@"; then
            return 0
        fi

        if [ $count -lt $max_retries ]; then
            log "${YELLOW}   Falha no lote '$label'. Aguardando ${wait_secs}s antes de tentar novamente...${NC}"
            sleep "$wait_secs"
        fi
    done

    log "${RED}   [AVISO] Falha ao baixar o lote '$label' após $max_retries tentativas.${NC}"
    log "${YELLOW}   Após o deploy, execute manualmente: docker compose pull $*${NC}"
    echo ""
    read -r -p "   Pressione ENTER para continuar o deploy, ou Ctrl+C para abortar: "
}

pull_images() {
    log "\n${YELLOW}[10/10] Baixando imagens em grupos para proteger a integridade da rede...${NC}"

    log "-> Lote 1/5 [Núcleo Automação]: n8n e PostgreSQL (Base Pesada)..."
    pull_with_retry "Núcleo Automação" n8n postgres-chatbot redis-chatbot minio-chatbot
    sleep 3

    log "-> Lote 2/5 [Núcleo CRM]: Chatwoot (Base Pesada c/ Camadas Compartilhadas)..."
    pull_with_retry "Núcleo CRM" chatwoot-rails chatwoot-sidekiq
    sleep 3

    log "-> Lote 3/5 [Núcleo Builder]: Typebot (Base Pesada c/ Camadas Compartilhadas)..."
    pull_with_retry "Núcleo Builder" typebot-builder typebot-viewer
    sleep 3

    log "-> Lote 4/5 [Data & APIs]: Evolution (Serviços Leves)..."
    pull_with_retry "Data & APIs" evolution-api evolution-frontend
    sleep 3

    log "-> Lote 5/5 [Opcionais]: Proxy e Ferramentas (Micro-serviços)..."
    OPTIONAL_SERVICES=""
    [[ "$USE_TRAEFIK_MODULES" == "s" ]] && OPTIONAL_SERVICES="traefik"
    [[ "$USE_MAILPIT" == "s" ]] && OPTIONAL_SERVICES="$OPTIONAL_SERVICES mailpit-chatbot"
    [[ "$USE_DOCOPS" == "s" ]] && OPTIONAL_SERVICES="$OPTIONAL_SERVICES docops"

    if [ -n "$OPTIONAL_SERVICES" ]; then
        # shellcheck disable=SC2086
        pull_with_retry "Opcionais" $OPTIONAL_SERVICES
    fi
}

# ==============================================================================
# 13. PREPARAÇÃO DO BANCO DE DADOS
# ==============================================================================
prepare_databases() {
    # Preparando o banco de dados (as imagens já estão cacheadas agrupadas, logo não quebra a tela)
    log "\nProcessando as instâncias estruturais..."
    docker compose run --rm chatwoot-rails bundle exec rails db:chatwoot_prepare
    log_ok "Banco de dados do Chatwoot preparado."
}

# ==============================================================================
# 14. GERAÇÃO DAS INSTRUÇÕES DE ACESSO
# ==============================================================================
generate_instructions() {
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

    # Calcula duração total do deploy
    local deploy_end
    local elapsed_secs
    local elapsed_min
    local elapsed_sec
    deploy_end=$(date +%s)
    elapsed_secs=$(( deploy_end - DEPLOY_START_TIME ))
    elapsed_min=$(( elapsed_secs / 60 ))
    elapsed_sec=$(( elapsed_secs % 60 ))

    log "\n${GREEN}[OK] Deploy concluído com sucesso!${NC}"
    log "${BOLD}${BLUE}=====================================================${NC}"
    log "A matriz de configuração foi concluída."
    log "Instruções completas e URLs foram salvas no arquivo:"
    log "${YELLOW}$INSTRUCTIONS_FILE${NC}"
    log ""
    log "Ao terminar de configurar o DNS, execute o comando abaixo"
    log "para iniciar toda a infraestrutura:"
    log "${YELLOW}docker compose up -d${NC}"
    log ""
    log "${CYAN}⏱  Tempo total do deploy: ${elapsed_min}m ${elapsed_sec}s${NC}"
    log "${BOLD}${BLUE}=====================================================${NC}"
}

# ==============================================================================
# MAIN — ORQUESTRAÇÃO SEQUENCIAL
# ==============================================================================
main() {
    print_banner
    check_root
    detect_system
    check_dependencies
    clone_repository "$1"
    run_anamnesis
    generate_env_files
    setup_network
    build_compose
    set_permissions
    pull_images
    prepare_databases
    generate_instructions
}

main "$@"