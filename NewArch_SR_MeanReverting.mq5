//+------------------------------------------------------------------+
//|                                  NewArchitecture_SRSystem.mq5    |
//|                                  Copyright 2026, Antigravity AI  |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Antigravity AI"
#property link "https://www.mql5.com"
#property version "1.00"
#property strict

#include <Trade\Trade.mqh>

// ─────────────────────────────────────────────
// CONFIG
// ─────────────────────────────────────────────
input group "Grid-Lock Settings" input double InpGrid =
    10.0;                        // Grid Size (Bucket)
input double InpMinDist = 20.0;  // Min Distance between locked levels
input int InpMinTap = 3;         // Min Taps to qualify
input double InpMinStr = 1.5;    // Min Strength to qualify
input double InpLambda = 0.0005; // Decay factor (LAM)

input group "Analysis settings"
input int InpLookback = 5000;             // History bars to analyze
input ENUM_TIMEFRAMES InpTF = PERIOD_H1;  // Timeframe for SR

input group "Strategy Settings"
input double InpRatio = 1.0;              // SL:TP Ratio (e.g. 1.0 for 1:1)
input int InpOvertime = 24;               // Overtime (Hours)
input double InpSigTol = 0.5;             // Signal Touch Tolerance (Ticks)
input uint InpMagic = 123456;             // Magic Number
input double InpLotSize = 0.1;            // Lot Size

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

// Trading 
CTrade m_trade;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
  m_trade.SetExpertMagicNumber(InpMagic);
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
    HandleSignals(); // Check for entries on new bar
    last_bar = iTime(_Symbol, InpTF, 0);
  }
  HandleOvertime(); // Check for force-close on every tick
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

// ─────────────────────────────────────────────────────────────
//  Signal Engine Helpers
// ─────────────────────────────────────────────────────────────

bool FindFocusSR(double close_0, double open_0, double close_1, double high_1,
                 double low_1, double &focus_sr) {
  int sz = ArraySize(ActiveLevels);
  if (sz == 0)
    return false;

  double tol = InpSigTol * _Point;

  // 1. Strictly Crossed by previous candle (close[1])
  // Wait, Pine code: (close[1] >= curr_l and close < curr_l) or (close[1] <=
  // curr_l and close > curr_l) In MQL5 OnTick after bar close, close[1] is the
  // bar that just closed.
  for (int i = 0; i < sz; i++) {
    double curr_l = ActiveLevels[i].price_bucket;
    // Check if close[1] (just finished) crossed curr_l vs close[2]
    // But Pine code uses close[1] vs close (current).
    // In MQL5 OnTick with iTime check, we are at the START of bar 0.
    // So bar 1 is the one that just completed.
    double close_2 = iClose(_Symbol, InpTF, 2);
    if ((close_2 >= curr_l && close_1 < curr_l) ||
        (close_2 <= curr_l && close_1 > curr_l)) {
      focus_sr = curr_l;
      return true;
    }
  }

  // 2. Nearest Wick Extreme of bar 1
  double min_dist_wick = 1e10;
  bool found_wick = false;
  bool is_red_1 = close_1 < iOpen(_Symbol, InpTF, 1);
  double target_p = is_red_1 ? low_1 : high_1;

  for (int i = 0; i < sz; i++) {
    double curr_l = ActiveLevels[i].price_bucket;
    if (high_1 >= curr_l - tol && low_1 <= curr_l + tol) {
      double dist = MathAbs(target_p - curr_l);
      if (dist < min_dist_wick) {
        min_dist_wick = dist;
        focus_sr = curr_l;
        found_wick = true;
      }
    }
  }

  return found_wick;
}

bool CheckInSRRange(double price, bool &has_above, bool &has_below) {
  has_above = false;
  has_below = false;
  int sz = ArraySize(ActiveLevels);
  double tol = InpSigTol * _Point;

  for (int i = 0; i < sz; i++) {
    double lvl = ActiveLevels[i].price_bucket;
    if (lvl > price + tol)
      has_above = true;
    if (lvl < price - tol)
      has_below = true;
  }
  return (has_above && has_below);
}

bool GetNearestSR(double price, bool look_above, double &found_sr) {
  int sz = ArraySize(ActiveLevels);
  double best_dist = 1e10;
  bool found = false;
  double tol = 2.0 * _Point; // Skip current SR

  for (int i = 0; i < sz; i++) {
    double lvl = ActiveLevels[i].price_bucket;
    if (look_above) {
      if (lvl > price + tol) {
        double dist = lvl - price;
        if (dist < best_dist) {
          best_dist = dist;
          found_sr = lvl;
          found = true;
        }
      }
    } else {
      if (lvl < price - tol) {
        double dist = price - lvl;
        if (dist < best_dist) {
          best_dist = dist;
          found_sr = lvl;
          found = true;
        }
      }
    }
  }
  return found;
}

void HandleSignals() {
  // Check if position already exists
  ulong ticket = 0;
  if (PositionSelectByMagic(InpMagic, ticket))
    return;

  double close_0 = iClose(_Symbol, InpTF, 0);
  double open_0 = iOpen(_Symbol, InpTF, 0);
  double close_1 = iClose(_Symbol, InpTF, 1);
  double high_1 = iHigh(_Symbol, InpTF, 1);
  double low_1 = iLow(_Symbol, InpTF, 1);

  double focus_sr = 0;
  if (!FindFocusSR(close_0, open_0, close_1, high_1, low_1, focus_sr))
    return;

  bool has_above, has_below;
  if (!CheckInSRRange(close_0, has_above, has_below))
    return;

  bool buy_signal = close_0 > focus_sr;
  bool sell_signal = close_0 < focus_sr;

  if (buy_signal) {
    double tp_price = 0;
    if (GetNearestSR(close_0, true, tp_price)) {
      double tp_dist = tp_price - close_0;
      double sl_dist = tp_dist / InpRatio;
      double sl_price = close_0 - sl_dist;
      m_trade.Buy(InpLotSize, _Symbol, close_0, sl_price, tp_price,
                  "SR Long Signal");
    }
  } else if (sell_signal) {
    double tp_price = 0;
    if (GetNearestSR(close_0, false, tp_price)) {
      double tp_dist = close_0 - tp_price;
      double sl_dist = tp_dist / InpRatio;
      double sl_price = close_0 + sl_dist;
      m_trade.Sell(InpLotSize, _Symbol, close_0, sl_price, tp_price,
                   "SR Short Signal");
    }
  }
}

void HandleOvertime() {
  ulong ticket = 0;
  if (!PositionSelectByMagic(InpMagic, ticket))
    return;

  datetime open_time = (datetime)PositionGetInteger(POSITION_TIME);
  if (TimeCurrent() - open_time >= (datetime)InpOvertime * 3600) {
    m_trade.PositionClose(ticket, "Force Closed - Overtime");
  }
}

bool PositionSelectByMagic(long magic, ulong &found_ticket) {
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong ticket = PositionGetTicket(i);
    if (PositionSelectByTicket(ticket)) {
      if (PositionGetInteger(POSITION_MAGIC) == magic &&
          PositionGetString(POSITION_SYMBOL) == _Symbol) {
        found_ticket = ticket;
        return true;
      }
    }
  }
  return false;
}
