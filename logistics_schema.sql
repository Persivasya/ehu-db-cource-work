CREATE TABLE clients (
    client_id    SERIAL PRIMARY KEY,
    company_name VARCHAR(200) NOT NULL,
    contact_name VARCHAR(100),
    email        VARCHAR(150) UNIQUE NOT NULL,
    phone        VARCHAR(20),
    address      TEXT,
    city         VARCHAR(100),
    country      VARCHAR(100) NOT NULL DEFAULT 'Kazakhstan',
    created_at   TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMP,
    version      INT NOT NULL DEFAULT 1
);

CREATE TABLE warehouses (
    warehouse_id SERIAL PRIMARY KEY,
    name         VARCHAR(150) NOT NULL,
    address      TEXT NOT NULL,
    city         VARCHAR(100) NOT NULL,
    country      VARCHAR(100) NOT NULL DEFAULT 'Kazakhstan',
    capacity_m3  NUMERIC(10, 2) NOT NULL,
    is_active    BOOLEAN NOT NULL DEFAULT TRUE,
    updated_at   TIMESTAMP,
    version      INT NOT NULL DEFAULT 1
);

CREATE TABLE employees (
    employee_id SERIAL PRIMARY KEY,
    first_name  VARCHAR(100) NOT NULL,
    last_name   VARCHAR(100) NOT NULL,
    role        VARCHAR(50) NOT NULL CHECK (role IN ('driver', 'manager', 'dispatcher', 'warehouse_worker')),
    email       VARCHAR(150) UNIQUE NOT NULL,
    phone       VARCHAR(20),
    hired_at    DATE NOT NULL DEFAULT CURRENT_DATE,
    is_active   BOOLEAN NOT NULL DEFAULT TRUE,
    updated_at  TIMESTAMP,
    version     INT NOT NULL DEFAULT 1
);

CREATE TABLE vehicles (
    vehicle_id      SERIAL PRIMARY KEY,
    plate_number    VARCHAR(20) UNIQUE NOT NULL,
    model           VARCHAR(100) NOT NULL,
    type            VARCHAR(50) NOT NULL CHECK (type IN ('truck', 'van', 'motorcycle', 'trailer')),
    capacity_kg     NUMERIC(10, 2) NOT NULL,
    capacity_m3     NUMERIC(10, 2) NOT NULL,
    year            SMALLINT NOT NULL,
    is_available    BOOLEAN NOT NULL DEFAULT TRUE,
    assigned_driver INT REFERENCES employees(employee_id) ON DELETE SET NULL,
    updated_at      TIMESTAMP,
    version         INT NOT NULL DEFAULT 1
);

CREATE TABLE routes (
    route_id        SERIAL PRIMARY KEY,
    name            VARCHAR(150) NOT NULL,
    origin_city     VARCHAR(100) NOT NULL,
    dest_city       VARCHAR(100) NOT NULL,
    distance_km     NUMERIC(10, 2),
    estimated_hours NUMERIC(6, 2),
    updated_at      TIMESTAMP,
    version         INT NOT NULL DEFAULT 1
);

-- 6. SHIPMENTS
CREATE TABLE shipments (
    shipment_id     SERIAL PRIMARY KEY,
    client_id       INT NOT NULL REFERENCES clients(client_id) ON DELETE RESTRICT,
    vehicle_id      INT REFERENCES vehicles(vehicle_id) ON DELETE SET NULL,
    route_id        INT REFERENCES routes(route_id) ON DELETE SET NULL,
    origin_warehouse    INT REFERENCES warehouses(warehouse_id) ON DELETE SET NULL,
    dest_warehouse      INT REFERENCES warehouses(warehouse_id) ON DELETE SET NULL,
    status          VARCHAR(50) NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending','in_transit','delivered','cancelled','returned')),
    total_weight_kg NUMERIC(10, 2),
    total_volume_m3 NUMERIC(10, 2),
    scheduled_date  DATE NOT NULL,
    delivered_at    TIMESTAMP,
    notes           TEXT,
    created_at      TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP,
    version         INT NOT NULL DEFAULT 1
);

