//+------------------------------------------------------------------+
//|                                              BTCCycle Trader.mq5 |
//|                                  Copyright 2024, Trading AI Corp |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Trading AI Corp"
#property link "https://www.mql5.com"
#property version "1.00"
#property strict

#include <Trade\Trade.mqh>

// --- INPUTS ---
input int InpStartYear = 2010;       // Cycle Start Year
input int InpStartMonth = 2;         // Cycle Start Month
input int InpStartDay = 14;          // Cycle Start Day
input int InpBearDays = 376;         // Bear Cycle Length
input int InpBullDays = 1050;        // Bull Cycle Length
input double InpSLPerc = 50.0;       // Stop Loss %
input double InpVolumePerc = 50.0;   // % of Equity for Volume
input long InpMagic = 3761050;       // Magic Number
input bool InpInverseCycles = false; // Inverse Cycle Phases?

// --- GLOBALS ---
CTrade trade;
datetime cycleStartTime;
int cycleLength;
bool reversedThisBar = false;
datetime lastBarTime;
const string OBJ_PREFIX = "BTCCycle_";
bool pendingEntry = false;   // Wait-1-bar flag
ENUM_ORDER_TYPE pendingType; // Type of pending entry

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
  MqlDateTime dt;
  dt.year = InpStartYear;
  dt.mon = InpStartMonth;
  dt.day = InpStartDay;
  dt.hour = 0;
  dt.min = 0;
  dt.sec = 0;

  cycleStartTime = StructToTime(dt);
  cycleLength = InpBearDays + InpBullDays;

  if (cycleLength <= 0) {
    Print("Invalid cycle length. Please check inputs.");
    return (INIT_PARAMETERS_INCORRECT);
  }

  trade.SetExpertMagicNumber(InpMagic);

  // Draw background cycles for visual debugging
  DrawCycles();

  return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) { ObjectsDeleteAll(0, OBJ_PREFIX); }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
  datetime currentTime = iTime(_Symbol, _Period, 0);

  // New bar detection
  if (currentTime != lastBarTime) {
    reversedThisBar = false;
    lastBarTime = currentTime;

    // If previous bar was flip-day, enter NOW at this bar's open (= close of
    // flip candle)
    if (pendingEntry) {
      ExecuteTrade(pendingType);
      pendingEntry = false;
    }

    // Check if THIS bar triggers a new flip
    CheckCycleFlip(currentTime);
  }

  // Continuous dashboard update
  UpdateDashboard();

  // Continuous Stop Loss and Auto-Reverse monitoring
  CheckStopLoss();
}

//+------------------------------------------------------------------+
//| Check for Cycle Flip and Initial Entry                           |
//+------------------------------------------------------------------+
void CheckCycleFlip(datetime barTime) {
  // Get current and previous bar times for cycle calculation
  datetime times[2];
  if (CopyTime(_Symbol, _Period, 0, 2, times) < 2)
    return;

  long daysFromStart = (long)(times[0] - cycleStartTime) / 86400;
  long prevDaysFromStart = (long)(times[1] - cycleStartTime) / 86400;

  if (daysFromStart < 0)
    return;

  int cyclePos = (int)(daysFromStart % cycleLength);
  int prevCyclePos = (int)(prevDaysFromStart % cycleLength);

  bool isBull = (cyclePos >= InpBearDays);
  bool wasBull = (prevCyclePos >= InpBearDays);

  if (InpInverseCycles) {
    isBull = !isBull;
    wasBull = !wasBull;
  }

  // Identify flips
  bool enterLong = (isBull && !wasBull);
  bool enterShort = (!isBull && wasBull);

  // Cycle flip: close current position, defer entry to NEXT bar's open
  if (isBull != wasBull) {
    PrintFormat("Cycle Flip! Phase will be: %s | Flip candle date: %s | Will "
                "enter at next open",
                isBull ? "BULL" : "BEAR", TimeToString(times[0], TIME_DATE));

    if (AccountInfoDouble(ACCOUNT_EQUITY) > 0) {
      CloseAllPositions();
      // Set pending — entry happens at open of NEXT bar (= close of this
      // candle)
      pendingEntry = true;
      pendingType = isBull ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
    }
  }
}

//+------------------------------------------------------------------+
//| Check for Position Count                                         |
//+------------------------------------------------------------------+
int PositionCount() {
  int count = 0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    if (PositionSelectByTicket(PositionGetTicket(i))) {
      if (PositionGetString(POSITION_SYMBOL) == _Symbol &&
          PositionGetInteger(POSITION_MAGIC) == InpMagic)
        count++;
    }
  }
  return count;
}

//+------------------------------------------------------------------+
//| Check for Specific Position Type                                 |
//+------------------------------------------------------------------+
bool PositionExists(ENUM_POSITION_TYPE type) {
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong ticket = PositionGetTicket(i);
    if (PositionSelectByTicket(ticket)) {
      if (PositionGetString(POSITION_SYMBOL) == _Symbol &&
          PositionGetInteger(POSITION_MAGIC) == InpMagic &&
          PositionGetInteger(POSITION_TYPE) == type) {
        return true;
      }
    }
  }
  return false;
}

//+------------------------------------------------------------------+
//| Close all expert positions for this symbol                      |
//+------------------------------------------------------------------+
void CloseAllPositions() {
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong ticket = PositionGetTicket(i);
    if (PositionSelectByTicket(ticket)) {
      if (PositionGetString(POSITION_SYMBOL) == _Symbol &&
          PositionGetInteger(POSITION_MAGIC) == InpMagic) {
        trade.PositionClose(ticket);
      }
    }
  }
}

