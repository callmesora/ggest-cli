---
name: customer-data-cleanup
description: Find customer records to fix in gGest — duplicate records, invalid or missing NIF, active customers without phone/e-mail, incomplete postal codes, inactive flags on buying customers — and measure contact completeness. Use for "limpeza da base de clientes", "fichas duplicadas", "NIF inválidos", "clientes sem contacto", "qualidade dos dados de clientes", "data cleanup", "duplicate customers", "RGPD / contact completeness".
---
# Customer data cleanup (qualidade da base de clientes)

Run from the project root. Results show codes and names only — **never export phones/e-mails in bulk**; the person
fixing the data opens each record in gGest.

1. **Overview of problems**: `uv run ggest run_saved_query --name customers_data_quality_summary --json`
2. **Contact completeness** by segment and status (active / lapsed / never):
   `uv run ggest run_saved_query --name customers_contact_completeness` (`"by":"segment"` or `"status"` for fewer rows).
3. **Records to fix**, one issue at a time (`issue` = invalid_nif | missing_nif_buyer | no_contact_active |
   partial_postal_code | same_nif_same_name | inactive_flag_but_buying):
   `uv run ggest run_saved_query --name customers_data_quality --params '{"issue":"same_nif_same_name","limit":50}'`
4. **Duplicates in depth**: same NIF `uv run ggest run_saved_query --name customers_duplicates --params '{"kind":"nif"}'`;
   same name (often without NIF) `--params '{"kind":"name"}'`.

## How to judge
- `same_nif_same_name` and `customers_duplicates` with `same_name = 1` → real duplicates: merge in gGest (keep the
  record with most history; `codes_with_sales ≥ 2` first, they split statistics).
- Same NIF, different names, NIF starting with 6 → departments of one public body: usually correct, do not merge.
- Same NIF and a new name → company renamed: update the name, keep history.
- `invalid_nif`: PT checksum fails (typo) — invoices with a wrong NIF are a tax problem; fix first those with sales.
- `missing_nif_buyer`: customers with high purchases and no NIF (ask for it on the next sale).
- `no_contact_active`: active in the last 2 years without phone or e-mail → ask at the counter.
- `partial_postal_code`: only "9900 Horta" → parish unknown for geography; ask for the full code.
- `inactive_flag_but_buying`: record marked inactive but still invoiced → review the flag.
- Records opened per year (`created_this_year`) show data-entry volume; many new records with no NIF/contact = training.

## Output (Portuguese)
Summary table (problema | nº fichas | prioridade), then the top 10–20 records of the 2–3 most important issues
(código, nome, segmento, vendas, último contacto). Close with a short procedure for the front desk
(pedir NIF/telemóvel/código postal completo ao abrir ficha; procurar por NIF antes de criar ficha nova).
