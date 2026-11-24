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
  pública. O fluxo de apoio não chama Sovharn nem depende de um modelo.
- A interface não mostra anexos enquanto o armazenamento privado e o scanner não
  estiverem ligados. Não existe modo de demonstração que abra o acesso.

## Identidade e runtime

O servidor tem de instalar `sovharn.request_context` no ambiente WSGI após autenticar
uma pessoa. Cabeçalhos, cookies, query e corpo do pedido nunca criam tenant ou ator.
Sem esse objeto, as rotas de negócio devolvem 401. O PostgreSQL tem de usar papel
próprio sem `BYPASSRLS`; cada transação recebe o contexto confiável via settings
transaction-local.

O contrato esperado está fixado em `support_portal/d0-contract.lock.json`: PR draft
`katatua/gravit-workspace-cloud#3479`, commit
`72c22b87c4989dc50749087184d34cacb81127c4`, schema
`packages/sovharn-apps-core/contracts/request-context.v1.schema.json` (blob
`b5a47c322ad71638ad9ba6b888449a7c946a269c`). O schema não está publicado nem ligado
ao provedor de identidade. O destino Apoio continua `PLANNED`; a existência do lock
não prova compatibilidade de runtime nem integração SH Connect.

O schema D0 declara os campos de ID como strings não vazias, sem formato UUID. Este
adapter e o esquema PostgreSQL da app exigem UUID nos campos indicados em
`adapter_requirements.uuid_string_fields`. A emissão desses valores no formato UUID
é um requisito de compatibilidade do runtime ainda por verificar; a app não declara
integração D0 funcional até haver essa prova.

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

Em PostgreSQL descartável, aplicar `migrations/0001_support_portal.sql` e depois
`tests/postgres_rls.sql` com `psql -v ON_ERROR_STOP=1`. A fixture usa apenas contas,
pessoas, tickets, mensagens e anexos sintéticos e faz rollback.

## Limites para D1 utilizável

1. Publicar o contrato D0 e ligar o middleware de identidade, memberships, grants e
   contexto por transação; manter a role da app sem `BYPASSRLS`.
2. Ligar FileAsset privado e scanner real. Upload, URL de anexo, exportação de ficheiro
   e publicação de mensagem com anexos não estão implementados nem aceitam conteúdo.
3. Provar a API contra PostgreSQL através de runtime autenticado e correr os 19
   cenários APO-AT de ponta a ponta.
4. Verificar a interface em browser real a 390 px com teclado aberto e provar a
   revogação de URLs antigos de ficheiros.
5. Confirmar o port SH Connect oficial, obter recibo/readback reais e só então ligar
   pedidos de evolução do software. Nenhuma tarefa foi submetida ou admitida aqui.

O estado por cenário está em [docs/acceptance-status.md](docs/acceptance-status.md).
Fallback operacional enquanto D0 ou Sovharn estão indisponíveis:
[docs/manual-fallback.md](docs/manual-fallback.md).
