//+------------------------------------------------------------------+
//|                                  NewArchitecture_SRSystem.mq5    |
//|                                  Copyright 2026, Antigravity AI  |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Antigravity AI"
#property link "https://www.mql5.com"
#property version "1.00"
#property strict

// ─────────────────────────────────────────────
// CONFIG
// ─────────────────────────────────────────────
input group "Grid-Lock Settings" input double InpGrid =
    10.0;                        // Grid Size (Bucket)
input double InpMinDist = 20.0;  // Min Distance between locked levels
input int InpMinTap = 3;         // Min Taps to qualify
input double InpMinStr = 1.5;    // Min Strength to qualify
input double InpLambda = 0.0005; // Decay factor (LAM)

input group "Analysis settings" input int InpLookback =
    5000;                                // History bars to analyze
input ENUM_TIMEFRAMES InpTF = PERIOD_H1; // Timeframe for SR

// ─────────────────────────────────────────────
// DATA STRUCTURES
// ─────────────────────────────────────────────
struct SRLevel {
  double price_bucket;
  int tap_count;
  int last_touch_idx;
  double strength;
  bool is_locked;
  datetime locked_time;
};

SRLevel LevelsMap[];    // All seen buckets
SRLevel ActiveLevels[]; // Locked levels

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
  ObjectsDeleteAll(0, "SR_");
  RunSRSystem();
  return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) { ObjectsDeleteAll(0, "SR_"); }

//+------------------------------------------------------------------+
//| Main logic                                                       |
//+------------------------------------------------------------------+
void OnTick() {
  static datetime last_bar = 0;
  if (iTime(_Symbol, InpTF, 0) != last_bar) {
    RunSRSystem();
    last_bar = iTime(_Symbol, InpTF, 0);
  }
}

// ─────────────────────────────────────────────────────────────
//  Logic implementation
// ─────────────────────────────────────────────────────────────

void RunSRSystem() {
  ArrayFree(LevelsMap);
  ArrayFree(ActiveLevels);

  double high[], low[];
  int copied = CopyHigh(_Symbol, InpTF, 0, InpLookback, high);
  CopyLow(_Symbol, InpTF, 0, InpLookback, low);

  if (copied < 3)
    return;

  for (int i = 1; i < copied - 1; i++) {
    // Detect Taps (Fractals)
    DetectAndProcessTap(high[i - 1], high[i], high[i + 1], true, i);
    DetectAndProcessTap(low[i - 1], low[i], low[i + 1], false, i);

    // Update strengths for all candidates and locked levels
    // In the python script, strength is computed at each step i
    double current_i = (double)i;
    for (int j = 0; j < ArraySize(LevelsMap); j++) {
      LevelsMap[j].strength = ComputeStrength(LevelsMap[j].tap_count,
                                              LevelsMap[j].last_touch_idx, i);

      // Try Locking
      if (!LevelsMap[j].is_locked) {
        if (LevelsMap[j].tap_count >= InpMinTap &&
            LevelsMap[j].strength >= InpMinStr) {
          if (IsFarFromExisting(LevelsMap[j].price_bucket)) {
            LevelsMap[j].is_locked = true;
            int sz = ArraySize(ActiveLevels);
            ArrayResize(ActiveLevels, sz + 1);
            ActiveLevels[sz] = LevelsMap[j];
          }
        }
      }
    }

    // Update strength for active levels as well (decaying over time)
    for (int j = 0; j < ArraySize(ActiveLevels); j++) {
      ActiveLevels[j].strength = ComputeStrength(
          ActiveLevels[j].tap_count, ActiveLevels[j].last_touch_idx, i);
    }
  }

  DrawSRLines();
}

void DetectAndProcessTap(double p1, double p2, double p3, bool is_high,
                         int idx) {
  bool is_tap = false;
  double p = 0;
  if (is_high && p2 > p1 && p2 > p3) {
    is_tap = true;
    p = p2;
  }
  if (!is_high && p2 < p1 && p2 < p3) {
    is_tap = true;
    p = p2;
  }

  if (!is_tap)
    return;

  double bucket = MathRound(p / InpGrid) * InpGrid;

  int map_idx = -1;
  for (int i = 0; i < ArraySize(LevelsMap); i++) {
    if (MathAbs(LevelsMap[i].price_bucket - bucket) < 0.0001) {
      map_idx = i;
      break;
    }
  }

  if (map_idx == -1) {
    map_idx = ArraySize(LevelsMap);
    ArrayResize(LevelsMap, map_idx + 1);
    LevelsMap[map_idx].price_bucket = bucket;
    LevelsMap[map_idx].tap_count = 0;
    LevelsMap[map_idx].is_locked = false;
  }

  LevelsMap[map_idx].tap_count++;
  LevelsMap[map_idx].last_touch_idx = idx;
}

double ComputeStrength(int taps, int last_idx, int current_idx) {
  double age = (double)(current_idx - last_idx);
  return (double)taps * MathExp(-InpLambda * age);
}

bool IsFarFromExisting(double p) {
  for (int i = 0; i < ArraySize(ActiveLevels); i++) {
    if (MathAbs(ActiveLevels[i].price_bucket - p) < InpMinDist)
      return false;
  }
  return true;
}

void DrawSRLines() {
  ObjectsDeleteAll(0, "SR_");
  for (int i = 0; i < ArraySize(ActiveLevels); i++) {
    string name = "SR_" + IntegerToString(i);
    ObjectCreate(0, name, OBJ_HLINE, 0, 0, ActiveLevels[i].price_bucket);

    ObjectSetInteger(0, name, OBJPROP_COLOR, clrYellow);
    ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
    ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);

    string lbl = "SR_L_" + IntegerToString(i);
    ObjectCreate(0, lbl, OBJ_TEXT, 0, TimeCurrent(),
                 ActiveLevels[i].price_bucket);
    ObjectSetString(
        0, lbl, OBJPROP_TEXT,
        "SR " + DoubleToString(ActiveLevels[i].price_bucket, 2) +
            " (Str: " + DoubleToString(ActiveLevels[i].strength, 2) + ")");
    ObjectSetInteger(0, lbl, OBJPROP_COLOR, clrWhite);
  }
}
