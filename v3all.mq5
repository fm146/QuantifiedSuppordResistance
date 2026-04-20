//+------------------------------------------------------------------+
//|                                     v3all_Strategy_Orchestrator  |
//|                                  Copyright 2026, Antigravity AI  |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Antigravity AI"
#property link      "https://www.mql5.com"
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\HistoryOrderInfo.mqh>

// ─────────────────────────────────────────────
// ENUMS & DEFINITIONS
// ─────────────────────────────────────────────
enum ENUM_STRAT_TYPE {
   TYPE_CT, // Counter-Trend
   TYPE_FT  // Follow-Trend
};

enum ENUM_STRAT_ID {
   STRAT_V3A, // v3a: Counter-Trend (Reversal at SR)
   STRAT_V3B, // v3b: Follow-Trend (Continuation at SR)
   STRAT_V3C, // v3c: Follow-Trend (Stop Order Center Trigger)
   STRAT_V3D  // v3d: Counter-Trend (Limit Order Center Trigger)
};

enum ENUM_SYSTEM_MODE {
   MODE_SPECTATOR,
   MODE_REAL_EXECUTION
};

struct SRLevel {
   double price_bucket;
};

// Virtual trade structure
struct VirtualTrade {
   ENUM_STRAT_ID strat_id;
   bool active;
   ENUM_POSITION_TYPE type;
   double entry_price;
   double sl;
   double tp;
   datetime open_time;
   string comment;
};

// ─────────────────────────────────────────────
// INPUTS
// ─────────────────────────────────────────────
input group "System Orchestrator Settings"
input double InpLotSize = 0.1;           // Real Lot Size
input uint   InpMagicPrefix = 123000;    // Magic prefix (Each strat adds its index)
input bool   InpUseCommonFolder = true;  // Use Common Folder for SR Files

input group "Universal Strategy Settings"
input ENUM_TIMEFRAMES InpTF = PERIOD_H1; // Primary Timeframe
input double InpRatio = 1.0;             // SL:TP Ratio
input int    InpOvertime = 24;          // Overtime (Hours)
input double InpSigTol = 0.5;            // Signal Touch Tolerance (Ticks)

input group "REST API Settings"
input string InpServerUrl = "http://127.0.0.1:8000/levels_raw";
input int    InpPollInterval = 60;
input string InpLocalFileName = "sr_levels.txt";

// ─────────────────────────────────────────────
// GLOBALS
// ─────────────────────────────────────────────
SRLevel ActiveLevels[];
CTrade  m_trade;
COrderInfo m_order;
CPositionInfo m_position;

// Decision Tree State
ENUM_SYSTEM_MODE CurrentMode = MODE_SPECTATOR;
ENUM_STRAT_ID    ActiveStrat = STRAT_V3A; // Only relevant in REAL_MODE
int ConsecutiveLosses = 0;
int SwitchLevel = 0; // 0: Start, 1: Category Switched, 2: Intra-Category Switched

// Global tracking for loss logic
datetime LastProcessedSignalTime = 0;
long     LastProcessedSignalID = 0;
ENUM_STRAT_ID LastProcessedStrat = STRAT_V3A;

// Virtual Tracker
VirtualTrade VirtualPositions[4]; // One slot per strategy
double LastCenter = 0; // For v3c/v3d logic

// UI Labels
string DecisionLog = "STARTING SPECTATOR MODE...";

// ─────────────────────────────────────────────
// CORE EA EVENTS
// ─────────────────────────────────────────────

int OnInit() {
   EventSetTimer(InpPollInterval);
   FetchRemoteLevels();
   
   // Initialize virtual positions
   for(int i=0; i<4; i++) VirtualPositions[i].active = false;
   
   UpdateLog("Spectator Mode Active. Waiting for profitable virtual trade...");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   EventKillTimer();
   ObjectsDeleteAll(0, "SR_V3_");
   ObjectsDeleteAll(0, "ORCH_");
}

void OnTimer() {
   FetchRemoteLevels();
}