//+------------------------------------------------------------------+
//| Execute Trade with Volume calculation                            |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type, double price = 0) {
  double volume = CalculateVolume();

  if (type == ORDER_TYPE_BUY)
    trade.Sell(volume, _Symbol, 0, 0, 0, "Long");
  else
    trade.Buy(volume, _Symbol, 0, 0, 0, "Short");
}

//+------------------------------------------------------------------+
//| Lot Calculation based on % of Equity                             |
//+------------------------------------------------------------------+
double CalculateVolume() {
  double equity = AccountInfoDouble(ACCOUNT_EQUITY);
  double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  double lotMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double lotMax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

  // Simplified volume: 50% of equity used for position size.
  // Note: Actual lot sizing depends on leverage and asset type (e.g. BTC vs
  // Fore). Using a conservative approach for general conversion.
  double targetEquity = equity * (InpVolumePerc / 100.0);

  // For BTC/USD, often 1 lot = 1 BTC. Price is ~60k-70k.
  // If equity is 10k, 50% is 5k. Lots = 5000 / Price.
  double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
  if (price <= 0)
    price = iClose(_Symbol, _Period, 0);

  double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
  if (contractSize <= 0)
    contractSize = 1.0;

  double lots = targetEquity / (price * contractSize);

  lots = MathRound(lots / lotStep) * lotStep;
  if (lots < lotMin)
    lots = lotMin;
  if (lots > lotMax)
    lots = lotMax;

  return lots;
}

//+------------------------------------------------------------------+
//| Tick-based Stop Loss and Auto-Reverse Logic                      |
//+------------------------------------------------------------------+
void CheckStopLoss() {
  if (reversedThisBar || AccountInfoDouble(ACCOUNT_EQUITY) <= 0)
    return;

  double slFactor = InpSLPerc / 100.0;

  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong ticket = PositionGetTicket(i);
    if (PositionSelectByTicket(ticket)) {
      if (PositionGetString(POSITION_SYMBOL) == _Symbol &&
          PositionGetInteger(POSITION_MAGIC) == InpMagic) {
        double entryPricePos = PositionGetDouble(POSITION_PRICE_OPEN);
        ENUM_POSITION_TYPE type =
            (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

        if (type == POSITION_TYPE_BUY) {
          double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
          if (currentBid <= entryPricePos * (1.0 - slFactor)) {
            CloseAllPositions();
            ExecuteTrade(ORDER_TYPE_BUY);
            reversedThisBar = true;
            break;
          }
        } else if (type == POSITION_TYPE_SELL) {
          double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
          if (currentAsk >= entryPricePos * (1.0 + slFactor)) {
            CloseAllPositions();
            ExecuteTrade(ORDER_TYPE_BUY);
            reversedThisBar = true;
            break;
          }
        }
      }
    }
  }
}

//+------------------------------------------------------------------+
//| Draw Cycle Background Colors                                     |
//+------------------------------------------------------------------+
void DrawCycles() {
  ObjectsDeleteAll(0, OBJ_PREFIX);

  datetime chartStart =
      (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_FIRSTDATE);
  datetime endTime = TimeCurrent() + 86400 * 365 * 2; // Look 2 years ahead

  // Anchor to a reasonable start to avoid drawing thousands of rectangles
  datetime current = cycleStartTime;
  if (chartStart > cycleStartTime) {
    long cyclesToSkip =
        (long)(chartStart - cycleStartTime) / (cycleLength * 86400);
    current += cyclesToSkip * cycleLength * 86400;
  }

  int safety = 0;
  while (current < endTime && safety < 200) {
    datetime bearEnd = current + InpBearDays * 86400;
    datetime bullEnd = bearEnd + InpBullDays * 86400;

    color bearClr = InpInverseCycles ? C '20,45,20' : C '45,20,20';
    color bullClr = InpInverseCycles ? C '45,20,20' : C '20,45,20';

    CreateRect(OBJ_PREFIX + "Phase1_" + (string)current, current, bearEnd,
               bearClr);
    CreateRect(OBJ_PREFIX + "Phase2_" + (string)bearEnd, bearEnd, bullEnd,
               bullClr);

    current = bullEnd;
    safety++;
  }
}

//+------------------------------------------------------------------+
//| Create Background Rectangle                                      |
//+------------------------------------------------------------------+
void CreateRect(string name, datetime t1, datetime t2, color clr) {
  if (ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, 0, t2, 1000000)) {
    ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
    ObjectSetInteger(0, name, OBJPROP_BACK, true);
    ObjectSetInteger(0, name, OBJPROP_FILL, true);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
    ObjectSetInteger(0, name, OBJPROP_ZORDER, -1);
  }
}

//+------------------------------------------------------------------+
//| Update Dashboard Comment                                         |
//+------------------------------------------------------------------+
void UpdateDashboard() {
  long daysFromStart = (long)(TimeCurrent() - cycleStartTime) / 86400;
  int cyclePos = (int)(daysFromStart % cycleLength);
  bool isBull = (cyclePos >= InpBearDays);
  if (InpInverseCycles)
    isBull = !isBull;

  int daysLeft = isBull ? (cycleLength - cyclePos) : (InpBearDays - cyclePos);
  if (InpInverseCycles && !isBull)
    daysLeft = cycleLength - cyclePos; // Adjust for inverted logic
  if (InpInverseCycles && isBull)
    daysLeft = InpBearDays - cyclePos;

  string phase = isBull ? "BULL (Long)" : "BEAR (Short)";

  string msg = "--- BTCCycle Trader Dashboard ---\n";
  msg +=
      "Time: " + TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + "\n";
  msg += "Current Phase: " + phase + "\n";
  msg += "Cycle Position: " + (string)cyclePos + " Days\n";
  msg += "Next Flip In: " + (string)daysLeft + " Days\n";
  msg += "----------------------------------";

  Comment(msg);
}
