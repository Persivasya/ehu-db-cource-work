-- Seed statistic

CREATE OR REPLACE FUNCTION dwh.seed_dim_vehicle_type()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO dwh.dim_vehicle_type (type_name)
    VALUES ('truck'), ('van'), ('motorcycle'), ('trailer')
    ON CONFLICT (type_name) DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION dwh.seed_dim_employee_role()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO dwh.dim_employee_role (role_name)
    VALUES ('driver'), ('manager'), ('dispatcher'), ('warehouse_worker')
    ON CONFLICT (role_name) DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION dwh.seed_dim_status()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO dwh.dim_status (domain, status_name) VALUES
        ('shipment', 'pending'),
        ('shipment', 'in_transit'),
        ('shipment', 'delivered'),
        ('shipment', 'cancelled'),
        ('shipment', 'returned'),
        ('invoice',  'unpaid'),
        ('invoice',  'paid'),
        ('invoice',  'overdue'),
        ('invoice',  'cancelled')
    ON CONFLICT (domain, status_name) DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION dwh.seed_dim_date()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO dwh.dim_date (
        date_key,
        full_date,
        day_of_week,
        day_name,
        day_of_month,
        day_of_year,
        week_of_year,
        month_num,
        month_name,
        quarter,
        year,
        is_weekend
    )
    SELECT
        TO_CHAR(d, 'YYYYMMDD')::INT,
        d::DATE,
        EXTRACT(DOW     FROM d)::SMALLINT,
        TRIM(TO_CHAR(d, 'Day')),
        EXTRACT(DAY     FROM d)::SMALLINT,
        EXTRACT(DOY     FROM d)::SMALLINT,
        EXTRACT(WEEK    FROM d)::SMALLINT,
        EXTRACT(MONTH   FROM d)::SMALLINT,
        TRIM(TO_CHAR(d, 'Month')),
        EXTRACT(QUARTER FROM d)::SMALLINT,
        EXTRACT(YEAR    FROM d)::SMALLINT,
        EXTRACT(DOW     FROM d) IN (0, 6)
    FROM generate_series(
        '2020-01-01'::DATE,
        '2030-12-31'::DATE,
        '1 day'::INTERVAL
    ) AS d
    ON CONFLICT (date_key) DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION dwh.seed_static_lookups()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM dwh.seed_dim_vehicle_type();
    PERFORM dwh.seed_dim_employee_role();
    PERFORM dwh.seed_dim_status();
    PERFORM dwh.seed_dim_date();
END;
$$;


-- Migration error log

CREATE TABLE IF NOT EXISTS dwh.migration_errors (
    error_id      SERIAL PRIMARY KEY,
    run_id        UUID        NOT NULL,
    migrated_at   TIMESTAMP   NOT NULL DEFAULT NOW(),
    source_table  TEXT        NOT NULL,
    source_id     TEXT,
    target_table  TEXT        NOT NULL,
    error_code    TEXT,
    error_msg     TEXT        NOT NULL,
    error_detail  TEXT
);

CREATE INDEX IF NOT EXISTS idx_merr_run_id ON dwh.migration_errors(run_id);
CREATE INDEX IF NOT EXISTS idx_merr_target ON dwh.migration_errors(target_table);


-- Migration functions

CREATE OR REPLACE FUNCTION dwh.migrate_dim_geography(
    p_run_id       UUID,
    OUT rows_inserted BIGINT,
    OUT errors_logged INT
)
LANGUAGE plpgsql AS $$
DECLARE
    rec RECORD;
