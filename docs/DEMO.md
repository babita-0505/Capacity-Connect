# CAPACITY CONNECT demo script

## Start the application

```powershell
Copy-Item .env.example .env
docker compose up --build
```

Open `http://localhost`. The API documentation is available at `http://localhost:8000/docs`.

All seeded accounts use `Demo@1234`.

## Five-minute walkthrough

1. Sign in as `admin@imd.demo`. Open **User Approvals** and approve one of the pending `trainee193@imd.demo` through `trainee200@imd.demo` accounts.
2. Open **Admin dashboard** to show live platform KPIs, course participation, and assessment metrics. Open **Competency Mapping**, choose *Doppler Weather Radar*, and show the trainer evidence cards and skill-gap section.
3. Sign out and sign in as `trainer01@imd.demo`. Open **My Courses & Content** to show published training content. Use **Question Generator** with an owned PDF resource UUID to queue PDF-derived draft MCQs; the worker completes this in the background.
4. Sign out and sign in as `trainee001@imd.demo`. Open the course catalogue, enrol in a published course, open an assessment, answer questions, and submit. The score is computed only by the server.
5. Return to the public **Verify certificate** page at `/verify` and enter an issued `IMD-CC-2026-XXXXXX` certificate number after the enrolment-completion workflow queues certificate issuance.

## Validation commands

Run these in a second PowerShell terminal after the stack is running:

```powershell
docker compose exec api pytest -q
docker compose exec web npm run build
```

To restore the deterministic database seed:

```powershell
make reset-db
```

## Troubleshooting

- If port 80 is already in use, stop the conflicting web server or change the nginx host port in `docker-compose.yml`.
- First startup downloads container images and Python/Node packages, so it can take several minutes.
- The database seed runs only when the Postgres volume is first created. Use `make reset-db` to reload the supplied seed data.
