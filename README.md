# GearVault — Containerized Equipment Locker & Lending Database

GearVault is a production-grade, containerized PostgreSQL database environment designed to manage physical equipment inventories, track active and historical loans, calculate real-time item availability, and enforce data persistence and disaster recovery with Docker.

---

## Table of Contents
1. [The Real-World Problem](#1-the-real-world-problem)
2. [Architecture Overview](#2-architecture-overview)
3. [Database Schema & Design](#3-database-schema--design)
4. [Docker Compose Configuration](#4-docker-compose-configuration)
5. [Named Volume & Persistence Strategy](#5-named-volume--persistence-strategy)
6. [Environment Setup & Quick Start](#6-environment-setup--quick-start)
7. [Startup and Shutdown Commands](#7-startup-and-shutdown-commands)
8. [Backup & Restore Procedure](#8-backup--restore-procedure)
9. [Acceptance Criteria & Test Results](#9-acceptance-criteria--test-results)
10. [End-to-End Demonstration Walkthrough](#10-end-to-end-demonstration-walkthrough)

---

## 1. The Real-World Problem

Organizations, educational media centers, and production houses frequently struggle with tracking high-value, shared physical hardware (e.g., cameras, lenses, microphones, projectors, and specialty adapters). Common operational pitfalls include:

- **Inventory Discrepancies**: Inability to immediately determine true shelf availability versus loaned stock.
- **Accidental Over-lending**: Approving loans beyond available physical units due to uncoordinated tracking.
- **Data Loss on Host or Container Restarts**: Ephemeral container filesystems destroying transactional history when containers stop, crash, or are upgraded.
- **Inadequate Disaster Recovery**: Lack of tested, non-blocking backup mechanisms that guarantee consistent restores without orphaned state.

**GearVault** resolves these challenges by providing:
1. **Automated Schema & Constraints**: Enforced integrity (non-negative stock, valid loan quantities, chronological return dates, and foreign keys).
2. **Dynamic Availability View (`equipment_availability`)**: Real-time calculation of remaining shelf quantity subtracting active loans (`returned_at IS NULL`) from total inventory.
3. **Persistent Named Volumes**: Decoupling container lifecycles from the database data directory (`PGDATA`).
4. **Point-in-Time Backup & Restore**: Repeatable custom-format dump (`pg_dump -Fc`) and restore (`pg_restore --clean`) pipelines.

---

## 2. Architecture Overview

GearVault packages the database engine, initialization pipelines, volume mounts, and network exposure into a reproducible Docker Compose architecture.

```
+-----------------------------------------------------------------------------------+
|                                 HOST SYSTEM                                       |
|                                                                                   |
|  +---------------------------+                      +--------------------------+  |
|  |       SQL Init Scripts    |                      |      Host Backup Dir     |  |
|  |     (./db/init/*.sql)     |                      |      (./backups/)        |  |
|  +-------------+-------------+                      +------------+-------------+  |
|                | (Read-Only Mount)                               ^                |
|                v                                                 |                |
|  +---------------------------------------------------------------+-------------+  |
|  | Docker Container: gearvault-db (postgres:16-alpine)           |             |  |
|  |                                                               | docker cp   |  |
|  |   +--------------------------+     +--------------------------+             |  |
|  |   | /docker-entrypoint-initdb|     | Dump File (/tmp/gear.dump)             |  |
|  |   +--------------------------+     +--------------------------+             |  |
|  |                | (Runs only on fresh init)                                  |  |
|  |                v                                                            |  |
|  |   +-------------------------------------------------------+                 |  |
|  |   | PostgreSQL Engine (gear_locker DB, gear_user)         |                 |  |
|  |   | - Schema: equipment, loans                            |                 |  |
|  |   | - View: equipment_availability                        |                 |  |
|  |   +---------------------------+---------------------------+                 |  |
|  |                               | (Stores PGDATA)                             |  |
|  +-------------------------------|---------------------------------------------+  |
|                                  v                                                |
|                   +-------------------------------+                               |
|                   | Docker Named Volume:          |                               |
|                   | gear_data                     |                               |
|                   +-------------------------------+                               |
+-----------------------------------------------------------------------------------+
```

### Component Breakdown
- **Engine**: `postgres:16-alpine` (lightweight, secure, and performant).
- **Service Name**: `db` | **Container Name**: `gearvault-db`.
- **Database / User**: `gear_locker` / `gear_user`.
- **Exposed Port**: `5432:5432` on localhost.
- **Entrypoint Mount**: `./db/init` mounted read-only to `/docker-entrypoint-initdb.d:ro`.
- **Storage**: Docker named volume `gear_data` mapped to `/var/lib/postgresql/data`.

---

## 3. Database Schema & Design

The database schema is organized into three sequenced scripts in `db/init/`:

### 3.1. Tables & Constraints (`01_schema.sql`)

```sql
CREATE TABLE equipment (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    category TEXT NOT NULL,
    total_quantity INTEGER NOT NULL CHECK (total_quantity >= 0)
);

CREATE TABLE loans (
    id SERIAL PRIMARY KEY,
    equipment_id INTEGER NOT NULL REFERENCES equipment(id) ON DELETE CASCADE,
    borrower_name TEXT NOT NULL,
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    borrowed_at DATE NOT NULL,
    returned_at DATE,
    CONSTRAINT chk_loan_returned_at CHECK (returned_at IS NULL OR returned_at >= borrowed_at)
);
```

#### Constraints Implemented:
- `PRIMARY KEY`: Auto-incrementing synthetic key (`SERIAL`) for unique identification.
- `NOT NULL`: Applied to vital fields (`name`, `category`, `total_quantity`, `equipment_id`, `borrower_name`, `quantity`, `borrowed_at`).
- `FOREIGN KEY`: `equipment_id` links loans to valid equipment records with `ON DELETE CASCADE`.
- `CHECK (total_quantity >= 0)`: Ensures inventory cannot hold negative stock.
- `CHECK (quantity > 0)`: Enforces that loans must reserve at least one unit.
- `CHECK (returned_at IS NULL OR returned_at >= borrowed_at)`: Guarantees logical date sequencing.

### 3.2. Initial Seed Data (`02_seed.sql`)

Seeds the required 5 equipment items and 4 loan transactions (2 active, 2 returned):

```sql
INSERT INTO equipment (name, category, total_quantity)
VALUES
('Camera Kit', 'Photography', 3),
('Tripod', 'Photography', 5),
('Wireless Mic', 'Audio', 4),
('Projector', 'Presentation', 2),
('HDMI Cable', 'Accessories', 10);

INSERT INTO loans (equipment_id, borrower_name, quantity, borrowed_at, returned_at)
VALUES
(1, 'Alice Smith', 1, '2026-11-20', NULL),                -- Active (1 Camera Kit)
(2, 'Bob Jones', 2, '2026-11-15', '2026-11-18'),          -- Returned (2 Tripods)
(3, 'Charlie Brown', 1, '2026-11-21', NULL),             -- Active (1 Wireless Mic)
(4, 'Diana Prince', 1, '2026-11-19', '2026-11-22');       -- Returned (1 Projector)
```

### 3.3. Availability View (`03_view.sql`)

The `equipment_availability` view computes remaining stock dynamically:

```sql
CREATE OR REPLACE VIEW equipment_availability AS
SELECT
    e.id,
    e.name,
    e.category,
    e.total_quantity,
    e.total_quantity - COALESCE(SUM(l.quantity), 0) AS available_quantity
FROM equipment e
LEFT JOIN loans l
    ON e.id = l.equipment_id
    AND l.returned_at IS NULL
GROUP BY e.id, e.name, e.category, e.total_quantity;
```

---

## 4. Docker Compose Configuration

The service is configured in `compose.yaml`:

```yaml
services:
  db:
    image: postgres:16-alpine
    container_name: gearvault-db
    environment:
      - POSTGRES_USER=gear_user
      - POSTGRES_PASSWORD=gear_password
      - POSTGRES_DB=gear_locker
    ports:
      - "5432:5432"
    volumes:
      - gear_data:/var/lib/postgresql/data
      - ./db/init:/docker-entrypoint-initdb.d:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $$POSTGRES_USER -d $$POSTGRES_DB"]
      interval: 5s
      timeout: 3s
      retries: 10
      start_period: 5s
    restart: unless-stopped

volumes:
  gear_data:
```

### Highlights:
- **Built-in Healthcheck**: Uses `pg_isready` targeting `POSTGRES_USER` and `POSTGRES_DB`.
- **Dynamic Startup Readiness**: Probes the socket until PostgreSQL is accepting connections.
- **Read-Only Volume Mount**: Protects host SQL init files (`:ro`).

---

## 5. Named Volume & Persistence Strategy

### Ephemeral vs. Persistent Storage
A container's root filesystem is **ephemeral**. Any files written inside the container lifecycle (without volumes) are lost permanently when the container is removed (`docker rm` or `docker compose down`).

To prevent data loss, GearVault utilizes a Docker **named volume** (`gear_data`):
1. **Host Isolation**: Docker manages the physical storage directory of the named volume on the host system.
2. **Container Independence**: The lifecycle of `gear_data` is decoupled from the lifecycle of the `gearvault-db` container.
3. **Re-attachment**: When a container is stopped and removed with `docker compose down`, the named volume remains intact. Starting the service again with `docker compose up -d` immediately mounts `gear_data` back to `/var/lib/postgresql/data`.

### Initialization Behavior (`/docker-entrypoint-initdb.d`)
The official PostgreSQL Docker image executes scripts in `/docker-entrypoint-initdb.d` **only once**:
- **Condition**: Executed when the target data directory (`PGDATA`) is empty (first initialization).
- **Subsequent Restarts**: When PostgreSQL boots with an existing data directory in `gear_data`, it skips `/docker-entrypoint-initdb.d` to avoid altering or overwriting existing user data.
- **Volume Removal (`down -v`)**: When explicitly running `docker compose down -v`, the volume is destroyed. On the next `docker compose up -d`, PostgreSQL encounters an empty data directory and reruns all SQL initialization scripts from scratch.

---

## 6. Environment Setup & Quick Start

### Prerequisites
- Docker Engine & Docker Compose v2+ installed.
- Terminal / PowerShell.

### 1-Minute Launch
```bash
# 1. Clone repository and navigate to root
cd GearVault

# 2. Launch the database stack in the background
docker compose up -d

# 3. Confirm container health
docker compose ps

# 4. View initialization logs
docker compose logs db
```

---

## 7. Startup and Shutdown Commands

| Task | Command | Effect |
| :--- | :--- | :--- |
| **Start Service** | `docker compose up -d` | Starts container in detached mode; initializes DB if volume is empty. |
| **Check Health & Status** | `docker compose ps` | Displays container state, port bindings, and health (`healthy`). |
| **Stream Database Logs** | `docker compose logs -f db` | Inspect startup logs, queries, and connection errors. |
| **Open Interactive PSQL** | `docker compose exec -it db psql -U gear_user -d gear_locker` | Opens interactive PostgreSQL CLI. |
| **Run One-Off Query** | `docker compose exec db psql -U gear_user -d gear_locker -c "QUERY"` | Runs SQL query and prints tabular result. |
| **Standard Shutdown** | `docker compose down` | Stops and removes container and network. **Retains named volume**. |
| **Purge Everything** | `docker compose down -v` | Stops and removes container, network, and **deletes named volume**. |

---

## 8. Backup & Restore Procedure

GearVault uses PostgreSQL's custom-format (`-Fc`) archive via `pg_dump` and `pg_restore`. Custom format is compressed, enables flexible table-level selection, and supports clean replacement.

### Step 1: Create Backup
Execute `pg_dump` inside the container:
```bash
docker compose exec -T db pg_dump \
  -U gear_user \
  -d gear_locker \
  -Fc \
  -f /tmp/gear.dump
```

### Step 2: Transfer Backup to Host
Safely copy the archive out of the container to `./backups/`:
```bash
docker cp gearvault-db:/tmp/gear.dump ./backups/gear.dump
```

### Step 3: Copy Backup into Container (Disaster Recovery)
If restoring into a new or modified container:
```bash
docker cp ./backups/gear.dump gearvault-db:/tmp/gear.dump
```

### Step 4: Perform Restoration
Execute `pg_restore` with flags to drop existing objects before recreating them:
```bash
docker compose exec db pg_restore \
  --clean \
  --if-exists \
  --no-owner \
  --exit-on-error \
  -U gear_user \
  -d gear_locker \
  /tmp/gear.dump
```
- `--clean`: Drops database objects (tables, views) prior to recreating them.
- `--if-exists`: Avoids errors if an object does not exist prior to dropping.
- `--no-owner`: Skips setting original object ownership to avoid role permission conflicts.
- `--exit-on-error`: Aborts immediately if an unhandled restore error is encountered.

---

## 9. Acceptance Criteria & Test Results

| Test ID | Test Description | Command | Expected Result | Status |
| :---: | :--- | :--- | :--- | :---: |
| **T-01** | Database Startup | `docker compose up -d` | Container starts in detached mode | **PASSED** |
| **T-02** | Health Check | `docker compose ps` | Container transitions to `(healthy)` | **PASSED** |
| **T-03** | Schema Initialization | `docker compose logs db` | Runs `01_schema.sql`, `02_seed.sql`, `03_view.sql` | **PASSED** |
| **T-04** | Initial Seed Verification | `psql -c "SELECT COUNT(*) FROM equipment;"` | 5 equipment records, 4 loan records | **PASSED** |
| **T-05** | View Availability Query | `psql -c "SELECT * FROM equipment_availability;"` | Calculates `total_quantity - active_loans` | **PASSED** |
| **T-06** | Standard Shutdown | `docker compose down` | Container stopped and removed | **PASSED** |
| **T-07** | Persistence Verification | Insert record -> `down` -> `up -d` -> `SELECT` | New record survives restart | **PASSED** |
| **T-08** | Custom Backup Creation | `pg_dump -Fc` + `docker cp` | Valid `.dump` file written to `./backups/` | **PASSED** |
| **T-09** | Database Restore | Insert dummy record -> `pg_restore` | Dummy record removed; original backup state restored | **PASSED** |
| **T-10** | Volume Wipe & Fresh Start | `docker compose down -v` -> `up -d` | Volume purged; init scripts re-seed fresh database | **PASSED** |

---

## 10. End-to-End Demonstration Walkthrough

Below are the exact commands and outputs demonstrating the full lifecycle of GearVault:

### 1. Fresh Startup & Health Status
```powershell
PS D:\GearVault> docker compose up -d
[+] Running 2/2
 ✔ Network gearvault_default  Created
 ✔ Container gearvault-db     Started

PS D:\GearVault> docker compose ps
NAME           IMAGE                STATUS                            PORTS
gearvault-db   postgres:16-alpine   Up 5 seconds (healthy)            0.0.0.0:5432->5432/tcp
```

### 2. Querying Equipment Availability
```powershell
PS D:\GearVault> docker compose exec db psql -U gear_user -d gear_locker -c "SELECT * FROM equipment_availability ORDER BY id;"
 id |     name     |   category   | total_quantity | available_quantity 
----+--------------+--------------+----------------+--------------------
  1 | Camera Kit   | Photography  |              3 |                  2
  2 | Tripod       | Photography  |              5 |                  5
  3 | Wireless Mic | Audio        |              4 |                  3
  4 | Projector    | Presentation |              2 |                  2
  5 | HDMI Cable   | Accessories  |             10 |                 10
(5 rows)
```
*(Note: Camera Kit has 1 active loan so 2 are available; Tripod was returned so all 5 are available; Wireless Mic has 1 active loan so 3 are available; Projector was returned so 2 are available; HDMI Cable has 0 loans).*

### 3. Testing Data Persistence Across Restarts
```powershell
# 1. Insert a new item
PS D:\GearVault> docker compose exec db psql -U gear_user -d gear_locker -c "INSERT INTO equipment (name, category, total_quantity) VALUES ('LED Ring Light', 'Lighting', 6);"
INSERT 0 1

# 2. Stop and remove the container
PS D:\GearVault> docker compose down
[+] Running 2/2
 ✔ Container gearvault-db  Removed
 ✔ Network gearvault_default  Removed

# 3. Bring container back up
PS D:\GearVault> docker compose up -d
[+] Running 2/2
 ✔ Network gearvault_default  Created
 ✔ Container gearvault-db     Started

# 4. Verify record persists
PS D:\GearVault> docker compose exec db psql -U gear_user -d gear_locker -c "SELECT * FROM equipment WHERE name = 'LED Ring Light';"
 id |      name      | category | total_quantity 
----+----------------+----------+----------------
  6 | LED Ring Light | Lighting |              6
(1 row)
```

### 4. Creating Backup
```powershell
PS D:\GearVault> docker compose exec -T db pg_dump -U gear_user -d gear_locker -Fc -f /tmp/gear.dump
PS D:\GearVault> docker cp gearvault-db:/tmp/gear.dump ./backups/gear.dump
```

### 5. Restoring Backup After Modifying Records
```powershell
# 1. Insert accidental / temporary record
PS D:\GearVault> docker compose exec db psql -U gear_user -d gear_locker -c "INSERT INTO equipment (name, category, total_quantity) VALUES ('Temporary Drone', 'Aviation', 1);"
INSERT 0 1

# 2. Copy backup into container and execute restore
PS D:\GearVault> docker cp ./backups/gear.dump gearvault-db:/tmp/gear.dump
PS D:\GearVault> docker compose exec db pg_restore --clean --if-exists --no-owner --exit-on-error -U gear_user -d gear_locker /tmp/gear.dump

# 3. Verify 'Temporary Drone' is gone and pre-backup state is restored
PS D:\GearVault> docker compose exec db psql -U gear_user -d gear_locker -c "SELECT * FROM equipment ORDER BY id;"
 id |      name      |   category   | total_quantity 
----+----------------+--------------+----------------
  1 | Camera Kit     | Photography  |              3
  2 | Tripod         | Photography  |              5
  3 | Wireless Mic   | Audio        |              4
  4 | Projector      | Presentation |              2
  5 | HDMI Cable     | Accessories  |             10
  6 | LED Ring Light | Lighting     |              6
(6 rows)
```
The temporary record is removed, and database consistency is restored.
