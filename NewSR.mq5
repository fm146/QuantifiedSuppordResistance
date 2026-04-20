//+------------------------------------------------------------------+
//|                                                        NewSR.mq5 |
//|                                  Copyright 2026, Antigravity AI  |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Antigravity AI"
#property link      "https://www.mql5.com"
#property version   "1.10"
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
input group "SR File Loading"
input string    InpFileName     = "SR_Levels.csv"; // Filename (in MQL5/Files)
input double    InpSandwichPct  = 12.5;         // Min Sandwiched SR Range (% of Daily Range)
input double    InpSigTol       = 0.5;          // Signal Touch Tolerance (Ticks)

input group "Manual SR Levels"
input bool      InpL1On = false;  input double InpL1 = 0.0;
input bool      InpL2On = false;  input double InpL2 = 0.0;
input bool      InpL3On = false;  input double InpL3 = 0.0;
input bool      InpL4On = false;  input double InpL4 = 0.0;
input bool      InpL5On = false;  input double InpL5 = 0.0;

input group "Display Settings"
input ENUM_STRAT_TYPE InpType   = STRAT_REVERSAL;
input bool      InpShowMarkers  = true;         // Show Signal Markers (R/C)
input bool      InpShowBoxes    = true;         // Show SL/TP Boxes (Debug)

input group "Strategy Settings"
input double    InpSLTPRatio    = 1.0;          // SL:TP Ratio
input ENUM_ENTRY_MODE InpMode   = MODE_AFTER_COMPLETED;
input int       InpOvertimeHrs  = 24;           // Overtime Force Close (Hours)
input long      InpMagicNum     = 123456;       // Magic Number
input double    InpLot          = 0.1;          // Lot Size

// ─────────────────────────────────────────────
// GLOBALS
// ─────────────────────────────────────────────
CTrade          Trade;
double          ActiveSR[];
int             SRTouches[];
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
    // Refresh levels every hour or manually if need be
    static datetime last_upd = 0;
    if(TimeCurrent() - last_upd > 3600) {
        UpdateSRLevels();
        last_upd = TimeCurrent();
    }

    // Signal Engine
    if(InpType == STRAT_REVERSAL) {
        CheckSignalsReversal();
    }
    
    // Force Close Overtime
    CheckForceClose();
}

//+------------------------------------------------------------------+
//| Update Support and Resistance Levels                             |
//+------------------------------------------------------------------+
void UpdateSRLevels()
{
    ArrayFree(ActiveSR);
    ArrayFree(SRTouches);
    
    // 1. Manual Inputs
    double manual_p[] = {InpL1, InpL2, InpL3, InpL4, InpL5};
    bool manual_on[]  = {InpL1On, InpL2On, InpL3On, InpL4On, InpL5On};
    for(int i=0; i<5; i++) {
        if(manual_on[i] && manual_p[i] > 0) {
            AddSR(manual_p[i], CountTouches(manual_p[i]));
        }
    }
    
    // 2. File Loading
    LoadSRFromFile(InpFileName);
    
    DrawSRLines();
}

void LoadSRFromFile(string filename)
{
    Alert("Attempting to load SR file: " + filename);
    // Try local folder first, then common folder if it fails
    int handle = FileOpen(filename, FILE_READ | FILE_TXT | FILE_ANSI);
    if(handle == INVALID_HANDLE) {
        handle = FileOpen(filename, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
    }
    
    if(handle != INVALID_HANDLE) {
        int count = 0;
        while(!FileIsEnding(handle)) {
            string line = FileReadString(handle);
            StringTrimLeft(line);
            StringTrimRight(line);
            if(line == "") continue;
            
            // Clean thousands separators (commas)
            StringReplace(line, ",", "");
            double p = StringToDouble(line);
            
            if(p > 0) {
                bool dup = false;
                for(int i=0; i<ArraySize(ActiveSR); i++) {
                    if(MathAbs(ActiveSR[i] - p) < 0.0001) { dup = true; break; }
                }
                if(!dup) {
                    AddSR(p, CountTouches(p));
                    count++;
                    Print("Parsed SR Level: ", p);
                }
            }
        }
        FileClose(handle);
        Alert("SR Loading Complete. Total levels from file: " + (string)count);
    } else {
        Alert("Failed to load file: " + filename + ". Error code: " + (string)GetLastError() + ". Ensure it is in MQL5/Files/");
        Print("MQL5 Path: ", TerminalInfoString(TERMINAL_DATA_PATH));
    }
}

int CountTouches(double price)
{
    static double h_buf[], l_buf[];
    static datetime last_buf_time = 0;
    int lookback = 3000; 
    if(TimeCurrent() - last_buf_time > 3600) {
        CopyHigh(_Symbol, PERIOD_H1, 0, lookback, h_buf);
        CopyLow(_Symbol, PERIOD_H1, 0, lookback, l_buf);
        last_buf_time = TimeCurrent();
    }
    int count = 0;
    int size = ArraySize(h_buf);
    for(int i=0; i<size; i++) {
        if(h_buf[i] >= price && l_buf[i] <= price) count++;
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
                if(dist < min_dist) { min_dist = dist; focus_sr = lvl; }
            }
        }
    }
    
    if(focus_sr == 0) return;
    
    bool buy_sig = (close0 > focus_sr);
    bool sell_sig = (close0 < focus_sr);
    if(!buy_sig && !sell_sig) return;
    
    // Sandwich Detection
    double near_above = 1e10, near_below = -1;
    for(int i=0; i<ArraySize(ActiveSR); i++) {
        if(ActiveSR[i] > close0 + tol && ActiveSR[i] < near_above) near_above = ActiveSR[i];
        if(ActiveSR[i] < close0 - tol && ActiveSR[i] > near_below) near_below = ActiveSR[i];
    }
    if(near_above == 1e10 || near_below == -1) return;
    
    double full_daily = GetFullDailyRange();
    if((near_above - near_below) < (full_daily * InpSandwichPct / 100.0)) return;

    if(InpShowMarkers) CreateMarker(buy_sig, close0);
    
    if(InpMode == MODE_AFTER_COMPLETED && PositionSelectByMagic(InpMagicNum)) return;
    ExecuteTrade(buy_sig ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, close0);
}

