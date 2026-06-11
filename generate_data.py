#!/usr/bin/env python3
"""Generate synthetic OLTP data for the logistics schema → CSV files.

One CSV per table, written to ./csv_data/.
Referential integrity is maintained across all tables.

Requirements:
    pip install faker
"""

import csv
import random
from datetime import date, datetime, timedelta
from pathlib import Path

from faker import Faker

# ── Reproducibility ───────────────────────────────────────────────────────────
SEED = 42
random.seed(SEED)
Faker.seed(SEED)
fake = Faker()

# ── Volume config ─────────────────────────────────────────────────────────────
N_CLIENTS    = 60
N_WAREHOUSES = 12
N_EMPLOYEES  = 50
N_VEHICLES   = 22
N_ROUTES     = 20
N_SHIPMENTS  = 400
OUTPUT_DIR   = Path("csv_data")

# ── Domain constants ──────────────────────────────────────────────────────────
KZ_CITIES = [
    "Almaty", "Astana", "Shymkent", "Aktobe", "Karaganda",
    "Pavlodar", "Oskemen", "Semey", "Aktau", "Atyrau",
    "Taraz", "Kostanay", "Uralsk", "Petropavl", "Kyzylorda",
]

EMPLOYEE_ROLES = ["driver", "manager", "dispatcher", "warehouse_worker"]
VEHICLE_TYPES  = ["truck", "van", "motorcycle", "trailer"]

SHIPMENT_STATUS_WEIGHTS = {
    "pending":    8,
    "in_transit": 18,
    "delivered":  58,
    "cancelled":  9,
    "returned":   7,
}

EVENT_CHAINS = {
    "pending":    ["created"],
    "in_transit": ["created", "picked_up", "arrived_warehouse",
                   "departed_warehouse", "out_for_delivery"],
    "delivered":  ["created", "picked_up", "arrived_warehouse",
                   "departed_warehouse", "out_for_delivery", "delivered"],
    "cancelled":  ["created", "cancelled"],
    "returned":   ["created", "picked_up", "out_for_delivery",
                   "failed_attempt", "returned"],
}

ITEM_DESCRIPTIONS = [
    "Server rack units", "Auto spare parts", "Steel pipes",
    "Textile rolls", "Frozen produce", "Industrial chemicals",
    "Office furniture", "Medical equipment", "Construction materials",
    "Consumer electronics", "Machinery components", "Paper products",
    "Agricultural produce", "Plastic containers", "Cable reels",
]

VEHICLE_MODELS = {
    "truck":      ["MAN TGX 18.500", "Volvo FH16", "Scania R500",
                   "Mercedes Actros 1845", "DAF XF 480"],
    "van":        ["Mercedes Sprinter 316", "Ford Transit 350",
                   "Volkswagen Crafter 35"],
    "motorcycle": ["Honda CB500X", "Yamaha MT-07"],
    "trailer":    ["Schmitz Cargobull S.KO", "Krone Box Liner",
                   "Wielton NS 3", "Kogel Cargo"],
}

VEHICLE_SPECS = {
    "truck":      {"kg": (10_000, 25_000), "m3": (40.0, 110.0), "yr": (2015, 2023)},
    "van":        {"kg": (800,    3_000),  "m3": (6.0,  20.0),  "yr": (2017, 2024)},
    "motorcycle": {"kg": (50,     200),    "m3": (0.2,  1.0),   "yr": (2019, 2024)},
    "trailer":    {"kg": (20_000, 30_000), "m3": (80.0, 130.0), "yr": (2014, 2022)},
}


# ── Helpers ───────────────────────────────────────────────────────────────────

def rand_date(start: date, end: date) -> date:
    return start + timedelta(days=random.randint(0, (end - start).days))


def rand_dt(start: date, end: date) -> datetime:
    d = rand_date(start, end)
    return datetime(d.year, d.month, d.day,
                    random.randint(6, 22), random.randint(0, 59))


def kz_phone() -> str:
    return f"+7{random.randint(700, 799)}{random.randint(1_000_000, 9_999_999)}"


def plate() -> str:
    chars = "ABCDEFGHJKMNPRSTUVWXYZ"
    return (f"{random.choice(chars)}"
            f"{random.randint(100, 999)}"
            f"{random.choice(chars)}{random.choice(chars)}")


# ── 1. CLIENTS ────────────────────────────────────────────────────────────────
clients: list[dict] = []
for i in range(1, N_CLIENTS + 1):
    clients.append({
        "client_id":    i,
        "company_name": fake.company(),
        "contact_name": fake.name(),
        "email":        f"contact{i}@{fake.domain_name()}",
        "phone":        kz_phone(),
        "address":      fake.street_address(),
        "city":         random.choice(KZ_CITIES),
        "country":      "Kazakhstan",
        "created_at":   rand_dt(date(2019, 1, 1), date(2024, 12, 31)),
        "updated_at":   None,
        "version":      1,
    })

client_ids = [c["client_id"] for c in clients]

