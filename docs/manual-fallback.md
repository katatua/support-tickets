# Procedimento manual de contingência

Este procedimento cobre falhas do modelo, de Sovharn ou do portal. Não configura
email, WhatsApp, chat, SLA nem qualquer canal externo.

## Modelo ou Sovharn indisponível

O apoio normal usa a API e a base PostgreSQL do Apoio, sem chamar o modelo ou
Sovharn. A equipa pode continuar a abrir, classificar, atribuir, responder e resolver
pedidos no portal. A evolução do software fica separada e aguarda um recibo real do
serviço comum.

## Portal ou base de dados indisponível

1. Não confirmar ao cliente que o pedido foi registado. Sem recibo do portal não há
   confirmação de persistência.
2. Usar apenas o procedimento manual e o canal de comunicação já autorizados pela
   organização. Este repositório não declara nem cria um canal externo.
3. Registar nesse sistema autorizado uma referência de contingência, hora, pessoa e
   empresa, assunto, responsável, ação tomada e próxima revisão. Restringir a nota à
   audiência necessária; não incluir informação sensível que não seja indispensável.
4. Não receber nem reenviar ficheiros durante a contingência: o armazenamento privado
   e o scanner ainda não estão ligados.
5. Quando o portal recuperar, criar o pedido com a mesma referência de contingência,
   verificar se já foi importado antes de repetir e manter a resposta original na
   história. Não marcar uma proposta de software como submetida ou admitida sem o
   recibo e readback verdadeiros.

Se a organização ainda não tiver um canal ou registo manual aprovado, a equipa deve
informar o cliente de que o pedido não foi confirmado e seguir o processo operacional
definido pelo responsável de suporte. Não copiar dados de clientes para fixtures,
logs de teste ou repositórios.