BEGIN
    rows_inserted := 0; errors_logged := 0;

    FOR rec IN
        SELECT DISTINCT city, country FROM (
            SELECT city, country             FROM public.clients    WHERE city IS NOT NULL
            UNION ALL
            SELECT city, country             FROM public.warehouses
            UNION ALL
            SELECT origin_city, 'Kazakhstan' FROM public.routes
            UNION ALL
            SELECT dest_city,   'Kazakhstan' FROM public.routes
        ) src
        WHERE city IS NOT NULL AND country IS NOT NULL
    LOOP
        BEGIN
            INSERT INTO dwh.dim_geography (city, country)
            VALUES (rec.city, rec.country)
            ON CONFLICT (city, country) DO NOTHING;

            rows_inserted := rows_inserted + 1;
        EXCEPTION WHEN OTHERS THEN
            errors_logged := errors_logged + 1;
            INSERT INTO dwh.migration_errors
                (run_id, source_table, source_id, target_table, error_code, error_msg, error_detail)
            VALUES (p_run_id, 'public.clients/warehouses/routes',
                    rec.city || ',' || rec.country,
                    'dwh.dim_geography', SQLSTATE, SQLERRM,
                    row_to_json(rec)::TEXT);
        END;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION dwh.migrate_dim_client(
    p_run_id       UUID,
    OUT rows_inserted BIGINT,
    OUT errors_logged INT
)
LANGUAGE plpgsql AS $$
DECLARE
    rec         RECORD;
    v_geo_key   INT;
BEGIN
    rows_inserted := 0; errors_logged := 0;

    FOR rec IN SELECT * FROM public.clients LOOP
        BEGIN
            SELECT geography_key INTO v_geo_key
            FROM dwh.dim_geography
            WHERE city    = COALESCE(rec.city, 'Almaty')
              AND country = rec.country
            LIMIT 1;

            IF v_geo_key IS NULL THEN
                RAISE EXCEPTION 'Geography not found: city=%, country=%',
                    rec.city, rec.country;
            END IF;

            INSERT INTO dwh.dim_client
                (client_id, company_name, contact_name, email, phone,
                 geography_key, valid_from, valid_to, is_current, scd_version)
            VALUES
                (rec.client_id, rec.company_name, rec.contact_name, rec.email, rec.phone,
                 v_geo_key, rec.created_at::DATE, NULL, TRUE, 1);

            rows_inserted := rows_inserted + 1;
        EXCEPTION WHEN OTHERS THEN
            errors_logged := errors_logged + 1;
            INSERT INTO dwh.migration_errors
                (run_id, source_table, source_id, target_table, error_code, error_msg, error_detail)
            VALUES (p_run_id, 'public.clients', rec.client_id::TEXT,
                    'dwh.dim_client', SQLSTATE, SQLERRM,
                    json_build_object('client_id',    rec.client_id,
                                      'company_name', rec.company_name,
                                      'city',         rec.city)::TEXT);
        END;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION dwh.migrate_dim_warehouse(
    p_run_id       UUID,
    OUT rows_inserted BIGINT,
    OUT errors_logged INT
)
LANGUAGE plpgsql AS $$
DECLARE
    rec         RECORD;
    v_geo_key   INT;
BEGIN
    rows_inserted := 0; errors_logged := 0;

    FOR rec IN SELECT * FROM public.warehouses LOOP
        BEGIN
            SELECT geography_key INTO STRICT v_geo_key
            FROM dwh.dim_geography
            WHERE city = rec.city AND country = rec.country;

            INSERT INTO dwh.dim_warehouse (warehouse_key, name, geography_key, capacity_m3)
            VALUES (rec.warehouse_id, rec.name, v_geo_key, rec.capacity_m3);

            rows_inserted := rows_inserted + 1;
        EXCEPTION WHEN OTHERS THEN
            errors_logged := errors_logged + 1;
            INSERT INTO dwh.migration_errors
                (run_id, source_table, source_id, target_table, error_code, error_msg, error_detail)
            VALUES (p_run_id, 'public.warehouses', rec.warehouse_id::TEXT,
                    'dwh.dim_warehouse', SQLSTATE, SQLERRM,
                    json_build_object('warehouse_id', rec.warehouse_id,
                                      'city',         rec.city)::TEXT);
        END;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION dwh.migrate_dim_vehicle(
    p_run_id       UUID,
    OUT rows_inserted BIGINT,
    OUT errors_logged INT
)
LANGUAGE plpgsql AS $$
DECLARE
    rec RECORD;
