//+------------------------------------------------------------------+
//|                                NewArch_SR_MeanReverting_ATR.mq5  |
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
input group "ATR-Adaptive Settings"
input int InpATR_Period = 10;        // ATR Period for volatility (H1 based)
input double InpGridFactor = 0.15;   // Grid Size = ATR * Factor
input double InpRadiusFactor = 0.5;  // Locking Radius = ATR * Factor
input int InpMinTap = 3;             // Min Taps to qualify
input double InpMinStr = 1.5;        // Min Strength to qualify
input double InpLambda = 0.0005;     // Decay factor (LAM)

input group "Analysis settings"
input int InpLookback = 5000;             // History bars to analyze
input ENUM_TIMEFRAMES InpTF = PERIOD_H1;  // Timeframe for SR

input group "Strategy Settings"
input double InpRatio = 1.0;              // SL:TP Ratio
input int InpOvertime = 24;               // Overtime (Hours)
input double InpSigTol = 0.5;             // Signal Touch Tolerance (Ticks)
input uint InpMagic = 123457;             // Magic Number
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

int atr_handle;
CTrade m_trade;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
  m_trade.SetExpertMagicNumber(InpMagic);
  // Initialize ATR from H1 as requested
  atr_handle = iATR(_Symbol, PERIOD_H1, InpATR_Period);
  if (atr_handle == INVALID_HANDLE)
    return (INIT_FAILED);

  ObjectsDeleteAll(0, "SR_");
  RunSRSystem();
  return (INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
  IndicatorRelease(atr_handle);
  ObjectsDeleteAll(0, "SR_");
}

void OnTick() {
  static datetime last_sr_update = 0;
  static datetime last_signal_check = 0;

  // 1. Update SR Levels only once per Daily bar for stability
  if (iTime(_Symbol, PERIOD_D1, 0) != last_sr_update) {
    RunSRSystem();
    last_sr_update = iTime(_Symbol, PERIOD_D1, 0);
  }

  // 2. Check for entry signals on primary timeframe (e.g. H1)
  if (iTime(_Symbol, InpTF, 0) != last_signal_check) {
    HandleSignals();
    last_signal_check = iTime(_Symbol, InpTF, 0);
  }

  // 3. Force close management on every tick
  HandleOvertime();
}

// ─────────────────────────────────────────────────────────────
//  Logic implementation
// ─────────────────────────────────────────────────────────────

void RunSRSystem() {
  ArrayFree(LevelsMap);
  ArrayFree(ActiveLevels);

  double atr_buffer[];
  if (CopyBuffer(atr_handle, 0, 0, 1, atr_buffer) < 1)
    return;
  double current_atr = atr_buffer[0];
  double dynamic_grid = current_atr * InpGridFactor;
  double dynamic_radius = current_atr * InpRadiusFactor;

  if (dynamic_grid <= 0)
    dynamic_grid = _Point * 10;

  double high[], low[];
  int copied = CopyHigh(_Symbol, InpTF, 0, InpLookback, high);
  CopyLow(_Symbol, InpTF, 0, InpLookback, low);

  if (copied < 3)
    return;

  for (int i = 1; i < copied - 1; i++) {
    DetectAndProcessTap(high[i - 1], high[i], high[i + 1], true, i,
                        dynamic_grid);
    DetectAndProcessTap(low[i - 1], low[i], low[i + 1], false, i, dynamic_grid);

    for (int j = 0; j < ArraySize(LevelsMap); j++) {
      LevelsMap[j].strength = ComputeStrength(LevelsMap[j].tap_count,
                                              LevelsMap[j].last_touch_idx, i);

      if (!LevelsMap[j].is_locked) {
        if (LevelsMap[j].tap_count >= InpMinTap &&
            LevelsMap[j].strength >= InpMinStr) {
          if (IsFarFromExisting(LevelsMap[j].price_bucket, dynamic_radius)) {
            LevelsMap[j].is_locked = true;
            int sz = ArraySize(ActiveLevels);
            ArrayResize(ActiveLevels, sz + 1);
            ActiveLevels[sz] = LevelsMap[j];
          }
        }
      }
    }

    for (int j = 0; j < ArraySize(ActiveLevels); j++) {
      ActiveLevels[j].strength = ComputeStrength(
          ActiveLevels[j].tap_count, ActiveLevels[j].last_touch_idx, i);
    }
  }

  // --- NEW: Filter 5 nearest above and 5 nearest below ---
  double current_p = iClose(_Symbol, InpTF, 0);
  SRLevel above[], below[];

  for (int j = 0; j < ArraySize(ActiveLevels); j++) {
    if (ActiveLevels[j].price_bucket > current_p) {
      int sz = ArraySize(above);
      ArrayResize(above, sz + 1);
      above[sz] = ActiveLevels[j];
    } else {
      int sz = ArraySize(below);
      ArrayResize(below, sz + 1);
      below[sz] = ActiveLevels[j];
    }
  }

  // Sort Above (Ascending)
  for (int i = 0; i < (int)ArraySize(above) - 1; i++) {
    for (int j = 0; j < (int)ArraySize(above) - i - 1; j++) {
      if (above[j].price_bucket > above[j + 1].price_bucket) {
        SRLevel tmp = above[j];
        above[j] = above[j + 1];
        above[j + 1] = tmp;
      }
    }
  }

  // Sort Below (Descending)
  for (int i = 0; i < (int)ArraySize(below) - 1; i++) {
    for (int j = 0; j < (int)ArraySize(below) - i - 1; j++) {
      if (below[j].price_bucket < below[j + 1].price_bucket) {
        SRLevel tmp = below[j];
        below[j] = below[j + 1];
        below[j + 1] = tmp;
      }
    }
  }

  // Re-populate ActiveLevels with max 10 total
  int count_above = MathMin(5, (int)ArraySize(above));
  int count_below = MathMin(5, (int)ArraySize(below));

  ArrayFree(ActiveLevels);
  ArrayResize(ActiveLevels, count_above + count_below);
  for (int i = 0; i < count_above; i++)
    ActiveLevels[i] = above[i];
  for (int i = 0; i < count_below; i++)
    ActiveLevels[count_above + i] = below[i];

  DrawSRLines();
}

