CREATE OR REPLACE FUNCTION load_logistics_csv(
    base_path      TEXT,
    truncate_first BOOLEAN DEFAULT TRUE
)
RETURNS TABLE (
    table_name  TEXT,
    rows_loaded BIGINT,
    status      TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    tables TEXT[] := ARRAY[
        'clients',
        'warehouses',
        'employees',
        'vehicles',
        'routes',
        'shipments',
        'shipment_items',
        'delivery_events',
        'invoices',
        'warehouse_inventory'
    ];

    sequences TEXT[] := ARRAY[
        'clients_client_id_seq',
        'warehouses_warehouse_id_seq',
        'employees_employee_id_seq',
        'vehicles_vehicle_id_seq',
        'routes_route_id_seq',
        'shipments_shipment_id_seq',
        'shipment_items_item_id_seq',
        'delivery_events_event_id_seq',
        'invoices_invoice_id_seq',
        'warehouse_inventory_inventory_id_seq'
    ];

    pk_cols TEXT[] := ARRAY[
        'client_id',
        'warehouse_id',
        'employee_id',
        'vehicle_id',
        'route_id',
        'shipment_id',
        'item_id',
        'event_id',
        'invoice_id',
        'inventory_id'
    ];

    i        INT;
    tname    TEXT;
    fpath    TEXT;
    n_rows   BIGINT;
    max_id   BIGINT;
BEGIN
    IF truncate_first THEN
        TRUNCATE
            warehouse_inventory,
            delivery_events,
            invoices,
            shipment_items,
            shipments,
            vehicles,
            routes,
            employees,
            warehouses,
            clients
        CASCADE;
    END IF;

    FOR i IN 1 .. array_length(tables, 1) LOOP
        tname := tables[i];
        fpath := rtrim(base_path, '/') || '/' || tname || '.csv';

        BEGIN
            EXECUTE format(
                'COPY %I FROM %L WITH (FORMAT csv, HEADER true, NULL '''')',
                tname, fpath
            );

            EXECUTE format('SELECT COUNT(*) FROM %I', tname) INTO n_rows;

            EXECUTE format(
                'SELECT MAX(%I) FROM %I',
                pk_cols[i], tname
            ) INTO max_id;

            IF max_id IS NOT NULL THEN
                EXECUTE format(
                    'SELECT setval(%L, %s)',
                    sequences[i], max_id
                );
            END IF;

            table_name  := tname;
            rows_loaded := n_rows;
            status      := 'OK';
            RETURN NEXT;

        EXCEPTION WHEN OTHERS THEN
            table_name  := tname;
            rows_loaded := 0;
            status      := SQLERRM;
            RETURN NEXT;
        END;
    END LOOP;
END;
$$;

SELECT table_name, rows_loaded, status
FROM load_logistics_csv('/csv_data/');
