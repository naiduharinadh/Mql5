//+------------------------------------------------------------------+
//|                                          BasketGridHedgeEA.mq5   |
//|  Basket-profit grid EA with pyramid layers, hedge-lock,          |
//|  basket trailing, daily-loss recovery lot, time/spread filters.  |
//|  Requires a HEDGING account.                                     |
//+------------------------------------------------------------------+
#property version   "1.00"
#property description "Basket grid + hedge-lock EA"

#include <Trade\Trade.mqh>

enum ENUM_ENTRY_MODE
  {
   ENTRY_BUY  = 0,   // Buy only
   ENTRY_SELL = 1,   // Sell only
   ENTRY_BOTH = 2    // Buy and Sell (one cycle per side)
  };

input group "Basket"
input double InpStepProfit     = 5.0;    // Step profit ($) - basket target
input int    InpPauseMinutes   = 15;     // Pause after target (minutes)
input bool   InpBasketTrailing = true;   // Basket trailing
input double InpTrailPullback  = 2.0;    // Trailing pullback ($)

input group "Lots"
input double InpBaseLot        = 0.01;   // Base lot
input double InpLotMultiplier  = 1.0;    // Layer lot multiplier (1 = no martingale)
input bool   InpUseRecoveryLot = true;   // Add recovery lot for today's losses
input double InpRecoveryLotCap = 0.01;   // Max extra recovery lot
input int    InpRecoveryPoints = 150;    // Recover daily loss within N points

input group "Grid / Hedge"
input ENUM_ENTRY_MODE InpEntryMode = ENTRY_BOTH; // Entry mode
input int    InpGridPoints     = 200;    // Grid distance (points)
input int    InpMaxLayers      = 1;      // Pyramid layers per side (additional)
input bool   InpHedgeLock      = true;   // Hedge-lock when all layers used

input group "Filters"
input int    InpStartHour      = 1;      // Trading window start hour (server time)
input int    InpEndHour        = 23;     // Trading window end hour (server time)
input int    InpMaxSpread      = 70;     // Max spread (points)
input int    InpMaxSlippage    = 30;     // Max slippage (points)
input ulong  InpMagic          = 20260926; // Magic number

#define CMT_GRID_BUY   "GRID_B"
#define CMT_GRID_SELL  "GRID_S"
#define CMT_HEDGE_BUY  "HEDGE_B"   // hedge protecting the BUY side (a sell)
#define CMT_HEDGE_SELL "HEDGE_S"   // hedge protecting the SELL side (a buy)

CTrade   trade;
datetime g_pauseUntil = 0;
bool     g_trailing   = false;
double   g_peakProfit = 0.0;

//+------------------------------------------------------------------+
int OnInit()
  {
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Print("BasketGridHedgeEA requires a hedging account.");
      return INIT_FAILED;
     }
   if(InpGridPoints <= 0 || InpBaseLot <= 0 || InpStartHour >= InpEndHour)
     {
      Print("Invalid inputs.");
      return INIT_PARAMETERS_INCORRECT;
     }
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpMaxSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(CountPositions() > 0)
     {
      if(ManageBasket())
         return;
      ManageSide(POSITION_TYPE_BUY);
      ManageSide(POSITION_TYPE_SELL);
      return;
     }

   // Flat: reset trailing and consider a new cycle
   g_trailing   = false;
   g_peakProfit = 0.0;

   if(TimeCurrent() < g_pauseUntil || !InTradingWindow())
      return;

   StartCycle();
  }

