-- name: sales_quotes_followup
-- description: Follow-up list of quotes / pro-formas / orders NOT converted (outcome open, partial or not_won in view quote_outcomes; open = still valid: valid_until >= today when set, else <= 60 days old) made between start and end, net >= min_net, biggest first. Columns: doc_id, doc_date, age_days, valid_until, valid_days_left, customer code/name, net quoted, lines (item lines, text lines excluded), top quoted items, invoiced_60d_net (what the customer bought in the 60 days after), outcome, variant_of (another quote of the same customer within 7 days, or with net within 3% within 90 days — a revision/variant of the same deal; the biggest/latest of a group is the main one), customer's net sales in the last 12 months, and totals over ALL matching quotes (not only the rows shown): list_count, open_count, open_net_total (raw) and open_net_dedup (variants excluded) — quote the dedup figure as the pipeline. Contacts: customer_profile tool for one customer. Big quotes to public bodies are often tenders that were lost, not forgotten.
-- params: start=last_year_start, end=today, min_net=200, doc_type=all, outcome=all, limit=50
WITH snap AS (SELECT max(doc_date) AS today FROM sales_facts),
allq AS MATERIALIZED (SELECT doc_id, doc_type, doc_date, customer_code, customer_name, net, line_count, valid_until,
                             valid_days_left, age_days, invoiced_60d_net, outcome
      FROM quote_outcomes WHERE doc_date BETWEEN date(:start, '-90 days') AND :end),
q0 AS MATERIALIZED (SELECT * FROM allq
      WHERE doc_date BETWEEN :start AND :end AND net >= :min_net AND outcome IN ('open','partial','not_won')
        AND (doc_type = :doc_type OR :doc_type = 'all') AND (outcome = :outcome OR :outcome = 'all')),
v AS MATERIALIZED (
  SELECT a.doc_id,
         (SELECT b.doc_id FROM allq b
           WHERE b.customer_code = a.customer_code AND b.doc_id <> a.doc_id AND b.net > 0
             AND (abs(julianday(b.doc_date) - julianday(a.doc_date)) <= 7
                  OR (abs(julianday(b.doc_date) - julianday(a.doc_date)) <= 90 AND abs(b.net - a.net) <= 0.03 * a.net))
             AND (b.net > a.net OR (b.net = a.net AND b.doc_date > a.doc_date)
                  OR (b.net = a.net AND b.doc_date = a.doc_date AND b.doc_id > a.doc_id))
           ORDER BY b.net DESC, b.doc_date DESC LIMIT 1) AS variant_of
  FROM q0 a),
tot AS (SELECT COUNT(*) AS list_count, SUM(q0.outcome = 'open') AS open_count,
               ROUND(SUM(CASE WHEN q0.outcome = 'open' THEN q0.net ELSE 0 END), 2) AS open_net_total,
               ROUND(SUM(CASE WHEN q0.outcome = 'open' AND v.variant_of IS NULL THEN q0.net ELSE 0 END), 2) AS open_net_dedup
        FROM q0 JOIN v ON v.doc_id = q0.doc_id),
q AS MATERIALIZED (SELECT q0.*, v.variant_of FROM q0 JOIN v ON v.doc_id = q0.doc_id ORDER BY q0.net DESC LIMIT :limit),
top AS MATERIALIZED (SELECT doc_id, d, ROW_NUMBER() OVER (PARTITION BY doc_id ORDER BY t DESC) AS rn FROM (
      SELECT l.Codigo || ' ' || l.serie || '/' || l.numero AS doc_id, substr(trim(l.descricao), 1, 40) AS d,
             CAST(l.Total AS REAL) AS t
      FROM lin_outros l WHERE CAST(l.Total AS REAL) > 0
        AND l.Codigo || ' ' || l.serie || '/' || l.numero IN (SELECT doc_id FROM q)))
SELECT q.doc_id, q.doc_date, q.age_days, q.valid_until, q.valid_days_left, q.customer_code, q.customer_name,
       ROUND(q.net, 2) AS net_quoted, q.line_count AS lines,
       (SELECT group_concat(t.d, ' | ') FROM top t WHERE t.doc_id = q.doc_id AND t.rn <= 3) AS top_items,
       ROUND(q.invoiced_60d_net, 2) AS invoiced_60d_net, q.outcome, q.variant_of,
       (SELECT ROUND(SUM(f.net), 2) FROM sales_facts f WHERE f.customer_code = q.customer_code
         AND f.doc_date > date((SELECT today FROM snap), '-12 months')) AS customer_sales_12m,
       tot.list_count, tot.open_count, tot.open_net_total, tot.open_net_dedup
FROM q CROSS JOIN tot
ORDER BY q.net DESC
