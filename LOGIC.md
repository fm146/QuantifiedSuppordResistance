# Support & Resistance (SR) Signal Strategy - Algorithm Documentation

This document explains the technical logic and algorithms used in the **SR Signal Strategy** Pine Script.

## 1. SR Level Detection (The Core)

### Auto-Detection Algorithm
- **Historical Scan**: The script scans the last **5000 Higher Timeframe (HTF)** bars (default 60m or 240m).
- **Price Clustering**: Since prices rarely hit exact levels identical to the penny every time, the algorithm uses a **Clustering Sensitivity** setting. If multiple price points are within this sensitivity range, they are grouped into one candidate level.
- **Top 20 Selection**: Out of all detected clusters, the script prioritizes levels with the highest number of historical "touches" (wick overlaps).
- **Manual Overrides**: Up to **10 manual levels** can be added. These take priority and are deduplicated against auto-detected levels to prevent visual clutter.

---

## 2. Signal Generation Logic

Each candle's interaction with the detected SR levels is analyzed to determine a **"Focus Level"**.

### Focus Level Selection:
1.  **Priority 1 (Breakout)**: If a candle crosses an SR level (previous close on one side, current close on the other), that level becomes the focus.
2.  **Priority 2 (Wick Touch)**: If no level is crossed, the SR level closest to the candle's wick extreme (Low for red/reversal, High for green/reversal) is selected as the focus.

### Signal Classification:

| Condition | Candle Color | Signal | Label |
| :--- | :--- | :--- | :--- |
| **Close > SR** | 🔴 Red | **Reversal (Bounce)** | **R** |
| **Close > SR** | 🟢 Green | **Continuation (Break)** | **C** |
| **Close < SR** | 🟢 Green | **Reversal (Rejection)** | **R** |
| **Close < SR** | 🔴 Red | **Continuation (Break)** | **C** |

---

## 3. Strategy Entry Rules

Signals are filtered through specific strategy rules before execution:

### 1. The "Sandwich" Requirement (SR Range)
To ensure balanced risk/reward, the strategy only enters a trade if the current price is **sandwiched** between two SR levels:
- There must be at least one SR level **above** the current price (to act as a potential Take Profit).
- There must be at least one SR level **below** the current price (to act as a potential Take Profit or Stop Loss).

### 2. Entry Modes
- **After Completed Trades (Only Flat)**: The strategy ignores new signals while a position is already open. It only initiates a new trade after the previous one hits SL or TP.
- **All Signals (Pyramiding)**: The strategy will take every valid signal, allowing multiple entries (scale-in) up to 10 positions simultaneously.

---

## 4. Risk Management (TP & SL)

Risk parameters are calculated dynamically at the moment of entry.

### Take Profit (TP)
- **Long**: TP is set to the **nearest SR level above** the entry price (skipping the SR level the entry was based on).
- **Short**: TP is set to the **nearest SR level below** the entry price.

### Stop Loss (SL) & Ratios
The SL is calculated mathematically based on the distance between the entry price and the TP.
- **Formula**: `SL Distance = TP Distance / Ratio`
- **Supported Ratios**: 1:1, 1:1.2, 1:1.5, 1:1.66, 1:2 (Risk-to-Reward).
- *Example*: At a 1:2 ratio, if the profit target is 100 ticks away, the SL will be set at 50 ticks away.

---

## 5. Visual Overlays & Debugging

- **SR Lines**: Orange horizontal lines extending across the chart with touch counts.
- **Signal Markers (C/R)**: Optional labels indicating which type of signal was generated on each bar.
- **Box Overlay**: 
    - **Green Zone**: Visualizes the profit potential from Entry to TP.
    - **Red Zone**: Visualizes the risk from Entry to SL.
    - **Labels**: Displays exact price levels for TP, SL, and Entry on the active trade.