void DetectAndProcessTap(double p1, double p2, double p3, bool is_high, int idx,
                         double grid_size) {
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

  double bucket = MathRound(p / grid_size) * grid_size;

  int map_idx = -1;
  for (int i = 0; i < ArraySize(LevelsMap); i++) {
    if (MathAbs(LevelsMap[i].price_bucket - bucket) < 0.00001) {
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

bool IsFarFromExisting(double p, double radius) {
  for (int i = 0; i < ArraySize(ActiveLevels); i++) {
    if (MathAbs(ActiveLevels[i].price_bucket - p) < radius)
      return false;
  }
  return true;
}

void DrawSRLines() {
  ObjectsDeleteAll(0, "SR_");
  for (int i = 0; i < ArraySize(ActiveLevels); i++) {
    string name = "SR_" + IntegerToString(i);
    ObjectCreate(0, name, OBJ_HLINE, 0, 0, ActiveLevels[i].price_bucket);
    ObjectSetInteger(0, name, OBJPROP_COLOR, clrAqua);
    ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);

    string lbl = "SR_L_" + IntegerToString(i);
    ObjectCreate(0, lbl, OBJ_TEXT, 0, TimeCurrent(),
                 ActiveLevels[i].price_bucket);
    ObjectSetString(
        0, lbl, OBJPROP_TEXT,
        "ATR_SR " + DoubleToString(ActiveLevels[i].price_bucket, _Digits) +
            " (Str: " + DoubleToString(ActiveLevels[i].strength, 2) + ")");
    ObjectSetInteger(0, lbl, OBJPROP_COLOR, clrWhite);
  }
}

// ─────────────────────────────────────────────────────────────
//  Signal Engine (Ported)
// ─────────────────────────────────────────────────────────────

bool FindFocusSR(double close_0, double open_0, double close_1, double high_1,
                 double low_1, double &focus_sr) {
  int sz = ArraySize(ActiveLevels);
  if (sz == 0)
    return false;
  double tol = InpSigTol * _Point;

  for (int i = 0; i < sz; i++) {
    double curr_l = ActiveLevels[i].price_bucket;
    double close_2 = iClose(_Symbol, InpTF, 2);
    if ((close_2 >= curr_l && close_1 < curr_l) ||
        (close_2 <= curr_l && close_1 > curr_l)) {
      focus_sr = curr_l;
      return true;
    }
  }

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
  double tol = 2.0 * _Point;
  for (int i = 0; i < sz; i++) {
    double lvl = ActiveLevels[i].price_bucket;
    if (look_above) {
      if (lvl > price + tol) {
        double dist = lvl - price;
        if (dist < best_dist) {
          found_sr = lvl;
          found = true;
          best_dist = dist;
        }
      }
    } else {
      if (lvl < price - tol) {
        double dist = price - lvl;
        if (dist < best_dist) {
          found_sr = lvl;
          found = true;
          best_dist = dist;
        }
      }
    }
  }
  return found;
}

void HandleSignals() {
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
  if (close_0 > focus_sr) {
    double tp_price = 0;
    if (GetNearestSR(close_0, true, tp_price)) {
      double tp_dist = tp_price - close_0;
      double sl_price = close_0 - (tp_dist / InpRatio);
      m_trade.Buy(InpLotSize, _Symbol, close_0, sl_price, tp_price, "ATR Long");
    }
  } else {
    double tp_price = 0;
    if (GetNearestSR(close_0, false, tp_price)) {
      double tp_dist = close_0 - tp_price;
      double sl_price = close_0 + (tp_dist / InpRatio);
      m_trade.Sell(InpLotSize, _Symbol, close_0, sl_price, tp_price, "ATR Short");
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
