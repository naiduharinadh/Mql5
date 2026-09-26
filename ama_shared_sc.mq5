//+------------------------------------------------------------------+
//|        Aman bro shared              GoldGridRecovery_EA.mq5      |
//|                                    Grid/Pyramid Recovery Bot     |
//|                                    RSI-directed entry + basket   |
//+------------------------------------------------------------------+
#property copyright "Hari Trading Bot"
#property version   "1.00"
#property description "Gold Grid Recovery EA — RSI entry, pyramid layers,"
#property description "basket profit lock with trailing, intraday loss recovery."
#property description "Demo-tested. Add equity-stop before live use."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters — matches the spreadsheet spec                  |
//+------------------------------------------------------------------+
input group "=== Cycle & Profit ==="
input double   InpStepProfit         = 5.0;    // Step profit to lock & restart ($)
input bool     InpPauseAfterStep     = true;   // Pause trading after step target
input int      InpPauseDuration      = 15;     // Pause duration (minutes)
input ENUM_TIMEFRAMES InpCycleTF     = PERIOD_M15; // Cycle timeframe

input group "=== Lot Sizing ==="
input double   InpBaseLot            = 0.01;   // Standard base lot size
input double   InpPyramidMultiplier  = 1.0;    // Multiplier per pyramid layer (1=no increase)
input double   InpRecoveryLotCap     = 0.01;   // Hard cap on recovery lot

input group "=== Loss Recovery ==="
input bool     InpAutoRecover        = true;   // Auto-recover intraday losses
input int      InpRecoveryPoints     = 150;    // Expected points to recover loss

input group "=== Grid / Pyramid ==="
input int      InpGridDistance        = 200;    // Distance between layers (points)
input int      InpPyramidLayers       = 1;     // Total pyramid layers per side
input bool     InpAutoReplaceLayer    = true;   // Re-place layer if stopped by trailing SL
input bool     InpShiftHedgeLock      = true;   // Shift hedge-lock to nearest opposite

input group "=== Basket Management ==="
input double   InpHardBasketTP        = 0;     // Hard basket TP ($) (0 = use stepped lock)
input bool     InpEnableTrailing      = true;  // Enable global basket profit trailing
input double   InpTrailStep           = 1.0;   // Trail step ($) — how much profit must grow to raise floor
input double   InpTrailDistance       = 2.0;   // Trail distance ($) — floor sits this far below peak

input group "=== Trading Window ==="
input string   InpWindowStart         = "01:00"; // Trading window start (server time)
input string   InpWindowEnd           = "23:00"; // Trading window end (server time)
input int      InpMaxSpread           = 70;      // Max spread (points)
input int      InpMaxSlippage         = 30;      // Max slippage (points)

input group "=== Entry Logic (RSI) ==="
input int      InpRSIPeriod           = 14;      // RSI period
input int      InpRSIBuyBelow         = 40;      // Open BUY when RSI < this
input int      InpRSISellAbove        = 60;      // Open SELL when RSI > this

input group "=== Safety (CRITICAL for live) ==="
input double   InpMaxEquityDD         = 30.0;   // Max equity drawdown % — close all & stop
input double   InpMaxDailyLoss        = 5.0;    // Max daily loss % — stop new trades
input double   InpMaxBasketLoss       = 50.0;   // Max basket floating loss ($) — close all

input group "=== General ==="
input ulong    InpMagic               = 888111;   // Magic number
input bool     InpLogTrades           = true;      // Log trades to CSV

//+------------------------------------------------------------------+
//| Cycle state                                                        |
//+------------------------------------------------------------------+
enum ENUM_CYCLE_STATE
{
   CYCLE_IDLE,        // No active cycle, looking for entry
   CYCLE_ACTIVE,      // Trades open, managing basket
   CYCLE_PAUSED       // Post-profit pause
};

