//+------------------------------------------------------------------+
//|                             NewArch_SR_CounterTrend_v3d.mq5     |
//|                                  Copyright 2026, Antigravity AI  |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Antigravity AI"
#property link "https://www.mql5.com"
#property version "3.00d"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\OrderInfo.mqh>

// ─────────────────────────────────────────────
// CONFIG
// ─────────────────────────────────────────────
input group "SR v3d - REST API Settings"
input string InpServerUrl = "http://127.0.0.1:8000/levels_raw"; // API URL
input int InpPollInterval = 60;                                  // Check every X seconds
input string InpLocalFileName = "sr_levels.txt";                 // Fallback file name
input bool InpUseCommonFolder = true;                            // Look in Common/Files? (Recommended for Tester)

input group "Analysis settings"
input ENUM_TIMEFRAMES InpTF = PERIOD_H1;  // Primary Timeframe (H1)

input group "Strategy Settings (LIMIT ORDER CENTER TRIGGER)"
input double InpRatio = 1.0;              // SL:TP Ratio
input int InpOvertime = 24;               // Overtime (Hours)
input double InpSigTol = 0.5;             // Signal Touch Tolerance (Ticks)
input uint InpMagic = 123465;             // New Magic Number for v3d
input double InpLotSize = 0.1;            // Lot Size

// ─────────────────────────────────────────────
// DATA STRUCTURES
// ─────────────────────────────────────────────
struct SRLevel {
  double price_bucket;
};

SRLevel ActiveLevels[];
CTrade m_trade;
COrderInfo m_order;

double LastCenter = 0; // To detect crossing

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
  ObjectsDeleteAll(0, "SR_V3D_"); 
}

void OnTimer() {
  FetchRemoteLevels();
}

void OnTick() {
  HandleSignals();
  HandleCleanup();
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
  if (res == -1 || res != 200) { FetchFromFile(); return; }
  string response = CharArrayToString(result);
  StringReplace(response, "\"", "");
  ParseAndLoadLevels(response, "API");
}

void FetchFromFile() {
  int flags = FILE_READ|FILE_TXT|FILE_ANSI;
  if (InpUseCommonFolder) flags |= FILE_COMMON;
  int handle = FileOpen(InpLocalFileName, flags);
  if (handle == INVALID_HANDLE) return;
  string data = "";
  while (!FileIsEnding(handle)) data += FileReadString(handle);
  FileClose(handle);
  if (StringLen(data) > 0) ParseAndLoadLevels(data, "FILE");
}

void ParseAndLoadLevels(string data, string source) {
  ArrayFree(ActiveLevels);
  string parts[];
  int count = StringSplit(data, ',', parts);
  if (count <= 0) {
    if (StringLen(data) > 0) { ArrayResize(ActiveLevels, 1); ActiveLevels[0].price_bucket = StringToDouble(data); }
  } else {
    ArrayResize(ActiveLevels, count);
    for (int i = 0; i < count; i++) {
        string val = parts[i]; StringTrimLeft(val); StringTrimRight(val);
        ActiveLevels[i].price_bucket = StringToDouble(val);
    }
  }
}

// ─────────────────────────────────────────────────────────────
//  Center Logic & Visualization
// ─────────────────────────────────────────────────────────────

bool GetBounds(double price, double &sr_high, double &sr_low) {
    int sz = ArraySize(ActiveLevels);
    if(sz < 2) return false;
    sr_high = 1e10; sr_low = -1e10;
    bool found_h = false, found_l = false;
    for(int i=0; i<sz; i++) {
        double lvl = ActiveLevels[i].price_bucket;
        if(lvl > price && lvl < sr_high) { sr_high = lvl; found_h = true; }
        if(lvl < price && lvl > sr_low)  { sr_low = lvl; found_l = true; }
    }
    return (found_h && found_l);
}

