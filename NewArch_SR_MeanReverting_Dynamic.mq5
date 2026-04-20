//+------------------------------------------------------------------+
//|                             NewArch_SR_MeanReverting_Dynamic.mq5  |
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
input group "Dynamic-Threshold Settings"
input double InpBaseStr = 1.5;       // Base Strength Threshold
input int InpVolPeriod = 20;         // Volatility Period (Average Body)
input double InpClusterSize = 2.0;   // Cluster Size multiplier (Avg Body * Factor)
input int InpMinTap = 3;             // Min Taps to qualify
input double InpLambda = 0.0005;     // Decay factor (LAM)

input group "Analysis settings"
input int InpLookback = 5000;             // History bars to analyze
input ENUM_TIMEFRAMES InpTF = PERIOD_H1;  // Timeframe for SR

input group "Strategy Settings"
input double InpRatio = 1.0;              // SL:TP Ratio
input int InpOvertime = 24;               // Overtime (Hours)
input double InpSigTol = 0.5;             // Signal Touch Tolerance (Ticks)
input uint InpMagic = 123459;             // Magic Number
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
};

SRLevel LevelsMap[];    // All seen buckets
SRLevel ActiveLevels[]; // Locked levels

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

void OnDeinit(const int reason) { ObjectsDeleteAll(0, "SR_"); }

void OnTick() {
  static datetime last_bar = 0;
  if (iTime(_Symbol, InpTF, 0) != last_bar) {
    RunSRSystem();
    HandleSignals();
    last_bar = iTime(_Symbol, InpTF, 0);
  }
  HandleOvertime();
}

// ─────────────────────────────────────────────────────────────
//  Logic implementation
// ─────────────────────────────────────────────────────────────

void RunSRSystem() {
  ArrayFree(LevelsMap);
  ArrayFree(ActiveLevels);

  double high[], low[], open[], close[];
  int copied = CopyHigh(_Symbol, InpTF, 0, InpLookback, high);
  CopyLow(_Symbol, InpTF, 0, InpLookback, low);
  CopyOpen(_Symbol, InpTF, 0, InpLookback, open);
  CopyClose(_Symbol, InpTF, 0, InpLookback, close);

  if (copied < InpVolPeriod + 5) return;

  // Calculate Current Volatility (Avg Body)
  double avg_body = 0;
  for(int i = copied - InpVolPeriod; i < copied; i++) {
    avg_body += MathAbs(close[i] - open[i]);
  }
  avg_body /= InpVolPeriod;
  if(avg_body <= 0) avg_body = _Point * 20;

  // Adaptive Strength Threshold (Higher volatility = stricter threshold)
  // Ratio current volatility vs historical is not used here for simplicity, 
  // but we can scale InpBaseStr. 
  double dynamic_str = InpBaseStr; 

  double grid_size = avg_body * 0.25; // Smaller grid for clustering
  double cluster_width = avg_body * InpClusterSize;

  for (int i = 1; i < copied - 1; i++) {
    DetectAndProcessTap(high[i - 1], high[i], high[i + 1], true, i, grid_size);
    DetectAndProcessTap(low[i - 1], low[i], low[i + 1], false, i, grid_size);
  }

  // Second pass: Calculate strength for candidates
  for (int j = 0; j < ArraySize(LevelsMap); j++) {
    LevelsMap[j].strength = ComputeStrength(LevelsMap[j].tap_count, LevelsMap[j].last_touch_idx, copied);
  }

  // 3. Cluster Density Ranking (Ranking strongest level in each volatility cluster)
  // We sort LevelsMap by strength descending to prioritize stronger levels
  SortLevelsByStrength(LevelsMap);

  for (int j = 0; j < ArraySize(LevelsMap); j++) {
    if (LevelsMap[j].tap_count >= InpMinTap && LevelsMap[j].strength >= dynamic_str) {
      // Check if this level is in a "taken" cluster
      if (IsClusterFree(LevelsMap[j].price_bucket, cluster_width)) {
          LevelsMap[j].is_locked = true;
          int sz = ArraySize(ActiveLevels);
          ArrayResize(ActiveLevels, sz + 1);
          ActiveLevels[sz] = LevelsMap[j];
      }
    }
  }

  DrawSRLines();
}

void DetectAndProcessTap(double p1, double p2, double p3, bool is_high, int idx, double grid_size) {
  bool is_tap = (is_high && p2 > p1 && p2 > p3) || (!is_high && p2 < p1 && p2 < p3);
  if (!is_tap) return;

  double bucket = MathRound(p2 / grid_size) * grid_size;
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

void SortLevelsByStrength(SRLevel &arr[]) {
  int n = ArraySize(arr);
  for (int i = 0; i < n - 1; i++) {
    for (int j = 0; j < n - i - 1; j++) {
      if (arr[j].strength < arr[j+1].strength) {
        SRLevel temp = arr[j];
        arr[j] = arr[j+1];
        arr[j+1] = temp;
      }
    }
  }
}

bool IsClusterFree(double p, double width) {
  for (int i = 0; i < ArraySize(ActiveLevels); i++) {
    if (MathAbs(ActiveLevels[i].price_bucket - p) < width)
      return false;
  }
  return true;
}

void DrawSRLines() {
  ObjectsDeleteAll(0, "SR_");
  for (int i = 0; i < ArraySize(ActiveLevels); i++) {
    string name = "SR_" + IntegerToString(i);
    ObjectCreate(0, name, OBJ_HLINE, 0, 0, ActiveLevels[i].price_bucket);
    ObjectSetInteger(0, name, OBJPROP_COLOR, clrLime);
    ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);

    string lbl = "SR_L_" + IntegerToString(i);
    ObjectCreate(0, lbl, OBJ_TEXT, 0, TimeCurrent(), ActiveLevels[i].price_bucket);
    ObjectSetString(0, lbl, OBJPROP_TEXT, "DYN_SR " + DoubleToString(ActiveLevels[i].price_bucket, _Digits));
    ObjectSetInteger(0, lbl, OBJPROP_COLOR, clrWhite);
  }
}

