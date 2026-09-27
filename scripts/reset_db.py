"""
Utility script to reset the database and load schema.sql followed by seed_demo.sql.
Can be run locally or inside docker.
"""
import os
import sys
import asyncio
import asyncpg

DATABASE_URL = os.environ.get(
    "DATABASE_URL", 
    "postgresql://postgres:postgrespassword@localhost:5432/capacity_connect"
)

# Convert SQLAlchemy style url to asyncpg if needed
if "postgresql+asyncpg://" in DATABASE_URL:
    DATABASE_URL = DATABASE_URL.replace("postgresql+asyncpg://", "postgresql://")

async def reset_db():
    print(f"Connecting to database at {DATABASE_URL}...")
    try:
        conn = await asyncpg.connect(DATABASE_URL)
    except Exception as e:
        print(f"Error connecting: {e}")
        sys.exit(1)

    try:
        print("Dropping public schema...")
        await conn.execute("DROP SCHEMA IF EXISTS public CASCADE;")
        await conn.execute("CREATE SCHEMA public;")
        await conn.execute("CREATE EXTENSION IF NOT EXISTS citext;")

        schema_path = os.path.join(os.path.dirname(__file__), "..", "db", "schema.sql")
        seed_path = os.path.join(os.path.dirname(__file__), "..", "db", "seed_demo.sql")

        print("Executing db/schema.sql...")
        with open(schema_path, "r", encoding="utf-8") as f:
            schema_sql = f.read()
        await conn.execute(schema_sql)

        print("Executing db/seed_demo.sql...")
        with open(seed_path, "r", encoding="utf-8") as f:
            seed_sql = f.read()
        await conn.execute(seed_sql)

        print("Database successfully reset and seeded!")
    finally:
        await conn.close()

if __name__ == "__main__":
    asyncio.run(reset_db())
