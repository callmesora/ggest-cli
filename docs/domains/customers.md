# Customers & CRM (gGest)

Views in `bi/sql/ext/customers.sql` (apply: `uv run ggest build-views --file bi/sql/ext/customers.sql`), saved queries in
`bi/queries/customers/`, skills `customer-briefing`, `winback-campaign`, `customer-segments`, `customer-data-cleanup`.

## Views

| view | grain | what for |
|---|---|---|
| `customer_dim` | one row per `Clientes` record | derived **segment**, legal-entity key, NIF check, contact-completeness flags, CRM attributes. Single source of the segment rules used by every `customers_*` query |
| `customer_activity` | one row per customer record | every interaction: purchases (lifetime / last 365 days), credit notes, quotes, repairs, open repairs, agenda appointments, `last_contact`, `days_since_contact`, `relationship` (buys_only / repairs_only / buys_and_repairs / quotes_only / no_activity). `as_of` = last sales/repair date |
| `customer_appointments` | one row per agenda entry | `Agenda` + status + task type, linked customer when `entidade_tipo = 'cliente'` |

### `customer_dim` columns
customer_code, name, nif, `nif_clean` (spaces, `PT`, dots removed), `nif_status` (valid = PT checksum OK / invalid /
missing / final_consumer `999999990` / foreign = letter prefix), `entity_key` (`NIF <nif>` for 9-digit NIFs except
999999990, else `COD <code>`: group by it to merge duplicate records and departments sharing a NIF), `segment`,
customer_group + group_name (`Grupos_Entidades`), is_walk_in, is_inactive, name_norm, fiscal_space (`espaco_fiscal`:
PTA Azores, PTC mainland, PTM Madeira), country_prefix, presence flags has_email / has_mobile (9[1-6]xxxxxxx) /
has_phone (any 2xxxxxxxx or 9xxxxxxxx in the phone fields) / has_contact_person / has_full_postal_code (NNNN-NNN) /
has_street_address, is_public_administration, sends_e_invoices, vat_exemption_code, payment_terms_code,
balance_gross (`Clientes.saldo`, VAT incl.), has_alert_note, has_notes, active_contracts / contracts
(`Avencas_Clientes`), extra_addresses (`Moradas_Clientes`), opened_on, created_on, `record_opened_on`, created_by_user,
modified_on. **No contact values** are exposed by the view.

### Segment rules (in order)
1. `consumidor_final`: walk-in records (`customers.is_walk_in`).
2. `publico`: NIF 6xxxxxxxx or gGest group 1 "Entidades Governamentais".
3. `empresa`: Lda / Limitada / Unipessoal / S.A. / SGPS in the name.
4. `associativo`: associações, clubes, filarmónicas, misericórdias, paróquias, casas do povo, fundações, bombeiros,
   IPSS, lares, creches, cooperativas…
5. `publico`: public-body names (câmara, município, junta de freguesia, escola, secretaria/direção regional, governo
   regional, universidade, hospital, centro de saúde, tribunal, GNR/PSP, instituto…).
6. `empresa`: group 2 "Empresas", NIF 5/8/9 (not 999999990), 71–79 except 74/75, foreign VAT id, or business words
   (hotel, restaurante, snack, sociedade, &, CRL).
7. `particular`: everything else (NIF 1–3, no NIF, 999999990).
The gGest group exists only since late 2022, and most old records sit in group 3 by default — that is why the name and
NIF rules come first. Sole traders with NIF 1–2 count as `particular` unless group 2 or a business word.

