# Apoio · estado de APO-AT-001–019

Esta matriz descreve o que foi provado neste ramo. **Prova de domínio ou RLS não
equivale a fluxo autenticado end-to-end.** O D1 só fica pronto depois de cada item
ser repetido através do runtime comum num ambiente de testes.

| Cenário | Prova atual | Falta para fechar end-to-end |
| --- | --- | --- |
| APO-AT-001 | `test_customer_cannot_discover_other_tenant_ticket` e prova RLS com Alfa/Beta; uma query por ticket alheio devolve o mesmo vazio que um ID inexistente. O RLS também recusa um service actor com o mesmo UUID de uma pessoa. | Executar pelo shell e API autenticados. |
| APO-AT-002 | Projeção, pesquisa, contexto de assistente e payload de notificação omitem o texto interno; RLS oculta nota e anexo internos ao cliente. | Exercitar API, pesquisa persistida, exportação, notificação e ferramenta real do assistente. |
| APO-AT-003 | Replay do mesmo payload reconhecido pelo digest canónico. | Persistir recibo durável e repetir POST após perder a resposta. |
| APO-AT-004 | Chave igual com conteúdo diferente dá conflito 409 no domínio. | Repetir pelo endpoint transacional e provar que não houve mutação. |
| APO-AT-005 | Atribuição com versão antiga dá conflito 412; SQL exige incremento da versão. | Atualização concorrente real na API/base. |
| APO-AT-006 | Resolver sem responsável ou sem resumo válido é rejeitado no domínio. | Repetir na API e persistir histórico/auditoria. |
| APO-AT-007 | Resposta de cliente reabre `waiting_customer` para `in_progress` e conserva mensagens anteriores. | Confirmar operação atómica na base e vista móvel. |
| APO-AT-008 | Anexo pendente não pode ser publicado; a migração só guarda anexos limpos ligados a uma mensagem. | Upload privado, validação real, rejeição sem vínculo e limpeza do rascunho através de FileAsset. |
| APO-AT-009 | Contexto tipado do assistente recebe só conversa pública. | Ligar ferramenta real ao serviço autorizado e provar ausência do texto interno no pedido ao modelo. |
| APO-AT-010 | Revisão aprovada antiga ou com digest diferente não passa o gate. | Recibo/admissão oficial no serviço comum. |
| APO-AT-011 | Sem prova local ainda. | Reconciliar resposta perdida com recibo D0, sem criar tarefa duplicada. |
| APO-AT-012 | `CLAIMED_DONE` é rotulado como à espera de confirmação, nunca produção. | Confirmar a rotulagem na UI real e só mudar com prova de runtime. |
| APO-AT-013 | Transição de apoio funciona no domínio sem chamar Sovharn. | API e UI persistentes enquanto Sovharn/modelo estão indisponíveis. |
| APO-AT-014 | Prova RLS retira acesso a ticket, mensagens e anexos após revogar cliente ou equipa. | FileAsset deve negar URL/download antigo após revogação; testar fluxo real de exportação. |
| APO-AT-015 | Sem interface móvel implementada. | Browser real em 390 px com teclado aberto, rolagem, foco e submissão. |
| APO-AT-016 | Sem integração externa. | Aguardar contrato/runtime SH Connect certificado e obter recibo e readback reais. |
| APO-AT-017 | Paginação filtra ACL antes de `has_more` e cursor; page size validado. | Paginação SQL/HTTP com cursor estável, concorrência e nenhum duplicado. |
| APO-AT-018 | Categoria inativa é rejeitada sem alterar estado ou versão. | Testar transação persistida e resposta da API. |
| APO-AT-019 | Chave composta liga anexo a mensagem publicada e a mesma instalação/tenant; cliente não vê anexo de nota interna. | Publicar FileAsset + mensagem atomicamente; anexo sem mensagem continua privado ao uploader. |

## Dependência D0

O contexto esperado está fixado em `../support_portal/d0-contract.lock.json`, que aponta
para o commit `2b33272c8287d2ce5e52da96bb20f45635be1c2c` do PR draft
`katatua/gravit-workspace-cloud#3479`. Essa revisão ainda não está publicada nem ligada
à identidade. Não ligar o serviço nem declarar a integração verificada até a entrada
real do middleware/contrato comum.
