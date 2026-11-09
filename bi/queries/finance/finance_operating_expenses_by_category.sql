-- name: finance_operating_expenses_by_category
-- description: Overheads and other payments recorded as 'outros credores' invoices (Cab_DirCC_Cre, FTOC/FROC positive, NCOC negative; available from 2021) per year and category: staff (salaries + social security), rents, vehicles, energy/telecom, accounting, CHIP7 franchise & marketing, insurance/health, bank & payment fees, taxes (IRC/IRS/IUC), loan instalments and investments (vehicles, shop furniture, solar panels). Categories are assigned from the creditor (credores) and the document text; amounts net and gross of VAT. Excludes goods bought from suppliers (see purchases).
-- params: start_year=2021, end_year=2026
WITH e AS (
  SELECT CAST(substr(d.data_doc,1,4) AS INTEGER) AS year, d.entidade_codigo AS code,
         lower(trim(d.entidade_descricao)) AS name, lower(COALESCE(d.descritivo,'')) AS txt,
         CASE WHEN d.Codigo = 'NCOC' THEN -1 ELSE 1 END AS sign,
         CAST(d.total_documento AS REAL) AS gross, CAST(d.Total_iva AS REAL) AS vat
  FROM Cab_DirCC_Cre d
  WHERE d.Codigo IN ('FTOC','FROC','NCOC') AND d.estado_doc <> '1' AND d.data_doc <> ''),
c AS (
  SELECT year, sign*gross AS gross, sign*(gross - vat) AS net,
    CASE WHEN code IN ('43','1') OR name LIKE '%penhora%' THEN '01 Pessoal (salarios e Seguranca Social)'
         WHEN code IN ('139','191') OR txt LIKE 'renda%' THEN '02 Rendas (loja e armazem)'
         WHEN code IN ('190','377','276') OR (code = '137' AND (txt LIKE '%painei%' OR txt LIKE '%fotovolt%' OR txt LIKE '%bateria%'))
              THEN '11 Investimento (viaturas, mobiliario, paineis solares)'
         WHEN code = '380' OR (code = '15' AND txt LIKE '%empr%stimo%') THEN '12 Prestacoes de emprestimos'
         WHEN code = '38' THEN '10 Impostos (IRC, IRS, IUC)'
         WHEN code IN ('16','160','153','289') OR name LIKE '%galp%' OR name LIKE '%pneu%' OR name LIKE '%renault%'
              OR name LIKE '%terauto%' OR name LIKE '%l2auto%' OR name LIKE '%carjet%' OR name LIKE 'prio %' THEN '03 Viaturas (combustivel, manutencao)'
         WHEN code IN ('3','151') OR name LIKE '%meo%' OR name LIKE '%altice%' THEN '04 Energia e telecomunicacoes'
         WHEN code = '332' OR name LIKE '%contabilidade%' THEN '05 Contabilidade'
         WHEN code IN ('292','374') OR name LIKE '%meta facebook%' OR name LIKE '%canva%' OR name LIKE '%publicit%'
              THEN '06 Franchising CHIP7 e marketing'
         WHEN code IN ('298','37','246') OR name LIKE '%seguro%' OR name LIKE '%clini%' OR name LIKE '%medicina%' OR name LIKE '%precur%'
              THEN '07 Seguros, saude e SHST'
         WHEN code = '15' OR name LIKE '%ifthenpay%' OR name LIKE '%easypay%' OR name LIKE '%mypos%' THEN '08 Banca e meios de pagamento'
         WHEN code = '13' OR name LIKE '%ctt%' THEN '09 Correios'
         ELSE '13 Outros (consumiveis, refeicoes, deslocacoes, obras, diversos)' END AS category
  FROM e)
SELECT year, category, ROUND(SUM(net),0) AS net, ROUND(SUM(gross),0) AS gross, COUNT(*) AS docs,
       ROUND(100.0 * SUM(gross) / SUM(SUM(gross)) OVER (PARTITION BY year),1) AS share_of_year_pct
FROM c WHERE year BETWEEN :start_year AND :end_year
GROUP BY year, category ORDER BY year, category
