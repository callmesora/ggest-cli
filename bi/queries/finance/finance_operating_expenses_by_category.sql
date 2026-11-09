-- name: finance_operating_expenses_by_category
-- description: Overheads and other payments recorded as 'outros credores' invoices (expense_docs: FTOC/FROC positive, NCOC negative, VAT data-entry slips corrected) per year and category (staff, rent, vehicles, energy/telecom, accounting, marketing/franchise, insurance/health, bank fees, taxes, loans, investment, ...). Categories come from the expense_rules of the database's ggest.json config (creditor code, creditor name or document text; first matching rule wins; unmatched -> default_expense_category). Amounts net and gross of VAT; documents after the data date are excluded. Excludes goods bought from suppliers (see purchases). Same numbers as finance_profit_and_loss_by_year.
-- params: start_year=last_year, end_year=this_year, as_of=today
SELECT year, category, ROUND(SUM(net), 0) AS net, ROUND(SUM(gross), 0) AS gross, COUNT(*) AS docs,
       ROUND(100.0 * SUM(gross) / SUM(SUM(gross)) OVER (PARTITION BY year), 1) AS share_of_year_pct
FROM expense_docs
WHERE year BETWEEN :start_year AND :end_year AND doc_date <= :as_of
GROUP BY year, category ORDER BY year, category
