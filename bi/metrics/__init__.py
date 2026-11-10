"""Business metrics for a gGest company (sales, customers, repairs, purchasing) plus exploration tools.

Every function returns plain data (list of dicts / dict) and registers itself as a tool, so the same functions
power the CLI (`ggest ...`), the MCP server and the dashboards.

Conventions (see docs/DATA_DICTIONARY.md):
  * money is NET of VAT, in EUR; credit notes are negative; cancelled docs and internal consumption excluded
  * margin = net - qty * unit_cost (gross margin estimate; unit_cost from average cost at sale time)
  * dates are ISO 'YYYY-MM-DD' or date words; `start` and `end` inclusive; omit for all time
"""

from ..registry import TOOLS
from .customers import customer_concentration, customer_profile, dormant_customers, top_customers
from .explore import data_dictionary, describe, query, run_saved_query, saved_queries
from .purchases import purchases_by_supplier, purchases_vs_sales
from .repairs import common_faults, repair_revenue, repair_turnaround, repairs_breakdown, repairs_over_time
from .sales import (
    PERIODS,
    kpis,
    product_profile,
    sales_by_category,
    sales_by_weekday_hour,
    sales_over_time,
    top_products,
    year_over_year,
)

__all__ = [
    "PERIODS",
    "TOOLS",
    "common_faults",
    "customer_concentration",
    "customer_profile",
    "data_dictionary",
    "describe",
    "dormant_customers",
    "kpis",
    "product_profile",
    "purchases_by_supplier",
    "purchases_vs_sales",
    "query",
    "repair_revenue",
    "repair_turnaround",
    "repairs_breakdown",
    "repairs_over_time",
    "run_saved_query",
    "sales_by_category",
    "sales_by_weekday_hour",
    "sales_over_time",
    "saved_queries",
    "top_customers",
    "top_products",
    "year_over_year",
]
