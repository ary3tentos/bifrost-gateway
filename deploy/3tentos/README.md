# LLM Gateway 3tentos (Bifrost → Azure AI Foundry)

Gateway LLM central dos apps internos. Os apps não falam mais direto com o Foundry: chamam o Bifrost com uma **virtual key** própria (`sk-bf-…`), e só o Bifrost conhece a key do Foundry.

```
VPS
  chat-ai (uvicorn :3001) ──api-key: sk-bf-<vk>──► Bifrost 127.0.0.1:8081 (Docker) ──key real──► Azure AI Foundry
  [fase 2] nginx llm.3tentos.ai ─────────────────►        (só rotas de inferência)
```

O que isso dá:

- **Key do Foundry centralizada:** fica só no gateway, criptografada no `config.db`.
- **Uma virtual key por app:** cada uma com a lista de deployments permitidos. Budget e rate limit podem ser ligados depois.
- **Custo e uso por app:** tokens, custo e latência visíveis na UI. O conteúdo das conversas **não** é gravado (`disable_content_logging`).

O código Go deste fork não é alterado. A imagem é a oficial `maximhq/bifrost`, com tag fixa no `docker-compose.yml`.

## Arquivos

| Arquivo | Para quê |
|---|---|
| `docker-compose.yml` | Container do Bifrost. Porta presa em `127.0.0.1:8081`, rede `llm-gw`, limite de 512 MB. |
| `config.json` | Providers, virtual keys, segurança. Sem segredos: só referências `env.*`. |
| `env.example` | Modelo do `.env` (segredos). O `.env` real fica só na VPS. |
| `scripts/deploy.sh` | `pull` + `up -d` + espera o `/health`. |
| `scripts/backup.sh` | Backup diário do `config.db`. |
| `nginx/llm.3tentos.ai.conf` | Fase 2: expõe só as rotas de inferência num subdomínio. |
| `../../.github/workflows/deploy-gateway.yml` | Deploy automático na VPS a cada push em `deploy/3tentos/**` na branch `3tentos`. |

## 1. Pré-requisitos na VPS

```bash
free -h; nproc; df -h        # o Bifrost usa ~100–150 MB; deixe >= 600 MB livres
ss -tlnp | grep 8081         # tem que estar livre
docker --version && docker compose version
id appuser                   # precisa estar no grupo docker
sudo apt install -y sqlite3  # só para o backup
```

## 2. Primeira instalação

A VPS tem um clone parcial deste repo em `/data/apps/bifrost-gateway`: só `deploy/3tentos` e os arquivos da raiz, sem baixar o histórico inteiro do Bifrost. O diretório de trabalho do gateway é `/data/apps/bifrost-gateway/deploy/3tentos`. O `.env`, o `data/` e o `backups/` ficam ali, ignorados pelo git.

**1. Deploy key (somente leitura) para a VPS ler o repo privado:**

```bash
ssh-keygen -t ed25519 -f ~/.ssh/bifrost_gateway_deploy -N "" -C "vps-bifrost-gateway"
cat ~/.ssh/bifrost_gateway_deploy.pub
# GitHub → repo → Settings → Deploy keys → Add deploy key → cole a chave (NÃO marque "Allow write access")
cat >> ~/.ssh/config <<'EOF'
Host github-bifrost
  HostName github.com
  User git
  IdentityFile ~/.ssh/bifrost_gateway_deploy
  IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config
ssh -T github-bifrost        # responda "yes" ao fingerprint; deve dizer "successfully authenticated"
```

**2. Clone e subida:**

```bash
sudo mkdir -p /data/apps/bifrost-gateway && sudo chown appuser:appuser /data/apps/bifrost-gateway
git clone --depth 1 --filter=blob:none --sparse -b 3tentos \
  github-bifrost:ary3tentos/bifrost-gateway.git /data/apps/bifrost-gateway
cd /data/apps/bifrost-gateway && git sparse-checkout set deploy/3tentos
cd deploy/3tentos
cp env.example .env && chmod 600 .env && nano .env
mkdir -p data && sudo chown -R 1000:0 data     # o container roda como UID 1000
bash scripts/deploy.sh
```

**Como gerar os segredos do `.env`:**

| Variável | Como gerar |
|---|---|
| `BIFROST_ENCRYPTION_KEY` | `openssl rand -base64 32`. Guarde no cofre de senhas: **não pode mudar** depois sem apagar o banco. |
| `BIFROST_ADMIN_PASSWORD` | Senha forte. |
| `BIFROST_VK_CHAT_AI` | `echo "sk-bf-$(openssl rand -hex 24)"`. O prefixo `sk-bf-` é obrigatório. |

**Primeiro boot:** leva ~80s (migrations e sync do catálogo de modelos). Os seguintes levam ~6s.

