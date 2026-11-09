-- name: sales_credit_cancel_reasons
-- description: Why money is given back or documents voided: credit-note reasons (raw cab_vendas.motivo_credito) and cancellation reasons (sales_docs.cancel_reason) grouped into categories (avaria, devolucao, engano no cliente/valor/artigo/tipo de documento, dados/NIF, desconto, sem motivo). Count, value and % per kind.
-- params: start=last_year_start, end=today
WITH r AS (
  SELECT 'credit_note' AS kind, d.doc_id, abs(d.net) AS net, lower(trim(COALESCE(v.motivo_credito, ''))) AS reason
  FROM sales_docs d
  JOIN cab_vendas v ON v.Codigo = d.doc_type AND v.serie = d.series AND CAST(v.numero AS INTEGER) = d.number
  WHERE d.doc_class = 'credit_note' AND d.is_cancelled = 0 AND d.is_internal = 0 AND d.doc_date BETWEEN :start AND :end
  UNION ALL
  SELECT 'cancelled', doc_id, abs(net), lower(trim(COALESCE(cancel_reason, '')))
  FROM sales_docs WHERE is_cancelled = 1 AND doc_date BETWEEN :start AND :end),
c AS (SELECT kind, net, reason,
        CASE WHEN reason = '' THEN '(sem motivo registado)'
             WHEN reason LIKE '%avari%' OR reason LIKE '%funciona%' OR reason LIKE '%defeit%' OR reason LIKE '%garantia%' THEN 'avaria / defeito'
             WHEN reason LIKE '%devol%' OR reason LIKE '%serviu%' OR reason LIKE '%quis%'
                  OR reason LIKE '%gostou%' OR reason LIKE '%desist%' OR reason LIKE '%buscar%' THEN 'devolucao / desistencia do cliente'
             WHEN reason LIKE '%tipo%doc%' THEN 'engano no tipo de documento'
             WHEN reason LIKE '%nif%' OR reason LIKE '%dados%' OR reason LIKE '%outro nome%' OR reason LIKE '%contribuinte%' THEN 'dados do cliente / NIF'
             WHEN reason LIKE '%cliente%' THEN 'engano no cliente'
             WHEN reason LIKE '%valor%' OR reason LIKE '%pre_o%' OR reason LIKE '%quantidade%' THEN 'engano no valor / quantidade'
             WHEN reason LIKE '%artigo%' OR reason LIKE '%faltou%' OR reason LIKE '%falta%' THEN 'engano / falta de artigos'
             WHEN reason LIKE '%desconto%' THEN 'desconto em falta'
             WHEN reason LIKE '%duplica%' OR reason LIKE '%tinha sido%' OR reason LIKE '%repetid%' THEN 'documento em duplicado'
             WHEN reason LIKE '%engan%' THEN 'engano (outro)'
             ELSE 'outro' END AS category FROM r)
SELECT kind, category, COUNT(*) AS documents, ROUND(SUM(net), 2) AS net_value,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM c c2 WHERE c2.kind = c.kind), 1) AS pct_of_kind
FROM c GROUP BY kind, category ORDER BY kind, documents DESC