# ── 2. WAREHOUSES ─────────────────────────────────────────────────────────────
warehouses: list[dict] = []
wh_cities: list[str] = []
for i in range(1, N_WAREHOUSES + 1):
    city = random.choice(KZ_CITIES)
    wh_cities.append(city)
    suffix = random.choice(["Hub", "Depot", "Terminal", "Logistics Center"])
    warehouses.append({
        "warehouse_id": i,
        "name":         f"{city} {suffix} {i}",
        "address":      fake.street_address(),
        "city":         city,
        "country":      "Kazakhstan",
        "capacity_m3":  round(random.uniform(500.0, 8_000.0), 2),
        "is_active":    random.choices([True, False], weights=[92, 8])[0],
        "updated_at":   None,
        "version":      1,
    })

wh_ids = [w["warehouse_id"] for w in warehouses]

# ── 3. EMPLOYEES ─────────────────────────────────────────────────────────────
role_pool = (
    ["driver"] * 20 +
    ["dispatcher"] * 12 +
    ["manager"] * 8 +
    ["warehouse_worker"] * 10
)[:N_EMPLOYEES]
random.shuffle(role_pool)

employees: list[dict] = []
driver_ids: list[int] = []

for i in range(1, N_EMPLOYEES + 1):
    role = role_pool[i - 1]
    if role == "driver":
        driver_ids.append(i)
    employees.append({
        "employee_id": i,
        "first_name":  fake.first_name(),
        "last_name":   fake.last_name(),
        "role":        role,
        "email":       f"emp{i}@logco.kz",
        "phone":       kz_phone(),
        "hired_at":    rand_date(date(2017, 1, 1), date(2025, 6, 1)),
        "is_active":   random.choices([True, False], weights=[92, 8])[0],
        "updated_at":  None,
        "version":     1,
    })

all_emp_ids = [e["employee_id"] for e in employees]

# ── 4. VEHICLES ───────────────────────────────────────────────────────────────
vehicles: list[dict] = []
assigned_drivers = random.sample(driver_ids, min(N_VEHICLES, len(driver_ids)))

for i in range(1, N_VEHICLES + 1):
    vtype = random.choice(VEHICLE_TYPES)
    spec  = VEHICLE_SPECS[vtype]
    vehicles.append({
        "vehicle_id":      i,
        "plate_number":    plate(),
        "model":           random.choice(VEHICLE_MODELS[vtype]),
        "type":            vtype,
        "capacity_kg":     round(random.uniform(*spec["kg"]), 2),
        "capacity_m3":     round(random.uniform(*spec["m3"]), 2),
        "year":            random.randint(*spec["yr"]),
        "is_available":    random.choices([True, False], weights=[75, 25])[0],
        "assigned_driver": assigned_drivers[i - 1] if i <= len(assigned_drivers) else None,
        "updated_at":      None,
        "version":         1,
    })

vehicle_ids = [v["vehicle_id"] for v in vehicles]

# ── 5. ROUTES ─────────────────────────────────────────────────────────────────
city_pairs = list({(a, b) for a in KZ_CITIES for b in KZ_CITIES if a != b})
random.shuffle(city_pairs)

routes: list[dict] = []
for i, (orig, dest) in enumerate(city_pairs[:N_ROUTES], start=1):
    dist = round(random.uniform(150.0, 2_500.0), 1)
    routes.append({
        "route_id":        i,
        "name":            f"{orig} → {dest}",
        "origin_city":     orig,
        "dest_city":       dest,
        "distance_km":     dist,
        "estimated_hours": round(dist / random.uniform(65.0, 90.0), 1),
        "updated_at":      None,
        "version":         1,
    })

route_ids = [r["route_id"] for r in routes]

# ── 6–9. SHIPMENTS / ITEMS / EVENTS / INVOICES ───────────────────────────────
shipments:           list[dict] = []
shipment_items:      list[dict] = []
delivery_events:     list[dict] = []
invoices:            list[dict] = []

item_id  = 1
event_id = 1

s_statuses  = list(SHIPMENT_STATUS_WEIGHTS.keys())
s_weights   = list(SHIPMENT_STATUS_WEIGHTS.values())

today = date.today()