void DrawSRLines()
{
    ObjectsDeleteAll(0, "SR_");
    for(int i=0; i<ArraySize(ActiveSR); i++) {
        string name = "SR_" + IntegerToString(i);
        ObjectCreate(0, name, OBJ_HLINE, 0, 0, ActiveSR[i]);
        ObjectSetInteger(0, name, OBJPROP_COLOR, clrOrange);
        ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
        
        string lbl = "SR_L_" + IntegerToString(i);
        ObjectCreate(0, lbl, OBJ_TEXT, 0, TimeCurrent(), ActiveSR[i]);
        ObjectSetString(0, lbl, OBJPROP_TEXT, DoubleToString(ActiveSR[i], _Digits) + " (" + (string)SRTouches[i] + ")");
        ObjectSetInteger(0, lbl, OBJPROP_COLOR, clrWhite);
    }
}

void CreateMarker(bool is_buy, double p)
{
    string name = "SR_M_" + (string)TimeCurrent();
    ObjectCreate(0, name, OBJ_ARROW, 0, TimeCurrent(), p);
    ObjectSetInteger(0, name, OBJPROP_ARROWCODE, is_buy ? 241 : 242);
    ObjectSetInteger(0, name, OBJPROP_COLOR, is_buy ? clrLime : clrRed);
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
        Trade.PositionOpen(_Symbol, type, InpLot, p, sl, tp, comment);
        if(InpShowBoxes) CreateDebugBox(type == ORDER_TYPE_BUY, p, tp, sl);
    }
}

void CheckForceClose()
{
    for(int i=PositionsTotal()-1; i>=0; i--) {
        if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNum) {
            datetime entry_t = (datetime)PositionGetInteger(POSITION_TIME);
            if(TimeCurrent() - entry_t >= InpOvertimeHrs * 3600) {
                Trade.PositionClose(PositionGetTicket(i));
            }
        }
    }
}

void CreateDebugBox(bool is_long, double p, double tp, double sl)
{
    DebugBoxCount++;
    string prefix = "DBX_" + (string)DebugBoxCount + "_";
    ObjectCreate(0, prefix+"TP", OBJ_RECTANGLE, 0, TimeCurrent(), p, TimeCurrent()+6000, tp);
    ObjectSetInteger(0, prefix+"TP", OBJPROP_COLOR, clrLime);
    ObjectSetInteger(0, prefix+"TP", OBJPROP_FILL, true);
    ObjectSetInteger(0, prefix+"TP", OBJPROP_BACK, true);
    ObjectCreate(0, prefix+"SL", OBJ_RECTANGLE, 0, TimeCurrent(), p, TimeCurrent()+6000, sl);
    ObjectSetInteger(0, prefix+"SL", OBJPROP_COLOR, clrRed);
    ObjectSetInteger(0, prefix+"SL", OBJPROP_FILL, true);
    ObjectSetInteger(0, prefix+"SL", OBJPROP_BACK, true);
}

bool PositionSelectByMagic(long magic) {
    for(int i=0; i<PositionsTotal(); i++) {
        if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == magic) return true;
    }
    return false;
}

double GetFullDailyRange()
{
    double h = iHigh(_Symbol, PERIOD_D1, 1);
    double l = iLow(_Symbol, PERIOD_D1, 1);
    return (h > l) ? (h - l) : 0;
}