BEGIN
    rows_inserted := 0; errors_logged := 0;

    FOR rec IN SELECT * FROM public.vehicles LOOP
        BEGIN
            INSERT INTO dwh.dim_vehicle
                (vehicle_key, plate_number, model, vehicle_type_key,
                 capacity_kg, capacity_m3, manufacture_year)
            SELECT rec.vehicle_id, rec.plate_number, rec.model,
                   vt.vehicle_type_key, rec.capacity_kg, rec.capacity_m3, rec.year
            FROM dwh.dim_vehicle_type vt
            WHERE vt.type_name = rec.type;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'Unknown vehicle type: "%"', rec.type;
            END IF;

            rows_inserted := rows_inserted + 1;
        EXCEPTION WHEN OTHERS THEN
            errors_logged := errors_logged + 1;
            INSERT INTO dwh.migration_errors
                (run_id, source_table, source_id, target_table, error_code, error_msg, error_detail)
            VALUES (p_run_id, 'public.vehicles', rec.vehicle_id::TEXT,
                    'dwh.dim_vehicle', SQLSTATE, SQLERRM,
                    json_build_object('vehicle_id',   rec.vehicle_id,
                                      'type',         rec.type,
                                      'plate_number', rec.plate_number)::TEXT);
        END;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION dwh.migrate_dim_employee(
    p_run_id       UUID,
    OUT rows_inserted BIGINT,
    OUT errors_logged INT
)
LANGUAGE plpgsql AS $$
DECLARE
    rec RECORD;
BEGIN
    rows_inserted := 0; errors_logged := 0;

    FOR rec IN SELECT * FROM public.employees LOOP
        BEGIN
            INSERT INTO dwh.dim_employee (employee_key, full_name, role_key, hired_date)
            SELECT rec.employee_id,
                   rec.first_name || ' ' || rec.last_name,
                   er.role_key,
                   rec.hired_at
            FROM dwh.dim_employee_role er
            WHERE er.role_name = rec.role;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'Unknown employee role: "%"', rec.role;
            END IF;

            rows_inserted := rows_inserted + 1;
        EXCEPTION WHEN OTHERS THEN
            errors_logged := errors_logged + 1;
            INSERT INTO dwh.migration_errors
                (run_id, source_table, source_id, target_table, error_code, error_msg, error_detail)
            VALUES (p_run_id, 'public.employees', rec.employee_id::TEXT,
                    'dwh.dim_employee', SQLSTATE, SQLERRM,
                    json_build_object('employee_id', rec.employee_id,
                                      'role',        rec.role)::TEXT);
        END;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION dwh.migrate_dim_route(
    p_run_id       UUID,
    OUT rows_inserted BIGINT,
    OUT errors_logged INT
)
LANGUAGE plpgsql AS $$
DECLARE
    rec              RECORD;
    v_geo_orig_key   INT;
    v_geo_dest_key   INT;
BEGIN
    rows_inserted := 0; errors_logged := 0;

    FOR rec IN SELECT * FROM public.routes LOOP
        BEGIN
            SELECT geography_key INTO STRICT v_geo_orig_key
            FROM dwh.dim_geography
            WHERE city = rec.origin_city AND country = 'Kazakhstan';

            SELECT geography_key INTO STRICT v_geo_dest_key
            FROM dwh.dim_geography
            WHERE city = rec.dest_city AND country = 'Kazakhstan';

            INSERT INTO dwh.dim_route
                (route_key, name, origin_geography_key, dest_geography_key,
                 distance_km, estimated_hours)
            VALUES
                (rec.route_id, rec.name, v_geo_orig_key, v_geo_dest_key,
                 rec.distance_km, rec.estimated_hours);

            rows_inserted := rows_inserted + 1;
        EXCEPTION WHEN OTHERS THEN
            errors_logged := errors_logged + 1;
            INSERT INTO dwh.migration_errors
                (run_id, source_table, source_id, target_table, error_code, error_msg, error_detail)
            VALUES (p_run_id, 'public.routes', rec.route_id::TEXT,
                    'dwh.dim_route', SQLSTATE, SQLERRM,
                    json_build_object('route_id',    rec.route_id,
                                      'origin_city', rec.origin_city,
                                      'dest_city',   rec.dest_city)::TEXT);
        END;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION dwh.migrate_fact_shipments(
    p_run_id       UUID,
    OUT rows_inserted BIGINT,
    OUT errors_logged INT
)
LANGUAGE plpgsql AS $$
DECLARE
    rec            RECORD;
    v_client_key   INT;
    v_status_key   INT;
    v_date_key     INT;
    v_del_date_key INT;