for s_id in range(1, N_SHIPMENTS + 1):
    client_id  = random.choice(client_ids)
    vehicle_id = random.choice(vehicle_ids)
    route_id   = random.choice(route_ids)
    orig_wh    = random.choice(wh_ids)
    dest_wh    = random.choice([w for w in wh_ids if w != orig_wh])
    status     = random.choices(s_statuses, weights=s_weights)[0]

    sched = rand_date(date(2023, 1, 1), date(2026, 12, 31))

    delivered_at = None
    if status == "delivered":
        d = sched + timedelta(days=random.randint(1, 14))
        delivered_at = datetime(d.year, d.month, d.day,
                                random.randint(8, 20), random.randint(0, 59))

    # Items
    n_items     = random.randint(1, 6)
    total_kg    = 0.0
    total_m3    = 0.0
    total_value = 0.0

    for _ in range(n_items):
        qty  = random.randint(1, 60)
        wkg  = round(random.uniform(2.0, 600.0), 3)
        vm3  = round(random.uniform(0.01, 6.0),  3)
        val  = round(random.uniform(500.0, 800_000.0), 2)
        total_kg    += wkg * qty
        total_m3    += vm3 * qty
        total_value += val

        shipment_items.append({
            "item_id":        item_id,
            "shipment_id":    s_id,
            "description":    random.choice(ITEM_DESCRIPTIONS),
            "quantity":       qty,
            "weight_kg":      wkg,
            "volume_m3":      vm3,
            "is_fragile":     random.choices([True, False], weights=[15, 85])[0],
            "is_hazardous":   random.choices([True, False], weights=[8,  92])[0],
            "declared_value": val,
        })
        item_id += 1

    created_at = datetime.combine(
        sched - timedelta(days=random.randint(1, 10)), datetime.min.time()
    ).replace(hour=random.randint(8, 17), minute=random.randint(0, 59))

    shipments.append({
        "shipment_id":      s_id,
        "client_id":        client_id,
        "vehicle_id":       vehicle_id,
        "route_id":         route_id,
        "origin_warehouse": orig_wh,
        "dest_warehouse":   dest_wh,
        "status":           status,
        "total_weight_kg":  round(total_kg, 2),
        "total_volume_m3":  round(total_m3, 2),
        "scheduled_date":   sched,
        "delivered_at":     delivered_at,
        "notes":            fake.sentence() if random.random() < 0.15 else None,
        "created_at":       created_at,
        "updated_at":       None,
        "version":          1,
    })

    # Delivery events — spaced realistically
    chain = EVENT_CHAINS[status]
    ts    = created_at
    for etype in chain:
        ts = ts + timedelta(hours=random.randint(3, 30))
        delivery_events.append({
            "event_id":    event_id,
            "shipment_id": s_id,
            "employee_id": random.choice(all_emp_ids),
            "event_type":  etype,
            "location":    random.choice(KZ_CITIES),
            "notes":       fake.sentence() if random.random() < 0.1 else None,
            "occurred_at": ts,
        })
        event_id += 1

    # Invoice (one per shipment)
    issued = sched - timedelta(days=random.randint(0, 5))
    due    = issued + timedelta(days=30)

    if status == "delivered":
        inv_status = "paid"
        paid_at    = issued + timedelta(days=random.randint(1, 28))
    elif due < today:
        inv_status = "overdue"
        paid_at    = None
    else:
        inv_status = "unpaid"
        paid_at    = None

    invoices.append({
        "invoice_id":  s_id,
        "shipment_id": s_id,
        "client_id":   client_id,
        "amount":      round(total_value * random.uniform(0.04, 0.12), 2),
        "currency":    "KZT",
        "issued_at":   issued,
        "due_at":      due,
        "paid_at":     paid_at,
        "status":      inv_status,
        "updated_at":  None,
        "version":     1,
    })

# ── 10. WAREHOUSE_INVENTORY ───────────────────────────────────────────────────
# Items from in_transit / pending shipments currently stored at origin warehouse.
storable_statuses = {"in_transit", "pending"}
storable_items = [
    (it, next(s for s in shipments if s["shipment_id"] == it["shipment_id"]))
    for it in shipment_items
    if any(s["shipment_id"] == it["shipment_id"] and s["status"] in storable_statuses
           for s in shipments)
]
random.shuffle(storable_items)

warehouse_inventory: list[dict] = []
used_pairs: set[tuple[int, int]] = set()
inv_id = 1

for it, ship in storable_items:
    wh_id = ship["origin_warehouse"]
    pair  = (wh_id, it["item_id"])
    if pair in used_pairs:
        continue
    used_pairs.add(pair)

    aisle = random.choice("ABCDEFGHJK")
    slot  = f"{aisle}-{random.randint(1, 24):02d}-{random.randint(1, 6)}"

    warehouse_inventory.append({
        "inventory_id": inv_id,
        "warehouse_id": wh_id,
        "item_id":      it["item_id"],
        "stored_at":    rand_dt(date(2024, 1, 1), today),
        "removed_at":   None,
        "slot_label":   slot,
        "updated_at":   None,
        "version":      1,
    })
    inv_id += 1

    if inv_id > 120:   # cap at 120 inventory rows
        break

# ── CSV output ────────────────────────────────────────────────────────────────
TABLES: list[tuple[str, list[dict]]] = [
    ("clients",             clients),
    ("warehouses",          warehouses),
    ("employees",           employees),
    ("vehicles",            vehicles),
    ("routes",              routes),
    ("shipments",           shipments),
    ("shipment_items",      shipment_items),
    ("delivery_events",     delivery_events),
    ("invoices",            invoices),
    ("warehouse_inventory", warehouse_inventory),
]

OUTPUT_DIR.mkdir(exist_ok=True)

for table_name, data in TABLES:
    path = OUTPUT_DIR / f"{table_name}.csv"
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(data[0].keys()))
        writer.writeheader()
        writer.writerows(data)
    print(f"  {table_name:<24} {len(data):>5} rows  →  {path}")

print(f"\nDone. Files in ./{OUTPUT_DIR}/")
