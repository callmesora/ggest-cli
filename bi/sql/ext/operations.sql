-- Operations views (domain: operations): who does what in gGest, aggregated by tools/queries.
-- Docs: docs/domains/operations.md. Use for workload and process questions, not for monitoring individuals.

-- User activity log (log_atividades), without the free-text description (it holds customer names) ---------
-- area = first [bracket] of the description: the gGest screen/module (Artigos, Vendas, Clientes, OSA...).
DROP VIEW IF EXISTS activity_log;
CREATE VIEW activity_log AS
SELECT datetime(substr(l.data_hora,1,4)||'-'||substr(l.data_hora,5,2)||'-'||substr(l.data_hora,7,2)||' '||
                substr(l.data_hora,9,2)||':'||substr(l.data_hora,11,2)||':'||substr(l.data_hora,13,2)) AS event_at,
       date(substr(l.data_hora,1,4)||'-'||substr(l.data_hora,5,2)||'-'||substr(l.data_hora,7,2)) AS event_date,
       CAST(substr(l.data_hora,1,4) AS INTEGER) AS year, substr(l.data_hora,1,4)||'-'||substr(l.data_hora,5,2) AS month,
       CAST(strftime('%w', substr(l.data_hora,1,4)||'-'||substr(l.data_hora,5,2)||'-'||substr(l.data_hora,7,2)) AS INTEGER) AS weekday,
       CAST(substr(l.data_hora,9,2) AS INTEGER) AS hour,
       l.utilizador AS user_code, trim(u.descricao) AS user_name, l.posto AS workstation, l.programa AS program,
       COALESCE(NULLIF(l.operacao,''), '(none)') AS operation,
       CASE WHEN substr(l.descricao,1,1) = '[' THEN substr(l.descricao, 2, instr(l.descricao,']') - 2) ELSE '(none)' END AS area
FROM log_atividades l
LEFT JOIN utilizadores u ON u.Codigo = l.utilizador
WHERE l.data_hora > '20000101';

-- Documents created per user across gGest modules --------------------------------------------------------
-- created_at = record insertion time (inserido_data). The current gGest installation started 2020-03-24:
-- older documents were imported then by one user (is_migrated = 1): exclude them from per-user analysis.
DROP VIEW IF EXISTS documents_created;
CREATE VIEW documents_created AS
WITH src AS (
  SELECT 'sales' AS module, Codigo, serie, numero, data_doc, inserido_util, inserido_data, estado_doc FROM cab_vendas
  UNION ALL SELECT 'purchases', Codigo, serie, numero, data_doc, inserido_util, inserido_data, estado_doc FROM cab_compras
  UNION ALL SELECT 'repairs', Codigo, serie, numero, data_doc, inserido_util, inserido_data, '0' FROM Cab_Assistec
  UNION ALL SELECT CASE WHEN Codigo = 'ORC' THEN 'quotes' ELSE 'other_sales_docs' END, Codigo, serie, numero, data_doc, inserido_util, inserido_data, estado_doc FROM cab_outros
  UNION ALL SELECT 'receipts_payments', Codigo, serie, numero, data_doc, inserido_util, inserido_data, estado_doc FROM cab_recpag
  UNION ALL SELECT 'delivery_notes', Codigo, serie, numero, data_doc, inserido_util, inserido_data, estado_doc FROM cab_guias
  UNION ALL SELECT 'stock', Codigo, serie, numero, data, inserido_util, inserido_data, '0' FROM Cab_Stocks WHERE substr(Codigo,1,1) NOT IN ('_','')
  UNION ALL SELECT 'assembly', Codigo, serie, numero, data, inserido_util, inserido_data, '0' FROM cab_producao WHERE Codigo = 'PRCE'
  UNION ALL SELECT 'expenses', Codigo, serie, numero, data_doc, inserido_util, inserido_data, estado_doc FROM Cab_DirCC_Cre)
SELECT s.module, s.Codigo AS doc_type, s.Codigo || ' ' || s.serie || '/' || s.numero AS doc_id,
       date(substr(s.data_doc,1,4)||'-'||substr(s.data_doc,5,2)||'-'||substr(s.data_doc,7,2)) AS doc_date,
       datetime(substr(s.inserido_data,1,4)||'-'||substr(s.inserido_data,5,2)||'-'||substr(s.inserido_data,7,2)||' '||
                substr(s.inserido_data,9,2)||':'||substr(s.inserido_data,11,2)) AS created_at,
       CAST(substr(s.inserido_data,1,4) AS INTEGER) AS year, substr(s.inserido_data,1,4)||'-'||substr(s.inserido_data,5,2) AS month,
       CAST(strftime('%w', substr(s.inserido_data,1,4)||'-'||substr(s.inserido_data,5,2)||'-'||substr(s.inserido_data,7,2)) AS INTEGER) AS weekday,
       CAST(substr(s.inserido_data,9,2) AS INTEGER) AS hour,
       s.inserido_util AS user_code, trim(u.descricao) AS user_name,
       CASE WHEN s.estado_doc = '1' THEN 1 ELSE 0 END AS is_cancelled,
       CASE WHEN s.inserido_data < '20200325' THEN 1 ELSE 0 END AS is_migrated
FROM src s
LEFT JOIN utilizadores u ON u.Codigo = s.inserido_util
WHERE s.inserido_data > '20000101' AND s.data_doc > '19000101';
