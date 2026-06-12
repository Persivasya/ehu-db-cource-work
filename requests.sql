-- OLTP

-- 1. Top 10 clients by shipment volume and cargo value
SELECT
    c.client_id,
    c.company_name,
    c.city,
    COUNT(s.shipment_id)                        AS total_shipments,
    SUM(s.total_weight_kg)                      AS total_weight_kg,
    SUM(i_agg.invoice_total)                    AS total_invoiced_kzt,
    ROUND(AVG(s.total_weight_kg), 2)            AS avg_weight_per_shipment
FROM public.clients c
JOIN public.shipments s ON s.client_id = c.client_id
LEFT JOIN (
    SELECT client_id, SUM(amount) AS invoice_total
    FROM public.invoices
    GROUP BY client_id
) i_agg ON i_agg.client_id = c.client_id
GROUP BY c.client_id, c.company_name, c.city
ORDER BY total_shipments DESC
LIMIT 10;


-- 2. Route performance: delivery success rate and average transit time
SELECT
    r.route_id,
    r.name                                                          AS route_name,
    r.origin_city,
    r.dest_city,
    r.distance_km,
    COUNT(s.shipment_id)                                            AS total_shipments,
    COUNT(s.shipment_id) FILTER (WHERE s.status = 'delivered')     AS delivered,
    COUNT(s.shipment_id) FILTER (WHERE s.status = 'cancelled')     AS cancelled,
    COUNT(s.shipment_id) FILTER (WHERE s.status = 'returned')      AS returned,
    ROUND(
        COUNT(s.shipment_id) FILTER (WHERE s.status = 'delivered')::NUMERIC
        / NULLIF(COUNT(s.shipment_id), 0) * 100, 1
    )                                                               AS delivery_rate_pct,
    ROUND(AVG(
        EXTRACT(EPOCH FROM (s.delivered_at - s.scheduled_date::TIMESTAMP)) / 86400.0
    ) FILTER (WHERE s.delivered_at IS NOT NULL), 1)                AS avg_days_in_transit
FROM public.routes r
LEFT JOIN public.shipments s ON s.route_id = r.route_id
GROUP BY r.route_id, r.name, r.origin_city, r.dest_city, r.distance_km
ORDER BY total_shipments DESC;


-- 3. Employee workload: event activity breakdown by role
SELECT
    e.employee_id,
    e.first_name || ' ' || e.last_name  AS full_name,
    e.role,
    COUNT(de.event_id)                  AS total_events,
    COUNT(DISTINCT de.shipment_id)      AS distinct_shipments,
    COUNT(*) FILTER (WHERE de.event_type = 'delivered')       AS deliveries_completed,
    COUNT(*) FILTER (WHERE de.event_type = 'failed_attempt')  AS failed_attempts,
    MIN(de.occurred_at)::DATE           AS first_event_date,
    MAX(de.occurred_at)::DATE           AS last_event_date
FROM public.employees e
JOIN public.delivery_events de ON de.employee_id = e.employee_id
GROUP BY e.employee_id, e.first_name, e.last_name, e.role
ORDER BY total_events DESC
LIMIT 20;


-- OLAP

-- 1. Monthly revenue and invoice payment health (last 24 months)
SELECT
    dd.year,
    dd.month_num,
    dd.month_name,
    COUNT(fi.invoice_fact_id)                                       AS invoices_issued,
    ROUND(SUM(fi.amount), 2)                                        AS total_amount_kzt,
    COUNT(*) FILTER (WHERE ds.status_name = 'paid')                 AS paid_count,
    COUNT(*) FILTER (WHERE ds.status_name = 'overdue')              AS overdue_count,
    ROUND(SUM(fi.amount) FILTER (WHERE ds.status_name = 'overdue'), 2) AS overdue_amount_kzt,
    ROUND(AVG(fi.days_to_pay) FILTER (WHERE fi.days_to_pay IS NOT NULL), 1) AS avg_days_to_pay
