.PHONY: up down build test reset-db logs

up:
	docker compose up -d

down:
	docker compose down

build:
	docker compose build

test:
	docker compose exec api pytest -v

reset-db:
	docker compose exec -T db psql -U postgres -d capacity_connect -c "DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public; CREATE EXTENSION IF NOT EXISTS citext;"
	docker compose exec -T db psql -U postgres -d capacity_connect -f /docker-entrypoint-initdb.d/01_schema.sql
	docker compose exec -T db psql -U postgres -d capacity_connect -f /docker-entrypoint-initdb.d/02_seed_demo.sql
	@echo "Database successfully reset and seeded."

logs:
	docker compose logs -f

backup:
	@mkdir -p backups
	docker compose exec -T db pg_dump -U postgres capacity_connect > backups/backup_$$(date +%Y%m%d_%H%M%S).sql
	@echo "Database backup completed successfully in backups/ folder."

restore:
	@if [ -z "$(FILE)" ]; then echo "Error: specify backup file with FILE=backups/your_backup.sql"; exit 1; fi
	docker compose exec -T db psql -U postgres -d capacity_connect < $(FILE)
	@echo "Database restore completed from $(FILE)."
