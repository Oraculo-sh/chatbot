#!/bin/bash
set -e

# O script consome as variáveis globais para forjar os bancos de dados
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL

    -- Chatwoot (Requer a extensão vector ativada via superusuário)
    CREATE USER chatwoot_user WITH PASSWORD '$DB_PASS_CHATWOOT';
    CREATE DATABASE chatwoot_db;
    GRANT ALL PRIVILEGES ON DATABASE chatwoot_db TO chatwoot_user;
    \c chatwoot_db
    CREATE EXTENSION IF NOT EXISTS vector;
    ALTER DATABASE chatwoot_db OWNER TO chatwoot_user;

    -- Evolution API
    CREATE USER evolution_user WITH PASSWORD '$DB_PASS_EVOLUTION';
    CREATE DATABASE evolution_db;
    GRANT ALL PRIVILEGES ON DATABASE evolution_db TO evolution_user;
    ALTER DATABASE evolution_db OWNER TO evolution_user;

    -- n8n
    CREATE USER n8n_user WITH PASSWORD '$DB_PASS_N8N';
    CREATE DATABASE n8n_db;
    GRANT ALL PRIVILEGES ON DATABASE n8n_db TO n8n_user;
    ALTER DATABASE n8n_db OWNER TO n8n_user;

    -- Typebot
    CREATE USER typebot_user WITH PASSWORD '$DB_PASS_TYPEBOT';
    CREATE DATABASE typebot_db;
    GRANT ALL PRIVILEGES ON DATABASE typebot_db TO typebot_user;
    ALTER DATABASE typebot_db OWNER TO typebot_user;

EOSQL