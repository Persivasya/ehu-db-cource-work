import pandas as pd
from sqlalchemy import create_engine

DB_URL = "postgresql+psycopg2://postgres:postgres@localhost:5432/logistics"
OUTPUT  = "dwh_export.xlsx"

DWH_TABLES = [
    # static lookups
    "dwh.dim_date",
    "dwh.dim_status",
    "dwh.dim_vehicle_type",
    "dwh.dim_employee_role",
    # OLTP-derived dims
    "dwh.dim_geography",
    "dwh.dim_client",
    "dwh.dim_warehouse",
    "dwh.dim_vehicle",
    "dwh.dim_employee",
    "dwh.dim_route",
    # facts
    "dwh.fact_shipments",
    "dwh.fact_invoices",
    # bridge
    "dwh.bridge_shipment_employees",
]

def main():
    engine = create_engine(DB_URL)

    with pd.ExcelWriter(OUTPUT, engine="openpyxl") as writer:
        for qualified_name in DWH_TABLES:
            sheet = qualified_name.replace("dwh.", "")   # strip schema prefix for sheet name
            print(f"  exporting {qualified_name} ...", end=" ")

            df = pd.read_sql_table(
                table_name=sheet,
                con=engine,
                schema="dwh",
            )

            df.to_excel(writer, sheet_name=sheet, index=False)
            print(f"{len(df)} rows")

    print(f"\nSaved → {OUTPUT}")

if __name__ == "__main__":
    main()
