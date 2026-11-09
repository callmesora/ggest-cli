-- name: customers_appointments
-- description: gGest agenda (Agenda table, view customer_appointments): appointments/tasks starting between start and end with status (Agendada = scheduled / Concluida = done), task type (customer assistance, bookings, RMA, urgent...), resource code, title, location, linked customer code and name with the customer's lifetime net and repairs. Only entries linked to an entity (customer or other) are listed; untyped entries are private notes. Use for "what is scheduled", follow-ups and on-site visits. status = all | Agendada | Concluida. The agenda is little used in this database (dozens of rows, some tests).
-- params: start=year_start, end=2099-12-31, status=all, limit=100
SELECT a.starts_at, a.ends_at, a.all_day, a.status, a.task_type, a.resource_code, a.title, a.location,
       a.customer_code, COALESCE(d.name, a.entity_name) AS customer, ca.net_lifetime, ca.repairs, a.synced_to_calendar
FROM customer_appointments a
LEFT JOIN customer_dim d ON d.customer_code = a.customer_code
LEFT JOIN customer_activity ca ON ca.customer_code = a.customer_code
WHERE date(a.starts_at) BETWEEN :start AND :end AND (:status = 'all' OR a.status = :status)
  AND a.entity_type IS NOT NULL
ORDER BY a.starts_at LIMIT :limit
