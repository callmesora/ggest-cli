"""Guards for agent-supplied SQL: read-only, one statement, never credentials.

gGest stores credentials readably: user passwords, e-mail/SMTP, web-shop, POS and workshop terminal passwords,
API keys and tokens, licence keys, bank account numbers. Agents never get them: these tables are refused, and so
is any query that names or returns a column that looks like a credential.
"""

import re

SECRET_TABLES = (
    "utilizadores", "broker", "contas_mail", "email_configuracao", "emails_perfil_contas", "ecom_lojas",
    "dropbox_contas", "sms_contas", "ia_extratordados", "mobivendas_terminais", "oficina_mecanicos",
    "oficina_terminais_recepcao", "oficina_terminais_recolha", "licencas", "licencas_registos", "conf_sistema",
    "contas_bancarias", "frlock", "terminais_mobistock", "perfisutl",
)  # fmt: skip
_SECRET_COLUMN_PATTERNS = (
    r"\w*password\w*", "palavrapasse", r"pwd\w*", r"senha\w*", r"\w*token\w*", r"chave\w*", r"nib\w*", r"iban\w*",
    "swift", r"\w*_iban\w*", "numero_cartao",
)  # fmt: skip
_SECRET_COLS = "|".join(_SECRET_COLUMN_PATTERNS)
_SECRET_NAME = re.compile(r"\b(" + "|".join(SECRET_TABLES) + "|" + _SECRET_COLS + r")\b", re.IGNORECASE)
_SECRET_COLUMN = re.compile(r"^(" + _SECRET_COLS + r")$", re.IGNORECASE)
_WRITE_WORDS = re.compile(
    r"\b(insert|update|delete|drop|alter|create|replace|attach|detach|pragma|vacuum|reindex)\b", re.IGNORECASE
)
_READ_START = re.compile(r"^\s*(select|with)\b", re.IGNORECASE | re.DOTALL)

SECRET_MESSAGE = "password columns are not available through this tool"  # noqa: S105 - message text


def mentions_secret(text: str) -> bool:
    """True when `text` names a credential table or a credential-like column."""
    return bool(_SECRET_NAME.search(text))


def is_secret_column(name: str) -> bool:
    """True for a column name that looks like a credential (password, token, IBAN…)."""
    return bool(_SECRET_COLUMN.match(name))


def check_read_only(sql: str) -> str:
    """Return the statement without its trailing ';', or raise ValueError when it is not a safe single read."""
    statement = sql.strip().rstrip(";")
    if ";" in statement:
        raise ValueError("only one statement allowed")
    if not _READ_START.match(statement):
        raise ValueError("only SELECT / WITH queries are allowed")
    if _WRITE_WORDS.search(statement):
        raise ValueError("write/DDL keywords are not allowed")
    if mentions_secret(statement):
        raise ValueError(SECRET_MESSAGE)
    return statement
