CREATE SCHEMA IF NOT EXISTS dwh;

-- DIMS

CREATE TABLE dwh.dim_date (
    date_key     INT PRIMARY KEY,   -- YYYYMMDD integer
    full_date    DATE NOT NULL UNIQUE,
    day_of_week  SMALLINT NOT NULL,
    day_name     VARCHAR(10) NOT NULL,
    day_of_month SMALLINT NOT NULL,
    day_of_year  SMALLINT NOT NULL,
    week_of_year SMALLINT NOT NULL,
    month_num    SMALLINT NOT NULL,
    month_name   VARCHAR(10) NOT NULL,
    quarter      SMALLINT NOT NULL,
    year         SMALLINT NOT NULL,
    is_weekend   BOOLEAN NOT NULL,
    is_holiday   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE dwh.dim_geography (
    geography_key SERIAL PRIMARY KEY,
    city          VARCHAR(100) NOT NULL,
    country       VARCHAR(100) NOT NULL,
    UNIQUE (city, country)
);

CREATE TABLE dwh.dim_vehicle_type (
    vehicle_type_key SERIAL PRIMARY KEY,
    type_name        VARCHAR(50) NOT NULL UNIQUE
);

CREATE TABLE dwh.dim_employee_role (
    role_key  SERIAL PRIMARY KEY,
    role_name VARCHAR(50) NOT NULL UNIQUE
);

CREATE TABLE dwh.dim_status (
    status_key  SERIAL PRIMARY KEY,
    domain      VARCHAR(20) NOT NULL, -- 'shipment' | 'invoice'
    status_name VARCHAR(50) NOT NULL,
    UNIQUE (domain, status_name)
);

-- SCD Type 2 control
CREATE TABLE dwh.dim_client (
    client_key    SERIAL PRIMARY KEY,           -- surrogate key 
    client_id     INT NOT NULL,
    company_name  VARCHAR(200) NOT NULL,
    contact_name  VARCHAR(100),
    email         VARCHAR(150) NOT NULL,
    phone         VARCHAR(20),
    geography_key INT NOT NULL REFERENCES dwh.dim_geography(geography_key),
    valid_from    DATE NOT NULL,
    valid_to      DATE,                         -- NULL = active record
    is_current    BOOLEAN NOT NULL DEFAULT TRUE,
    scd_version   INT NOT NULL DEFAULT 1
);

CREATE TABLE dwh.dim_warehouse (
    warehouse_key INT PRIMARY KEY,
    name          VARCHAR(150) NOT NULL,
    geography_key INT NOT NULL REFERENCES dwh.dim_geography(geography_key),
    capacity_m3   NUMERIC(10, 2) NOT NULL
);

CREATE TABLE dwh.dim_vehicle (
    vehicle_key      INT PRIMARY KEY,
    plate_number     VARCHAR(20) NOT NULL,
    model            VARCHAR(100) NOT NULL,
    vehicle_type_key INT NOT NULL REFERENCES dwh.dim_vehicle_type(vehicle_type_key),
    capacity_kg      NUMERIC(10, 2) NOT NULL,
    capacity_m3      NUMERIC(10, 2) NOT NULL,
    manufacture_year SMALLINT NOT NULL
);

CREATE TABLE dwh.dim_employee (
    employee_key INT PRIMARY KEY,              
    full_name    VARCHAR(200) NOT NULL,
    role_key     INT NOT NULL REFERENCES dwh.dim_employee_role(role_key),
    hired_date   DATE NOT NULL
);

CREATE TABLE dwh.dim_route (
    route_key            INT PRIMARY KEY,      
    name                 VARCHAR(150) NOT NULL,
    origin_geography_key INT NOT NULL REFERENCES dwh.dim_geography(geography_key),
    dest_geography_key   INT NOT NULL REFERENCES dwh.dim_geography(geography_key),
    distance_km          NUMERIC(10, 2),
    estimated_hours      NUMERIC(6, 2)
);

-- FACTS

CREATE TABLE dwh.fact_shipments (
    shipment_fact_id     SERIAL PRIMARY KEY,
    shipment_id          INT NOT NULL,
    client_key           INT NOT NULL REFERENCES dwh.dim_client(client_key),
    vehicle_key          INT      REFERENCES dwh.dim_vehicle(vehicle_key),
    route_key            INT      REFERENCES dwh.dim_route(route_key),
    origin_warehouse_key INT      REFERENCES dwh.dim_warehouse(warehouse_key),
    dest_warehouse_key   INT      REFERENCES dwh.dim_warehouse(warehouse_key),
    status_key           INT NOT NULL REFERENCES dwh.dim_status(status_key),
    scheduled_date_key   INT NOT NULL REFERENCES dwh.dim_date(date_key),
    delivered_date_key   INT      REFERENCES dwh.dim_date(date_key),   -- NULL until delivered
    total_weight_kg      NUMERIC(10, 2),
    total_volume_m3      NUMERIC(10, 2),
    item_count           INT,
    declared_value_total NUMERIC(14, 2),
    distance_km          NUMERIC(10, 2),
    days_in_transit      INT                    -- NULL until delivered; can be negative
);

CREATE TABLE dwh.fact_invoices (
    invoice_fact_id SERIAL PRIMARY KEY,
    invoice_id      INT NOT NULL,
    shipment_id     INT NOT NULL,
    client_key      INT NOT NULL REFERENCES dwh.dim_client(client_key),
    issued_date_key INT NOT NULL REFERENCES dwh.dim_date(date_key),
    due_date_key    INT NOT NULL REFERENCES dwh.dim_date(date_key),
    paid_date_key   INT      REFERENCES dwh.dim_date(date_key),
    status_key      INT NOT NULL REFERENCES dwh.dim_status(status_key),
    amount          NUMERIC(12, 2) NOT NULL,
    days_to_pay     INT,
    days_overdue    INT
);


-- BRIDGE
 
CREATE TABLE dwh.bridge_shipment_employees (
    shipment_fact_id INT NOT NULL REFERENCES dwh.fact_shipments(shipment_fact_id),
    employee_key     INT NOT NULL REFERENCES dwh.dim_employee(employee_key),
    role_key         INT NOT NULL REFERENCES dwh.dim_employee_role(role_key), -- role at time of event
    event_count      INT NOT NULL DEFAULT 1,    -- how many events this employee logged for shipment
    PRIMARY KEY (shipment_fact_id, employee_key, role_key)
);
