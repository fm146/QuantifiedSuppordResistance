//+------------------------------------------------------------------+
//|                                           SRSignalStrategy.mq5   |
//|                                  Copyright 2026, Antigravity AI  |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Antigravity AI"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <ChartObjects\ChartObjectsLines.mqh>
#include <ChartObjects\ChartObjectsShapes.mqh>
#include <ChartObjects\ChartObjectsTxtControls.mqh>

// ─────────────────────────────────────────────
// ENUMS
// ─────────────────────────────────────────────
enum ENUM_STRAT_TYPE {
    STRAT_REVERSAL, // Ranging - Reversal
    STRAT_FOLLOWING // Trend - Following
};

enum ENUM_ENTRY_MODE {
    MODE_AFTER_COMPLETED, // After Completed Trades
    MODE_ALL_SIGNALS      // All Signals
};

// ─────────────────────────────────────────────
// INPUTS
// ─────────────────────────────────────────────
input group "Auto-Detection Logic"
input bool      InpAutoOn       = true;         // Enable Auto-SR Levels
input ENUM_TIMEFRAMES InpSRTF   = PERIOD_H1;    // SR Timeframe
input int       InpLookback     = 5000;         // Scan Lookback (Bars)
input int       InpMinTouches   = 3;            // Min Touches Required
input double    InpClusterSense = 10.0;         // Clustering Sensitivity (Points)
input double    InpSigTol       = 0.5;          // Signal Touch Tolerance (Ticks)

input group "Manual SR Levels"
input bool      InpL1On = true;  input double InpL1 = 0.0;
input bool      InpL2On = true;  input double InpL2 = 0.0;
input bool      InpL3On = true;  input double InpL3 = 0.0;
input bool      InpL4On = true;  input double InpL4 = 0.0;
input bool      InpL5On = true;  input double InpL5 = 0.0;

input group "Strategy Settings"
input double    InpSLTPRatio    = 1.0;          // SL:TP Ratio (e.g. 1.0, 1.5, 2.0)
input ENUM_ENTRY_MODE InpMode   = MODE_AFTER_COMPLETED;
input ENUM_STRAT_TYPE InpType   = STRAT_REVERSAL;
input bool      InpShowMarkers  = true;         // Show Signal Markers (R/C)
input bool      InpShowBoxes    = true;         // Show Debug Boxes
input bool      InpShowBoxLabels= false;        // Show Price Labels on Boxes
input int       InpOvertimeHrs  = 24;           // Overtime Force Close (Hours)
input long      InpMagicNum     = 123456;       // Magic Number

// ─────────────────────────────────────────────
// GLOBALS
// ─────────────────────────────────────────────
CTrade          Trade;
double          ActiveSR[];
int             SRTouches[];
datetime        LastSRUpdate = 0;

struct DebugBox {
    long        id_tp;
    long        id_sl;
    double      tp_lvl;
    double      sl_lvl;
    bool        is_long;
    datetime    entry_time;
    bool        active;
};

CArrayObj       DebugBoxes; // Array of DebugBox objects (using a helper or managed manually)

// Since MQL5 handles objects by name, we'll use naming conventions for debug boxes.
int             DebugBoxCount = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    Trade.SetExpertMagicNumber(InpMagicNum);
    UpdateSRLevels();
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    ObjectsDeleteAll(0, "SR_");
    ObjectsDeleteAll(0, "DBX_");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // 1. Update SR Levels on New Bar of SRTF
    datetime current_sr_time = iTime(_Symbol, InpSRTF, 0);
    if(current_sr_time != LastSRUpdate) {
        UpdateSRLevels();
        LastSRUpdate = current_sr_time;
    }

    // 2. Signal Engine (Reversal)
    if(InpType == STRAT_REVERSAL) {
        CheckSignalsReversal();
    }
    
    // 3. Force Close Overtime
    CheckForceClose();
    
    // 4. Update Debug Boxes
    UpdateDebugBoxes();
}

