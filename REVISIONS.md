# Support & Resistance Project Revisions

Use this document to track all requested revisions, bugs, and new features for the **SR Level Debugger** Pine Script.

## 🚀 Current Status: [Debugging Phase - SR Detection & Marking]

| Feature | Status | Description |
| :--- | :--- | :--- |
| **Auto-SR (20 Levels)** | ✅ Active | Scans 5000 HTF bars for price clusters. |
| **Manual SR (10 Levels)** | ✅ Active | Includes user-defined prices in the pool. |
| **Orange SR Lines** | ✅ Active | Infinite horizontal lines with touch counts. |
| **Breakout Marking** | ✅ Active | Tiny arrows on candles that touch and close above/below. |
| **Touch Counter** | ✅ Strict | Labels show exact price overlap count for both Auto & Manual. |

---

## 📝 Planned Revisions & Tasks

*Please add your revision requests below:*

1. [ ] **Signal Generation (Paused)**: Re-enable Buy/Sell logic once SR detection is perfect.
2. [ ] ...
3. [ ] ...

---

## ✅ Completed Tasks

- [x] Switched from Strategy to Indicator for easier debugging.
- [x] Implemented "Strict Touch" rule (Wick intersection only).
- [x] Added Clustering Sensitivity input for fine-tuning.
- [x] Shrunk breakout icons to `size.tiny`.
- [x] Implemented 5000-bar historical scan.

---

*Last Updated: 2026-03-20 01:27*