**Backup diário** (crontab do root, `sudo crontab -e`):

```
0 3 * * * bash /data/apps/bifrost-gateway/deploy/3tentos/scripts/backup.sh >> /var/log/llm-gateway-backup.log 2>&1
```

## 3. Atualizações

**Manual** (na VPS, depois do merge na branch `3tentos`):

```bash
cd /data/apps/bifrost-gateway && git pull --ff-only && bash deploy/3tentos/scripts/deploy.sh
```

Não edite arquivos versionados (`config.json`, `docker-compose.yml`) direto na VPS: o `git pull` recusa atualizar com mudanças locais. Toda mudança vai por commit; na VPS só existem o `.env`, o `data/` e o `backups/`.

**Automática (opcional):** o workflow `.github/workflows/deploy-gateway.yml` faz o mesmo `git pull` + `deploy.sh` via SSH.

- **Quando roda:** em push na `3tentos` que toque `deploy/3tentos/**`, ou manualmente (Actions → Run workflow).
- **O que faz antes:** valida o `config.json` contra o schema e o `docker-compose.yml`.
- **O que precisa no repo:** a variable `VPS_HOST` e o secret `VPS_SSH_PRIVATE_KEY`, os mesmos do chat-ai.
- **Enquanto não estiverem configurados:** o workflow falha no passo "Check VPS_HOST" sem tocar na VPS.

`config.json` usa `source_of_truth: split` (default):

- No primeiro boot, o arquivo semeia o banco.
- Depois disso, edições feitas na UI permanecem, **exceto** quando a seção correspondente muda no arquivo. Nesse caso, o arquivo vence no próximo restart.
- Regra prática: mudanças estruturais (providers, VKs, segurança) vão por PR no `config.json`.

## 4. Ligar o chat-ai

No `backend/.env` do chat-ai, na VPS. Depois rode `sudo supervisorctl restart fastapi-backend`.

```env
AZURE_OPENAI_ENDPOINT=http://127.0.0.1:8081/azure_passthrough
AZURE_OPENAI_API_KEY=<o mesmo valor de BIFROST_VK_CHAT_AI>

# Vazios, senão estas chamadas contornam o gateway:
AZURE_OPENAI_EMBEDDING_ENDPOINT=
AZURE_OPENAI_EMBEDDING_API_KEY=
CONVERSATION_TITLE_LLM_ENDPOINT=
CONVERSATION_TITLE_LLM_API_KEY=

# >= 2024-06: o chat-ai passa a enviar stream_options.include_usage e o gateway mede tokens/custo dos streams
AZURE_OPENAI_GPT41_API_VERSION=2025-01-01-preview
```

Os nomes de deployment (`AZURE_OPENAI_*_DEPLOYMENT`, `AZURE_EMBEDDINGS_MODEL`) não mudam.

- **Deployment fora da lista:** precisa entrar em `allowed_models` da VK `vk-chat-ai` no `config.json`, senão o gateway responde `403 model_blocked`. Isso vale, por exemplo, para o `WEB_SEARCH_MODEL_DEPLOYMENT`.
- **Por que funciona sem mudar código:** o chat-ai monta `{AZURE_OPENAI_ENDPOINT}/openai/deployments/...` e `{AZURE_OPENAI_ENDPOINT}/openai/v1/responses` com o header `api-key`. O passthrough reconhece `api-key: sk-bf-…` como virtual key, troca pela key real e repassa a resposta do Azure byte a byte. Isso inclui `content_filter_results` e os erros de content filter e context length, que o chat-ai já trata.
- **Depois de ~1 semana estável:** regenere a key do Foundry no portal e atualize só o `.env` do gateway. A partir daí, nenhum app tem a key real.
- **Rollback (< 1 min):** volte `AZURE_OPENAI_ENDPOINT` e `AZURE_OPENAI_API_KEY` para os valores do Foundry e reinicie o backend.

## 5. Adicionar outro app

1. Gere `BIFROST_VK_<APP>=sk-bf-…` e coloque no `.env` da VPS.
2. No `config.json`, copie o bloco da `vk-chat-ai`:
   - mude `id` e `name`;
   - use `value: "env.BIFROST_VK_<APP>"`;
   - liste só os deployments que o app usa.
3. Se o app usar um deployment novo, acrescente o alias identidade em `providers.azure.keys[0].aliases`. Os aliases servem para catálogo e preço; no passthrough eles **não** renomeiam o deployment.
4. Faça o PR. O merge na `3tentos` faz o deploy.

**Como cada app chama o gateway:**

