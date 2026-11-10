"""A tiny synthetic gGest database (fake names and figures) with the business views as plain tables."""

import sqlite3
from collections.abc import Iterator
from pathlib import Path

import pytest

from bi import dates, db

SCHEMA = """
CREATE TABLE sales_facts (doc_id TEXT, doc_type TEXT, doc_class TEXT, doc_date TEXT, year INT, quarter TEXT,
  month TEXT, customer_code TEXT, customer_name TEXT, item_code TEXT, item_description TEXT, line_kind TEXT,
  group_name TEXT, family_name TEXT, brand_name TEXT, qty REAL, net REAL, cost REAL, margin REAL, cost_source TEXT,
  origin_doc_type TEXT);
CREATE TABLE sales_docs (doc_id TEXT, doc_date TEXT, doc_class TEXT, is_cancelled INT, is_internal INT,
  weekday INT, hour INT, net REAL);
CREATE TABLE customers (customer_code TEXT, name TEXT, nif TEXT, email TEXT, phone TEXT, opened_on TEXT,
  is_walk_in INT);
CREATE TABLE customer_dim (customer_code TEXT, segment TEXT);
CREATE TABLE items (item_code TEXT, description TEXT, kind TEXT, family_name TEXT, brand_name TEXT,
  price_net REAL, last_purchase_price REAL, last_supplier TEXT, stock_qty REAL);
CREATE TABLE repairs (repair_id TEXT, opened_on TEXT, year INT, month TEXT, closed_at TEXT, status_code TEXT,
  status TEXT, customer_code TEXT, equipment_type_code TEXT, equipment_type TEXT, brand_code TEXT, brand_name TEXT,
  model TEXT, repair_technician_code TEXT);
CREATE TABLE assTec_tecnicos (codigo TEXT, descricao TEXT);
CREATE TABLE purchase_docs (doc_id TEXT, doc_date TEXT, year INT, month TEXT, supplier_code TEXT,
  supplier_name TEXT, is_cancelled INT, net REAL);
CREATE TABLE utilizadores (codigo TEXT, password TEXT);
CREATE TABLE contacts (code TEXT, iban TEXT);
CREATE VIEW sales_by_year_v AS SELECT year, SUM(net) AS net FROM sales_facts GROUP BY year;
"""

# (doc_id, date, customer, item, kind, family, qty, net, cost, cost_source, origin)
LINES = [
    ("FT 2024/1", "2024-03-05", "C1", "PC1", "product", "Desktops", 1, 1000.0, 700.0, "pmc", None),
    ("FT 2024/2", "2024-06-10", "C2", "SVC", "service", "Labour", 2, 100.0, 0.0, "not_applicable", "OSA"),
    ("FT 2025/1", "2025-02-01", "C1", "PC1", "product", "Desktops", 2, 2400.0, 1600.0, "pmc", None),
    ("FT 2025/2", "2025-03-15", "C3", "INK", "product", "Ink", 10, 200.0, 150.0, "estimated", "ORC"),
    ("FT 2025/3", "2025-12-20", "WALK", "INK", "product", "Ink", 1, 20.0, 15.0, "pmc", None),
    ("NC 2025/1", "2025-04-01", "C3", "INK", "product", "Ink", -1, -20.0, -15.0, "pmc", None),
    ("FT 2026/1", "2026-02-10", "C2", "SVC", "service", "Labour", 3, 150.0, 0.0, "not_applicable", "OSA"),
    ("FT 2026/2", "2026-03-01", "C1", "PC2", "product", "Desktops", 1, 900.0, 600.0, "pmc", None),
]