## Raw tables
| table | meaning | notes |
|---|---|---|
| `Clientes` | customer master | `Codigo` = customer_code. Contacts are free text: `telefone1..4`, `telemovel1..4`, `mail1..4`, `contacto1..4` often mix a name and a number. `obs` + `obs_alerta = 1` = note popped up when the record is used (can hold equipment lists, payment remarks, personal data). `saldo` = open balance. `grupo` → `Grupos_Entidades`. `data_abertura` filled until early 2020, `inserido_data` reliable after the 2020-03 migration (earlier rows carry the migration timestamp). `caracter_livre*`, `numerico_livre*`, `data_livre*` = free fields (titles in `Campos_Livres`, mostly unused). `latitude/longitude`, `zona`, `rota`, `RGPD_Estado`, `sexo`, `data_nascimento` empty in this DB |
| `Grupos_Entidades` | customer groups | 1 Entidades Governamentais, 2 Empresas, 3 Consumidor Final |
| `Moradas_Clientes` | extra delivery addresses per customer (`Cliente`, `Codigo_Morada`) | few rows |
| `moradas_documentos` | load/unload address per document (`codigo`, `serie`, `numero`, `entidade`) | load = shop address; unload = delivery place. Covers sales, quotes, purchases (`VFT`); not modelled |
| `Agenda`, `Agenda_Estados` (1 Agendada, 2 Concluida), `Agenda_Tipo_Tarefas` | calendar | `entidade_tipo = 'cliente'` + `entidade_codigo` link to a customer; `eventID` = synced to an external calendar. Mixed with staff's private entries and tests |
| `Avencas_Clientes` + `Avencas` | recurring contracts (domain, hosting, maintenance) | value per billing = `Quantidade × Valor`; `Avencas.Periodo` ANUAL / SEMESTRAL / MENSAL; `Seguinte` next billing; `Inativo`. Contract billing belongs to finance; here only as customer attribute |
| `cab_outros` (`Codigo = 'ORC'`) | quotes | used for `last_quote`; `fechado` is always 0 (not a conversion flag) |
| `analises_clientes` | gGest ABC classification (A/B/C) snapshot | one run (2020) — stale, not modelled |
| `RGPD_Campos`, `RGPD_Campos_Acessos` | which `Clientes` fields are personal data / visible per profile | config only; consent tables (`RGPD_Consentimentos` …) empty |
| `SMS`, `SMS_contas`, `mensagens_internas` | SMS sent and internal user messages | tests and "assistência fechada" notifications only; `SMS_contas.token` is a credential — never select it |
| `Zonas_Servicos*`, `paises`, `prefixos_paises`, `Campos_Livres` | POS service zones, countries, phone prefixes, free-field titles | lookups / config |

## Joins
- `customer_dim.customer_code` = `customers.customer_code` = `sales_facts.customer_code` = `repairs.customer_code`
  = `cab_vendas.entidade_codigo` = `cab_outros.entidade_codigo` = `Avencas_Clientes.Cliente` = `Agenda.entidade_codigo`
  (when `entidade_tipo = 'cliente'`).
- Entity level: `GROUP BY customer_dim.entity_key`.
- Open balance per customer: unpaid sales documents `cab_vendas` (`total_documento − Total_liquidado`, credit notes
  negative, `estado_doc <> '1'`) — same rule as `finance_receivables_open`.

## Traps
- Names are as typed: `LIKE` is accent-sensitive for non-ASCII letters (search "munic" rather than "município").
- The same NIF on many records is often legitimate (departments of a regional government body). Public bodies
  change name and NIF with each government: check `customers_duplicates --kind name` before calling one lost.
- `nif_status = 'missing'` is normal for walk-in individuals; it matters on large invoices (`missing_nif_buyer`).
- Contact flags only say a value exists, not that it is current. Never export contact values in bulk (GDPR).
- `Clientes.obs` and agenda titles are free text that may hold personal data: show only for one customer, on request.
- 2017 looks like "all new customers" because sales history starts in 2017.
- Repair counts differ by scope: per record vs per NIF entity (`entity_key`), all time vs the query period. Column
  names say which (`repairs_all_time_record`, `repairs_in_period_entity`, `repairs_all_time_entity`).
- `Clientes.obs` (alert note) is returned by `customers_briefing` only with `show_alert_note=1`.
