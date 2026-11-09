-- name: finance_payables_open
-- description: What the company owes now (contas a pagar): every open supplier document (cab_compras: VFT, FTINC, FTEXC; credit notes negative) and open 'outros credores' document (overheads: FTOC, NCOC), gross with VAT, with document date, due date, days to/after due date (negative = not yet due), the supplier's own document number and text, oldest due first. party_type = all | supplier | creditor. The total equals the sum of Fornecedores.saldo + Credores.saldo. Very old open documents are usually opening balances or invoices settled outside gGest: confirm before paying.
-- params: as_of=today, party_type=all, limit=100
SELECT party_type, party_code, party_name, doc_id, external_number, doc_date, due_date,
       CAST(julianday(:as_of) - julianday(due_date) AS INTEGER) AS days_overdue,
       ROUND(gross,2) AS gross, ROUND(settled,2) AS paid, ROUND(open_amount,2) AS open_amount,
       ROUND(SUM(open_amount) OVER (),2) AS total_open, description
FROM payable_docs
WHERE is_open = 1 AND (:party_type = 'all' OR party_type = :party_type)
ORDER BY due_date, open_amount DESC
LIMIT :limit
