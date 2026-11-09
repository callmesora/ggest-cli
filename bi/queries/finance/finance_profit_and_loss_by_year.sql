-- name: finance_profit_and_loss_by_year
-- description: Indicative management P&L per year (from the year overheads start being recorded in gGest as 'outros credores' documents): net sales and estimated gross margin (sales_facts) minus operating overheads net of VAT (expense_docs, categories from the expense rules in ggest.json: staff, rents, other running costs) = indicative operating result (before depreciation, interest and income tax). period says what each row covers: 'full year' or 'partial: 01-01..MM-DD' (the current year stops at as_of = data date, so expense documents dated in the future, e.g. rent invoiced in advance, are left out; cutoff_mmdd cuts every year for like-for-like). break_even_sales = overheads / gross margin % for the period covered; for partial rows break_even_annualized scales it to 12 months (overheads x 365 / days covered) — compare it with a full-year sales forecast, not with year-to-date sales. Investments (vehicles, furniture, solar panels), loan instalments and taxes are shown separately and NOT deducted.
-- params: start_year=2021, end_year=this_year, cutoff_mmdd=12-31, as_of=today
WITH s AS MATERIALIZED (SELECT year, SUM(net) AS sales, SUM(margin) AS margin FROM sales_facts
           WHERE substr(doc_date,6,5) <= :cutoff_mmdd AND doc_date <= :as_of GROUP BY year),
o AS MATERIALIZED (SELECT year, SUM(CASE WHEN pnl_line='staff' THEN net ELSE 0 END) AS staff, SUM(CASE WHEN pnl_line='rent' THEN net ELSE 0 END) AS rent,
             SUM(CASE WHEN pnl_line='opex' THEN net ELSE 0 END) AS other_opex, SUM(CASE WHEN pnl_line='investment' THEN net ELSE 0 END) AS investment,
             SUM(CASE WHEN pnl_line='loans' THEN net ELSE 0 END) AS loans, SUM(CASE WHEN pnl_line='taxes' THEN net ELSE 0 END) AS taxes
      FROM expense_docs WHERE substr(doc_date,6,5) <= :cutoff_mmdd AND doc_date <= :as_of GROUP BY year),
r AS (SELECT s.*, o.staff, o.rent, o.other_opex, o.investment, o.loans, o.taxes,
             MIN(s.year || '-' || :cutoff_mmdd, :as_of) AS period_end,
             julianday(MIN(s.year || '-' || :cutoff_mmdd, :as_of)) - julianday(s.year || '-01-01') + 1 AS days_covered,
             julianday(s.year || '-12-31') - julianday(s.year || '-01-01') + 1 AS days_in_year
      FROM s JOIN o ON o.year = s.year)
SELECT year, CASE WHEN days_covered >= days_in_year THEN 'full year' ELSE 'partial: 01-01..' || substr(period_end,6,5) END AS period,
       ROUND(sales,0) AS net_sales, ROUND(margin,0) AS gross_margin, ROUND(100.0*margin/sales,1) AS gross_margin_pct,
       ROUND(staff,0) AS staff_costs, ROUND(rent,0) AS rents, ROUND(other_opex,0) AS other_overheads,
       ROUND(staff + rent + other_opex,0) AS total_overheads,
       ROUND(margin - (staff + rent + other_opex),0) AS operating_result_indicative,
       ROUND(100.0*(margin - (staff + rent + other_opex))/sales,1) AS operating_margin_pct,
       ROUND((staff + rent + other_opex) / (margin / sales),0) AS break_even_sales,
       CASE WHEN days_covered < days_in_year
            THEN ROUND((staff + rent + other_opex) * days_in_year / days_covered / (margin / sales),0) END AS break_even_annualized,
       ROUND(investment,0) AS investments_not_deducted, ROUND(loans,0) AS loan_instalments_not_deducted,
       ROUND(taxes,0) AS taxes_paid_not_deducted
FROM r
WHERE year BETWEEN :start_year AND :end_year ORDER BY year
