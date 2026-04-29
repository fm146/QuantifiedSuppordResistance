//+------------------------------------------------------------------+
//|                               NewArch_SR_MeanReverting_v3.mq5    |
//|                                  Copyright 2026, Antigravity AI  |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Antigravity AI"
#property link "https://www.mql5.com"
#property version "3.00"
#property strict

#include <Trade\Trade.mqh>

// ─────────────────────────────────────────────
// CONFIG
// ─────────────────────────────────────────────
input group "SR v3 - REST API Settings"
input string InpServerUrl = "http://127.0.0.1:8000/levels_raw"; // API URL
input int InpPollInterval = 60;                                  // Check every X seconds
input string InpLocalFileName = "sr_levels.txt";                 // Fallback file name
input bool InpUseCommonFolder = true;                            // Look in Common/Files? (Recommended for Tester)

input group "Analysis settings"
input ENUM_TIMEFRAMES InpTF = PERIOD_H1;  // Primary Timeframe (H1)

input group "Strategy Settings"
input double InpRatio = 1.0;              // SL:TP Ratio
input int InpOvertime = 24;               // Overtime (Hours)
input double InpSigTol = 0.5;             // Signal Touch Tolerance (Ticks)
input uint InpMagic = 123461;             // Magic Number
input double InpLotSize = 0.1;            // Lot Size

// ─────────────────────────────────────────────
// DATA STRUCTURES
// ─────────────────────────────────────────────
struct SRLevel {
  double price_bucket;
  int tap_count;      // Placeholder for v3 (manual)
  int last_touch_idx; // Placeholder for v3 (manual)
  double strength;    // Placeholder for v3 (manual)
  bool is_locked;     // Placeholder for v3 (manual)
};

SRLevel ActiveLevels[]; // Manually defined levels from API

CTrade m_trade;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
  m_trade.SetExpertMagicNumber(InpMagic);
  EventSetTimer(InpPollInterval);
  FetchRemoteLevels();
  return (INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { 
  EventKillTimer();
  ObjectsDeleteAll(0, "SR_V3_"); 
}

void OnTimer() {
  FetchRemoteLevels();
}

void OnTick() {
  static datetime last_signal_check = 0;
  if (iTime(_Symbol, InpTF, 0) != last_signal_check) {
    HandleSignals();
    last_signal_check = iTime(_Symbol, InpTF, 0);
  }
  HandleOvertime();
}

// ─────────────────────────────────────────────────────────────
//  Logic implementation
// ─────────────────────────────────────────────────────────────

void FetchRemoteLevels() {
  char post[], result[];
  string result_headers, cookie;
  int timeout = 3000;

  ResetLastError();
  int res = WebRequest("GET", InpServerUrl, cookie, NULL, timeout, post, 0, result, result_headers);

  if (res == -1 || res != 200) {
    if (res == -1) Print("WebRequest Failed (Code ", GetLastError(), "). Trying local file fallback...");
    else Print("Server returned ", res, ". Trying local file fallback...");
    
    FetchFromFile();
    return;
  }

  string response = CharArrayToString(result);
  StringReplace(response, "\"", "");
  ParseAndLoadLevels(response, "API");
}

void FetchFromFile() {
  int flags = FILE_READ|FILE_TXT|FILE_ANSI;
  if (InpUseCommonFolder) flags |= FILE_COMMON;

  int handle = FileOpen(InpLocalFileName, flags);
  if (handle == INVALID_HANDLE) {
    Print("Local file fallback failed: ", InpLocalFileName, " not found in ", (InpUseCommonFolder ? "Common/Files" : "MQL5/Files"));
    return;
  }

  string data = "";
  while (!FileIsEnding(handle)) {
    data += FileReadString(handle);
  }
  FileClose(handle);

  if (StringLen(data) > 0) {
    ParseAndLoadLevels(data, "FILE");
  } else {
    Print("Local file is empty.");
  }
}

void ParseAndLoadLevels(string data, string source) {
  ArrayFree(ActiveLevels);
  string parts[];
  int count = StringSplit(data, ',', parts);

  if (count <= 0) {
    if (StringLen(data) > 0) {
        ArrayResize(ActiveLevels, 1);
        ActiveLevels[0].price_bucket = StringToDouble(data);
    }
  } else {
    ArrayResize(ActiveLevels, count);
    for (int i = 0; i < count; i++) {
        string val = parts[i];
        StringTrimLeft(val); StringTrimRight(val);
        ActiveLevels[i].price_bucket = StringToDouble(val);
        ActiveLevels[i].tap_count = 5;
        ActiveLevels[i].strength = 5.0;
    }
  }

  Print("Source: ", source, " | Loaded ", ArraySize(ActiveLevels), " manual levels.");
  DrawSRLines();
}

void DrawSRLines() {
  ObjectsDeleteAll(0, "SR_V3_");
  for (int i = 0; i < ArraySize(ActiveLevels); i++) {
    string name = "SR_V3_" + IntegerToString(i);
    ObjectCreate(0, name, OBJ_HLINE, 0, 0, ActiveLevels[i].price_bucket);
    ObjectSetInteger(0, name, OBJPROP_COLOR, clrDodgerBlue);
    ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);

    string lbl = "SR_V3_L_" + IntegerToString(i);
    ObjectCreate(0, lbl, OBJ_TEXT, 0, TimeCurrent(), ActiveLevels[i].price_bucket);
    ObjectSetString(0, lbl, OBJPROP_TEXT, "MANUAL_SR " + DoubleToString(ActiveLevels[i].price_bucket, _Digits));
    ObjectSetInteger(0, lbl, OBJPROP_COLOR, clrWhite);
  }
}

// ─────────────────────────────────────────────────────────────
//  Signal Engine & Trade Management (Ported)
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
      m_trade.Buy(InpLotSize, _Symbol, close_0, sl_price, tp_price, "v3 Manual Long");
    }
  } else {
    double tp_price = 0;
    if (GetNearestSR(close_0, false, tp_price)) {
      double tp_dist = close_0 - tp_price;
      double sl_price = close_0 + (tp_dist / InpRatio);
      m_trade.Sell(InpLotSize, _Symbol, close_0, sl_price, tp_price, "v3 Manual Short");
    }
  }
}

void HandleOvertime() {
  ulong ticket = 0;
  if (!PositionSelectByMagic(InpMagic, ticket)) return;
  datetime open_time = (datetime)PositionGetInteger(POSITION_TIME);
  if (TimeCurrent() - open_time >= (datetime)InpOvertime * 3600) {
    m_trade.PositionClose(ticket, "Force Closed - v3 Overtime");
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