//+------------------------------------------------------------------+
//| Globals                                                            |
//+------------------------------------------------------------------+
int            g_hRSI;
datetime       g_lastBarTime       = 0;
ENUM_CYCLE_STATE g_cycleState      = CYCLE_IDLE;
int            g_cycleDirection     = 0;         // +1 = BUY cycle, -1 = SELL cycle
int            g_buyLayers          = 0;
int            g_sellLayers         = 0;
bool           g_hedgeActive        = false;
double         g_dailyLossAccum     = 0.0;       // Realized losses today
double         g_dailyStartEquity   = 0.0;
datetime       g_currentDay         = 0;
datetime       g_pauseEndTime       = 0;
double         g_basketPeakProfit   = 0.0;       // For trailing
double         g_trailingFloor      = 0.0;       // Profit floor when trailing
bool           g_trailingActive     = false;
double         g_initialEquity      = 0.0;       // For drawdown calc
CTrade         g_trade;

//+------------------------------------------------------------------+
//| OnInit                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   g_hRSI = iRSI(_Symbol, InpCycleTF, InpRSIPeriod, PRICE_CLOSE);
   if(g_hRSI == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create RSI handle");
      return INIT_FAILED;
   }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpMaxSlippage);
   g_trade.SetTypeFilling(DetectFillingType());

   g_initialEquity    = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dailyStartEquity = g_initialEquity;
   g_cycleState       = CYCLE_IDLE;

   SyncExistingPositions();

   if(InpLogTrades)
      InitLogFile();

   PrintFormat("Grid Recovery EA started | %s %s | Base lot %.2f | Magic %I64u",
               _Symbol, EnumToString(InpCycleTF), InpBaseLot, InpMagic);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_hRSI != INVALID_HANDLE) IndicatorRelease(g_hRSI);
   Comment("");
}

//+------------------------------------------------------------------+
//| OnTick                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   ResetDailyCounters();
   UpdateChartComment();

   //--- Safety circuit breakers (checked every tick) ---

   if(CheckEquityDrawdown())
      return;

   if(InpMaxBasketLoss > 0 && g_cycleState == CYCLE_ACTIVE)
   {
      double basketPnL = GetBasketPnL();
      if(basketPnL <= -InpMaxBasketLoss)
      {
         PrintFormat("BASKET LOSS LIMIT: $%.2f — closing all", basketPnL);
         CloseAllPositions("BASKET_LOSS_LIMIT");
         g_dailyLossAccum += MathAbs(basketPnL);
         ResetCycle();
         return;
      }
   }

   //--- Basket management runs every tick (trailing reacts to price) ---

   if(g_cycleState == CYCLE_ACTIVE)
   {
      ManageBasket();

      if(!IsNewBar())
         return;

      ManageGridLayers();
   }
   else if(g_cycleState == CYCLE_PAUSED)
   {
      if(TimeCurrent() >= g_pauseEndTime)
      {
         Print("Pause ended — ready for new cycle");
         g_cycleState = CYCLE_IDLE;
      }
      return;
   }
   else // CYCLE_IDLE
   {
      if(!IsNewBar())
         return;

      if(!IsWithinWindow())
         return;

      if(!CheckSpread())
         return;

      if(InpMaxDailyLoss > 0 && IsDailyLossHit())
      {
         Print("Daily loss limit hit — no new cycles today");
         return;
      }

      if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
         !MQLInfoInteger(MQL_TRADE_ALLOWED))
         return;

      TryStartCycle();
   }
}


// ================================================================
//  ENTRY LOGIC — RSI-directed first trade
// ================================================================

