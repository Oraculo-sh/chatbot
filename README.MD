# 🚀 Plataforma de Atendimento Multi-Operador (Chatbot Stack)

Infraestrutura de alta performance para orquestração de atendimento omnichannel e automação de fluxos. O ecossistema opera sob arquitetura de microsserviços em contêineres, blindado e otimizado para escalabilidade.

## 📐 Topologia Visual

![Fluxograma da Arquitetura](assets/fuxograma.png)

## ⚙️ Stack Tecnológico

A planta consolida os seguintes motores em uma única rede de processamento:

- **Evolution API (v2):** Motor central de disparos e integração WhatsApp.
- **Chatwoot:** Plataforma de atendimento humano (Rails + Sidekiq).
- **Typebot:** Construtor visual de fluxos de conversação (Builder & Viewer).
- **n8n:** Orquestrador lógico e de automação (Topologia distribuída com Workers e Runners em _sandbox_).
- **PostgreSQL (pgvector):** Banco de dados relacional unificado com suporte a IA.
- **Redis (AOF Mode):** Motor de fila (_broker_) e cache de alta resiliência.
- **MinIO:** Armazenamento de objetos (S3 Compatible) para mídias e anexos.
- **Traefik:** _API Gateway_ e balanceador de carga externo.

## 📁 Estrutura de Diretórios

O servidor hospedeiro exige a seguinte simetria estrutural para injeção de volumes e credenciais:

```text
chatbot/
├── assets/
│   └── fuxograma.png
├── envs/
│   ├── chatwoot.env
│   ├── evolution.env
│   ├── n8n.env
│   └── typebot.env
├── scripts/
├── .env                  <-- Cofre Mestre de Variáveis
├── docker-compose.yml    <-- Manifesto de Orquestração
└── init-databases.sh     <-- Script de Provisionamento de Bancos

```

## 🔒 Protocolo de Ignição

### 1. Preparação do Hospedeiro

Para garantir a resolução de nomes (DNS) correta no ambiente de desenvolvimento, atualize o arquivo `hosts` da máquina de teste (ex: `/etc/hosts`):

```text
127.0.0.1 s3-minio.local console-minio.local api-evolution.local manager-evolution.local builder-typebot.local viewer-typebot.local chatwoot.local n8n.local

```

### 2. Permissões de Execução

O motor do PostgreSQL exige elevação de privilégio para injetar as credenciais iniciais:

```bash
chmod +x init-databases.sh

```

### 3. Acionamento

A partir da raiz do diretório `chatbot`, execute a ordem de levantamento dos motores em segundo plano:

```bash
docker compose up -d

```

### 4. Auditoria de Provisionamento

Para atestar que os bancos de dados foram forjados com sucesso via script:

```bash
docker compose logs -f postgres_chatbot

```

## ⚠️ Manutenção e Escalabilidade

- **Logs:** A rotação de logs está limitada a 60MB por contêiner (3 arquivos de 20MB) via `json-file` para evitar o estrangulamento do disco.
- **Persistência:** O Redis opera em modo `--appendonly yes`. Desligamentos abruptos não corromperão a fila do n8n ou as tarefas do Sidekiq.
- **Isolamento:** Variáveis de banco presentes na pasta `envs/` são implacavelmente sobrescritas no momento do _boot_ pelas credenciais centrais do `.env` mestre. Nunca declare senhas definitivas nos arquivos secundários.