BEGIN
    rows_inserted := 0; errors_logged := 0;

    FOR rec IN SELECT * FROM public.shipments LOOP
        BEGIN
            SELECT client_key INTO STRICT v_client_key
            FROM dwh.dim_client
            WHERE client_id = rec.client_id AND is_current = TRUE;

            SELECT status_key INTO STRICT v_status_key
            FROM dwh.dim_status
            WHERE status_name = rec.status AND domain = 'shipment';

            SELECT date_key INTO STRICT v_date_key
            FROM dwh.dim_date
            WHERE full_date = rec.scheduled_date;

            v_del_date_key := NULL;
            IF rec.delivered_at IS NOT NULL THEN
                SELECT date_key INTO v_del_date_key
                FROM dwh.dim_date
                WHERE full_date = rec.delivered_at::DATE;
                -- NULL is acceptable when delivered_at falls outside 2020-2030
            END IF;

            INSERT INTO dwh.fact_shipments (
                shipment_id,
                client_key,           vehicle_key,         route_key,
                origin_warehouse_key, dest_warehouse_key,
                status_key,           scheduled_date_key,  delivered_date_key,
                total_weight_kg,      total_volume_m3,
                item_count,           declared_value_total,
                distance_km,          days_in_transit
            )
            VALUES (
                rec.shipment_id,
                v_client_key,
                rec.vehicle_id,
                rec.route_id,
                rec.origin_warehouse,
                rec.dest_warehouse,
                v_status_key,
                v_date_key,
                v_del_date_key,
                rec.total_weight_kg,
                rec.total_volume_m3,
                (SELECT COUNT(*)           FROM public.shipment_items WHERE shipment_id = rec.shipment_id),
                (SELECT SUM(declared_value) FROM public.shipment_items WHERE shipment_id = rec.shipment_id),
                (SELECT distance_km        FROM public.routes          WHERE route_id    = rec.route_id),
                CASE WHEN rec.delivered_at IS NOT NULL
                     THEN (rec.delivered_at::DATE - rec.scheduled_date)
                END
            );

            rows_inserted := rows_inserted + 1;
        EXCEPTION WHEN OTHERS THEN
            errors_logged := errors_logged + 1;
            INSERT INTO dwh.migration_errors
                (run_id, source_table, source_id, target_table, error_code, error_msg, error_detail)
            VALUES (p_run_id, 'public.shipments', rec.shipment_id::TEXT,
                    'dwh.fact_shipments', SQLSTATE, SQLERRM,
                    json_build_object('shipment_id',    rec.shipment_id,
                                      'client_id',      rec.client_id,
                                      'status',         rec.status,
                                      'scheduled_date', rec.scheduled_date)::TEXT);
        END;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION dwh.migrate_fact_invoices(
    p_run_id       UUID,
    OUT rows_inserted BIGINT,
    OUT errors_logged INT
)
LANGUAGE plpgsql AS $$
DECLARE
    rec           RECORD;
    v_client_key  INT;
    v_status_key  INT;
    v_date_key    INT;
