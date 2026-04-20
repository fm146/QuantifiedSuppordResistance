import pandas as pd
import threading
import json
import os
import asyncio
import tkinter as tk
from tkinter import filedialog
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import uvicorn
from lightweight_charts import Chart

# ─────────────────────────────────────────────────────────────
#  API SERVER (FastAPI)
# ─────────────────────────────────────────────────────────────
app = FastAPI()

# Add CORS support
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

manual_levels = []
SAVE_FILE    = "manual_levels.json"
TXT_FILE     = "sr_levels.txt"
chart_global = None

class LevelBody(BaseModel):
    price: float

@app.post("/copy_to_mt5")
def copy_to_mt5():
    """Copy sr_levels.txt to MT5 Common Data folder for Strategy Tester."""
    import shutil
    try:
        # Common data path on Windows
        appdata = os.environ.get('AppData')
        if not appdata:
            return {"status": "error", "message": "AppData not found"}
        
        # This is the standard 'Common' folder for all MT5 terminals
        common_path = os.path.join(os.path.dirname(appdata), 'Roaming', 'MetaQuotes', 'Terminal', 'Common', 'Files')
        
        if not os.path.exists(common_path):
            os.makedirs(common_path, exist_ok=True)
            
        dest = os.path.join(common_path, TXT_FILE)
        shutil.copy2(TXT_FILE, dest)
        print(f"  → Successfully copied to MT5 Common: {dest}")
        return {"status": "success", "path": dest}
    except Exception as e:
        print(f"  ! Copy Failed: {e}")
        return {"status": "error", "message": str(e)}

@app.get("/ping")
def get_levels():
    return {"levels": manual_levels}

@app.get("/levels_raw")
def get_levels_raw():
    return ",".join([str(x) for x in manual_levels])

@app.post("/add_level")
def add_level(body: LevelBody):
    price = round(body.price, 5)
    _add_level_logic(price)
    return {"levels": manual_levels}

def _add_level_logic(price):
    global manual_levels
    if price not in manual_levels:
        manual_levels.append(price)
        manual_levels.sort()
        _save_levels()
        if chart_global is not None:
            chart_global.horizontal_line(price, color="rgba(0, 255, 136, 0.8)", text=f"SR: {price}")
        print(f"  + Added level: {price}")

@app.delete("/clear_levels")
def clear_levels():
    global manual_levels
    manual_levels = []
    _save_levels()
    print("  ! All levels cleared")
    return {"levels": manual_levels}

def _save_levels():
    with open(SAVE_FILE, "w") as f:
        json.dump(manual_levels, f)
    with open(TXT_FILE, "w") as f:
        f.write(",".join([str(x) for x in manual_levels]))

def _load_levels():
    global manual_levels
    if os.path.exists(SAVE_FILE):
        try:
            with open(SAVE_FILE, "r") as f:
                manual_levels = json.load(f)
            print(f"  → Loaded {len(manual_levels)} existing levels.")
        except:
            manual_levels = []

# ─────────────────────────────────────────────────────────────
#  CALLBACKS (Robust Signatures)
# ─────────────────────────────────────────────────────────────
def on_chart_click(chart_instance, arg1, arg2=None, *args, **kwargs):
    """Callback for chart clicks. Detects which argument is the price."""
    # Debug: Print what we received
    # print(f"DEBUG: arg1={arg1}, arg2={arg2}")
    
    # Logic: Usually price is the one that isn't a massive timestamp-like number
    # arg1 is typically price, arg2 is time. 
    # But if arg1 > 1000000000 and arg2 is smaller, arg2 is likely the price.
    
    selected_price = None
    
    # Handle based on typical MT5 price vs unix timestamp magnitudes
    try:
        val1 = float(arg1) if arg1 is not None else 0
        val2 = float(arg2) if arg2 is not None else 0
        
        # If val1 looks like a timestamp (e.g. BTC prices could be high, but timestamps are 10^9)
        # We assume things > 10^9 are timestamps unless it's a very specific asset
        if val1 > 1000000000 and val2 > 0 and val2 < 1000000000:
            selected_price = val2
        else:
            selected_price = val1
            
    except:
        selected_price = arg1

    if selected_price:
        _add_level_logic(round(float(selected_price), 5))

def on_sync_hotkey(chart_instance, *args, **kwargs):
    """Hotkey Shift+S triggers copy to MT5 folder."""
    print("\n  [SYNC] Synchronizing levels to MT5...")
    res = copy_to_mt5()
    if res.get("status") == "success":
        print(f"  ✓ SYNC OK: {res.get('path')}")
    else:
        print(f"  × SYNC FAILED: {res.get('message')}")