//+------------------------------------------------------------------+
//| Decide cycle direction from RSI and open first trade               |
//+------------------------------------------------------------------+
void TryStartCycle()
{
   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(g_hRSI, 0, 0, 3, rsi) < 3) return;

   double rsi1 = rsi[1]; // most recently closed bar

   int direction = 0;
   if(rsi1 < InpRSIBuyBelow)
      direction = +1;   // oversold → BUY
   else if(rsi1 > InpRSISellAbove)
      direction = -1;   // overbought → SELL
   else
      return;            // no signal, wait

   double lot = CalculateCycleLot();
   if(lot <= 0) return;

   bool ok = false;
   if(direction == +1)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      ok = g_trade.Buy(lot, _Symbol, ask, 0, 0,
                        StringFormat("Grid_BUY_L0|M%I64u", InpMagic));
   }
   else
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      ok = g_trade.Sell(lot, _Symbol, bid, 0, 0,
                         StringFormat("Grid_SELL_L0|M%I64u", InpMagic));
   }

   if(ok)
   {
      g_cycleState      = CYCLE_ACTIVE;
      g_cycleDirection   = direction;
      g_buyLayers        = (direction == +1) ? 1 : 0;
      g_sellLayers       = (direction == -1) ? 1 : 0;
      g_hedgeActive      = false;
      g_basketPeakProfit = 0;
      g_trailingFloor    = 0;
      g_trailingActive   = false;

      PrintFormat("CYCLE STARTED: %s | lot=%.2f | RSI=%.1f",
                  direction == +1 ? "BUY" : "SELL", lot, rsi1);
      LogTrade(direction == +1 ? "CYCLE_BUY" : "CYCLE_SELL",
               direction == +1 ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) :
                                 SymbolInfoDouble(_Symbol, SYMBOL_BID),
               0, 0, lot, rsi1);
   }
}


// ================================================================
//  GRID / PYRAMID MANAGEMENT
// ================================================================

//+------------------------------------------------------------------+
//| Check if a new pyramid layer should be added                       |
//+------------------------------------------------------------------+
void ManageGridLayers()
{
   if(g_cycleState != CYCLE_ACTIVE) return;

   double gridDist = InpGridDistance * SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   // Count current positions to know actual layer counts
   int buyCount = 0, sellCount = 0;
   double worstBuyPrice = 0, worstSellPrice = 999999;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long posType = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);

      if(posType == POSITION_TYPE_BUY)
      {
         buyCount++;
         if(openPrice < worstBuyPrice || worstBuyPrice == 0)
            worstBuyPrice = openPrice;
      }
      else
      {
         sellCount++;
         if(openPrice > worstSellPrice || worstSellPrice == 999999)
            worstSellPrice = openPrice;
      }
   }

   g_buyLayers  = buyCount;
   g_sellLayers = sellCount;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Add pyramid layer on the cycle's side if price moved against us
   if(g_cycleDirection == +1 && buyCount > 0 && buyCount <= InpPyramidLayers)
   {
      if(worstBuyPrice > 0 && ask <= worstBuyPrice - gridDist)
      {
         if(CheckSpread())
         {
            double lot = CalculateLayerLot(buyCount);
            if(lot > 0 && g_trade.Buy(lot, _Symbol, ask, 0, 0,
               StringFormat("Grid_BUY_L%d|M%I64u", buyCount, InpMagic)))
            {
               PrintFormat("PYRAMID BUY layer %d @ %.2f | lot=%.2f", buyCount, ask, lot);
               LogTrade("PYRAMID_BUY", ask, 0, 0, lot, 0);
            }
         }
      }
   }

   if(g_cycleDirection == -1 && sellCount > 0 && sellCount <= InpPyramidLayers)
   {
      if(worstSellPrice < 999999 && bid >= worstSellPrice + gridDist)
      {
         if(CheckSpread())
         {
            double lot = CalculateLayerLot(sellCount);
            if(lot > 0 && g_trade.Sell(lot, _Symbol, bid, 0, 0,
               StringFormat("Grid_SELL_L%d|M%I64u", sellCount, InpMagic)))
            {
               PrintFormat("PYRAMID SELL layer %d @ %.2f | lot=%.2f", sellCount, bid, lot);
               LogTrade("PYRAMID_SELL", bid, 0, 0, lot, 0);
            }
         }
      }
   }

   // Hedge: if all layers used and still losing, open opposite side
   if(InpShiftHedgeLock && !g_hedgeActive)
   {
      bool allLayersUsed = (g_cycleDirection == +1 && buyCount > InpPyramidLayers) ||
                           (g_cycleDirection == -1 && sellCount > InpPyramidLayers);
      double basketPnL = GetBasketPnL();

      if(allLayersUsed && basketPnL < -InpStepProfit)
      {
         double lot = InpBaseLot;
         bool ok = false;
         if(g_cycleDirection == +1)
            ok = g_trade.Sell(lot, _Symbol, bid, 0, 0,
                              StringFormat("Grid_HEDGE_SELL|M%I64u", InpMagic));
         else
            ok = g_trade.Buy(lot, _Symbol, ask, 0, 0,
                              StringFormat("Grid_HEDGE_BUY|M%I64u", InpMagic));

         if(ok)
         {
            g_hedgeActive = true;
            PrintFormat("HEDGE opened: %s | lot=%.2f | basket=%.2f",
                        g_cycleDirection == +1 ? "SELL" : "BUY", lot, basketPnL);
         }
      }
   }
}


