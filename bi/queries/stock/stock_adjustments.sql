-- name: stock_adjustments
-- description: Stock that entered or left WITHOUT a sale or purchase in a period, per document: miscellaneous exits/entries (SAID/ENTD/STKS), write-offs (SSTKA), internal use (CI and FRCIN), warranty use (CG), workshop use (CONOF/CSOF), technical loans, sponsorship. Columns: doc_date, doc_id, movement_kind, lines, units, value_at_cost (negative = stock out), items (first descriptions). gGest stock documents carry no reason text, so check large exits with the team (parts used in repairs or PC builds without an invoice, losses). `kind` filters one movement_kind (empty = all).
-- params: start=year_start, end=today, kind=, limit=100
SELECT doc_date, doc_id, movement_kind, COUNT(*) AS lines, ROUND(SUM(qty),0) AS units, ROUND(SUM(value_at_cost),2) AS value_at_cost,
       substr(group_concat(description, ' | '), 1, 120) AS items
FROM stock_movements
WHERE movement_kind IN ('adjustment_in','adjustment_out','write_off','internal_use','warranty_use','workshop_use','loan_out','sponsorship','other')
  AND doc_date BETWEEN :start AND :end
  AND (:kind = '' OR movement_kind = :kind)
GROUP BY doc_id, doc_date, movement_kind
ORDER BY ABS(SUM(value_at_cost)) DESC
LIMIT :limit
