"""Repair (assistência) tools: volumes, breakdowns, turnaround, service revenue, fault categories."""

from typing import Literal

from .. import db, saved
from ..registry import DateArg, LimitArg, tool
from ._sql import clean, where
from .sales import PERIODS

_TECHNICIAN = (
    "COALESCE((SELECT t.descricao FROM assTec_tecnicos t WHERE t.codigo = repairs.repair_technician_code), "
    "repair_technician_code, '(não registado)')"
)
_BREAKDOWN = {
    "equipment": "COALESCE(equipment_type, equipment_type_code)",
    "brand": "COALESCE(brand_name, brand_code)",
    "technician": _TECHNICIAN,
    "status": "COALESCE(status, status_code)",
}


@tool("Repair orders (assistências) opened per year or month, with how many are not closed.")
def repairs_over_time(
    period: Literal["year", "month"] = "year", start: DateArg = None, end: DateArg = None
) -> list[dict]:
    """Repair orders opened per period, with how many are still open."""
    w, p = where(start, end, date_col="opened_on")
    return db.rows(
        f"""SELECT {period} AS period, COUNT(*) AS repairs,
                       SUM(status_code NOT IN ('FEC')) AS not_closed, COUNT(DISTINCT customer_code) AS customers
                       FROM repairs {w} GROUP BY 1 ORDER BY 1""",
        p,
    )


@tool("Repairs by equipment type, brand, technician or status.")
def repairs_breakdown(
    by: Literal["equipment", "brand", "technician", "status"] = "equipment",
    start: DateArg = None,
    end: DateArg = None,
    limit: LimitArg = 25,
) -> list[dict]:
    """Repairs grouped by one dimension, with each group's share."""
    w, p = where(start, end, date_col="opened_on")
    return db.rows(
        f"""SELECT {_BREAKDOWN[by]} AS category, COUNT(*) AS repairs,
                       100.0 * COUNT(*) / (SELECT COUNT(*) FROM repairs {w}) AS share_pct
                       FROM repairs {w} GROUP BY 1 ORDER BY 2 DESC LIMIT ?""",
        [*p, *p, int(limit)],
    )


@tool("Days to close repairs, per year.")
def repair_turnaround(start: DateArg = None, end: DateArg = None) -> list[dict]:
    """Days from opening to closing a repair (closed repairs with a real closing date), per year."""
    w, p = where(start, end, ["closed_at IS NOT NULL", "closed_at >= opened_on"], date_col="opened_on")
    return clean(
        db.rows(
            f"""
        SELECT year, COUNT(*) AS closed_repairs, AVG(julianday(closed_at) - julianday(opened_on)) AS avg_days,
               SUM(julianday(closed_at) - julianday(opened_on) <= 1) AS within_1_day,
               SUM(julianday(closed_at) - julianday(opened_on) <= 7) AS within_7_days
        FROM repairs {w} GROUP BY 1 ORDER BY 1""",
            p,
        )
    )


@tool("Service (labour) revenue vs repairs opened.")
def repair_revenue(
    period: Literal["year", "quarter", "month"] = "year", start: DateArg = None, end: DateArg = None
) -> list[dict]:
    """Service revenue (labour/assistance lines) on invoices, vs number of repairs opened."""
    w, p = where(start, end, ["line_kind = 'service'"])
    services = db.rows(
        f"""SELECT {PERIODS[period]} AS period, SUM(net) AS service_net,
                           SUM(CASE WHEN origin_doc_type = 'OSA' THEN net END) AS billed_from_repair_orders
                           FROM sales_facts {w} GROUP BY 1 ORDER BY 1""",
        p,
    )
    opened = repairs_over_time("year" if period == "year" else "month", start, end)
    by_period = {r["period"]: r["repairs"] for r in opened}
    for r in services:
        r["repairs_opened"] = by_period.get(r["period"])
    return clean(services)


@tool("What breaks most: reported faults grouped into categories (no raw text). grain=total|year.")
def common_faults(
    start: DateArg = None,
    end: DateArg = None,
    grain: Literal["total", "year"] = "total",
    equipment_group: Literal["all", "notebook", "desktop", "impressora", "tablet_telemovel", "outro"] = "all",
) -> list[dict]:
    """Fault categories by keyword rules. The raw fault text is never returned: customers often write
    passwords/PINs in it. Same as saved query repairs_fault_categories."""
    params = {"grain": grain, "equipment_group": equipment_group, "start": start, "end": end}
    return saved.run_saved_query("repairs_fault_categories", {k: v for k, v in params.items() if v})