CREATE TABLE shipment_items (
    item_id        SERIAL PRIMARY KEY,
    shipment_id    INT NOT NULL REFERENCES shipments(shipment_id) ON DELETE CASCADE,
    description    VARCHAR(255) NOT NULL,
    quantity       INT NOT NULL CHECK (quantity > 0),
    weight_kg      NUMERIC(10, 3) NOT NULL,
    volume_m3      NUMERIC(10, 3),
    is_fragile     BOOLEAN NOT NULL DEFAULT FALSE,
    is_hazardous   BOOLEAN NOT NULL DEFAULT FALSE,
    declared_value NUMERIC(12, 2)
);

CREATE TABLE delivery_events (
    event_id    SERIAL PRIMARY KEY,
    shipment_id INT NOT NULL REFERENCES shipments(shipment_id) ON DELETE CASCADE,
    employee_id INT REFERENCES employees(employee_id) ON DELETE SET NULL,
    event_type  VARCHAR(80) NOT NULL
                    CHECK (event_type IN (
                        'created','picked_up','arrived_warehouse',
                        'departed_warehouse','out_for_delivery',
                        'delivered','failed_attempt','returned','cancelled'
                    )),
    location    VARCHAR(200),
    notes       TEXT,
    occurred_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE invoices (
    invoice_id  SERIAL PRIMARY KEY,
    shipment_id INT NOT NULL REFERENCES shipments(shipment_id) ON DELETE RESTRICT,
    client_id   INT NOT NULL REFERENCES clients(client_id) ON DELETE RESTRICT,
    amount      NUMERIC(12, 2) NOT NULL,
    currency    CHAR(3) NOT NULL DEFAULT 'KZT',
    issued_at   DATE NOT NULL DEFAULT CURRENT_DATE,
    due_at      DATE NOT NULL,
    paid_at     DATE,
    status      VARCHAR(20) NOT NULL DEFAULT 'unpaid'
                    CHECK (status IN ('unpaid','paid','overdue','cancelled')),
    updated_at  TIMESTAMP,
    version     INT NOT NULL DEFAULT 1
);

CREATE TABLE warehouse_inventory (
    inventory_id  SERIAL PRIMARY KEY,
    warehouse_id  INT NOT NULL REFERENCES warehouses(warehouse_id) ON DELETE CASCADE,
    item_id       INT NOT NULL REFERENCES shipment_items(item_id) ON DELETE CASCADE,
    stored_at     TIMESTAMP NOT NULL DEFAULT NOW(),
    removed_at    TIMESTAMP,
    slot_label    VARCHAR(50),
    updated_at    TIMESTAMP,
    version       INT NOT NULL DEFAULT 1,
    UNIQUE (warehouse_id, item_id)
);

-- trigger for versioning
CREATE OR REPLACE FUNCTION trg_bump_version()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.version    := OLD.version + 1;
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_clients_version
    BEFORE UPDATE ON clients
    FOR EACH ROW EXECUTE FUNCTION trg_bump_version();

CREATE TRIGGER trg_warehouses_version
    BEFORE UPDATE ON warehouses
    FOR EACH ROW EXECUTE FUNCTION trg_bump_version();

CREATE TRIGGER trg_employees_version
    BEFORE UPDATE ON employees
    FOR EACH ROW EXECUTE FUNCTION trg_bump_version();

CREATE TRIGGER trg_vehicles_version
    BEFORE UPDATE ON vehicles
    FOR EACH ROW EXECUTE FUNCTION trg_bump_version();

CREATE TRIGGER trg_routes_version
    BEFORE UPDATE ON routes
    FOR EACH ROW EXECUTE FUNCTION trg_bump_version();

CREATE TRIGGER trg_shipments_version
    BEFORE UPDATE ON shipments
    FOR EACH ROW EXECUTE FUNCTION trg_bump_version();

CREATE TRIGGER trg_invoices_version
    BEFORE UPDATE ON invoices
    FOR EACH ROW EXECUTE FUNCTION trg_bump_version();

CREATE TRIGGER trg_warehouse_inventory_version
    BEFORE UPDATE ON warehouse_inventory
    FOR EACH ROW EXECUTE FUNCTION trg_bump_version();