// ─────────────────────────────────────────────────────────────
//  Signal Engine (Ported)
// ─────────────────────────────────────────────────────────────

bool FindFocusSR(double close_0, double open_0, double close_1, double high_1, double low_1, double &focus_sr) {
  int sz = ArraySize(ActiveLevels);
  if (sz == 0) return false;
  double tol = InpSigTol * _Point;
  for (int i = 0; i < sz; i++) {
    double curr_l = ActiveLevels[i].price_bucket;
    double close_2 = iClose(_Symbol, InpTF, 2);
    if ((close_2 >= curr_l && close_1 < curr_l) || (close_2 <= curr_l && close_1 > curr_l)) {
      focus_sr = curr_l; return true;
    }
  }
  double min_dist_wick = 1e10; bool found_wick = false;
  bool is_red_1 = close_1 < iOpen(_Symbol, InpTF, 1);
  double target_p = is_red_1 ? low_1 : high_1;
  for (int i = 0; i < sz; i++) {
    double curr_l = ActiveLevels[i].price_bucket;
    if (high_1 >= curr_l - tol && low_1 <= curr_l + tol) {
      double dist = MathAbs(target_p - curr_l);
      if (dist < min_dist_wick) { min_dist_wick = dist; focus_sr = curr_l; found_wick = true; }
    }
  }
  return found_wick;
}

bool CheckInSRRange(double price, bool &has_above, bool &has_below) {
  has_above = false; has_below = false;
  int sz = ArraySize(ActiveLevels);
  double tol = InpSigTol * _Point;
  for (int i = 0; i < sz; i++) {
    double lvl = ActiveLevels[i].price_bucket;
    if (lvl > price + tol) has_above = true;
    if (lvl < price - tol) has_below = true;
  }
  return (has_above && has_below);
}

bool GetNearestSR(double price, bool look_above, double &found_sr) {
  int sz = ArraySize(ActiveLevels);
  double best_dist = 1e10; bool found = false;
  double tol = 2.0 * _Point;
  for (int i = 0; i < sz; i++) {
    double lvl = ActiveLevels[i].price_bucket;
    if (look_above) {
      if (lvl > price + tol) {
        double dist = lvl - price;
        if (dist < best_dist) { found_sr = lvl; found = true; best_dist = dist; }
      }
    } else {
      if (lvl < price - tol) {
        double dist = price - lvl;
        if (dist < best_dist) { found_sr = lvl; found = true; best_dist = dist; }
      }
    }
  }
  return found;
}

void HandleSignals() {
  ulong ticket = 0;
  if (PositionSelectByMagic(InpMagic, ticket)) return;
  double close_0 = iClose(_Symbol, InpTF, 0);
  double close_1 = iClose(_Symbol, InpTF, 1);
  double high_1 = iHigh(_Symbol, InpTF, 1);
  double low_1 = iLow(_Symbol, InpTF, 1);
  double focus_sr = 0;
  if (!FindFocusSR(close_0, close_0, close_1, high_1, low_1, focus_sr)) return;
  bool has_above, has_below;
  if (!CheckInSRRange(close_0, has_above, has_below)) return;
  if (close_0 > focus_sr) {
    double tp_price = 0;
    if (GetNearestSR(close_0, true, tp_price)) {
      double tp_dist = tp_price - close_0;
      double sl_price = close_0 - (tp_dist / InpRatio);
      m_trade.Buy(InpLotSize, _Symbol, close_0, sl_price, tp_price, "DYN Long");
    }
  } else {
    double tp_price = 0;
    if (GetNearestSR(close_0, false, tp_price)) {
      double tp_dist = close_0 - tp_price;
      double sl_price = close_0 + (tp_dist / InpRatio);
      m_trade.Sell(InpLotSize, _Symbol, close_0, sl_price, tp_price, "DYN Short");
    }
  }
}

void HandleOvertime() {
  ulong ticket = 0;
  if (!PositionSelectByMagic(InpMagic, ticket)) return;
  datetime open_time = (datetime)PositionGetInteger(POSITION_TIME);
  if (TimeCurrent() - open_time >= (datetime)InpOvertime * 3600) {
    m_trade.PositionClose(ticket, "Force Closed - Overtime");
  }
}

bool PositionSelectByMagic(long magic, ulong &found_ticket) {
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong ticket = PositionGetTicket(i);
    if (PositionSelectByTicket(ticket)) {
      if (PositionGetInteger(POSITION_MAGIC) == magic && PositionGetString(POSITION_SYMBOL) == _Symbol) {
        found_ticket = ticket; return true;
      }
    }
  }
  return false;
}
