# Orquestrador de Ecossistema Chatbot

### O que é

Uma infraestrutura conteinerizada de alta performance para operações de atendimento, automação e mensageria corporativa.

### 🏗️ Arquitetura e Fluxo de Integração

O ecossistema opera de forma interconectada, onde webhooks e APIs garantem a fluidez das mensagens entre o cliente final, a automação e o atendimento humano.

![Fluxo de Integração do Chatbot](./assets/fuxograma.png)

### 📦 Aplicações Integradas

O ecossistema provisiona e orquestra automaticamente os seguintes serviços:

- **Traefik v3:** Proxy reverso de borda e balanceador de carga. Responsável pelo roteamento de tráfego HTTP/HTTPS e emissão automatizada de certificados SSL via Let's Encrypt.
- **PostgreSQL 16 (pgvector):** Motor de banco de dados relacional central. Armazena de forma isolada os dados estruturados do Chatwoot, Typebot, Evolution API e n8n.
- **Redis 7:** Banco de dados em memória de altíssimo desempenho. Atua como sistema de cache, gerenciador de filas de processamento assíncrono e limitador de taxa (_rate-limit_).
- **MinIO:** Servidor de armazenamento de objetos compatível com Amazon S3. Fornece a infraestrutura local para hospedagem de mídias, arquivos de conversas e _backups_.
- **Evolution API:** Motor de integração de mensageria (WhatsApp). Gerencia sessões, webhooks e o tráfego de mensagens entre a rede social e as plataformas de atendimento.
- **Evolution Manager:** Interface gráfica (Frontend) para gestão facilitada de instâncias, conexões e configurações da Evolution API.
- **Chatwoot:** Plataforma _omnichannel_ de atendimento ao cliente (CRM/Inbox). Centraliza o suporte humano e o histórico de conversações. Opera com instâncias dedicadas para a aplicação (Rails) e processamento em segundo plano (Sidekiq).
- **Typebot:** Construtor visual avançado para fluxos de conversação automatizada. Fragmentado em duas camadas operacionais: _Builder_ (criação visual de fluxos) e _Viewer_ (motor de execução e renderização para os usuários finais).
- **n8n:** Orquestrador de automação de fluxos de trabalho. Configurado em topologia escalável avançada (modo de fila com _Workers_ e _Runners_), responsável por interligar todos os sistemas via APIs e Webhooks.
- **Mailpit** _(opcional)_**:** Servidor SMTP interno. Atua como interceptador e roteador de e-mails transacionais gerados pelo ecossistema, dispensando a necessidade imediata de provedores externos para notificações do sistema.
- **DocOps** _(opcional)_**:** Painel de monitoramento e visibilidade de infraestrutura. Fornece métricas e controle em tempo real sobre a saúde dos contêineres Docker do ambiente host.

### 🚀 Como Executar

**1. Pré-requisitos**

- Sistema Operacional Linux (Debian/Ubuntu ou RHEL/CentOS/Rocky/Alma).
- Privilégios de superusuário (root).
- Um domínio principal com apontamento DNS (Tipo A) configurado para o IP do servidor (caso utilize HTTPS via Traefik).

**2. Implantação Automatizada**

Faça o download do script orquestrador e inicie o deploy interativo. O assistente cuidará da clonagem, auditoria de dependências, geração segura de credenciais criptográficas e inicialização da malha de rede.

```bash
# 1. Eleve o privilégio para superusuário
sudo su

# 2. Execute o orquestrador
bash <(curl -sSL https://raw.githubusercontent.com/Or4cu1o/chatbot/main/deploy.sh)
```

**3. Anamnese Interativa**

O script conduz um assistente passo a passo que configura toda a infraestrutura antes do deploy:

**4. O que o script faz automaticamente**

1. Detecta o sistema operacional e hardware.
2. Instala dependências ausentes (curl, git, openssl, Docker, UFW/Firewalld).
3. Clona o repositório em `/opt/chatbot`.
4. Gera credenciais criptográficas aleatórias para todos os serviços.
5. Preenche os arquivos `.env` e `envs/*.env` com base nas respostas da anamnese.
6. Cria a rede Docker `rede_proxy` e configura o firewall (portas 22, 80 e 443).
7. Monta o `docker-compose.yml` dinamicamente via injeção de modelos YAML.
8. Realiza o download das imagens em lotes organizados por criticidade.
9. Prepara o banco de dados do Chatwoot.
10. Gera o arquivo `instrucoes_acesso.txt` com URLs, credenciais e apontamentos DNS.

**5. URLs de Acesso**

Após o status _healthy_ de todos os contêineres, os serviços estarão disponíveis nos subdomínios vinculados ao seu domínio base (exemplo considerando HTTPS):

- **Automação:** `https://n8n.<seu-dominio>`
- **Atendimento:** `https://chatwoot.<seu-dominio>`
- **Criação de Bots:** `https://builder-typebot.<seu-dominio>`
- **Visualização de Bots:** `https://viewer-typebot.<seu-dominio>`
- **API de Mensageria:** `https://api-evolution.<seu-dominio>`
- **Gestão de Mensageria:** `https://manager-evolution.<seu-dominio>`
- **Armazenamento S3:** `https://console-minio.<seu-dominio>`
- **E-mail Interno** _(Mailpit)_**:** `https://mail-chatbot.<seu-dominio>`
- **Monitoramento** _(DocOps)_**:** `https://monitor.<seu-dominio>`

**6. Gerenciamento Pós-Deploy**

Para iniciar ou parar a infraestrutura de forma segura após a instalação inicial, acesse o diretório da aplicação:

```bash
cd /opt/chatbot

# Iniciar toda a infraestrutura
docker compose up -d

# Parar todos os contêineres
docker compose down

# Verificar saúde dos serviços
docker compose ps
```