def on_clear_hotkey(chart_instance, *args, **kwargs):
    """Hotkey Shift+C clears levels."""
    clear_levels()
    print("  ! Levels cleared in memory and API.")
    print("  (Note: Visual lines on chart remain until restart)")

# ─────────────────────────────────────────────────────────────
#  CSV LOADING
# ─────────────────────────────────────────────────────────────
def load_csv(file_path):
    df = pd.read_csv(file_path, sep=None, engine="python")
    col_map = {
        "date":      ["date", "Time", "time", "datetime", "Date", "Local time", "TIMESTAMP", "<DATE>", "DATE"],
        "time_part": ["<TIME>", "TIME"],
        "open":      ["open", "Open", "O", "<OPEN>", "OPEN"],
        "high":      ["high", "High", "H", "<HIGH>", "HIGH"],
        "low":       ["low",  "Low",  "L", "<LOW>",  "LOW"],
        "close":     ["close", "Close", "C", "<CLOSE>", "CLOSE"],
        "volume":    ["volume", "Volume", "Tick volume", "V", "vol", "<TICKVOL>", "<VOL>", "TICKVOL"],
    }
    final_rename = {}
    found = set()
    for col in df.columns:
        cleaned = col.strip()
        for target, aliases in col_map.items():
            if (cleaned in aliases or cleaned.lower() == target) and target not in found:
                final_rename[col] = target
                found.add(target)
                break
    df = df.rename(columns=final_rename)
    if "date" in df.columns and "time_part" in df.columns:
        df["date"] = df["date"].astype(str) + " " + df["time_part"].astype(str)
        df = df.drop(columns=["time_part"])
    df["date"] = pd.to_datetime(df["date"])
    df = df.sort_values("date").reset_index(drop=True)
    return df

# ─────────────────────────────────────────────────────────────
#  MAIN GUI
# ─────────────────────────────────────────────────────────────
def run_gui():
    global chart_global

    root = tk.Tk()
    root.withdraw()
    file_path = filedialog.askopenfilename(title="Select MT5 Data CSV")
    root.destroy()

    if not file_path: return

    try:
        df = load_csv(file_path)
    except Exception as e:
        print(f"CSV Error: {e}"); return

    chart = Chart(toolbox=True, width=1280, height=720)
    chart_global = chart
    chart.legend(visible=True)
    chart.set(df)

    # 1. Load Existing
    _load_levels()
    for p in manual_levels:
        chart.horizontal_line(p, color="rgba(255, 165, 0, 0.7)", text=f"SR: {p}")

    # 2. Event Listeners
    chart.events.click += on_chart_click
    chart.hotkey('shift', 'C', on_clear_hotkey)
    chart.hotkey('shift', 'S', on_sync_hotkey)
    
    # 3. Fast Scroll JS (Simplified to avoid None errors)
    js_scroll = """
    window.addEventListener('wheel', function(e) {
        if (e.altKey && window.chart) {
            e.preventDefault();
            var ts = window.chart.timeScale();
            var jump = e.deltaY > 0 ? -100 : 100;
            if (ts && typeof ts.scrollToPosition === 'function') {
                ts.scrollToPosition((ts.scrollPosition ? ts.scrollPosition() : 0) + jump, true);
            }
        }
    }, { passive: false });
    """
    chart.run_script(js_scroll)

    print("\n" + "═"*60)
    print("  SR MANAGER v5.5 - HOTKEY EDITION (SUPER STABLE)")
    print("═"*60)
    print("  CONTROLS:")
    print("  • LEFT CLICK    : Add SR Level at Price")
    print("  • SHIFT + S     : SYNC to MT5 (Copy to Folder)")
    print("  • SHIFT + C     : CLEAR All Levels")
    print("  • ALT + SCROLL  : Fast Jump (±100 Bars)")
    print("-" * 60)
    print(f"  API ENDPOINT   : http://127.0.0.1:8000/levels_raw")
    print("  MT5 COMMON DIR : Detecting...")
    print("═"*60 + "\n")

    chart.show(block=True)

def start_api():
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    config = uvicorn.Config(app, host="127.0.0.1", port=8000, log_level="error")
    uvicorn.Server(config).run()

if __name__ == "__main__":
    api_thread = threading.Thread(target=start_api, daemon=True)
    api_thread.start()
    run_gui()
