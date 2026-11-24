# Apoio

Portal persistente para pedidos de clientes e trabalho da equipa de suporte. A antiga
demonstração Streamlit com dados aleatórios foi removida. Esta branch contém uma API
Flask, uma interface web responsiva, serviço PostgreSQL/RLS e operações idempotentes.

## O que já está no ramo

- Criação e pesquisa de pedidos, paginação por cursor, visibilidade por pessoa/empresa
  e resposta uniforme quando o pedido não está autorizado ou não existe.
- Rascunhos privados por autor, publicação de resposta pública ou nota interna e
  transições persistidas com controlo de versão.
- Fila da equipa, triagem, atribuição apenas a membros ativos e resolução com resumo.
- Recibos persistidos para criação, publicação, triagem, atribuição e transições;
  pedidos repetidos com outra carga útil devolvem conflito.
- Notificações internas guardam apenas destinatário e metadados, sem o texto da nota.
- Ferramentas tipadas e só de leitura para o assistente, usando a mesma ACL e a vista
  pública. O fluxo normal continua a funcionar sem Sovharn ou fornecedor de modelo.
- Uma ação explícita de pessoal autorizado propõe texto de alteração pelo port SH Connect
  injetado e guarda UUID/readback no recibo do ticket. Repetições reconciliam pelo mesmo
  UUID; esta rota não aprova nem cria tarefas.
- A interface não mostra anexos enquanto o armazenamento privado e o scanner não
  estiverem ligados. Não existe modo de demonstração que abra o acesso.
- A aplicação não admite `CLEAN`: `AttachmentRef` ainda não transporta
  atestação D0 v2, a migration proíbe `clean` e RLS bloqueia inserts de anexos.

## Identidade e runtime

O servidor tem de instalar `sovharn.request_context` no ambiente WSGI após autenticar
uma pessoa. Cabeçalhos, cookies, query e corpo do pedido nunca criam tenant ou ator.
Sem esse objeto, as rotas de negócio devolvem 401. O PostgreSQL tem de usar papel
próprio sem `BYPASSRLS`; cada transação recebe o contexto confiável via settings
transaction-local.

O contrato esperado está fixado em `support_portal/d0-contract.lock.json`: PR draft
`katatua/gravit-workspace-cloud#3479`, commit
`0e68980c2cb73b1549ba0f95c5e1cf1e870a2c32`, schema
`packages/sovharn-apps-core/contracts/request-context.v1.schema.json` (blob
`b5a47c322ad71638ad9ba6b888449a7c946a269c`). O contrato FileAsset usa
`ScannerAttestation` v2 (`files.py`, blob
`01591270a7e07d4c6feb515e641ed42a462934ea`): veredito CLEAN, digest dos bytes
inspecionados e HMAC de uma chave confiável. Apoio ainda não implementa esse adapter,
por isso não permite publicar nem guardar anexos como `CLEAN`. O schema não está
publicado nem ligado ao provedor de identidade. O port SH Connect `ShConnectChangeRequestPort` é descrito por interface estrutural local
e pinado em `support_portal/d0-contract.lock.json`; o adapter é injetado pelo host e a
instalação do package não está provada. O destino Apoio continua `PLANNED`;
a existência do lock não prova compatibilidade de runtime nem integração SH Connect.

Os IDs do contexto D0 são tratados como strings opacas: o adapter exige valor não
vazio e sem whitespace nas extremidades, tal como o parser D0 no pin; não acrescenta
um limite local de comprimento nem rejeita caracteres de controlo internos. O
PostgreSQL guarda as mesmas dimensões como texto e inclui organização, app, instalação,
ambiente, tipo de ambiente e tenant nas políticas, chaves e relações.
`application_id` fica limitado a `apoio` na camada SQL. O runtime de identidade ainda
não está ligado; o pin prova apenas a referência do contrato, não a emissão de contexto
nem a integração SH Connect.

## Arranque local

Instalar `requirements.txt`, configurar `APOIO_DATABASE_URL` para uma base de teste
com a migração aplicada e iniciar:

```sh
python -m flask --app support_portal.api run --host 127.0.0.1 --port 8501
```

O servidor local continua a falhar fechado sem middleware de identidade. O endpoint
`/healthz` só confirma que o processo responde; não confirma base de dados, identidade
ou SH Connect. O ambiente Codespaces usa o mesmo portal na porta 8501.

## Verificações

```sh
python3 -m unittest discover -s tests -v
python3 -m py_compile support_portal/*.py
```

Em PostgreSQL descartável, aplicar `migrations/0001_support_portal.sql`,
`migrations/0002_internal_change_request_links.sql` e depois `tests/postgres_rls.sql`
com `psql -v ON_ERROR_STOP=1`. A fixture usa apenas contas,
pessoas, tickets, mensagens e anexos sintéticos e faz rollback. O workflow
`.github/workflows/ci.yml` repete os testes Python e esta prova em PostgreSQL 16.

## Limites para D1 utilizável

1. Publicar o contrato D0 e ligar o middleware de identidade, memberships, grants e
   contexto por transação; manter a role da app sem `BYPASSRLS`.
2. Ligar FileAsset privado e scanner real, incluindo verificação HMAC da atestação v2.
   Não existe rota de upload/descarga; o domínio e SQL recusam CLEAN até o adapter.
3. Provar a API contra PostgreSQL através de runtime autenticado e correr os 19
   cenários APO-AT de ponta a ponta.
4. Verificar a interface em browser real a 390 px com teclado aberto e provar a
   revogação de URLs antigos de ficheiros.
5. Configurar no host o port D0 tipado para submissão/readback SH Connect e a
   credencial server-side por instalação. O package não é dependência desta app; sem port,
   a rota falha fechado. Nenhuma proposta real nem tarefa foi criada.

O estado por cenário está em [docs/acceptance-status.md](docs/acceptance-status.md).
Fallback operacional enquanto D0 ou Sovharn estão indisponíveis:
[docs/manual-fallback.md](docs/manual-fallback.md).