//+------------------------------------------------------------------+
//| Update Support and Resistance Levels                             |
//+------------------------------------------------------------------+
void UpdateSRLevels()
{
    ArrayFree(ActiveSR);
    ArrayFree(SRTouches);
    
    // Manual
    double manual_p[] = {InpL1, InpL2, InpL3, InpL4, InpL5};
    bool manual_on[]  = {InpL1On, InpL2On, InpL3On, InpL4On, InpL5On};
    
    for(int i=0; i<5; i++) {
        if(manual_on[i] && manual_p[i] > 0) {
            int count = CountTouches(manual_p[i]);
            AddSR(manual_p[i], count);
        }
    }
    
    // Auto
    if(InpAutoOn) {
        double high[], low[];
        int copied = CopyHigh(_Symbol, InpSRTF, 0, InpLookback, high);
        CopyLow(_Symbol, InpSRTF, 0, InpLookback, low);
        
        struct Cand { double p; int c; };
        Cand cands[];
        ArrayResize(cands, 0);
        
        for(int i=0; i<copied; i++) {
            double ps[] = {high[i], low[i]};
            for(int j=0; j<2; j++) {
                bool found = false;
                for(int k=0; k<ArraySize(cands); k++) {
                    if(MathAbs(cands[k].p - ps[j]) <= InpClusterSense * _Point) {
                        cands[k].c++;
                        found = true;
                        break;
                    }
                }
                if(!found) {
                    int sz = ArraySize(cands);
                    ArrayResize(cands, sz+1);
                    cands[sz].p = ps[j];
                    cands[sz].c = 1;
                }
            }
        }
        
        for(int i=0; i<ArraySize(cands); i++) {
            int exact = CountTouches(cands[i].p);
            if(exact >= InpMinTouches) {
                bool exists = false;
                for(int j=0; j<ArraySize(ActiveSR); j++) {
                    if(MathAbs(ActiveSR[j] - cands[i].p) <= InpClusterSense * _Point) {
                        exists = true;
                        break;
                    }
                }
                if(!exists) AddSR(cands[i].p, exact);
            }
        }
    }
    
    DrawSRLines();
}

int CountTouches(double price)
{
    double high[], low[];
    int copied = CopyHigh(_Symbol, InpSRTF, 0, InpLookback, high);
    CopyLow(_Symbol, InpSRTF, 0, InpLookback, low);
    int count = 0;
    for(int i=0; i<copied; i++) {
        if(high[i] >= price && low[i] <= price) count++;
    }
    return count;
}

void AddSR(double p, int c)
{
    int sz = ArraySize(ActiveSR);
    ArrayResize(ActiveSR, sz+1);
    ArrayResize(SRTouches, sz+1);
    ActiveSR[sz] = p;
    SRTouches[sz] = c;
}

//+------------------------------------------------------------------+
//| Check for Reversal Signals                                       |
//+------------------------------------------------------------------+
void CheckSignalsReversal()
{
    double close0 = iClose(_Symbol, _Period, 0);
    double close1 = iClose(_Symbol, _Period, 1);
    double open0  = iOpen(_Symbol, _Period, 0);
    double high0  = iHigh(_Symbol, _Period, 0);
    double low0   = iLow(_Symbol, _Period, 0);
    
    double focus_sr = 0;
    double tol = InpSigTol * _Point;
    
    // 1. Cross Check
    for(int i=0; i<ArraySize(ActiveSR); i++) {
        double lvl = ActiveSR[i];
        if((close1 >= lvl && close0 < lvl) || (close1 <= lvl && close0 > lvl)) {
            focus_sr = lvl;
            break;
        }
    }
    
    // 2. Wick Check
    if(focus_sr == 0) {
        double target = (close0 < open0) ? low0 : high0;
        double min_dist = 1e10;
        for(int i=0; i<ArraySize(ActiveSR); i++) {
            double lvl = ActiveSR[i];
            if(high0 >= lvl - tol && low0 <= lvl + tol) {
                double dist = MathAbs(target - lvl);
                if(dist < min_dist) {
                    min_dist = dist;
                    focus_sr = lvl;
                }
            }
        }
    }
    
    if(focus_sr == 0) return;
    
    bool buy_sig = (close0 > focus_sr);
    bool sell_sig = (close0 < focus_sr);
    
    if(!buy_sig && !sell_sig) return;
    
    // Check range filter (sandwiched)
    bool has_above = false, has_below = false;
    for(int i=0; i<ArraySize(ActiveSR); i++) {
        if(ActiveSR[i] > close0 + tol) has_above = true;
        if(ActiveSR[i] < close0 - tol) has_below = true;
    }
    if(!has_above || !has_below) return;
    
    // Entry Logic
    if(InpMode == MODE_AFTER_COMPLETED && PositionSelectByMagic(InpMagicNum)) return;
    
    if(buy_sig) ExecuteTrade(ORDER_TYPE_BUY, close0);
    if(sell_sig) ExecuteTrade(ORDER_TYPE_SELL, close0);
}