FROM dwh.fact_invoices fi
JOIN dwh.dim_date   dd ON dd.date_key  = fi.issued_date_key
JOIN dwh.dim_status ds ON ds.status_key = fi.status_key
WHERE dd.year >= EXTRACT(YEAR FROM CURRENT_DATE)::INT - 2
GROUP BY dd.year, dd.month_num, dd.month_name
ORDER BY dd.year, dd.month_num;


-- 2. Route efficiency ranking: transit time vs distance
SELECT
    dr.route_key,
    dr.name                                         AS route_name,
    g_orig.city                                     AS origin_city,
    g_dest.city                                     AS dest_city,
    dr.distance_km,
    dr.estimated_hours,
    COUNT(fs.shipment_fact_id)                      AS total_shipments,
    ROUND(AVG(fs.days_in_transit), 1)               AS avg_days_in_transit,
    ROUND(SUM(fs.total_weight_kg), 0)               AS total_weight_kg,
    ROUND(SUM(fs.declared_value_total), 2)          AS total_declared_value_kzt,
    COUNT(*) FILTER (WHERE ds.status_name = 'delivered')    AS delivered,
    COUNT(*) FILTER (WHERE ds.status_name = 'cancelled')    AS cancelled,
    ROUND(
        COUNT(*) FILTER (WHERE ds.status_name = 'delivered')::NUMERIC
        / NULLIF(COUNT(fs.shipment_fact_id), 0) * 100, 1
    )                                               AS delivery_rate_pct
FROM dwh.dim_route dr
JOIN dwh.dim_geography g_orig ON g_orig.geography_key = dr.origin_geography_key
JOIN dwh.dim_geography g_dest ON g_dest.geography_key = dr.dest_geography_key
LEFT JOIN dwh.fact_shipments fs ON fs.route_key = dr.route_key
LEFT JOIN dwh.dim_status     ds ON ds.status_key = fs.status_key
GROUP BY dr.route_key, dr.name, g_orig.city, g_dest.city, dr.distance_km, dr.estimated_hours
ORDER BY avg_days_in_transit DESC NULLS LAST;


-- 3. Client value segmentation: shipment activity + payment behaviour
SELECT
    dc.client_id,
    dc.company_name,
    dg.city,
    dg.country,
    COUNT(DISTINCT fs.shipment_fact_id)             AS total_shipments,
    ROUND(SUM(fs.declared_value_total), 2)          AS total_cargo_value_kzt,
    ROUND(SUM(fi.amount), 2)                        AS total_invoiced_kzt,
    COUNT(fi.invoice_fact_id)                       AS invoices_total,
    COUNT(fi.invoice_fact_id) FILTER (WHERE ds_i.status_name = 'paid')    AS invoices_paid,
    COUNT(fi.invoice_fact_id) FILTER (WHERE ds_i.status_name = 'overdue') AS invoices_overdue,
    ROUND(
        COUNT(fi.invoice_fact_id) FILTER (WHERE ds_i.status_name = 'paid')::NUMERIC
        / NULLIF(COUNT(fi.invoice_fact_id), 0) * 100, 1
    )                                               AS payment_rate_pct,
    ROUND(AVG(fi.days_to_pay) FILTER (WHERE fi.days_to_pay IS NOT NULL), 1) AS avg_days_to_pay
FROM dwh.dim_client dc
JOIN dwh.dim_geography  dg   ON dg.geography_key  = dc.geography_key
LEFT JOIN dwh.fact_shipments fs   ON fs.client_key    = dc.client_key
LEFT JOIN dwh.fact_invoices  fi   ON fi.client_key    = dc.client_key
LEFT JOIN dwh.dim_status     ds_i ON ds_i.status_key  = fi.status_key
WHERE dc.is_current = TRUE
GROUP BY dc.client_id, dc.company_name, dg.city, dg.country
ORDER BY total_invoiced_kzt DESC NULLS LAST
LIMIT 20;