void OnTick() {
   static datetime last_bar = 0;
   datetime curr_bar = iTime(_Symbol, InpTF, 0);
   bool is_new_bar = (curr_bar != last_bar);
   
   // 1. Update SR Levels visualization periodically or on new bar
   if (is_new_bar) {
      DrawChartUI();
      last_bar = curr_bar;
   }
   
   // 2. Track Real Positions for the Active Strategy
   TrackRealTrades();
   
   // 3. Update Virtual Positions for all strategies
   UpdateVirtualTrades();

   // 4. Run Strategy Engines
   // v3a & v3b (Candle Close Logic)
   if (is_new_bar) {
      RunCandleCloseEngine();
   }
   
   // v3c & v3d (Crossing Logic)
   RunCrossingEngine();
   
   // 5. Update UI
   UpdateUIOverlay();
}

// ─────────────────────────────────────────────
// LEVEL FETCHING (Common)
// ─────────────────────────────────────────────

void FetchRemoteLevels() {
   char post[], result[];
   string result_headers, cookie;
   ResetLastError();
   int res = WebRequest("GET", InpServerUrl, cookie, NULL, 3000, post, 0, result, result_headers);
   if (res == -1 || res != 200) { FetchFromFile(); return; }
   string response = CharArrayToString(result);
   StringReplace(response, "\"", "");
   ParseLevels(response);
}

void FetchFromFile() {
   int flags = FILE_READ|FILE_TXT|FILE_ANSI;
   if (InpUseCommonFolder) flags |= FILE_COMMON;
   int handle = FileOpen(InpLocalFileName, flags);
   if (handle == INVALID_HANDLE) return;
   string data = "";
   while (!FileIsEnding(handle)) data += FileReadString(handle);
   FileClose(handle);
   if (StringLen(data) > 0) ParseLevels(data);
}

