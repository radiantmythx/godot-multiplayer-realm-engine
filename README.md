# Godot Multiplayer ARPG (Realm → Zone Architecture)

This project is a **server-authoritative multiplayer ARPG prototype** built in Godot 4.4.

It uses a **three-layer architecture** inspired by Path of Exile:

```
Client  →  Realm  →  Zone
```

- **Realm** = control plane (authentication, matchmaking, instance management)  
- **Zone** = authoritative game simulation (movement, combat, entities)  
- **Client** = rendering + input → intent  

---

# 🚀 Running the Project (Exported Build)

## 1️⃣ Export the Project

From Godot:

- Export target: **Windows**
- Output file: `GameDev.exe`
- Export to the **repo root** (same directory as `project.godot`)

After export you should see:

```
GameDev.exe
GameDev.console.exe
GameDev.pck
```

---

## 2️⃣ Run the Full Debug Suite

Navigate to:

```
batch/
```

Run:

```
run_full_debug_suite.bat
```

This will:

1. Kill any running instances
2. Launch:
   - 1 Realm server
   - 3 Client instances

Each window will be prefixed with:

```
TEST_REALM
TEST_CLIENT_1
TEST_CLIENT_2
TEST_CLIENT_3
```

To manually stop everything:

```
run_closeall.bat
```

---

# 🔐 Authentication & Database Setup

This project includes a full authentication stack:

- **ASP.NET Core API**
- **PostgreSQL (Dockerized)**
- **BCrypt password hashing**
- **JWT-based Realm authentication**

Connection flow:

```
Client → Auth API → PostgreSQL
Client → Realm (JWT validation) → Zone
```

---

# 🗄 PostgreSQL (Docker)

The authentication database runs inside Docker.

## Port Mapping

```
Host:      5433
Container: 5432
```

Your API connects using:

```
Host=localhost;Port=5433;Database=realm_auth;Username=realm_user;Password=realm_password;
```

---

## Start the Database

From the API project directory:

```
docker compose up -d
```

This will:

- Pull `postgres:16`
- Create `realm_auth` database
- Execute `db/init/001_accounts.sql`
- Persist data in the `realm_pgdata` Docker volume

To reset the database:

```
docker compose down -v
```

⚠ This deletes all account data.

---

# 🌐 Authentication API (ASP.NET Core)

The Auth API runs at:

```
http://localhost:5131
```

## Start the API

From the API project:

```
dotnet run
```

You should see:

```
Now listening on: http://localhost:5131
```

---

## Available Endpoints

### Register

```
POST http://localhost:5131/api/auth/register
```

Example body:

```json
{
  "username": "testname",
  "email": "testname@email.com",
  "password": "password123"
}
```

Response:

```json
{
  "accountId": 1,
  "username": "testname",
  "token": "<JWT>"
}
```

---

### Login

```
POST http://localhost:5131/api/auth/login
```

Example body:

```json
{
  "usernameOrEmail": "testname",
  "password": "password123"
}
```

Response:

```json
{
  "accountId": 1,
  "username": "testname",
  "token": "<JWT>"
}
```

---

# 🔐 JWT Authentication Model

- JWT signed using **HMAC SHA256**
- Issued by API
- Validated by Realm
- Stateless (no DB lookup required during validation)

The client:

1. Logs in via HTTP
2. Receives JWT
3. Connects to Realm
4. Sends:

```
c_authenticate(jwt_token)
```

Realm validates signature + expiration before allowing entry.

---

# 🏗 Architecture Overview

## 🧠 Realm (Control Plane)

The **Realm** server is responsible for:

- Accepting authenticated client connections
- Validating JWTs
- Creating Zone instances
- Issuing join tickets
- Telling clients where to travel
- Managing instance lifecycle
- Receiving health heartbeats from zones

The Realm does **not** simulate gameplay.

---

## 🌍 Zone (Authoritative Simulation)

Each Zone instance:

- Runs on its own port
- Loads a map scene
- Simulates all gameplay
- Is 100% authoritative

The Zone handles:

- Player movement simulation
- Projectile simulation
- Target HP & destruction
- Hit detection
- Snapshot replication
- Combat replication

Clients do **not** simulate gameplay state.

Zones connect back to Realm via TCP for:

- READY notification
- HEARTBEAT
- SHUTDOWN signals

---

## 🧍 Client

The client:

1. Displays login/register UI
2. Authenticates via HTTP API
3. Connects to Realm
4. Sends JWT for validation
5. Receives travel order
6. Connects to Zone
7. Sends join ticket
8. Receives spawn data

The client is responsible for:

- Rendering players
- Rendering projectiles
- Rendering targets
- Handling camera
- Sending movement intent
- Sending fire intent

The client does NOT:

- Decide movement outcome
- Apply damage
- Validate hits
- Own entity state

All gameplay truth lives on the Zone.

---

# 🔁 Flow: Authenticated Client → Realm → Zone

## Step 1: Client Login

Client calls:

```
POST /api/auth/login
```

Receives JWT.

---

## Step 2: Client connects to Realm

Client launches with:

```
--mode=client
```

Then sends:

```
c_authenticate(jwt_token)
```

Realm validates JWT.

---

## Step 3: Realm issues travel order

Realm:

- Creates or selects a Zone
- Generates join ticket
- Sends:

```
s_travel_to_zone
{
  host,
  port,
  join_ticket,
  map_id
}
```

---

## Step 4: Client connects to Zone

Client:

- Disconnects from Realm
- Connects to Zone
- Sends:

```
c_join_instance(join_ticket, character_id)
```

---

## Step 5: Zone verifies ticket

Zone:

- Verifies ticket signature
- Validates instance_id
- Spawns authoritative player state
- Sends:

```
s_join_accepted
s_spawn_players_bulk
```

Client now renders the world.

---

# ⚔ Combat Model

## Movement

Client:

```
c_set_move_target(world_pos)
```

Zone:

- Simulates movement
- Computes yaw
- Sends:

```
s_apply_snapshots
```

Clients apply position + yaw.

---

## Projectiles

Client:

```
c_fire_projectile(from, dir)
```

Zone:

- Sanitizes direction
- Computes spawn position
- Spawns projectile
- Simulates movement
- Performs segment-sphere hit test
- Applies damage
- Sends:

```
s_spawn_projectile
s_projectile_snapshots
s_despawn_projectile
s_target_hp
s_break_target
```

Clients only render visuals.

---

# 📁 Project Structure (Simplified)

```
realm/         → control-plane server
zone/          → authoritative simulation server
client/        → rendering + input
shared/        → shared logic (tickets, rpc contract, utils)
batch/         → dev launch scripts
```

---

# 🔐 Server Authority Model

Zone is fully authoritative.

Clients are treated as:

> "Untrusted intent senders"

Zone validates:

- Join tickets
- Movement targets
- Fire directions
- Projectile TTL
- Collision

Clients:

- Never apply damage
- Never move themselves
- Never own world state

---

# 🧪 Debug / Testing

Launch everything:

```
batch/run_full_debug_suite.bat
```

Kill everything:

```
batch/run_closeall.bat
```

---

# 🎯 Current Features

✔ Multi-process Realm → Zone architecture  
✔ Instance-based zones (not spatial offsets)  
✔ Server-authoritative movement  
✔ Server-authoritative projectile simulation  
✔ Hit detection (segment-sphere)  
✔ Target HP + destruction replication  
✔ Snapshot replication at 60hz  
✔ JWT authentication system  
✔ Dockerized PostgreSQL database  
✔ ASP.NET Core Auth API  

---

# 🛠 Next Steps

Possible improvements:

- Character selection screen
- Persistent character storage
- Session revocation
- Refresh tokens
- Client-side prediction
- Projectile interpolation
- Lag compensation
- Zone scaling
- Headless zone builds