| App | Endpoint |
|---|---|
| Langflow (container na VPS) | Junte o compose dele à rede externa `llm-gw` e use `TENTOS_AI_AZURE_ENDPOINT=http://bifrost:8080/azure_passthrough`. |
| Apps fora da VPS (transcribe-3t, dashboard-segmentos) | Habilite o nginx da fase 2 e use `https://llm.3tentos.ai/azure_passthrough`. |
| Apps novos | OpenAI SDK com `base_url="https://llm.3tentos.ai/v1"`, `api_key="sk-bf-…"` e `model="azure/<deployment>"`. |

- **dashboard-segmentos:** remova o `?api-version=...` da chamada `/openai/responses`. O gateway reescreve o path para `/openai/v1/responses`, que não aceita api-version datada.
- **Rota `/v1` (apps novos):** passa pelo pipeline completo, com retry em 429 com rotação de key, fallbacks e usage automático nos streams.

## 6. UI de admin

A UI não é exposta na internet. Acesse por túnel SSH:

```bash
ssh -L 8081:127.0.0.1:8081 appuser@<VPS>
# abra http://127.0.0.1:8081 e entre com BIFROST_ADMIN_USERNAME / BIFROST_ADMIN_PASSWORD
```

Em **Logs** aparecem as chamadas por virtual key, com tokens, custo e latência, sem o conteúdo.

## 7. Testes rápidos (na VPS)

```bash
VK=<valor de BIFROST_VK_CHAT_AI>; B=http://127.0.0.1:8081
curl -s $B/health                                                    # {"status":"ok"}
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$B/azure_passthrough/openai/deployments/gpt-4.1/chat/completions?api-version=2025-01-01-preview" \
  -H 'Content-Type: application/json' -d '{"messages":[{"role":"user","content":"ping"}]}'           # 401 (sem VK)
curl -s -X POST "$B/azure_passthrough/openai/deployments/gpt-4.1/chat/completions?api-version=2025-01-01-preview" \
  -H "api-key: $VK" -H 'Content-Type: application/json' -d '{"messages":[{"role":"user","content":"ping"}]}'  # completion
curl -s -o /dev/null -w '%{http_code}\n' $B/api/providers                                            # 401 (admin protegido)
curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://<IP-público>:8081/health                 # (de fora) tem que falhar
```

No PowerShell, use `curl.exe`: o alias `curl` vira `Invoke-WebRequest`.

## 8. Backup, restore e upgrade

**Backup:**

- O cron do root roda `scripts/backup.sh`, que grava `backups/config-<data>.db.gz` com retenção de 14 dias.
- `--with-logs` inclui também o `logs.db`.
- O backup só serve junto com a `BIFROST_ENCRYPTION_KEY`.

**Restore:**

```bash
cd /data/apps/bifrost-gateway/deploy/3tentos && docker compose down
gunzip -c backups/config-<data>.db.gz > data/config.db && rm -f data/config.db-wal data/config.db-shm
sudo chown 1000:0 data/config.db && bash scripts/deploy.sh
```

**Upgrade:**

1. Leia `docs/changelogs/v<nova>.mdx` (seções "Warning" e "Database Migrations").
2. Rode o backup.
3. Troque a tag da imagem no `docker-compose.yml` e faça o PR.
4. **Não há downgrade automático.** As migrations rodam no boot e não são desfeitas ao voltar a imagem; o rollback é restaurar o backup com a tag antiga.
5. Use sempre versão >= v2.2.5, que corrige um bypass de auth.

## 9. Limitações do passthrough (aceitas)

- **Sem retry e sem rotação de key em 429/5xx do Azure.** A resposta volta igual para o app. O chat-ai já tem retry próprio.
- **Sem fallbacks.** Os aliases não renomeiam o deployment na URL, então o nome do deployment precisa existir no recurso Foundry.
- **Custo de stream depende do app.** O custo e os budgets de streams só contam quando o app manda `stream_options.include_usage`; veja o `AZURE_OPENAI_GPT41_API_VERSION` acima.

## 10. Teste local (Windows)

1. Rode a partir desta pasta, com um `.env` local: `docker compose up -d`.
2. Use `127.0.0.1` na URL, não `localhost`.
3. Se a 8081 já estiver em uso (por exemplo, um Bifrost via `npx`), pare o outro processo ou troque a porta do host no compose.

## Fora do escopo, mas urgente

O `scripts/setup-vps.sh` do chat-ai roda `ufw allow 27017/tcp` e `6379/tcp`, o que expõe o MongoDB e o Redis à internet.

- Confira com `sudo ufw status`.
- Feche as portas: `sudo ufw delete allow 27017/tcp && sudo ufw delete allow 6379/tcp`.
- Garanta `bindIp: 127.0.0.1` no `mongod.conf` e `bind 127.0.0.1` no `redis.conf`.
