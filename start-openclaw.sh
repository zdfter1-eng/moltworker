#!/bin/bash
# Startup script for OpenClaw in Cloudflare Sandbox (Workers AI)

set -e

# Убиваем старые процессы при старте, чтобы не было конфликтов
pkill -9 -f "openclaw" 2>/dev/null || true
rm -f /root/.openclaw/gateway.lock 2>/dev/null || true
rm -f /tmp/openclaw-gateway.lock 2>/dev/null || true
sleep 1

CONFIG_DIR="/root/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"
WORKSPACE_DIR="/root/clawd"
SKILLS_DIR="/root/clawd/skills"

mkdir -p "$CONFIG_DIR" "$WORKSPACE_DIR" "$SKILLS_DIR"

# Создаем базовый конфиг, если его нет
if [ ! -f "$CONFIG_FILE" ]; then
  echo "{}" > "$CONFIG_FILE"
fi

echo "Patching configuration for Workers AI and Security..."
node << 'EOFPATCH'
const fs = require('fs');
const configPath = '/root/.openclaw/openclaw.json';
let config = {};

try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
    console.log('Starting with fresh config');
}

// 1. Настройки шлюза
config.gateway = config.gateway || {};
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.bind = 'lan';
config.gateway.trustedProxies = ['10.1.0.0'];
config.gateway.controlUi = config.gateway.controlUi || {};
config.gateway.controlUi.allowedOrigins = ['*'];

if (process.env.MOLTBOT_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.mode = 'token';
    config.gateway.auth.token = process.env.MOLTBOT_GATEWAY_TOKEN;
}

// 2. Провайдер Workers AI (через AI Gateway)
const accountId = process.env.CF_AI_GATEWAY_ACCOUNT_ID;
const gatewayId = process.env.CF_AI_GATEWAY_GATEWAY_ID;
const apiKey = process.env.CLOUDFLARE_AI_GATEWAY_API_KEY;
const model = process.env.CF_AI_GATEWAY_MODEL || '@cf/meta/llama-3.3-70b-instruct-fp8-fast';

if (accountId && gatewayId && apiKey) {
    const baseUrl = `https://gateway.ai.cloudflare.com/v1/${accountId}/${gatewayId}/workers-ai/v1`;
    config.models = config.models || {};
    config.models.providers = config.models.providers || {};
    
    // Настраиваем провайдера cloudflare
    config.models.providers.cloudflare = {
        baseUrl: baseUrl,
        apiKey: apiKey,
        api: 'openai-completions',
        models: [
            { id: model, name: model, contextWindow: 131072, maxTokens: 8192 }
        ]
    };
    
    // Устанавливаем модель по умолчанию
    config.agents = config.agents || {};
    config.agents.defaults = config.agents.defaults || {};
    config.agents.defaults.model = { primary: `cloudflare/${model}` };
    console.log(`✅ Workers AI configured with model: ${model}`);
}

// 3. Безопасность Telegram (только для тебя)
if (process.env.TELEGRAM_BOT_TOKEN) {
    // Принудительно ставим allowlist, если не задано иное
    const dmPolicy = process.env.TELEGRAM_DM_POLICY || 'allowlist';
    
    config.channels = config.channels || {};
    config.channels.telegram = {
        botToken: process.env.TELEGRAM_BOT_TOKEN,
        enabled: true,
        dmPolicy: dmPolicy,
        groupPolicy: 'disabled' // Отключаем группы
    };

    let allowFromList = [];
    if (process.env.TELEGRAM_DM_ALLOW_FROM) {
        allowFromList = process.env.TELEGRAM_DM_ALLOW_FROM.split(',').map(id => id.trim());
    }

    // УЯЗВИМОСТЬ: Вычищаем '*' если политика не 'open'
    if (dmPolicy !== 'open') {
        allowFromList = allowFromList.filter(id => id !== '*');
    }
    
    // Если политика open - разрешаем всем
    if (dmPolicy === 'open') {
        allowFromList = ['*'];
    }

    config.channels.telegram.allowFrom = allowFromList;
    console.log(`✅ Telegram secured. Allowed IDs: [${allowFromList.join(', ')}]`);
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('✅ Config patched and saved.');
EOFPATCH

# 4. Запуск шлюза
echo "Starting OpenClaw Gateway on port 18789..."
exec openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan
