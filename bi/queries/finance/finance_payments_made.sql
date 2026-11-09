-- name: finance_payments_made
-- description: Payments made in a period (pagamentos): supplier payments (P) and 'outros credores' payments (POC: salaries, rents, taxes, utilities...) per payee, with number of payments, total paid (gross), first/last payment, and the documents they settled; party_type = all | supplier | creditor. For the monthly cash view use finance_cash_flow_by_month; for overheads by category use finance_operating_expenses_by_category.
-- params: start=year_start, end=today, party_type=all, limit=50
SELECT party_type, party_code, MAX(party_name) AS party_name, COUNT(*) AS payments, ROUND(SUM(amount),2) AS paid,
       MIN(doc_date) AS first_payment, MAX(doc_date) AS last_payment,
       ROUND(100.0 * SUM(amount) / SUM(SUM(amount)) OVER (),1) AS share_pct
FROM payment_docs
WHERE direction = 'out' AND doc_date BETWEEN :start AND :end AND (:party_type = 'all' OR party_type = :party_type)
GROUP BY party_type, party_code
ORDER BY paid DESC
LIMIT :limit
