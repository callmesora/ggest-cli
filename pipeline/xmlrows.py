"""Tolerant streaming reader for WDMap XML exports.

WDMap writes `ISO-8859-1` in the header but the bytes are Windows-1252, and values can hold control
characters that strict XML parsers reject, so rows are cut with plain string search.
"""
import html
import re

FIELD = re.compile(r"<([A-Za-z_][\w.-]*)>(.*?)</\1>", re.S)


def rows_of(path, table):
    """Yield each row as a list of (column, value) pairs, in file order."""
    open_tag, close_tag = f"<{table}>", f"</{table}>"
    buf = ""
    with open(path, "rb") as f:
        while True:
            chunk = f.read(4 << 20)
            if not chunk:
                break
            buf += chunk.decode("cp1252", "replace")
            pos = 0
            while True:
                s = buf.find(open_tag, pos)
                if s < 0:
                    break
                e = buf.find(close_tag, s + len(open_tag))
                if e < 0:
                    break
                body = buf[s + len(open_tag):e]
                pos = e + len(close_tag)
                yield [(m.group(1), html.unescape(m.group(2))) for m in FIELD.finditer(body)]
            buf = buf[pos:]
