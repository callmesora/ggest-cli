-- name: repairs_replacement_leads
-- description: Sales leads from the workshop: recent repairs (opened since start) of notebooks/desktops/all-in-ones/tablets where the customer probably needs a new machine - diagnosis says repair is uneconomical ('nao compensa', 'economicamente'), or a major board/CPU failure ('em circuito', 'anomalia na motherboard/board/chip/cpu', 'anomalia grave'), or the same device (serial) has had >= min_device_repairs repairs - and the customer has NOT bought new equipment (COMPUTADORES/TABLET, unit net >= 150) since the repair opened. One row per repair; walk-in customers excluded. Diagnosis text is not returned (may contain passwords).
-- params: start=today_last_year, end=today, min_device_repairs=4, limit=100
WITH dev AS (
  SELECT lower(replace(trim(Numero_Serie), ' ', '')) AS s, COUNT(*) AS n
  FROM Cab_Assistec WHERE length(trim(Numero_Serie)) >= 6 GROUP BY 1),
r AS (
  SELECT 'OSA ' || c.serie || '/' || c.numero AS repair_id,
         date(substr(c.data_doc,1,4)||'-'||substr(c.data_doc,5,2)||'-'||substr(c.data_doc,7,2)) AS opened_on,
         c.entidade_codigo AS customer_code, trim(c.entidade_descricao) AS customer_name,
         lower(c.tipo_equipamento) AS eq, m.Descricao AS brand, NULLIF(c.Modelo, '') AS model,
         lower(COALESCE(i.avaria_encontrada, '')) AS d, COALESCE(dev.n, 1) AS device_repairs
  FROM Cab_Assistec c
  LEFT JOIN assTec_intervencao_tecnica i ON i.codigo = c.Codigo AND i.serie = c.serie AND i.numero = c.numero AND i.ano = c.ano
  LEFT JOIN Marcas m ON m.Codigo = c.Marca
  LEFT JOIN dev ON dev.s = lower(replace(trim(c.Numero_Serie), ' ', '')) AND length(trim(c.Numero_Serie)) >= 6
  JOIN customers cu ON cu.customer_code = c.entidade_codigo AND cu.is_walk_in = 0
  WHERE c.data_doc BETWEEN replace(:start, '-', '') AND replace(:end, '-', '') || '99'
    AND lower(c.tipo_equipamento) IN ('not','des','all','min','tab','ipa')),
x AS (
  SELECT r.*,
    CASE WHEN d LIKE '%economicamente%' OR d LIKE '%n_o compensa%' OR d LIKE '%nao compensa%' OR d LIKE '%n_o justifica%' THEN 'reparacao_nao_compensa'
         WHEN d LIKE '%em circuito%' OR d LIKE '%anomalia na motherboard%' OR d LIKE '%anomalia na board%' OR d LIKE '%anomalia no chip%'
              OR d LIKE '%anomalia grave%' OR d LIKE '%anomalia no cpu%' OR d LIKE '%anomalia no processador%' OR d LIKE '%motherboard avariada%' THEN 'avaria_grave_board_cpu'
         WHEN device_repairs >= :min_device_repairs THEN 'equipamento_com_muitas_reparacoes'
    END AS lead_reason
  FROM r)
SELECT x.repair_id, x.opened_on, x.customer_code, x.customer_name,
       CASE x.eq WHEN 'not' THEN 'notebook' WHEN 'tab' THEN 'tablet' WHEN 'ipa' THEN 'tablet' ELSE 'desktop' END AS equipment,
       x.brand, x.model, x.lead_reason, x.device_repairs,
       (SELECT MAX(f.doc_date) FROM sales_facts f WHERE f.customer_code = x.customer_code) AS last_purchase_any,
       (SELECT ROUND(SUM(f.net), 2) FROM sales_facts f WHERE f.customer_code = x.customer_code AND f.doc_date >= date(x.opened_on, '-3 years')) AS net_bought_last_3y
FROM x
WHERE x.lead_reason IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM sales_facts f WHERE f.customer_code = x.customer_code AND f.doc_date >= x.opened_on
                  AND f.line_kind = 'product' AND f.qty > 0 AND f.unit_price_net >= 150
                  AND (f.group_name = 'COMPUTADORES' OR f.family_name = 'TABLET'))
ORDER BY CASE x.lead_reason WHEN 'reparacao_nao_compensa' THEN 1 WHEN 'avaria_grave_board_cpu' THEN 2 ELSE 3 END, x.opened_on DESC
LIMIT :limit
