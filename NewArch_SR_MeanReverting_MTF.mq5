//+------------------------------------------------------------------+
//|                                NewArch_SR_MeanReverting_MTF.mq5  |
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
input group "MTF-Hierarchy Settings"
input ENUM_TIMEFRAMES InpTF_Higher = PERIOD_H4; // Higher Timeframe anchor
input double InpGrid = 10.0;                    // Grid Size (Bucket)
input double InpMergeFactor = 0.5;              // LTF Merge Zone (% of HTF Range)
input int InpMinTap = 3;                        // Min Taps to qualify
input double InpMinStr = 1.5;                   // Min Strength to qualify
input double InpLambda = 0.0005;                // Decay factor (LAM)

input group "Analysis settings"
input int InpLookback = 5000;             // History bars to analyze (LTF)
input ENUM_TIMEFRAMES InpTF = PERIOD_H1;  // Primary Timeframe (LTF)

input group "Strategy Settings"
input double InpRatio = 1.0;              // SL:TP Ratio
input int InpOvertime = 24;               // Overtime (Hours)
input double InpSigTol = 0.5;             // Signal Touch Tolerance (Ticks)
input uint InpMagic = 123458;             // Magic Number
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
  bool is_htf; // Level from HTF
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

  // 1. Process HTF first
  double htf_high[], htf_low[];
  int copied_htf = CopyHigh(_Symbol, InpTF_Higher, 0, InpLookback / 4, htf_high);
  CopyLow(_Symbol, InpTF_Higher, 0, InpLookback / 4, htf_low);
  
  if(copied_htf > 3) {
    for (int i = 1; i < copied_htf - 1; i++) {
        DetectAndProcessTap(htf_high[i-1], htf_high[i], htf_high[i+1], true, i, true);
        DetectAndProcessTap(htf_low[i-1], htf_low[i], htf_low[i+1], false, i, true);
    }
  }

  // 2. Process LTF
  double ltf_high[], ltf_low[];
  int copied_ltf = CopyHigh(_Symbol, InpTF, 0, InpLookback, ltf_high);
  CopyLow(_Symbol, InpTF, 0, InpLookback, ltf_low);

  if(copied_ltf > 3) {
    for (int i = 1; i < copied_ltf - 1; i++) {
        DetectAndProcessTap(ltf_high[i-1], ltf_high[i], ltf_high[i+1], true, i, false);
        DetectAndProcessTap(ltf_low[i-1], ltf_low[i], ltf_low[i+1], false, i, false);
    }
  }

  // Calculate Average HTF Candle Range for merging
  double avg_htf_range = 0;
  int count_htf = 0;
  for(int i=0; i < MathMin(100, ArraySize(htf_high)); i++) {
    avg_htf_range += (htf_high[i] - htf_low[i]);
    count_htf++;
  }
  if(count_htf > 0) avg_htf_range /= count_htf;
  else avg_htf_range = _Point * 50;

  double merge_zone = avg_htf_range * InpMergeFactor;

  // 3. Locking Hierarchy
  // First, lock all strong HTF levels
  for (int j = 0; j < ArraySize(LevelsMap); j++) {
    if(!LevelsMap[j].is_htf) continue;
    
    LevelsMap[j].strength = ComputeStrength(LevelsMap[j].tap_count, LevelsMap[j].last_touch_idx, copied_ltf);
    if (LevelsMap[j].tap_count >= InpMinTap && LevelsMap[j].strength >= InpMinStr) {
        // HTF levels only compete with other HTF levels (using base grid)
        if (IsFreeZone(LevelsMap[j].price_bucket, InpGrid)) {
            LevelsMap[j].is_locked = true;
            int sz = ArraySize(ActiveLevels);
            ArrayResize(ActiveLevels, sz + 1);
            ActiveLevels[sz] = LevelsMap[j];
        }
    }
  }

  // Second, lock LTF levels if they are far enough from locked HTF levels
  for (int j = 0; j < ArraySize(LevelsMap); j++) {
    if(LevelsMap[j].is_htf || LevelsMap[j].is_locked) continue;

    LevelsMap[j].strength = ComputeStrength(LevelsMap[j].tap_count, LevelsMap[j].last_touch_idx, copied_ltf);
    if (LevelsMap[j].tap_count >= InpMinTap && LevelsMap[j].strength >= InpMinStr) {
        if (IsFreeZone(LevelsMap[j].price_bucket, merge_zone)) {
            LevelsMap[j].is_locked = true;
            int sz = ArraySize(ActiveLevels);
            ArrayResize(ActiveLevels, sz + 1);
            ActiveLevels[sz] = LevelsMap[j];
        }
    }
  }

  DrawSRLines();
}

void DetectAndProcessTap(double p1, double p2, double p3, bool is_high, int idx, bool is_htf) {
  bool is_tap = (is_high && p2 > p1 && p2 > p3) || (!is_high && p2 < p1 && p2 < p3);
  if (!is_tap) return;

  double bucket = MathRound(p2 / InpGrid) * InpGrid;
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
    LevelsMap[map_idx].is_htf = is_htf;
  }
  
  if(is_htf) LevelsMap[map_idx].is_htf = true; // Upgrade if touched by HTF
  LevelsMap[map_idx].tap_count++;
  LevelsMap[map_idx].last_touch_idx = idx;
}

double ComputeStrength(int taps, int last_idx, int current_idx) {
  double age = (double)(current_idx - last_idx);
  return (double)taps * MathExp(-InpLambda * age);
}

bool IsFreeZone(double p, double zone) {
  for (int i = 0; i < ArraySize(ActiveLevels); i++) {
    if (MathAbs(ActiveLevels[i].price_bucket - p) < zone)
      return false;
  }
  return true;
}

void DrawSRLines() {
  ObjectsDeleteAll(0, "SR_");
  for (int i = 0; i < ArraySize(ActiveLevels); i++) {
    string name = "SR_" + IntegerToString(i);
    ObjectCreate(0, name, OBJ_HLINE, 0, 0, ActiveLevels[i].price_bucket);
    color clr = ActiveLevels[i].is_htf ? clrGold : clrWhite;
    ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
    ObjectSetInteger(0, name, OBJPROP_WIDTH, ActiveLevels[i].is_htf ? 2 : 1);

    string lbl = "SR_L_" + IntegerToString(i);
    ObjectCreate(0, lbl, OBJ_TEXT, 0, TimeCurrent(), ActiveLevels[i].price_bucket);
    ObjectSetString(0, lbl, OBJPROP_TEXT, (ActiveLevels[i].is_htf ? "HTF_" : "LTF_") + DoubleToString(ActiveLevels[i].price_bucket, _Digits));
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
      m_trade.Buy(InpLotSize, _Symbol, close_0, sl_price, tp_price, "MTF Long");
    }
  } else {
    double tp_price = 0;
    if (GetNearestSR(close_0, false, tp_price)) {
      double tp_dist = close_0 - tp_price;
      double sl_price = close_0 + (tp_dist / InpRatio);
      m_trade.Sell(InpLotSize, _Symbol, close_0, sl_price, tp_price, "MTF Short");
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
