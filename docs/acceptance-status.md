# Apoio · cenários técnicos locais (IDs provisórios APO-AT-001–019)

Estado desta branch. Unit tests exercem regras e HTTP com um serviço de teste; a prova
SQL exercita PostgreSQL 16 com identidade sintética e RLS. Nenhuma dessas provas
substitui o runtime autenticado comum.

**Não é a matriz canónica de aceite.** O ZIP e `04-Apoio.md` não foram recebidos. Os IDs APO-AT são rótulos locais provisórios, não foram mapeados contra os 231 cenários e não declaram critérios aceites. As evidências abaixo descrevem apenas provas técnicas da branch e limites observados.

Nesta revisão, `python3 -m unittest discover -s tests -v` passou 43 testes e
`python3 -m py_compile support_portal/*.py` passou. As regressões cobrem a compatibilidade
D0 dos IDs opacos e rejeitam CLEAN sem ScannerAttestation v2 no domínio, SQL e RLS.
A prova SQL não arrancou localmente: `initdb` não conseguiu alocar memória partilhada
SysV neste ambiente. O workflow desta branch executa a migration e `tests/postgres_rls.sql`
num PostgreSQL 16 descartável; o resultado de CI não substitui integração autenticada
nem scanner/FileAsset real.

| Cenário | Prova local nesta branch | Gate ainda aberto |
| --- | --- | --- |
| APO-AT-001 | `test_customer_cannot_discover_other_tenant_ticket`; fixture PostgreSQL confirma Alfa/Beta indistinguíveis, actor service sem acesso e isolamento perante mesmo environment_id em outra organização, instalação ou environment_kind. API mapeia todas as recusas a 404. | Repetir com identidade D0 e utilizadores reais de teste. |
| APO-AT-002 | Projeções de cliente, exportação, pesquisa, assistente e notificação não incluem notas internas; RLS filtra mensagem/anexo; drafts são por autor. | Cobrir pesquisa/exportação/assistente/notificação na API e runtime com Postgres. |
| APO-AT-003 | Digest idempotente no domínio; API exige chave e encaminha-a. O serviço cria recibo PostgreSQL na mesma transação; formulário reutiliza o mesmo ID/chave após resposta perdida. | Exercitar replay do POST persistido depois de perder a resposta via driver/runtime. |
| APO-AT-004 | Chave/digest igual dá replay; chave igual com corpo diferente dá conflito; HTTP recusa chave ausente. | Executar conflito contra recibo persistido e provar rollback da operação. |
| APO-AT-005 | Atribuição com versão antiga dá 412 no domínio; API encaminha a versão esperada; operações de persistência fazem `SELECT FOR UPDATE` e validam essa versão. | Corrida concorrente real por duas sessões autenticadas. |
| APO-AT-006 | Resolução sem membro de equipa ativo ou resumo de 10 caracteres falha no domínio. | Exercitar autorização e histórico pela API persistida. |
| APO-AT-007 | Resposta em `waiting_customer` regressa a `in_progress` e conserva a pergunta no histórico; backend publica mensagem e altera estado na transação. | Exercitar sequência completa cliente/equipa no runtime. |
| APO-AT-008 | Anexo `CLEAN` sem atestação D0 v2 é recusado no domínio; SQL rejeita CLEAN e RLS bloqueia inserts runtime. A interface desativa uploads e não aceita bytes. | FileAsset privado, verificação HMAC, validação de conteúdo e fluxo de upload inválido. |
| APO-AT-009 | Ferramenta `read_ticket` é tipada e só lê via serviço autorizado; contexto do assistente inclui mensagens públicas. | Ligar modelo real e provar o payload completo enviado, sem notas internas. |
| APO-AT-010 | Revisão aprovada antiga ou digest diferente não pode ser admitida. | Recibo oficial de admissão do serviço comum. |
| APO-AT-011 | A implementação grava UUID/link e recibo `reconciling` antes do efeito, lê primeiro pelo mesmo UUID e persiste readback append-only. A prova HTTP usa store/port fake e cobre replay/conflito da rota; não executa o store PostgreSQL. SQL/RLS prova que cliente não lê/cria links. | Package/runtime SH Connect real, identidade autenticada, credencial por instalação e reconciliação de timeout no serviço externo. |
| APO-AT-012 | `CLAIMED_DONE` é rotulado como aguardando confirmação, nunca como produção. | Confirmar no shell/runtime partilhado. |
| APO-AT-013 | O fluxo normal de tickets/assistente não depende de Sovharn nem de modelo. Só a ação staff-only de evolução chama o port injetado; com Sovharn ou modelo indisponíveis, o atendimento normal continua. | Repetir com Sovharn e fornecedor de modelo desligados em runtime persistente; ligação real ainda não está instalada. |
| APO-AT-014 | Fixture RLS revoga a leitura antiga de tickets, mensagens e anexos após retirar membership. | URLs de ficheiro e exports emitidos antes da revogação; serviço FileAsset ainda não ligado. |
| APO-AT-015 | HTML/CSS inclui layouts móveis até 390 px e campos de 16 px para evitar zoom automático. | Abrir browser real a 390 px com teclado, foco, rolagem e submissão. |
| APO-AT-016 | Nenhuma integração externa afirmada. Lock e inventário D0 continuam em `PLANNED`. | Contrato/credenciais/readback SH Connect e evidência externa autorizada. |
| APO-AT-017 | Paginação filtra ACL antes de cursor/`has_more`; API valida e passa cursor codificado em base64; lista não publica contagens ocultas. | Repetir em SQL/API com páginas simultâneas e provar ausência de duplicados. |
| APO-AT-018 | Categoria inativa é recusada sem alteração de ticket no domínio; endpoint de triagem usa transação e valida categoria antes do update. | Exercitar a mutação em PostgreSQL/API e confirmar estado/versionamento. |
| APO-AT-019 | A migration proíbe `clean`; o teste PostgreSQL cobre a recusa de CLEAN e o RLS bloqueia criação pelo papel runtime. Não há rota de upload/descarga. | Adapter FileAsset v2, scanner real com HMAC, publicação atómica e revogação do URL. |

