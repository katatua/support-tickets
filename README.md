# Apoio

Portal de apoio ao cliente em implementação. O repositório original era uma
demonstração Streamlit que criava tickets aleatórios em memória; essa demonstração
foi removida para não apresentar dados fictícios como trabalho real.

## Estado deste ramo

Este ramo contém a primeira camada de domínio, uma fronteira de contexto fail-closed,
uma migração PostgreSQL com isolamento por tenant/app/instalação/ambiente, e testes
unitários sem dependências externas.

Ainda não é um D1 utilizável: falta ligar o resolver ao middleware D0, o repositório
PostgreSQL, o armazenamento privado de ficheiros, o shell autenticado, e a prova real
de SH Connect. A interface atual explica este estado e não aceita informação de
clientes. Não configurar este ramo como serviço de produção.

## Princípios implementados

- O tenant, ator, instalação e ambiente só podem chegar do contexto autenticado
  instalado pelo middleware D0 no servidor. A app falha fechada sem ele.
- support_portal.domain contém regras puras de autorização por objeto, mensagens,
  transições, idempotência, anexos, revisões aprovadas e prova de entrega.
- migrations/0001_support_portal.sql cria tabelas com referências compostas e RLS.
  A aplicação deve iniciar cada transação com os valores resolvidos pelo D0 em
  app.owner_org_id, app.application_id, app.installation_id, app.environment_id,
  app.data_tenant_id e app.actor_id. O runtime não pode ser dono das tabelas nem ter
  BYPASSRLS.
- Mensagens internas passam por uma política de leitura separada. Anexos exigem uma
  mensagem publicada e scan_state = clean; o FileAsset original continua privado
  no serviço comum até a operação de publicação ser confirmada.
- A ligação ao Sovharn é um vínculo de evolução separado do ticket de apoio. Não há
  endpoint ou recibo SH Connect configurado neste ramo; nenhum estado local declara
  uma submissão, teste ou publicação real.

## Verificação local

Executar: python3 -m unittest discover -s tests -v
Executar: python3 -m py_compile support_portal/context.py support_portal/domain.py
Numa base PostgreSQL descartável: aplicar `migrations/0001_support_portal.sql` e depois
`tests/postgres_rls.sql` com `psql -v ON_ERROR_STOP=1`.

A suíte unitária prova as regras puras. A migração e o fixture RLS foram executados em
PostgreSQL 16.15, com um papel runtime sem `BYPASSRLS`; o fixture verifica tenants,
mensagens internas, anexos e revogação. Isto ainda não prova isolamento HTTP real,
autenticação, interface móvel, armazenamento de anexos ou integração SH Connect.

## Próximos passos para D1

1. Consumir a versão publicada do request-context.schema.json e middleware D0.
2. Implementar a transação PostgreSQL para ticket + primeira mensagem + auditoria e
   recibo idempotente.
3. Implementar o armazenamento de upload privado, inspeção e vínculo atómico.
4. Construir o shell autenticado para cliente e equipa, testar teclado e 390 px.
5. Ligar o adaptador SH Connect somente após descobrir e certificar o contrato real.
6. Executar APO-AT-001–019 num ambiente isolado de teste, separando prova local de
   integração real e publicação.