// ================================================================
//  BASKET PROFIT MANAGEMENT
// ================================================================

//+------------------------------------------------------------------+
//| Manage basket: stepped lock, trailing, close on target             |
//+------------------------------------------------------------------+
void ManageBasket()
{
   int posCount = CountOurPositions();
   if(posCount == 0)
   {
      ResetCycle();
      return;
   }

   double basketPnL = GetBasketPnL();

   // Hard basket TP
   if(InpHardBasketTP > 0 && basketPnL >= InpHardBasketTP)
   {
      PrintFormat("HARD BASKET TP hit: $%.2f", basketPnL);
      CloseAllPositions("HARD_TP");
      StartPause();
      return;
   }

   // Stepped lock with optional trailing
   if(basketPnL >= InpStepProfit)
   {
      if(!InpEnableTrailing)
      {
         PrintFormat("STEP PROFIT reached: $%.2f — closing basket", basketPnL);
         CloseAllPositions("STEP_PROFIT");
         StartPause();
         return;
      }

      // Trailing mode
      if(!g_trailingActive)
      {
         g_trailingActive  = true;
         g_basketPeakProfit = basketPnL;
         g_trailingFloor    = basketPnL - InpTrailDistance;
         PrintFormat("TRAILING activated: profit=$%.2f floor=$%.2f",
                     basketPnL, g_trailingFloor);
      }
      else
      {
         if(basketPnL > g_basketPeakProfit)
         {
            g_basketPeakProfit = basketPnL;
            double newFloor = basketPnL - InpTrailDistance;
            if(newFloor > g_trailingFloor + InpTrailStep)
            {
               g_trailingFloor = newFloor;
               PrintFormat("TRAIL raised: peak=$%.2f floor=$%.2f",
                           g_basketPeakProfit, g_trailingFloor);
            }
         }

         if(basketPnL <= g_trailingFloor)
         {
            PrintFormat("TRAIL STOP hit: profit=$%.2f floor=$%.2f — closing",
                        basketPnL, g_trailingFloor);
            CloseAllPositions("TRAIL_STOP");
            StartPause();
            return;
         }
      }
   }
}


// ================================================================
//  LOT SIZING
// ================================================================

//+------------------------------------------------------------------+
//| Calculate lot for a new cycle (base + optional recovery)           |
//+------------------------------------------------------------------+
double CalculateCycleLot()
{
   double lot = InpBaseLot;

   if(InpAutoRecover && g_dailyLossAccum > 0)
   {
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      if(tickSize > 0 && tickValue > 0)
      {
         double recoveryDist = InpRecoveryPoints * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
         double recoveryLot  = g_dailyLossAccum / (recoveryDist / tickSize * tickValue);
         recoveryLot = MathMin(recoveryLot, InpRecoveryLotCap);
         lot += recoveryLot;
         PrintFormat("Recovery lot added: +%.4f (recovering $%.2f in %d pts)",
                     recoveryLot, g_dailyLossAccum, InpRecoveryPoints);
      }
   }

   return NormalizeLot(lot);
}

//+------------------------------------------------------------------+
//| Calculate lot for a pyramid layer                                  |
//+------------------------------------------------------------------+
double CalculateLayerLot(int layerNumber)
{
   double lot = InpBaseLot * MathPow(InpPyramidMultiplier, layerNumber);
   return NormalizeLot(lot);
}

