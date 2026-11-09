-- name: repairs_fault_categories
-- description: Reported faults (avaria descrita by the customer at reception) grouped into categories by keyword rules on the free text (first matching rule wins, in this order): dano_fisico_liquido, recuperacao_dados, impressora, nao_liga, nao_arranca_bloqueia (no boot, blue/black screen, restarts, beeps, freezes), ecra_imagem, bateria_carregador_energia, teclado_rato, sobreaquecimento_desliga, lento_virus, internet_email, som_portas_perifericos, software_windows_instalacao, manutencao_upgrade, outro. Heuristic (accents are lost in the data, '_' wildcards cover them); ~7% fall in 'outro'. grain = year | total; equipment_group = all | notebook | desktop | impressora | tablet_telemovel | outro.
-- params: start=2007-01-01, end=2026-12-31, grain=total, equipment_group=all
WITH r AS (
  SELECT CASE WHEN :grain = 'total' THEN 'total' ELSE CAST(year AS TEXT) END AS period,
         lower(COALESCE(reported_fault, '')) AS t, equipment_type_code AS eq,
         CASE WHEN equipment_type_code = 'not' THEN 'notebook'
              WHEN equipment_type_code IN ('des','all','min') THEN 'desktop'
              WHEN equipment_type_code IN ('imp','sca') THEN 'impressora'
              WHEN equipment_type_code IN ('tab','ipa','pda','tel') THEN 'tablet_telemovel'
              ELSE 'outro' END AS equipment_group
  FROM repairs WHERE opened_on BETWEEN :start AND :end),
c AS (
  SELECT period, equipment_group,
  CASE
   WHEN t LIKE '%l_quido%' OR t LIKE '%entornou%' OR t LIKE '%molhou%' OR t LIKE '%molhad%' OR t LIKE '% _gua %' OR t LIKE '%entrou _gua%' OR t LIKE '%caiu _gua%' OR t LIKE '%caiu%' OR t LIKE '%queda%' OR t LIKE '%partid%' OR t LIKE '%partiu%' OR t LIKE '%rachad%' OR t LIKE '%dobradi%' THEN 'dano_fisico_liquido'
   WHEN t LIKE '%recuperar%' OR t LIKE '%recupera__o de dados%' OR t LIKE '%recupera__o dos dados%' OR t LIKE '%apagou%' OR t LIKE '%perdeu%fotos%' THEN 'recuperacao_dados'
   WHEN eq = 'imp' OR t LIKE '%imprim%' OR t LIKE '%impressora%' OR t LIKE '%tinteir%' OR t LIKE '%toner%' OR t LIKE '%papel%' OR t LIKE '%digitaliz%' THEN 'impressora'
   WHEN t LIKE '%n_o liga%' OR t LIKE '%nao liga%' OR t LIKE '%n liga%' OR t LIKE '%nliga%' OR t LIKE '%morto%' OR t LIKE '%n_o acende%' OR t LIKE '%nao acende%' OR t LIKE '%n_o d_ sinal%' OR t LIKE '%sem sinal de vida%' THEN 'nao_liga'
   WHEN t LIKE '%arranca%' OR t LIKE '%ecr_ azul%' OR t LIKE '%ecran azul%' OR t LIKE '%reinici%' OR t LIKE '%n_o entra%' OR t LIKE '%nao entra%' OR t LIKE '%apita%' OR t LIKE '%bios%' OR t LIKE '%ecr_ preto%' OR t LIKE '%ecran preto%' OR t LIKE '%bloque%' OR t LIKE '%encrav%' THEN 'nao_arranca_bloqueia'
   WHEN t LIKE '%ecr_%' OR t LIKE '%ecran%' OR t LIKE '%lcd%' OR t LIKE '%display%' OR t LIKE '%imagem%' OR t LIKE '%riscas%' OR t LIKE '%monitor%' OR t LIKE '%touch%' THEN 'ecra_imagem'
   WHEN t LIKE '%bateria%' OR t LIKE '%carreg%' OR t LIKE '%transformador%' OR t LIKE '%ficha%' OR t LIKE '%fonte%' THEN 'bateria_carregador_energia'
   WHEN t LIKE '%teclad%' OR t LIKE '%tecla%' OR t LIKE '%touchpad%' OR t LIKE '% rato%' THEN 'teclado_rato'
   WHEN t LIKE '%aquece%' OR t LIKE '%desliga%' OR t LIKE '%barulh%' OR t LIKE '%ventoinha%' OR t LIKE '%ru_do%' THEN 'sobreaquecimento_desliga'
   WHEN t LIKE '%lent%' OR t LIKE '%virus%' OR t LIKE '%v_rus%' OR t LIKE '%malware%' OR t LIKE '%publicidade%' OR t LIKE '%pop%up%' OR t LIKE '%janelas%' THEN 'lento_virus'
   WHEN t LIKE '% net%' OR t LIKE '%internet%' OR t LIKE '%wireless%' OR t LIKE '%wifi%' OR t LIKE '%wi-fi%' OR t LIKE '%rede%' OR t LIKE '%router%' OR t LIKE '%e-mail%' OR t LIKE '%email%' OR t LIKE '%outlook%' THEN 'internet_email'
   WHEN t LIKE '%som%' OR t LIKE '%usb%' OR t LIKE '%coluna%' OR t LIKE '%microfone%' OR t LIKE '%webcam%' OR t LIKE '%c_mara%' OR t LIKE '%dvd%' OR t LIKE '%leitor%' OR t LIKE '%portas%' OR t LIKE '%porta usb%' THEN 'som_portas_perifericos'
   WHEN t LIKE '%formata%' OR t LIKE '%windows%' OR t LIKE '%instala%' OR t LIKE '%office%' OR t LIKE '%antivirus%' OR t LIKE '%licen_a%' OR t LIKE '%atualiza%' OR t LIKE '%actualiza%' OR t LIKE '%programa%' OR t LIKE '%configur%' OR t LIKE '%erro%' THEN 'software_windows_instalacao'
   WHEN t LIKE '%limpeza%' OR t LIKE '%revis%' OR t LIKE '%ssd%' OR t LIKE '%mem_ria%' OR t LIKE '%upgrade%' OR t LIKE '%montar%' OR t LIKE '%disco%' THEN 'manutencao_upgrade'
   ELSE 'outro' END AS fault_category
  FROM r WHERE :equipment_group = 'all' OR equipment_group = :equipment_group),
g AS (SELECT period, fault_category, COUNT(*) AS repairs,
             SUM(equipment_group = 'notebook') AS notebook, SUM(equipment_group = 'desktop') AS desktop,
             SUM(equipment_group = 'impressora') AS impressora, SUM(equipment_group = 'tablet_telemovel') AS tablet_telemovel,
             SUM(equipment_group = 'outro') AS outro_equip
      FROM c GROUP BY period, fault_category)
SELECT period, fault_category, repairs,
       ROUND(100.0 * repairs / SUM(repairs) OVER (PARTITION BY period), 1) AS pct_of_period,
       notebook, desktop, impressora, tablet_telemovel, outro_equip
FROM g ORDER BY period, repairs DESC
