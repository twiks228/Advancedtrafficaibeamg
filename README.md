# 🚦 Advanced Traffic AI for BeamNG.drive

![BeamNG.drive Version](https://img.shields.io/badge/BeamNG.drive-0.38.3-blue.svg)
![Version](https://img.shields.io/badge/Version-3.5.0-success.svg)
![Lua](https://img.shields.io/badge/Language-Lua-2b2b2b.svg)

A massive overhaul of the default traffic AI in BeamNG.drive. This mod breathes life into the city by introducing human-like driver personalities, realistic accident reactions, functional police dispatch, and deep interaction between the player and NPC vehicles.

No more mindless drones — the traffic now makes mistakes, gets angry, yields to your signals, forms traffic jams, and avoids head-on collisions.

## ✨ Key Features

### 🧠 Driver Personalities & Vehicle Condition
Every spawned vehicle gets a unique profile consisting of a vehicle class, mechanical condition, and driver personality:
*   **The Pensioner:** Drives slowly, brakes early, uses turn signals, always stops at yield signs.
*   **The Normal Driver:** Follows the flow of traffic, behaves predictably.
*   **The Aggressive Driver:** Speeds, tailgates, weaves through traffic (шашки), ignores yellow lights, and honks at slowpokes.
*   **The Distracted Driver:** Uses their phone, drifts in the lane, misses blind spots, brakes late, and randomly fluctuates speed.
*   **Vehicle Condition Simulation:** Cars can spawn as brand new, average, or absolute junkers (bad brakes, worn tires, steering play, and bad alignment pulling to one side).
*   **Buses:** Commercial buses will actively make periodic stops at the side of the road.

### 🚗 Deep Player Interaction
The AI actually sees what you are doing with your car's electrics:
*   **Horn:** Honking at AI makes them speed up or honk back (if aggressive).
*   **High Beams:** Flashing your lights from behind makes the AI yield and change lanes. Flashing at an intersection gives them the right-of-way.
*   **Turn Signals:** AI will slightly slow down to let you merge if you use your indicators.
*   **Hazard Lights:** AI slows down significantly when approaching you.
*   **Smart "Go-Around":** If you block the road, the AI will honk, wait, put on their turn signal, and *actually drive around you* in the oncoming lane.
*   **Wrong-Way Detection:** Driving towards AI in their lane will cause them to panic, flash their lights, honk, and swerve to the shoulder.

### 💥 Accidents, Traffic Jams & Police Dispatch
*   **Real Collision Detection:** Detects sudden G-forces and proximity speed differences.
*   **Post-Crash Logic:** AI stops, puts on hazard lights, and waits.
*   **Rubbernecking & Jams:** Passing AI will slow down to look at the crash (rubbernecking). If the road is blocked, realistic traffic jams form.
*   **Police Dispatch:** A police cruiser is automatically dispatched to major accidents. It spawns nearby, drives to the scene with sirens/lights, parks, investigates, and despawns after clearing the scene.
*   **UI Notifications:** Toast messages appear on screen notifying you of accidents, police dispatch, or if you are blocking traffic.

### 🛣️ Advanced Driving Rules
*   **Dynamic Speed Limits:** AI calculates safe speeds based on road width, upcoming curves (slows down for sharp turns), and steep hills.
*   **Virtual Signals & Right-of-Way:** Generates virtual traffic lights and stop signs at intersections. Understands the "Right-Hand Rule" (помеха справа) and cross-traffic yielding.
*   **Lane Discipline:** AI overtakes slow vehicles safely (checking oncoming traffic) and balances lane queues.