//+------------------------------------------------------------------+
//| Basket target / trailing. Returns true if the basket was closed. |
//+------------------------------------------------------------------+
bool ManageBasket()
  {
   double profit = BasketProfit();

   if(!InpBasketTrailing)
     {
      if(profit >= InpStepProfit)
         return CloseAll();
      return false;
     }

   if(!g_trailing && profit >= InpStepProfit)
     {
      g_trailing   = true;
      g_peakProfit = profit;
      PrintFormat("Basket target hit (%.2f). Trailing started.", profit);
     }

   if(g_trailing)
     {
      if(profit > g_peakProfit)
         g_peakProfit = profit;
      if(profit <= g_peakProfit - InpTrailPullback)
        {
         PrintFormat("Basket pulled back to %.2f from peak %.2f. Closing.", profit, g_peakProfit);
         return CloseAll();
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Adds pyramid layers, then hedge-locks, for one side.             |
//+------------------------------------------------------------------+
void ManageSide(ENUM_POSITION_TYPE side)
  {
   string gridCmt  = (side == POSITION_TYPE_BUY) ? CMT_GRID_BUY  : CMT_GRID_SELL;
   string hedgeCmt = (side == POSITION_TYPE_BUY) ? CMT_HEDGE_BUY : CMT_HEDGE_SELL;

   int      layers      = 0;
   double   worstPrice  = 0.0;
   double   sideVolume  = 0.0;
   double   firstLot    = 0.0;
   datetime firstTime   = 0;
   bool     hedged      = false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!SelectOwnPosition(i))
         continue;
      string cmt = PositionGetString(POSITION_COMMENT);
      if(StringFind(cmt, hedgeCmt) == 0)
        {
         hedged = true;
         continue;
        }
      if(StringFind(cmt, gridCmt) != 0 || (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side)
         continue;

      double   open = PositionGetDouble(POSITION_PRICE_OPEN);
      double   vol  = PositionGetDouble(POSITION_VOLUME);
      datetime t    = (datetime)PositionGetInteger(POSITION_TIME);

      layers++;
      sideVolume += vol;
      if(layers == 1 || (side == POSITION_TYPE_BUY ? open < worstPrice : open > worstPrice))
         worstPrice = open;
      if(firstTime == 0 || t < firstTime)
        {
         firstTime = t;
         firstLot  = vol;
        }
     }

   if(layers == 0 || hedged)
      return;

   double adversePts = (side == POSITION_TYPE_BUY)
                       ? (worstPrice - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point
                       : (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - worstPrice) / _Point;
   if(adversePts < InpGridPoints)
      return;

   int addedLayers = layers - 1;
   if(addedLayers < InpMaxLayers)
     {
      double lot = NormalizeLot(firstLot * MathPow(InpLotMultiplier, layers));
      OpenTrade(side, lot, gridCmt);
     }
   else if(InpHedgeLock)
     {
      ENUM_POSITION_TYPE opposite = (side == POSITION_TYPE_BUY) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
      PrintFormat("All layers used on %s side. Hedge-locking %.2f lots.",
                  side == POSITION_TYPE_BUY ? "BUY" : "SELL", sideVolume);
      OpenTrade(opposite, NormalizeLot(sideVolume), hedgeCmt);
     }
  }

//+------------------------------------------------------------------+
void StartCycle()
  {
   double lot = NormalizeLot(InpBaseLot + RecoveryExtraLot());

   if(InpEntryMode == ENTRY_BUY || InpEntryMode == ENTRY_BOTH)
      OpenTrade(POSITION_TYPE_BUY, lot, CMT_GRID_BUY);
   if(InpEntryMode == ENTRY_SELL || InpEntryMode == ENTRY_BOTH)
      OpenTrade(POSITION_TYPE_SELL, lot, CMT_GRID_SELL);
  }

//+------------------------------------------------------------------+
bool OpenTrade(ENUM_POSITION_TYPE type, double lot, string comment)
  {
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpread)
     {
      PrintFormat("Spread %d > %d. Skipping %s.", spread, InpMaxSpread, comment);
      return false;
     }

   bool ok = (type == POSITION_TYPE_BUY)
             ? trade.Buy(lot, _Symbol, 0.0, 0.0, 0.0, comment)
             : trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0, comment);

   if(!ok || (trade.ResultRetcode() != TRADE_RETCODE_DONE && trade.ResultRetcode() != TRADE_RETCODE_PLACED))
     {
      PrintFormat("Open %s %.2f failed: %d %s", comment, lot, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Closes every EA position. Starts the pause once fully flat.      |
//+------------------------------------------------------------------+
bool CloseAll()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!SelectOwnPosition(i))
         continue;
      ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
      if(!trade.PositionClose(ticket))
         PrintFormat("Close #%I64u failed: %d %s", ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }

   if(CountPositions() > 0)
      return false;   // retry remaining positions next tick

   g_pauseUntil = TimeCurrent() + InpPauseMinutes * 60;
   g_trailing   = false;
   g_peakProfit = 0.0;
   PrintFormat("Cycle closed. Pausing until %s.", TimeToString(g_pauseUntil));
   return true;
  }

//+------------------------------------------------------------------+
//| Extra lot needed to recover today's closed loss within           |
//| InpRecoveryPoints, capped at InpRecoveryLotCap.                  |
//+------------------------------------------------------------------+
double RecoveryExtraLot()
  {
   if(!InpUseRecoveryLot || InpRecoveryPoints <= 0)
      return 0.0;

   double loss = -TodayClosedPnL();
   if(loss <= 0.0)
      return 0.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0)
      return 0.0;

   double valuePerPointPerLot = tickValue * _Point / tickSize;
   double lot = loss / (InpRecoveryPoints * valuePerPointPerLot);
   return MathMin(lot, InpRecoveryLotCap);
  }

//+------------------------------------------------------------------+
double TodayClosedPnL()
  {
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   t.hour = 0;
   t.min  = 0;
   t.sec  = 0;
   if(!HistorySelect(StructToTime(t), TimeCurrent()))
      return 0.0;

   double pnl = 0.0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0 ||
         HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol ||
         (ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic)
         continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT || entry == DEAL_ENTRY_OUT_BY)
         pnl += HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP);
      pnl += HistoryDealGetDouble(deal, DEAL_COMMISSION) + HistoryDealGetDouble(deal, DEAL_FEE);
     }
   return pnl;
  }

//+------------------------------------------------------------------+
double BasketProfit()
  {
   double profit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(SelectOwnPosition(i))
         profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   return profit;
  }

//+------------------------------------------------------------------+
int CountPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(SelectOwnPosition(i))
         n++;
   return n;
  }

//+------------------------------------------------------------------+
bool SelectOwnPosition(int index)
  {
   ulong ticket = PositionGetTicket(index);
   return ticket != 0 &&
          PositionGetString(POSITION_SYMBOL) == _Symbol &&
          (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic;
  }

//+------------------------------------------------------------------+
bool InTradingWindow()
  {
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   return t.hour >= InpStartHour && t.hour < InpEndHour;
  }

//+------------------------------------------------------------------+
double NormalizeLot(double lot)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepLot > 0.0)
      lot = MathFloor(lot / stepLot + 1e-9) * stepLot;
   return MathMax(minLot, MathMin(maxLot, NormalizeDouble(lot, 2)));
  }
//+------------------------------------------------------------------+
