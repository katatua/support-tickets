import streamlit as st

st.set_page_config(page_title="Apoio", page_icon="🎫", layout="wide")
st.title("Apoio")
st.caption("Portal de pedidos para clientes e equipa de suporte")

st.warning(
    "A autenticação por pessoa, as permissões da empresa e o armazenamento "
    "persistente ainda não estão ligados. Esta página não aceita pedidos nem "
    "ficheiros."
)
st.write(
    "O template anterior mostrava tickets aleatórios guardados apenas na sessão "
    "do browser. Essa demonstração foi retirada para evitar que dados fictícios "
    "pareçam pedidos reais."
)
st.info(
    "A interface será ativada depois de o middleware D0 entregar o contexto "
    "autenticado e de a base de dados e o armazenamento privado estarem ligados."
)
st.caption("Estado de desenvolvimento: IMPLEMENTED_UNVERIFIED")