BEGIN
    rows_inserted := 0; errors_logged := 0;

    FOR rec IN SELECT * FROM public.invoices LOOP
        BEGIN
            SELECT client_key INTO STRICT v_client_key
            FROM dwh.dim_client
            WHERE client_id = rec.client_id AND is_current = TRUE;

            SELECT status_key INTO STRICT v_status_key
            FROM dwh.dim_status
            WHERE status_name = rec.status AND domain = 'invoice';

            SELECT date_key INTO STRICT v_date_key
            FROM dwh.dim_date
            WHERE full_date = rec.issued_at;

            INSERT INTO dwh.fact_invoices (
                invoice_id,      shipment_id,
                client_key,
                issued_date_key, due_date_key, paid_date_key,
                status_key,
                amount,          days_to_pay,  days_overdue
            )
            SELECT
                rec.invoice_id,
                rec.shipment_id,
                v_client_key,
                v_date_key,
                dd.date_key,
                dp.date_key,
                v_status_key,
                rec.amount,
                CASE WHEN rec.paid_at IS NOT NULL
                     THEN (rec.paid_at - rec.issued_at) END,
                CASE WHEN rec.status IN ('unpaid', 'overdue')
                     THEN GREATEST(0, CURRENT_DATE - rec.due_at)
                     ELSE 0
                END
            FROM            dwh.dim_date dd
            LEFT JOIN dwh.dim_date dp ON dp.full_date = rec.paid_at
            WHERE dd.full_date = rec.due_at;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'due_at date % not found in dim_date', rec.due_at;
            END IF;

            rows_inserted := rows_inserted + 1;
        EXCEPTION WHEN OTHERS THEN
            errors_logged := errors_logged + 1;
            INSERT INTO dwh.migration_errors
                (run_id, source_table, source_id, target_table, error_code, error_msg, error_detail)
            VALUES (p_run_id, 'public.invoices', rec.invoice_id::TEXT,
                    'dwh.fact_invoices', SQLSTATE, SQLERRM,
                    json_build_object('invoice_id', rec.invoice_id,
                                      'client_id',  rec.client_id,
                                      'status',     rec.status,
                                      'issued_at',  rec.issued_at,
                                      'due_at',     rec.due_at)::TEXT);
        END;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION dwh.migrate_bridge_shipment_employees(
    p_run_id       UUID,
    OUT rows_inserted BIGINT,
    OUT errors_logged INT
)
LANGUAGE plpgsql AS $$
DECLARE
    rec RECORD;
