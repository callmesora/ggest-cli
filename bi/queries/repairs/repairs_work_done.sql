-- name: repairs_work_done
-- description: What the workshop actually did, from the technician's notes (assTec_intervencao_tecnica: avaria_encontrada = diagnosis, reparacao_efetuada = work done). Keyword flags (a repair can have several): reinstalacao_so (format / OS reinstall), limpeza_virus, recuperacao_backup_dados, troca_disco, troca_motherboard, troca_fonte, ecra_lcd, troca_teclado, bateria_carregador_ficha, memoria_ssd_upgrade, limpeza_interior_termica, impressora, rma_garantia (sent to supplier RMA / covered by warranty), sem_anomalia_detetada, nao_compensa_reparar (diagnosis says uneconomical). Counts and % of repairs per period. grain = year | total.
-- params: start=2007-01-01, end=2026-12-31, grain=year
WITH x AS (
  SELECT CASE WHEN :grain = 'total' THEN 'total' ELSE substr(c.data_doc, 1, 4) END AS period,
         lower(COALESCE(i.reparacao_efetuada, '')) AS w, lower(COALESCE(i.avaria_encontrada, '')) AS d,
         lower(c.tipo_equipamento) AS eq
  FROM Cab_Assistec c
  LEFT JOIN assTec_intervencao_tecnica i ON i.serie = c.serie AND i.numero = c.numero AND i.ano = c.ano
  WHERE c.data_doc <> '' AND c.data_doc BETWEEN replace(:start, '-', '') AND replace(:end, '-', '') || '99'),
f AS (
  SELECT period, w <> '' AS has_work_text, d <> '' AS has_diagnosis,
   (w LIKE '%reinstala%' OR w LIKE '%formata%' OR w LIKE '%instala__o do windows%' OR w LIKE '%instala__o do sistema%' OR w LIKE '%restauro do sistema%' OR w LIKE '%vers_o mais recente do windows%') AS reinstalacao_so,
   (w LIKE '%virus%' OR w LIKE '%v_rus%' OR w LIKE '%malicioso%' OR w LIKE '%spyware%' OR w LIKE '%malware%') AS limpeza_virus,
   (w LIKE '%recupera__o d%' OR w LIKE '%backup%' OR w LIKE '%clonagem%' OR w LIKE '%c_pia de seguran_a%' OR w LIKE '%salvaguarda%') AS recuperacao_backup_dados,
   ((w LIKE '%substitui%' OR w LIKE '%novo disco%' OR w LIKE '%coloca__o d%') AND (w LIKE '%disco%' OR w LIKE '%ssd%')) AS troca_disco,
   (w LIKE '%substitui%' AND (w LIKE '%motherboard%' OR w LIKE '%board%' OR w LIKE '%placa m_e%' OR w LIKE '%mb %')) AS troca_motherboard,
   (w LIKE '%substitui%' AND w LIKE '%fonte%') AS troca_fonte,
   ((w LIKE '%substitui%' OR w LIKE '%repara%') AND (w LIKE '%lcd%' OR w LIKE '%ecr_%' OR w LIKE '%ecran%' OR w LIKE '%display%' OR w LIKE '%touch%')) AS ecra_lcd,
   (w LIKE '%substitui%' AND w LIKE '%teclad%') AS troca_teclado,
   (w LIKE '%bateria%' OR w LIKE '%transformador%' OR w LIKE '%carregador%' OR w LIKE '%ficha ac%' OR w LIKE '%ficha dc%') AS bateria_carregador_ficha,
   (w LIKE '%mem_ria%' OR w LIKE '%ssd%' OR w LIKE '%upgrade%') AS memoria_ssd_upgrade,
   (w LIKE '%limpeza%' AND (w LIKE '%p_ %' OR w LIKE '%p_.%' OR w LIKE '%dissipador%' OR w LIKE '%ventoinha%' OR w LIKE '%interior%' OR w LIKE '%pasta t_rmica%')) AS limpeza_interior_termica,
   (eq = 'imp' OR w LIKE '%impressora%' OR w LIKE '%tinteir%' OR w LIKE '%toner%') AS impressora,
   (' ' || w || ' ' || d LIKE '% rma%' OR w || d LIKE '%(rma%' OR w || d LIKE '%acion%garantia%' OR w || d LIKE '%ao abrigo da garantia%' OR w || d LIKE '%coberto pela garantia%' OR w || d LIKE '%enviar para garantia%' OR w || d LIKE '%enviado para garantia%' OR w || d LIKE '%em garantia%') AS rma_garantia,
   (d LIKE '%normalmente%' OR d LIKE '%n_o foi detetad%' OR d LIKE '%n_o detetamos%' OR d LIKE '%n_o se detet%' OR d LIKE '%anomalia n_o detet%' OR d LIKE '%nao detect%' OR d LIKE '%sem anomalia%' OR d LIKE '%n_o se verificou%') AS sem_anomalia_detetada,
   (d LIKE '%economicamente%' OR d LIKE '%n_o compensa%' OR d LIKE '%nao compensa%' OR d LIKE '%n_o justifica%') AS nao_compensa_reparar
  FROM x)
SELECT period, COUNT(*) AS repairs, SUM(has_diagnosis) AS with_diagnosis, SUM(has_work_text) AS with_work_text,
  SUM(reinstalacao_so) AS reinstalacao_so, ROUND(100.0 * SUM(reinstalacao_so) / COUNT(*), 1) AS reinstalacao_so_pct,
  SUM(limpeza_virus) AS limpeza_virus, ROUND(100.0 * SUM(limpeza_virus) / COUNT(*), 1) AS limpeza_virus_pct,
  SUM(recuperacao_backup_dados) AS recuperacao_backup_dados,
  SUM(troca_disco) AS troca_disco, ROUND(100.0 * SUM(troca_disco) / COUNT(*), 1) AS troca_disco_pct,
  SUM(troca_motherboard) AS troca_motherboard, SUM(troca_fonte) AS troca_fonte, SUM(ecra_lcd) AS ecra_lcd,
  SUM(troca_teclado) AS troca_teclado, SUM(bateria_carregador_ficha) AS bateria_carregador_ficha,
  SUM(memoria_ssd_upgrade) AS memoria_ssd_upgrade, SUM(limpeza_interior_termica) AS limpeza_interior_termica,
  SUM(impressora) AS impressora, SUM(rma_garantia) AS rma_garantia, ROUND(100.0 * SUM(rma_garantia) / COUNT(*), 1) AS rma_garantia_pct,
  SUM(sem_anomalia_detetada) AS sem_anomalia_detetada, SUM(nao_compensa_reparar) AS nao_compensa_reparar,
  ROUND(100.0 * SUM(nao_compensa_reparar) / COUNT(*), 1) AS nao_compensa_reparar_pct
FROM f GROUP BY period ORDER BY period