def _fact(line: tuple) -> tuple:
    doc, day, cust, item, kind, family, qty, net, cost, source, origin = line
    year, month = int(day[:4]), day[:7]
    quarter = f"{year}-Q{(int(day[5:7]) - 1) // 3 + 1}"
    doc_class = "credit_note" if doc.startswith("NC") else "invoice"
    return (doc, doc[:2], doc_class, day, year, quarter, month, cust, f"Customer {cust}", item, f"Item {item}", kind,
            "Hardware" if kind == "product" else "Services", family, "Acme" if item.startswith("PC") else None,
            qty, net, cost, net - cost, source, origin)  # fmt: skip


def fill(con: sqlite3.Connection) -> None:
    con.executescript(SCHEMA)
    con.executemany(f"INSERT INTO sales_facts VALUES ({','.join('?' * 21)})", [_fact(x) for x in LINES])
    docs = {(x[0], x[1], "credit_note" if x[0].startswith("NC") else "invoice") for x in LINES}
    con.executemany("INSERT INTO sales_docs VALUES (?,?,?,0,0,2,10,100)", sorted(docs))
    con.executemany("INSERT INTO customers VALUES (?,?,?,?,?,?,?)", [
        ("C1", "Alpha Lda", "500000001", "a@example.test", "000", "2020-01-01", 0),
        ("C2", "Beta Unip", "500000002", None, None, "2021-01-01", 0),
        ("C3", "Alpha Gamma", "500000003", None, None, "2022-01-01", 0),
        ("WALK", "Consumidor Final", None, None, None, "2017-01-01", 1),
    ])  # fmt: skip
    con.executemany("INSERT INTO customer_dim VALUES (?,?)", [("C1", "empresa"), ("C2", "particular")])
    con.executemany("INSERT INTO items VALUES (?,?,?,?,?,?,?,?,?)", [
        ("PC1", "Desktop One", "P", "Desktops", "Acme", 1200, 800, "S1", 2),
        ("PC2", "Desktop Two", "P", "Desktops", "Acme", 900, 600, "S1", 0),
        ("INK", "Ink cartridge", "P", "Ink", None, 20, 15, "S2", 30),
        ("SVC", "Labour", "E", "Labour", None, 50, 0, None, 0),
    ])  # fmt: skip
    con.executemany("INSERT INTO repairs VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
        ("OSA 2025/1", "2025-01-10", 2025, "2025-01", "2025-01-11", "FEC", "Fechada", "C2", "NB", "Notebook",
         "B1", "Acme", "X1", "T1"),
        ("OSA 2026/1", "2026-02-01", 2026, "2026-02", None, "ABR", "Aberta", "C2", "DT", "Desktop",
         "B1", "Acme", "X2", None),
    ])  # fmt: skip
    con.execute("INSERT INTO assTec_tecnicos VALUES ('T1', 'Tech One')")
    con.executemany("INSERT INTO purchase_docs VALUES (?,?,?,?,?,?,?,?)", [
        ("VFT 1", "2025-01-05", 2025, "2025-01", "S1", "Supplier One", 0, 1500.0),
        ("VFT 2", "2025-02-05", 2025, "2025-02", "S2", "Supplier Two", 0, 100.0),
        ("VFT 3", "2025-02-06", 2025, "2025-02", "S2", "Supplier Two", 1, 999.0),
    ])  # fmt: skip
    con.commit()


@pytest.fixture
def fake_db(tmp_path: Path) -> Iterator[Path]:
    path = tmp_path / "data.sqlite"
    con = sqlite3.connect(path)
    fill(con)
    con.close()
    db.set_db(path)
    dates._words_for_db.cache_clear()
    yield path
    db.set_db(None)
    dates._words_for_db.cache_clear()


LIVE_DB = Path(__file__).resolve().parents[2] / "data" / "data.sqlite"


@pytest.fixture
def live_db() -> Iterator[Path]:
    if not LIVE_DB.exists():
        pytest.skip("no data/data.sqlite")
    db.set_db(LIVE_DB)
    dates._words_for_db.cache_clear()
    yield LIVE_DB
    db.set_db(None)
    dates._words_for_db.cache_clear()