## Requisitos APO-001–014

O domínio e o serviço local cobrem identidade por pessoa, ACL de objeto, membership
revogável, visibilidade requester/account, fila e atribuição, rascunhos, notas internas,
transições, versões esperadas, recibos idempotentes, limites de intake, pesquisa
autorizada, cursor, contexto de assistente só público, anexos presos a mensagem, e
separação entre ticket de suporte e pedido de evolução. Consulte os testes unitários e
`migrations/0001_support_portal.sql` para as regras específicas. O que depende de D0,
FileAsset, scanner, navegador ou SH Connect permanece por provar. Nenhum estado
CLEAN pode ser aceite localmente: AttachmentRef não transporta ScannerAttestation,
e a aplicação ainda não verifica a assinatura HMAC v2.

## D0 fixado

`support_portal/d0-contract.lock.json` aponta para o head atual consultado do PR draft
`katatua/gravit-workspace-cloud#3479`: `ad12e19670af05c7b196352c51f5c298b60cc4db`.
O schema `request-context.v1.schema.json` mantém o blob SHA
`b5a47c322ad71638ad9ba6b888449a7c946a269c`; o manifesto de destinos mantém
`0a8c9e8eb2a1622f3001a007303d657bdbea7889`. O contrato ScannerVerdict v2 está em
`sovharn_apps_core/files.py` (blob
`01591270a7e07d4c6feb515e641ed42a462934ea`): exige veredito CLEAN, SHA dos mesmos
bytes e HMAC válido por chave confiável; o SQL FileAsset v2 exige metadados de
atestação (blob `dec6110b4b58c4e021f751e8eea9da72e5588f75`). Apoio ainda não consome
esse adapter. O PR D0 continua draft, sem middleware de identidade, instalação Apoio
ou readback SH Connect; o resolver desta app falha fechado sem objeto confiável WSGI.
O port tipado `ShConnectChangeRequestPort` e os campos de readback estão no blob
`c392c2a72b272b9c57fdcdd4c99ca60713caed6c` de `sh_connect.py`; esta app não copia
o adapter HTTP nem instala o package. Só consome o port injectado pelo host.
Os IDs são strings opacas no adapter e no SQL, sem limite local de comprimento e com
validação de whitespace nas extremidades consistente com D0, mantendo o escopo completo
owner/app/installation/environment/environment_kind/tenant. O contexto
emitido pelo runtime continua por verificar.