//+------------------------------------------------------------------+
//| Normalize lot to broker constraints                                |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lotStep <= 0) return 0;

   lot = MathFloor(lot / lotStep) * lotStep;
   lot = NormalizeDouble(lot, 2);

   if(lot < minLot) return 0;
   if(lot > maxLot) lot = maxLot;

   return lot;
}


// ================================================================
//  CYCLE MANAGEMENT
// ================================================================

//+------------------------------------------------------------------+
//| Close all positions belonging to this EA                           |
//+------------------------------------------------------------------+
void CloseAllPositions(string reason)
{
   double totalProfit = GetBasketPnL();

   for(int attempt = 0; attempt < 3; attempt++)
   {
      bool allClosed = true;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

         if(!g_trade.PositionClose(ticket, InpMaxSlippage))
         {
            PrintFormat("Failed to close ticket %I64u: %s",
                        ticket, g_trade.ResultRetcodeDescription());
            allClosed = false;
         }
      }
      if(allClosed) break;
      Sleep(500);
   }

   PrintFormat("CYCLE CLOSED: reason=%s | basket PnL=$%.2f", reason, totalProfit);
   LogTrade("CLOSE_ALL", 0, 0, 0, 0, totalProfit);

   if(totalProfit < 0)
      g_dailyLossAccum += MathAbs(totalProfit);
}

//+------------------------------------------------------------------+
//| Start post-profit pause                                            |
//+------------------------------------------------------------------+
void StartPause()
{
   if(InpPauseAfterStep)
   {
      g_pauseEndTime = TimeCurrent() + InpPauseDuration * 60;
      g_cycleState   = CYCLE_PAUSED;
      PrintFormat("PAUSED for %d minutes (until %s)",
                  InpPauseDuration, TimeToString(g_pauseEndTime, TIME_MINUTES));
   }
   else
   {
      ResetCycle();
   }
}

//+------------------------------------------------------------------+
//| Reset cycle state                                                  |
//+------------------------------------------------------------------+
void ResetCycle()
{
   g_cycleState       = CYCLE_IDLE;
   g_cycleDirection   = 0;
   g_buyLayers        = 0;
   g_sellLayers       = 0;
   g_hedgeActive      = false;
   g_basketPeakProfit = 0;
   g_trailingFloor    = 0;
   g_trailingActive   = false;
}


// ================================================================
//  SAFETY
// ================================================================

//+------------------------------------------------------------------+
//| Check equity drawdown — emergency stop                             |
//+------------------------------------------------------------------+
bool CheckEquityDrawdown()
{
   if(InpMaxEquityDD <= 0) return false;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct  = (g_initialEquity - equity) / g_initialEquity * 100.0;

   if(ddPct >= InpMaxEquityDD)
   {
      PrintFormat("EMERGENCY: Equity DD %.1f%% >= %.1f%% — CLOSING ALL",
                  ddPct, InpMaxEquityDD);
      CloseAllPositions("EQUITY_DD_EMERGENCY");
      ResetCycle();
      g_cycleState = CYCLE_PAUSED;
      g_pauseEndTime = TimeCurrent() + 86400; // pause 24 hours
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Daily loss check                                                   |
//+------------------------------------------------------------------+
bool IsDailyLossHit()
{
   if(g_dailyStartEquity <= 0) return false;
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPct = (g_dailyStartEquity - equity) / g_dailyStartEquity * 100.0;
   return lossPct >= InpMaxDailyLoss;
}


// ================================================================
//  UTILITY FUNCTIONS
// ================================================================

//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime barTime = iTime(_Symbol, InpCycleTF, 0);
   if(barTime == 0 || barTime == g_lastBarTime)
      return false;
   g_lastBarTime = barTime;
   return true;
}

//+------------------------------------------------------------------+
void ResetDailyCounters()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   datetime today = (datetime)StringToTime(
      StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));

   if(today != g_currentDay)
   {
      g_currentDay       = today;
      g_dailyLossAccum   = 0;
      g_dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      PrintFormat("New day: equity=%.2f", g_dailyStartEquity);
   }
}

//+------------------------------------------------------------------+
bool IsWithinWindow()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   string now = StringFormat("%02d:%02d", dt.hour, dt.min);
   return (now >= InpWindowStart && now < InpWindowEnd);
}