void ParseLevels(string data) {
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

// ─────────────────────────────────────────────
// STRATEGY HANDLERS
// ─────────────────────────────────────────────

// Ported condition from v3a/v3b
void RunCandleCloseEngine() {
   double close_0 = iClose(_Symbol, InpTF, 0);
   double close_1 = iClose(_Symbol, InpTF, 1);
   double open_1  = iOpen(_Symbol, InpTF, 1);
   double high_1  = iHigh(_Symbol, InpTF, 1);
   double low_1   = iLow(_Symbol, InpTF, 1);
   
   double focus_sr = 0;
   if (!FindFocusSR(close_1, high_1, low_1, focus_sr)) return;
   
   bool has_above, has_below;
   if (!CheckInSRRange(close_0, has_above, has_below)) return;

   // Get Signal ID (Bar time)
   datetime sig_time = iTime(_Symbol, InpTF, 0);

   // v3a (CT - Reversal)
   if (close_0 > focus_sr && close_1 < open_1) { // BUY Reversal
      ExecuteSignal(STRAT_V3A, ORDER_TYPE_BUY, close_0, sig_time);
   } else if (close_0 < focus_sr && close_1 > open_1) { // SELL Reversal
      ExecuteSignal(STRAT_V3A, ORDER_TYPE_SELL, close_0, sig_time);
   }
   
   // v3b (FT - Continuation)
   if (close_0 > focus_sr && close_1 > open_1) { // BUY Follow
      ExecuteSignal(STRAT_V3B, ORDER_TYPE_BUY, close_0, sig_time);
   } else if (close_0 < focus_sr && close_1 < open_1) { // SELL Follow
      ExecuteSignal(STRAT_V3B, ORDER_TYPE_SELL, close_0, sig_time);
   }
}

// Ported logic from v3c/v3d
void RunCrossingEngine() {
   double cp = iClose(_Symbol, _Period, 0); 
   double sr_h, sr_l;
   if (!GetBounds(cp, sr_h, sr_l)) return;

   double center = (sr_h + sr_l) / 2.0;
   bool crossed = (LastCenter > 0) && ((cp >= center && LastCenter < center) || (cp <= center && LastCenter > center));
   LastCenter = cp;

   if(!crossed) return;

   double dist = sr_h - sr_l;
   double validity = dist / 6.0;
   double buy_stop_p = sr_h + validity;
   double sell_stop_p = sr_l - validity;

   double buy_limit_p = sr_l;
   double sell_limit_p = sr_h;

   // Verification
   double h1 = iHigh(_Symbol, InpTF, 1);
   double l1 = iLow(_Symbol, InpTF, 1);
   double tol = InpSigTol * _Point;
   bool touched = (h1 >= sr_h - tol) || (l1 <= sr_l + tol);

   if (touched) {
      datetime sig_time = TimeCurrent();
      
      // v3c (FT - Stop Orders)
      if (CheckSequential(STRAT_V3C)) {
         if (CurrentMode == MODE_REAL_EXECUTION && ActiveStrat == STRAT_V3C) {
            OpenRealDualSignal(STRAT_V3C, ORDER_TYPE_BUY_STOP, buy_stop_p, ORDER_TYPE_SELL_STOP, sell_stop_p, sig_time);
         }
         if (!VirtualPositions[STRAT_V3C].active) {
            OpenVirtualTrade(STRAT_V3C, ORDER_TYPE_BUY_STOP, buy_stop_p); 
         }
      }
      
      // v3d (CT - Limit Orders)
      if (CheckSequential(STRAT_V3D)) {
         if (CurrentMode == MODE_REAL_EXECUTION && ActiveStrat == STRAT_V3D) {
            OpenRealDualSignal(STRAT_V3D, ORDER_TYPE_BUY_LIMIT, buy_limit_p, ORDER_TYPE_SELL_LIMIT, sell_limit_p, sig_time);
         }
         if (!VirtualPositions[STRAT_V3D].active) {
            OpenVirtualTrade(STRAT_V3D, ORDER_TYPE_SELL_LIMIT, sell_limit_p);
         }
      }
   }
}

// ─────────────────────────────────────────────
// EXECUTION & VIRTUAL TRACKING
// ─────────────────────────────────────────────

void ExecuteSignal(ENUM_STRAT_ID strat, ENUM_ORDER_TYPE type, double entry, datetime sig_time) {
   // 1. Check Sequential Rule (No existing positions/orders for this strategy)
   if (!CheckSequential(strat)) return;

   // 2. Open Virtual Trade if slot is empty
   if (!VirtualPositions[strat].active) {
      OpenVirtualTrade(strat, type, entry);
   }
   
   // 3. Open Real Trade if conditions met
   if (CurrentMode == MODE_REAL_EXECUTION && ActiveStrat == strat) {
      OpenRealTrade(strat, type, entry, sig_time);
   }
}

bool CheckSequential(ENUM_STRAT_ID strat) {
   uint magic = InpMagicPrefix + strat;
   if (PositionsTotalByMagic(magic) > 0) return false;
   if (OrdersTotalByMagic(magic) > 0) return false;
   return true;
}

void OpenVirtualTrade(ENUM_STRAT_ID strat, ENUM_ORDER_TYPE type, double entry) {
   VirtualPositions[strat].active = true;
   VirtualPositions[strat].strat_id = strat;
   VirtualPositions[strat].type = (ENUM_POSITION_TYPE)type;
   VirtualPositions[strat].entry_price = entry;
   VirtualPositions[strat].open_time = TimeCurrent();
   
   // Calculate TP/SL using nearest SR (Simplified for Orch)
   double tp = 0;
   if (type == ORDER_TYPE_BUY) {
      if (GetNearestSR(entry, true, tp)) {
         VirtualPositions[strat].tp = tp;
         VirtualPositions[strat].sl = entry - (tp - entry) / InpRatio;
      }
   } else {
      if (GetNearestSR(entry, false, tp)) {
         VirtualPositions[strat].tp = tp;
         VirtualPositions[strat].sl = entry + (entry - tp) / InpRatio;
      }
   }
}

void OpenRealDualSignal(ENUM_STRAT_ID strat, ENUM_ORDER_TYPE t1, double p1, ENUM_ORDER_TYPE t2, double p2, datetime sig_time) {
   OpenRealTrade(strat, t1, p1, sig_time);
   OpenRealTrade(strat, t2, p2, sig_time);
}

void OpenRealTrade(ENUM_STRAT_ID strat, ENUM_ORDER_TYPE type, double entry, datetime sig_time) {
   double tp = 0, sl = 0;
   string comment = "Orch:" + (string)strat + ":" + (string)sig_time;
   
   m_trade.SetExpertMagicNumber(InpMagicPrefix + strat);
   
   // Determine SL/TP
   bool is_buy = (type == ORDER_TYPE_BUY || type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP);
   if (is_buy) {
      if (GetNearestSR(entry, true, tp)) {
         sl = entry - (tp - entry) / InpRatio;
      }
   } else {
      if (GetNearestSR(entry, false, tp)) {
         sl = entry + (entry - tp) / InpRatio;
      }
   }
   
   if (tp == 0) return; // No SR found

   switch(type) {
      case ORDER_TYPE_BUY:        m_trade.Buy(InpLotSize, _Symbol, entry, sl, tp, comment); break;
      case ORDER_TYPE_SELL:       m_trade.Sell(InpLotSize, _Symbol, entry, sl, tp, comment); break;
      case ORDER_TYPE_BUY_LIMIT:  m_trade.BuyLimit(InpLotSize, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment); break;
      case ORDER_TYPE_SELL_LIMIT: m_trade.SellLimit(InpLotSize, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment); break;
      case ORDER_TYPE_BUY_STOP:   m_trade.BuyStop(InpLotSize, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment); break;
      case ORDER_TYPE_SELL_STOP:  m_trade.SellStop(InpLotSize, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment); break;
   }
}

void UpdateVirtualTrades() {
   double cp = iClose(_Symbol, _Period, 0);
   for (int i = 0; i < 4; i++) {
      if (!VirtualPositions[i].active) continue;
      
      bool closed = false;
      bool won = false;
      
      // Check SL/TP
      if (VirtualPositions[i].type == POSITION_TYPE_BUY) {
         if (cp >= VirtualPositions[i].tp) { closed = true; won = true; }
         else if (cp <= VirtualPositions[i].sl) { closed = true; won = false; }
      } else {
         if (cp <= VirtualPositions[i].tp) { closed = true; won = true; }
         else if (cp >= VirtualPositions[i].sl) { closed = true; won = false; }
      }
      
      // Check Overtime
      if (!closed && (TimeCurrent() - VirtualPositions[i].open_time > InpOvertime * 3600)) {
         closed = true;
         won = (VirtualPositions[i].type == POSITION_TYPE_BUY ? cp > VirtualPositions[i].entry_price : cp < VirtualPositions[i].entry_price);
      }
      
      if (closed) {
         VirtualPositions[i].active = false;
         if (won && CurrentMode == MODE_SPECTATOR) {
            TransitionToRealMode((ENUM_STRAT_ID)i);
         }
      }
   }
}

void TrackRealTrades() {
   if (CurrentMode != MODE_REAL_EXECUTION) return;
   
   static int last_hist_count = 0;
   HistorySelect(0, TimeCurrent());
   int curr_hist_count = HistoryDealsTotal();
   
   if (curr_hist_count > last_hist_count) {
      // First time initialization
      if (last_hist_count == 0) { last_hist_count = curr_hist_count; return; }
      
      for (int i = last_hist_count; i < curr_hist_count; i++) {
         ulong ticket = HistoryDealGetTicket(i);
         long magic = HistoryDealGetInteger(ticket, DEAL_MAGIC);
         
         if (magic == (long)(InpMagicPrefix + ActiveStrat)) {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            double comm = HistoryDealGetDouble(ticket, DEAL_COMMISSION);
            double swap = HistoryDealGetDouble(ticket, DEAL_SWAP);
            double net_profit = profit + comm + swap;
            
            long entry_type = HistoryDealGetInteger(ticket, DEAL_ENTRY);
            
            if (entry_type == DEAL_ENTRY_OUT || entry_type == DEAL_ENTRY_INOUT) {
               long pos_id = HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
               string comment = GetPositionEntryComment(pos_id);
               datetime sig_time = ParseSignalTime(comment);
               
               if (net_profit > 0) {
                  ConsecutiveLosses = 0;
                  UpdateLog("Trade Won! Cycle Reset. ID:" + (string)sig_time);
               } else {
                  // Use sig_time if available, otherwise Position ID to distinguish signals
                  long signal_id = (sig_time > 0 ? (long)sig_time : pos_id);
                  
                  if (signal_id != LastProcessedSignalID || ActiveStrat != LastProcessedStrat) {
                     ConsecutiveLosses++;
                     LastProcessedSignalID = signal_id;
                     LastProcessedStrat = ActiveStrat;
                     UpdateLog("Signal Lost! Consecutive: " + (string)ConsecutiveLosses + " ID:" + (string)sig_time);
                     if (ConsecutiveLosses >= 2) HandleLossCycle();
                  } else {
                     UpdateLog("Duplicate signal failure detected. Not incrementing losses.");
                  }
               }
            }
         }
      }
      last_hist_count = curr_hist_count;
   }
}

string GetPositionEntryComment(long pos_id) {
   if (HistorySelectByPosition(pos_id)) {
      int total = HistoryDealsTotal();
      for (int i = 0; i < total; i++) {
         ulong t = HistoryDealGetTicket(i);
         if (HistoryDealGetInteger(t, DEAL_ENTRY) == DEAL_ENTRY_IN) {
            return HistoryDealGetString(t, DEAL_COMMENT);
         }
      }
   }
   return "";
}

datetime ParseSignalTime(string comment) {
   string parts[];
   if (StringSplit(comment, ':', parts) >= 3) {
      return (datetime)StringToInteger(parts[2]);
   }
   return 0;
}

// ─────────────────────────────────────────────
// DECISION TREE LOGIC
// ─────────────────────────────────────────────

void TransitionToRealMode(ENUM_STRAT_ID strat) {
   CurrentMode = MODE_REAL_EXECUTION;
   ActiveStrat = strat;
   ConsecutiveLosses = 0;
   SwitchLevel = 0;
   UpdateLog("Spectator Win detected from " + GetStratIDName(strat) + "! Switching to REAL MODE.");
}

void HandleLossCycle() {
   ConsecutiveLosses = 0;
   SwitchLevel++;
   
   if (SwitchLevel == 1) { // Change Category
      ENUM_STRAT_TYPE old_cat = GetStratType(ActiveStrat);
      ActiveStrat = (old_cat == TYPE_CT ? PickStrategy(TYPE_FT) : PickStrategy(TYPE_CT));
      UpdateLog("2nd Loss! Switching Category to " + (ActiveStrat == STRAT_V3B || ActiveStrat == STRAT_V3C ? "FollowTrend" : "CounterTrend"));
   } 
   else if (SwitchLevel == 2) { // Change Intra-Category
      ENUM_STRAT_ID old_strat = ActiveStrat;
      if (old_strat == STRAT_V3A) ActiveStrat = STRAT_V3D;
      else if (old_strat == STRAT_V3D) ActiveStrat = STRAT_V3A;
      else if (old_strat == STRAT_V3B) ActiveStrat = STRAT_V3C;
      else if (old_strat == STRAT_V3C) ActiveStrat = STRAT_V3B;
      UpdateLog("Loss in new category! Switching intra-category to " + GetStratIDName(ActiveStrat));
   }
   else { // Return to Spectator
      CurrentMode = MODE_SPECTATOR;
      SwitchLevel = 0;
      UpdateLog("Final loss! Returning to SPECTATOR MODE.");
   }
}

ENUM_STRAT_TYPE GetStratType(ENUM_STRAT_ID id) {
   if (id == STRAT_V3A || id == STRAT_V3D) return TYPE_CT;
   return TYPE_FT;
}

ENUM_STRAT_ID PickStrategy(ENUM_STRAT_TYPE type) {
   if (type == TYPE_CT) return STRAT_V3A;
   return STRAT_V3B;
}

// ─────────────────────────────────────────────
// HELPERS & UI
// ─────────────────────────────────────────────

bool FindFocusSR(double close_1, double high_1, double low_1, double &focus_sr) {
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
   for (int i = 0; i < sz; i++) {
      double curr_l = ActiveLevels[i].price_bucket;
      if (high_1 >= curr_l - tol && low_1 <= curr_l + tol) {
         focus_sr = curr_l; return true;
      }
   }
   return false;
}

bool CheckInSRRange(double price, bool &has_above, bool &has_below) {
   has_above = false; has_below = false;
   int sz = ArraySize(ActiveLevels);
   for (int i = 0; i < sz; i++) {
      if (ActiveLevels[i].price_bucket > price) has_above = true;
      if (ActiveLevels[i].price_bucket < price) has_below = true;
   }
   return (has_above && has_below);
}

bool GetBounds(double price, double &sr_high, double &sr_low) {
   int sz = ArraySize(ActiveLevels);
   if(sz < 2) return false;
   sr_high = 1e10; sr_low = -1e10;
   bool f_h = false, f_l = false;
   for(int i=0; i<sz; i++) {
      double lvl = ActiveLevels[i].price_bucket;
      if(lvl > price && lvl < sr_high) { sr_high = lvl; f_h = true; }
      if(lvl < price && lvl > sr_low)  { sr_low = lvl; f_l = true; }
   }
   return (f_h && f_l);
}

bool GetNearestSR(double price, bool look_above, double &found_sr) {
   int sz = ArraySize(ActiveLevels);
   double best_dist = 1e10; bool found = false;
   for (int i = 0; i < sz; i++) {
      double lvl = ActiveLevels[i].price_bucket;
      if (look_above && lvl > price + _Point) {
         if (lvl - price < best_dist) { found_sr = lvl; found = true; best_dist = lvl - price; }
      } else if (!look_above && lvl < price - _Point) {
         if (price - lvl < best_dist) { found_sr = lvl; found = true; best_dist = price - lvl; }
      }
   }
   return found;
}

int PositionsTotalByMagic(long magic) {
   int count = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (m_position.SelectByIndex(i) && m_position.Magic() == magic && m_position.Symbol() == _Symbol) count++;
   }
   return count;
}

