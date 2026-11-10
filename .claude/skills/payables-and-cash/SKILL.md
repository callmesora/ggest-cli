---
name: payables-and-cash
description: What the company owes suppliers and other creditors, what is due, payments made, and money in vs money out (till by payment method, monthly cash flow) from gGest. Use for "o que temos a pagar", "dívidas a fornecedores", "pagamentos feitos", "tesouraria", "fluxo de caixa", "fecho de caixa", "quanto entrou hoje", "payables", "what do we owe", "cash flow", "till closing".
---
# Payables and cash (pagamentos e tesouraria)

Amounts **gross, with VAT** (what leaves or enters the bank). Run from the project root.

## Steps
1. What we owe now: `uv run ggest run_saved_query --name finance_payables_open`
   (`--params '{"party_type":"supplier"}'` or `"creditor"`; one row per open document, oldest due first, total_open).
2. Payments made in a period, by payee:
   `uv run ggest run_saved_query --name finance_payments_made --params '{"start":"2026-10-01","end":"2026-10-31"}'`.
3. Money in vs money out by month: `uv run ggest run_saved_query --name finance_cash_flow_by_month`
   (receipts + counter sales vs supplier and overhead payments; net_flow and cumulative).
4. Till for a day or range: `uv run ggest run_saved_query --name finance_till_by_day` (default: last day in the data;
   `--params '{"start":"2026-11-01","end":"2026-11-07"}'`); cash_net = expected change in the cash drawer.
5. Payment-method mix over time: `uv run ggest run_saved_query --name finance_payment_methods --params '{"granularity":"month"}'`.
6. Entities we both sell to and buy from (offsets): `uv run ggest run_saved_query --name finance_customer_supplier_offsets`.

## Rules and traps
- Open = document total − amount settled; supplier credit notes are negative (money owed to us).
- **Very old open documents** (years) are usually opening balances or debts settled outside gGest: flag them,
  don't plan to pay them without confirming.
- Supplier and creditor payments do not go through the till, and the bank-movements module is not used, so
  gGest has no bank balance: this cash flow is document-based (receipts and payments issued), not a bank reconciliation.
- Till data starts the year the till module was adopted; the closing lines (`_CX99`) repeat totals and are excluded.
- Creditor (FTOC) numbers repeat across creditors: identify those documents by number **and** creditor.

## Output (Portuguese by default)
- **A pagar**: total, vencido, próximos 30 dias; table Fornecedor/Credor | Documento | Vencimento | Valor.
- **Pagamentos do período**: top payees and the total.
- **Tesouraria**: entradas vs saídas por mês (table) and one sentence on the trend; for a till day, a table by method.