//+------------------------------------------------------------------+
bool CheckSpread()
{
   if(InpMaxSpread <= 0) return true;
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return spread <= InpMaxSpread;
}

//+------------------------------------------------------------------+
double GetBasketPnL()
{
   double pnl = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      pnl += PositionGetDouble(POSITION_PROFIT)
           + PositionGetDouble(POSITION_SWAP);
   }
   return pnl;
}

//+------------------------------------------------------------------+
int CountOurPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 &&
         PositionGetInteger(POSITION_MAGIC) == (long)InpMagic &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| On startup, detect if positions from a previous session exist      |
//+------------------------------------------------------------------+
void SyncExistingPositions()
{
   int count = CountOurPositions();
   if(count > 0)
   {
      g_cycleState = CYCLE_ACTIVE;

      // Detect direction from majority position type
      int buys = 0, sells = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) buys++;
         else sells++;
      }
      g_cycleDirection = (buys >= sells) ? +1 : -1;
      g_buyLayers  = buys;
      g_sellLayers = sells;
      g_hedgeActive = (buys > 0 && sells > 0);

      PrintFormat("Synced %d existing positions: %d BUY, %d SELL | direction=%s",
                  count, buys, sells, g_cycleDirection == +1 ? "BUY" : "SELL");
   }
}

//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING DetectFillingType()
{
   long filling = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| CSV logging                                                        |
//+------------------------------------------------------------------+
void InitLogFile()
{
   int handle = FileOpen("GridRecovery_Log.csv",
                          FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(handle != INVALID_HANDLE)
   {
      FileWrite(handle, "Time", "Action", "Price", "SL", "TP",
                "Lots", "Info", "BasketPnL", "DailyLoss");
      FileClose(handle);
   }
}

void LogTrade(string action, double price, double sl, double tp,
              double lots, double info)
{
   if(!InpLogTrades) return;
   int handle = FileOpen("GridRecovery_Log.csv",
                          FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(handle == INVALID_HANDLE) return;
   FileSeek(handle, 0, SEEK_END);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   FileWrite(handle,
             TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES),
             action,
             DoubleToString(price, digits),
             DoubleToString(sl, digits),
             DoubleToString(tp, digits),
             DoubleToString(lots, 2),
             DoubleToString(info, 2),
             DoubleToString(GetBasketPnL(), 2),
             DoubleToString(g_dailyLossAccum, 2));
   FileClose(handle);
}

//+------------------------------------------------------------------+
//| Chart display                                                      |
//+------------------------------------------------------------------+
void UpdateChartComment()
{
   string stateStr = "IDLE";
   if(g_cycleState == CYCLE_ACTIVE) stateStr = "ACTIVE";
   else if(g_cycleState == CYCLE_PAUSED) stateStr = "PAUSED";

   string dirStr = g_cycleDirection == +1 ? "BUY" :
                   g_cycleDirection == -1 ? "SELL" : "NONE";

   double basketPnL = GetBasketPnL();
   int positions = CountOurPositions();

   string trailStr = "OFF";
   if(g_trailingActive)
      trailStr = StringFormat("ON (floor=$%.2f peak=$%.2f)",
                               g_trailingFloor, g_basketPeakProfit);

   Comment(StringFormat(
      "=== Gold Grid Recovery EA ===\n"
      "State: %s | Direction: %s\n"
      "Positions: %d (BUY:%d SELL:%d) | Hedge: %s\n"
      "Basket PnL: $%.2f | Target: $%.2f\n"
      "Trailing: %s\n"
      "Daily loss accum: $%.2f | Spread: %d\n"
      "Recovery: %s | Lot: %.2f",
      stateStr, dirStr,
      positions, g_buyLayers, g_sellLayers,
      g_hedgeActive ? "YES" : "NO",
      basketPnL, InpStepProfit,
      trailStr,
      g_dailyLossAccum, (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD),
      InpAutoRecover && g_dailyLossAccum > 0 ? "ACTIVE" : "OFF",
      InpBaseLot
   ));
}
//+------------------------------------------------------------------+