void ExecuteTrade(ENUM_ORDER_TYPE type, double p)
{
    double tp = 0, sl = 0;
    if(type == ORDER_TYPE_BUY) {
        double min_above = 1e10;
        for(int i=0; i<ArraySize(ActiveSR); i++) {
            if(ActiveSR[i] > p + 2*_Point && ActiveSR[i] < min_above) min_above = ActiveSR[i];
        }
        if(min_above < 1e10) {
            tp = min_above;
            sl = p - (tp - p) / InpSLTPRatio;
        }
    } else {
        double max_below = -1;
        for(int i=0; i<ArraySize(ActiveSR); i++) {
            if(ActiveSR[i] < p - 2*_Point && ActiveSR[i] > max_below) max_below = ActiveSR[i];
        }
        if(max_below > 0) {
            tp = max_below;
            sl = p + (p - tp) / InpSLTPRatio;
        }
    }
    
    if(tp > 0) {
        string comment = (type == ORDER_TYPE_BUY ? "Buy " : "Sell ") + DoubleToString(p, _Digits) + 
                         "\nSL : " + DoubleToString(sl, _Digits) + "\nTP : " + DoubleToString(tp, _Digits);
        
        Trade.PositionOpen(_Symbol, type, 0.1, p, sl, tp, comment);
        if(InpShowBoxes) CreateDebugBox(type == ORDER_TYPE_BUY, p, tp, sl);
        if(InpShowMarkers) CreateMarker(type == ORDER_TYPE_BUY, p);
    }
}

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
void CheckForceClose()
{
    for(int i=PositionsTotal()-1; i>=0; i--) {
        if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNum) {
            datetime entry_t = (datetime)PositionGetInteger(POSITION_TIME);
            if(TimeCurrent() - entry_t >= InpOvertimeHrs * 3600) {
                Trade.PositionClose(PositionGetTicket(i), "Force Closed - Overtime");
            }
        }
    }
}

void DrawSRLines()
{
    ObjectsDeleteAll(0, "SR_");
    for(int i=0; i<ArraySize(ActiveSR); i++) {
        string name = "SR_" + IntegerToString(i);
        ObjectCreate(0, name, OBJ_HLINE, 0, 0, ActiveSR[i]);
        ObjectSetInteger(0, name, OBJPROP_COLOR, clrOrange);
        ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
        ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
        
        string lbl = "SR_L_" + IntegerToString(i);
        ObjectCreate(0, lbl, OBJ_TEXT, 0, TimeCurrent(), ActiveSR[i]);
        ObjectSetString(0, lbl, OBJPROP_TEXT, DoubleToString(ActiveSR[i], _Digits) + " (" + (string)SRTouches[i] + ")");
        ObjectSetInteger(0, lbl, OBJPROP_COLOR, clrWhite);
    }
}

void CreateDebugBox(bool is_long, double p, double tp, double sl)
{
    DebugBoxCount++;
    string prefix = "DBX_" + (string)DebugBoxCount + "_";
    
    // TP Box (Green)
    ObjectCreate(0, prefix+"TP", OBJ_RECTANGLE, 0, TimeCurrent(), p, TimeCurrent()+600, tp);
    ObjectSetInteger(0, prefix+"TP", OBJPROP_COLOR, clrLime);
    ObjectSetInteger(0, prefix+"TP", OBJPROP_FILL, true);
    ObjectSetInteger(0, prefix+"TP", OBJPROP_BACK, true);
    
    // SL Box (Red)
    ObjectCreate(0, prefix+"SL", OBJ_RECTANGLE, 0, TimeCurrent(), p, TimeCurrent()+600, sl);
    ObjectSetInteger(0, prefix+"SL", OBJPROP_COLOR, clrRed);
    ObjectSetInteger(0, prefix+"SL", OBJPROP_FILL, true);
    ObjectSetInteger(0, prefix+"SL", OBJPROP_BACK, true);
    
    // Store levels in object descriptions or global array if needed
}

void UpdateDebugBoxes()
{
    // Update right side of active debug boxes
    // In MQL5, we'd need to track which ones are active. 
    // Simplified: update all "DBX_" objects until they hit target.
    for(int i=ObjectsTotal(0)-1; i>=0; i--) {
        string name = ObjectName(0, i);
        if(StringFind(name, "DBX_") == 0) {
            // Update time2 to current time
            ObjectSetInteger(0, name, OBJPROP_TIME, 1, TimeCurrent());
            
            // Check for hit (Logic omitted for brevity in POC, 
            // but basically: if Price hits lvl, stop updating this ID)
        }
    }
}

void CreateMarker(bool is_buy, double p)
{
    string name = "SR_M_" + (string)TimeCurrent();
    ObjectCreate(0, name, OBJ_ARROW, 0, TimeCurrent(), p);
    ObjectSetInteger(0, name, OBJPROP_ARROWCODE, is_buy ? 241 : 242);
    ObjectSetInteger(0, name, OBJPROP_COLOR, is_buy ? clrLime : clrRed);
}

bool PositionSelectByMagic(long magic) {
    for(int i=0; i<PositionsTotal(); i++) {
        if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == magic) return true;
    }
    return false;
}