void DrawZones(double sr_h, double sr_l, double center) {
    ObjectsDeleteAll(0, "SR_V3D_");
    
    // Bounds
    DrawLine("SR_V3D_H", sr_h, clrDodgerBlue, STYLE_SOLID, 2, "RESISTANCE (SELL LIMIT)");
    DrawLine("SR_V3D_L", sr_l, clrDodgerBlue, STYLE_SOLID, 2, "SUPPORT (BUY LIMIT)");
    
    // Center
    DrawLine("SR_V3D_C", center, clrYellow, STYLE_DOT, 1, "CENTER_TRIGGER");
}

void DrawLine(string name, double price, color col, ENUM_LINE_STYLE style, int width, string text) {
    ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
    ObjectSetInteger(0, name, OBJPROP_COLOR, col);
    ObjectSetInteger(0, name, OBJPROP_STYLE, style);
    ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
    
    string tname = name + "_T";
    ObjectCreate(0, tname, OBJ_TEXT, 0, TimeCurrent(), price);
    ObjectSetString(0, tname, OBJPROP_TEXT, " " + text + " (" + DoubleToString(price, _Digits) + ")");
    ObjectSetInteger(0, tname, OBJPROP_COLOR, clrWhite);
}

// ─────────────────────────────────────────────────────────────
//  Signal & Trade
// ─────────────────────────────────────────────────────────────

void HandleSignals() {
  double cp = iClose(_Symbol, _Period, 0); 
  double sr_h, sr_l;
  if (!GetBounds(cp, sr_h, sr_l)) return;

  double center = (sr_h + sr_l) / 2.0;

  // Visualization refresh
  static datetime last_draw = 0;
  if(TimeCurrent() - last_draw > 5) { DrawZones(sr_h, sr_l, center); last_draw = TimeCurrent(); }

  // Check Crossing Center
  bool crossed = (LastCenter > 0) && ((cp >= center && LastCenter < center) || (cp <= center && LastCenter > center));
  LastCenter = cp;

  if(!crossed) return;

  // Check Sequential (Only one session allowed)
  if(PositionsTotal() > 0 || OrdersTotal() > 0) return;

  // Touch Check (Candle Index 1) - Optional validation rule
  double h1 = iHigh(_Symbol, InpTF, 1);
  double l1 = iLow(_Symbol, InpTF, 1);
  double tol = InpSigTol * _Point;
  bool touched = (h1 >= sr_h - tol) || (l1 <= sr_l + tol);
  
  if(!touched) return;

  Print("v3d: Center Crossing Detected! Placing Counter-Trend Limit Orders...");
  
  // Placement Logic
  double tp_b = sr_h;
  double tp_s = sr_l;
  
  double dist = sr_h - sr_l;
  if(dist <= 0) return;

  double sl_b = sr_l - (dist / InpRatio);
  double sl_s = sr_h + (dist / InpRatio);
  
  // Place Buy Limit at Support
  if(m_trade.BuyLimit(InpLotSize, sr_l, _Symbol, sl_b, tp_b, ORDER_TIME_GTC, 0, "v3d BuyLimit")) {
      Print("Placed Buy Limit at ", sr_l, " TP: ", tp_b, " SL: ", sl_b);
  }
  
  // Place Sell Limit at Resistance
  if(m_trade.SellLimit(InpLotSize, sr_h, _Symbol, sl_s, tp_s, ORDER_TIME_GTC, 0, "v3d SellLimit")) {
      Print("Placed Sell Limit at ", sr_h, " TP: ", tp_s, " SL: ", sl_s);
  }
}

void HandleCleanup() {
  // Overtime (24h) for Positions
  for(int i=PositionsTotal()-1; i>=0; i--) {
     ulong t = PositionGetTicket(i);
     if(PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC) == InpMagic) {
        if(TimeCurrent() - PositionGetInteger(POSITION_TIME) > InpOvertime * 3600)
           m_trade.PositionClose(t, "v3d Overtime Position");
     }
  }
  // Overtime (24h) for Pending Orders
  for(int i=OrdersTotal()-1; i>=0; i--) {
     ulong t = OrderGetTicket(i);
     if(OrderSelect(t) && OrderGetInteger(ORDER_MAGIC) == InpMagic) {
        if(TimeCurrent() - OrderGetInteger(ORDER_TIME_SETUP) > InpOvertime * 3600)
           m_trade.OrderDelete(t);
     }
  }
}