int OrdersTotalByMagic(long magic) {
   int count = 0;
   for (int i = OrdersTotal() - 1; i >= 0; i--) {
      if (m_order.SelectByIndex(i) && m_order.Magic() == magic && m_order.Symbol() == _Symbol) count++;
   }
   return count;
}

void UpdateLog(string msg) {
   DecisionLog = msg;
   Print("v3Orch: ", msg);
}

void UpdateUIOverlay() {
   string state_str = (CurrentMode == MODE_SPECTATOR ? "SPECTATOR MODE" : "REAL EXECUTION [" + GetStratIDName(ActiveStrat) + "]");
   
   string text = "=== v3all ORCHESTRATOR ===\n" +
                 "Current State: " + state_str + "\n" +
                 "Consecutive Losses: " + (string)ConsecutiveLosses + "\n" +
                 "Switch Level: " + (string)SwitchLevel + "\n" +
                 "Latest Decision: " + DecisionLog + "\n\n" +
                 "Virtual Status (V_BT):\n";
   
   for(int i=0; i<4; i++) {
      text += GetStratIDName((ENUM_STRAT_ID)i) + ": " + (VirtualPositions[i].active ? "BUSY" : "WAITING") + "\n";
   }
   
   Comment(text);
}

void DrawChartUI() {
   ObjectsDeleteAll(0, "SR_V3_");
   double cp = iClose(_Symbol, _Period, 0);
   int total = ArraySize(ActiveLevels);
   for(int i=0; i<total; i++) {
      double p = ActiveLevels[i].price_bucket;
      if (MathAbs(p - cp) < 2000 * _Point) {
         string name = "SR_V3_" + (string)i;
         ObjectCreate(0, name, OBJ_HLINE, 0, 0, p);
         ObjectSetInteger(0, name, OBJPROP_COLOR, clrDarkGray);
         ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
      }
   }
}

string GetStratIDName(ENUM_STRAT_ID id) {
   switch(id) {
      case STRAT_V3A: return "v3a (CT)";
      case STRAT_V3B: return "v3b (FT)";
      case STRAT_V3C: return "v3c (FT)";
      case STRAT_V3D: return "v3d (CT)";
      default: return "Unknown";
   }
}
