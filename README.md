# Godot Multiplayer ARPG (Realm → Zone Architecture)

This project is a **server-authoritative multiplayer ARPG prototype**
built in Godot 4.4.

It uses a **three-layer architecture** inspired by Path of Exile:

    Client  →  Realm  →  Zone

-   **Realm** = control plane (matchmaking, instance management)
-   **Zone** = authoritative game simulation (movement, combat,
    entities)
-   **Client** = visual representation + input → intent

------------------------------------------------------------------------

# 🚀 Running the Project (Exported Build)

## 1️⃣ Export the Project

From Godot:

-   Export target: **Windows**
-   Output file: `GameDev.exe`
-   Export to the **repo root** (same directory as `project.godot`)

After export you should see:

    GameDev.exe
    GameDev.console.exe
    GameDev.pck

------------------------------------------------------------------------

## 2️⃣ Run the Full Debug Suite

Navigate to:

    batch/

Run:

    run_full_debug_suite.bat

This will:

1.  Kill any running instances
2.  Launch:
    -   1 Realm server
    -   3 Client instances

Each window will be prefixed with:

    TEST_REALM
    TEST_CLIENT_1
    TEST_CLIENT_2
    TEST_CLIENT_3

To manually stop everything:

    run_closeall.bat

------------------------------------------------------------------------

# 🏗 Architecture Overview

## 🧠 Realm (Control Plane)

The **Realm** server is responsible for:

-   Accepting initial client connections
-   Creating Zone instances
-   Issuing **join tickets**
-   Telling clients where to travel
-   Managing instance lifecycle
-   Health heartbeats from zones

The Realm does **not** simulate gameplay.

It only: - Verifies identity - Spawns zone processes - Routes players to
instances

------------------------------------------------------------------------

## 🌍 Zone (Authoritative Simulation)

Each Zone instance:

-   Runs on its own port
-   Loads a map scene
-   Simulates all gameplay
-   Is 100% authoritative

The Zone handles:

-   Player movement simulation
-   Projectile simulation
-   Target HP & destruction
-   Hit detection
-   Snapshot replication
-   Combat replication

Clients do **not** simulate gameplay state.

Zones connect back to Realm via TCP for:

-   READY notification
-   HEARTBEAT
-   SHUTDOWN signals

------------------------------------------------------------------------

## 🧍 Client

The client:

-   Connects to Realm first
-   Requests to enter hub
-   Receives travel order
-   Disconnects from Realm
-   Connects to Zone
-   Sends join ticket
-   Receives spawn data

The client is responsible for:

-   Rendering players
-   Rendering projectiles
-   Rendering targets
-   Handling camera
-   Sending movement intent
-   Sending fire intent

The client does NOT:

-   Decide movement outcome
-   Apply damage
-   Validate hits
-   Own entity state

All gameplay truth lives on the Zone.

------------------------------------------------------------------------

# 🔁 Flow: Client → Realm → Zone

## Step 1: Client connects to Realm

Client launches with:

    --mode=client

It connects to Realm and sends:

    c_request_enter_hub

------------------------------------------------------------------------

## Step 2: Realm issues travel order

Realm:

-   Creates or selects a Zone
-   Generates join ticket
-   Sends:

```{=html}
<!-- -->
```
    s_travel_to_zone
    {
      host,
      port,
      join_ticket,
      map_id
    }

------------------------------------------------------------------------

## Step 3: Client connects to Zone

Client:

-   Disconnects from Realm
-   Connects to Zone
-   Sends:

```{=html}
<!-- -->
```
    c_join_instance(join_ticket, character_id)

------------------------------------------------------------------------

## Step 4: Zone verifies ticket

Zone:

-   Verifies ticket signature
-   Validates instance_id
-   Spawns authoritative player state
-   Sends:

```{=html}
<!-- -->
```
    s_join_accepted
    s_spawn_players_bulk

Client now renders the world.

------------------------------------------------------------------------

# ⚔ Combat Model

### Movement

Client:

    c_set_move_target(world_pos)

Zone: - Simulates movement each tick - Computes yaw - Sends:

    s_apply_snapshots

Clients apply position + yaw.

------------------------------------------------------------------------

### Projectiles

Client:

    c_fire_projectile(from, dir)

Zone: - Sanitizes direction - Computes spawn position - Spawns
projectile - Simulates movement - Performs segment-sphere hit test -
Applies damage - Sends:

    s_spawn_projectile
    s_projectile_snapshots
    s_despawn_projectile
    s_target_hp
    s_break_target

Clients only render visuals.

------------------------------------------------------------------------

# 📁 Project Structure (Simplified)

    realm/         → control-plane server
    zone/          → authoritative simulation server
    client/        → rendering + input
    shared/        → shared logic (tickets, rpc contract, utils)
    batch/         → dev launch scripts

------------------------------------------------------------------------

# 🔐 Server Authority Model

Zone is fully authoritative.

Clients are treated as:

> "Untrusted intent senders"

Zone validates:

-   Join tickets
-   Movement targets
-   Fire directions
-   Projectile TTL
-   Collision

Clients:

-   Never apply damage
-   Never move themselves
-   Never own world state

------------------------------------------------------------------------

# 🧪 Debug / Testing

Launch everything:

    batch/run_full_debug_suite.bat

Kill everything:

    batch/run_closeall.bat

------------------------------------------------------------------------

# 🎯 Current Features

✔ Multi-process Realm → Zone architecture\
✔ Instance-based zones (not spatial offsets)\
✔ Server-authoritative movement\
✔ Server-authoritative projectile simulation\
✔ Hit detection (segment-sphere)\
✔ Target HP + destruction replication\
✔ Snapshot replication at 60hz\
✔ Modularized server and client systems

------------------------------------------------------------------------

# 🧭 Design Inspiration

Architecture inspired by:

-   Path of Exile
-   Modern MMO instance architecture
-   Dedicated simulation processes
-   Clean separation of control plane and gameplay plane

------------------------------------------------------------------------

# 🛠 Next Steps

Possible improvements:

-   Client-side prediction
-   Projectile interpolation
-   Lag compensation
-   Zone scaling
-   Process supervisor
-   Headless zone builds
-   Persistent characters