BEGIN
    rows_inserted := 0; errors_logged := 0;

    FOR rec IN
        SELECT de.shipment_id,
               de.employee_id,
               e.role,
               COUNT(*) AS event_count
        FROM public.delivery_events de
        JOIN public.employees        e ON e.employee_id = de.employee_id
        GROUP BY de.shipment_id, de.employee_id, e.role
    LOOP
        BEGIN
            INSERT INTO dwh.bridge_shipment_employees
                (shipment_fact_id, employee_key, role_key, event_count)
            SELECT fs.shipment_fact_id,
                   rec.employee_id,
                   er.role_key,
                   rec.event_count
            FROM dwh.fact_shipments    fs
            JOIN dwh.dim_employee_role er ON er.role_name = rec.role
            WHERE fs.shipment_id = rec.shipment_id;

            IF NOT FOUND THEN
                RAISE EXCEPTION
                    'fact_shipments row missing for shipment_id %; '
                    'it likely failed migration', rec.shipment_id;
            END IF;

            rows_inserted := rows_inserted + 1;
        EXCEPTION WHEN OTHERS THEN
            errors_logged := errors_logged + 1;
            INSERT INTO dwh.migration_errors
                (run_id, source_table, source_id, target_table, error_code, error_msg, error_detail)
            VALUES (p_run_id, 'public.delivery_events',
                    'shipment_id=' || rec.shipment_id || '/employee_id=' || rec.employee_id,
                    'dwh.bridge_shipment_employees', SQLSTATE, SQLERRM,
                    json_build_object('shipment_id',  rec.shipment_id,
                                      'employee_id',  rec.employee_id,
                                      'role',         rec.role,
                                      'event_count',  rec.event_count)::TEXT);
        END;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION dwh.migrate_oltp_to_dwh(
    full_reload BOOLEAN DEFAULT TRUE
)
RETURNS TABLE (
    target_table  TEXT,
    rows_inserted BIGINT,
    errors_logged INT
)
LANGUAGE plpgsql AS $$
DECLARE
    run_id UUID := gen_random_uuid();
    r_ins  BIGINT;
    r_err  INT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dwh.dim_status        LIMIT 1) OR
       NOT EXISTS (SELECT 1 FROM dwh.dim_date           LIMIT 1) OR
       NOT EXISTS (SELECT 1 FROM dwh.dim_vehicle_type   LIMIT 1) OR
       NOT EXISTS (SELECT 1 FROM dwh.dim_employee_role  LIMIT 1)
    THEN
        RAISE EXCEPTION 'Static lookup tables empty. Run dwh.seed_static_lookups() first.';
    END IF;

    IF full_reload THEN
        TRUNCATE
            dwh.bridge_shipment_employees,
            dwh.fact_invoices,
            dwh.fact_shipments,
            dwh.dim_client,
            dwh.dim_route,
            dwh.dim_vehicle,
            dwh.dim_employee,
            dwh.dim_warehouse,
            dwh.dim_geography
        RESTART IDENTITY;
    END IF;

    SELECT f.rows_inserted, f.errors_logged INTO r_ins, r_err FROM dwh.migrate_dim_geography(run_id) f;
    target_table := 'dwh.dim_geography';             rows_inserted := r_ins; errors_logged := r_err; RETURN NEXT;

    SELECT f.rows_inserted, f.errors_logged INTO r_ins, r_err FROM dwh.migrate_dim_client(run_id) f;
    target_table := 'dwh.dim_client';                rows_inserted := r_ins; errors_logged := r_err; RETURN NEXT;

    SELECT f.rows_inserted, f.errors_logged INTO r_ins, r_err FROM dwh.migrate_dim_warehouse(run_id) f;
    target_table := 'dwh.dim_warehouse';             rows_inserted := r_ins; errors_logged := r_err; RETURN NEXT;

    SELECT f.rows_inserted, f.errors_logged INTO r_ins, r_err FROM dwh.migrate_dim_vehicle(run_id) f;
    target_table := 'dwh.dim_vehicle';               rows_inserted := r_ins; errors_logged := r_err; RETURN NEXT;

    SELECT f.rows_inserted, f.errors_logged INTO r_ins, r_err FROM dwh.migrate_dim_employee(run_id) f;
    target_table := 'dwh.dim_employee';              rows_inserted := r_ins; errors_logged := r_err; RETURN NEXT;

    SELECT f.rows_inserted, f.errors_logged INTO r_ins, r_err FROM dwh.migrate_dim_route(run_id) f;
    target_table := 'dwh.dim_route';                 rows_inserted := r_ins; errors_logged := r_err; RETURN NEXT;

    SELECT f.rows_inserted, f.errors_logged INTO r_ins, r_err FROM dwh.migrate_fact_shipments(run_id) f;
    target_table := 'dwh.fact_shipments';            rows_inserted := r_ins; errors_logged := r_err; RETURN NEXT;

    SELECT f.rows_inserted, f.errors_logged INTO r_ins, r_err FROM dwh.migrate_fact_invoices(run_id) f;
    target_table := 'dwh.fact_invoices';             rows_inserted := r_ins; errors_logged := r_err; RETURN NEXT;

    SELECT f.rows_inserted, f.errors_logged INTO r_ins, r_err FROM dwh.migrate_bridge_shipment_employees(run_id) f;
    target_table := 'dwh.bridge_shipment_employees'; rows_inserted := r_ins; errors_logged := r_err; RETURN NEXT;
END;
$$;

SELECT * FROM dwh.seed_static_lookups();
SELECT * FROM dwh.migrate_oltp_to_dwh();
