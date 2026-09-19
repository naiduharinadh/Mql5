#property strict
#property version "1.00"

#include <Trade/Trade.mqh>

CTrade trade;

input ENUM_TIMEFRAMES SignalTimeframe = PERIOD_M1;

input int FastEMAPeriod = 13;
input int SlowEMAPeriod = 48;

input int ATRPeriod = 14;
input double ATR_SL_Multiplier = 1.50;
input double ATR_TP_Multiplier = 2.50;

input int SwingLookback = 150;
input int SwingStrength = 3;

input double RiskPerTradePercent = 0.50;
input double FixedLotSize = 0.0;

input double DailyProfitTarget = 70.0;
input double DailyLossLimit = 70.0;

input int MaxPositions = 5;
input double MaxSpreadPoints = 80.0;

input double MinimumRiskReward = 1.20;

input bool CloseOppositeOnSignal = true;

input bool EnableBreakEven = true;
input double BreakEvenATR = 1.00;
input double BreakEvenOffsetATR = 0.10;

input bool EnableTrailing = true;
input double TrailingATR = 1.20;

input ulong MagicNumber = 130048;

int fastHandle = INVALID_HANDLE;
int slowHandle = INVALID_HANDLE;
int atrHandle = INVALID_HANDLE;

datetime lastBarTime = 0;
datetime lastSignalBar = 0;

double DayStartBalance = 0.0;
int CurrentDay = -1;

int OnInit()
{
   fastHandle = iMA(_Symbol, SignalTimeframe, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   slowHandle = iMA(_Symbol, SignalTimeframe, SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   atrHandle = iATR(_Symbol, SignalTimeframe, ATRPeriod);

   if(fastHandle == INVALID_HANDLE || slowHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
      return INIT_FAILED;

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFillingBySymbol(_Symbol);

   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);
   CurrentDay = tm.day_of_year;
   DayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(fastHandle != INVALID_HANDLE)
      IndicatorRelease(fastHandle);

   if(slowHandle != INVALID_HANDLE)
      IndicatorRelease(slowHandle);

   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
}

void OnTick()
{
   ResetDailyState();

   ManagePositions();

   if(IsDailyTargetReached())
      return;

   if(IsDailyLossReached())
      return;

   if(!IsNewBar())
      return;

   if(!TradingConditionsOK())
      return;

   double fast[3];
   double slow[3];

   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);

   if(CopyBuffer(fastHandle, 0, 0, 3, fast) < 3)
      return;

   if(CopyBuffer(slowHandle, 0, 0, 3, slow) < 3)
      return;

   bool bullishCross = fast[2] <= slow[2] && fast[1] > slow[1];
   bool bearishCross = fast[2] >= slow[2] && fast[1] < slow[1];

   datetime signalBar = iTime(_Symbol, SignalTimeframe, 1);

   if(signalBar == lastSignalBar)
      return;

   if(bullishCross)
   {
      lastSignalBar = signalBar;

      if(CloseOppositeOnSignal)
         ClosePositionsByType(POSITION_TYPE_SELL);

      if(CountPositions(POSITION_TYPE_BUY) < MaxPositions)
         OpenBuy();
   }

   if(bearishCross)
   {
      lastSignalBar = signalBar;

      if(CloseOppositeOnSignal)
         ClosePositionsByType(POSITION_TYPE_BUY);

      if(CountPositions(POSITION_TYPE_SELL) < MaxPositions)
         OpenSell();
   }
}

void ResetDailyState()
{
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);

   if(tm.day_of_year != CurrentDay)
   {
      CurrentDay = tm.day_of_year;
      DayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   }
}

bool IsNewBar()
{
   datetime currentBar = iTime(_Symbol, SignalTimeframe, 0);

   if(currentBar == 0)
      return false;

   if(currentBar != lastBarTime)
   {
      lastBarTime = currentBar;
      return true;
   }

   return false;
}

bool TradingConditionsOK()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(bid <= 0 || ask <= 0)
      return false;

   double spread = (ask - bid) / _Point;

   if(spread > MaxSpreadPoints)
      return false;

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;

   return true;
}

double GetATR()
{
   double buffer[2];
   ArraySetAsSeries(buffer, true);

   if(CopyBuffer(atrHandle, 0, 1, 1, buffer) < 1)
      return 0.0;

   return buffer[0];
}

bool IsSwingHigh(MqlRates &rates[], int index)
{
   for(int i = 1; i <= SwingStrength; i++)
   {
      if(rates[index].high <= rates[index - i].high)
         return false;

      if(rates[index].high <= rates[index + i].high)
         return false;
   }

   return true;
}

bool IsSwingLow(MqlRates &rates[], int index)
{
   for(int i = 1; i <= SwingStrength; i++)
   {
      if(rates[index].low >= rates[index - i].low)
         return false;

      if(rates[index].low >= rates[index + i].low)
         return false;
   }

   return true;
}

double FindResistance(double entry, double minimumDistance)
{
   MqlRates rates[];

   int count = CopyRates(
      _Symbol,
      SignalTimeframe,
      0,
      SwingLookback,
      rates
   );

   if(count <= SwingStrength * 2 + 5)
      return 0.0;

   ArraySetAsSeries(rates, true);

   double selected = 0.0;

   for(int i = SwingStrength + 1; i < count - SwingStrength; i++)
   {
      if(!IsSwingHigh(rates, i))
         continue;

      double level = rates[i].high;

      if(level <= entry + minimumDistance)
         continue;

      if(selected == 0.0 || level < selected)
         selected = level;
   }

   return selected;
}

double FindSupport(double entry, double minimumDistance)
{
   MqlRates rates[];

   int count = CopyRates(
      _Symbol,
      SignalTimeframe,
      0,
      SwingLookback,
      rates
   );

   if(count <= SwingStrength * 2 + 5)
      return 0.0;

   ArraySetAsSeries(rates, true);

   double selected = 0.0;

   for(int i = SwingStrength + 1; i < count - SwingStrength; i++)
   {
      if(!IsSwingLow(rates, i))
         continue;

      double level = rates[i].low;

      if(level >= entry - minimumDistance)
         continue;

      if(selected == 0.0 || level > selected)
         selected = level;
   }

   return selected;
}

double FindBuyStop(double entry, double atr)
{
   double support = FindSupport(entry, atr * 0.20);

   double atrStop = entry - atr * ATR_SL_Multiplier;

   if(support > 0.0 && support < entry)
   {
      double structuralStop = support - atr * 0.15;

      if(structuralStop < entry)
         return MathMin(structuralStop, atrStop);
   }

   return atrStop;
}

double FindSellStop(double entry, double atr)
{
   double resistance = FindResistance(entry, atr * 0.20);

   double atrStop = entry + atr * ATR_SL_Multiplier;

   if(resistance > entry)
   {
      double structuralStop = resistance + atr * 0.15;

      if(structuralStop > entry)
         return MathMax(structuralStop, atrStop);
   }

   return atrStop;
}

double FindBuyTakeProfit(double entry, double stop, double atr)
{
   double risk = entry - stop;

   if(risk <= 0)
      return entry + atr * ATR_TP_Multiplier;

   double minimumTPDistance = risk * MinimumRiskReward;

   double resistance = FindResistance(
      entry,
      MathMax(minimumTPDistance * 0.20, atr * 0.10)
   );

   if(resistance > entry)
   {
      if(resistance - entry >= minimumTPDistance)
         return resistance;
   }

   return entry + MathMax(
      atr * ATR_TP_Multiplier,
      minimumTPDistance
   );
}

double FindSellTakeProfit(double entry, double stop, double atr)
{
   double risk = stop - entry;

   if(risk <= 0)
      return entry - atr * ATR_TP_Multiplier;

   double minimumTPDistance = risk * MinimumRiskReward;

   double support = FindSupport(
      entry,
      MathMax(minimumTPDistance * 0.20, atr * 0.10)
   );

   if(support > 0.0)
   {
      if(entry - support >= minimumTPDistance)
         return support;
   }

   return entry - MathMax(
      atr * ATR_TP_Multiplier,
      minimumTPDistance
   );
}

double NormalizePrice(double price)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
}

double GetMinimumStopDistance()
{
   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   double distance = stopsLevel * _Point;

   double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                 - SymbolInfoDouble(_Symbol, SYMBOL_BID);

   return MathMax(distance, spread * 1.5);
}

double CalculateLotSize(double entry, double stop)
{
   if(FixedLotSize > 0.0)
      return NormalizeVolume(FixedLotSize);

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   double riskMoney = balance * RiskPerTradePercent / 100.0;

   double distance = MathAbs(entry - stop);

   if(distance <= 0)
      return 0.0;

   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(tickSize <= 0 || tickValue <= 0)
      return NormalizeVolume(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));

   double moneyPerLot = (distance / tickSize) * tickValue;

   if(moneyPerLot <= 0)
      return 0.0;

   double lots = riskMoney / moneyPerLot;

   return NormalizeVolume(lots);
}

double NormalizeVolume(double lots)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0)
      step = minLot;

   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);

   lots = MathFloor(lots / step) * step;

   int digits = 2;

   if(step < 0.01)
      digits = 3;

   if(step < 0.001)
      digits = 4;

   return NormalizeDouble(lots, digits);
}

void OpenBuy()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(ask <= 0)
      return;

   double atr = GetATR();

   if(atr <= 0)
      return;

   double minimumStopDistance = GetMinimumStopDistance();

   double sl = FindBuyStop(ask, atr);

   if(ask - sl < minimumStopDistance)
      sl = ask - minimumStopDistance;

   sl = NormalizePrice(sl);

   double tp = FindBuyTakeProfit(ask, sl, atr);

   if(tp - ask < minimumStopDistance)
      tp = ask + minimumStopDistance;

   tp = NormalizePrice(tp);

   if(sl >= ask || tp <= ask)
      return;

   double lots = CalculateLotSize(ask, sl);

   if(lots <= 0)
      return;

   trade.Buy(
      lots,
      _Symbol,
      0.0,
      sl,
      tp,
      "EMA13x48 BUY"
   );
}

void OpenSell()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(bid <= 0)
      return;

   double atr = GetATR();

   if(atr <= 0)
      return;

   double minimumStopDistance = GetMinimumStopDistance();

   double sl = FindSellStop(bid, atr);

   if(sl - bid < minimumStopDistance)
      sl = bid + minimumStopDistance;

   sl = NormalizePrice(sl);

   double tp = FindSellTakeProfit(bid, sl, atr);

   if(bid - tp < minimumStopDistance)
      tp = bid - minimumStopDistance;

   tp = NormalizePrice(tp);

   if(sl <= bid || tp >= bid)
      return;

   double lots = CalculateLotSize(bid, sl);

   if(lots <= 0)
      return;

   trade.Sell(
      lots,
      _Symbol,
      0.0,
      sl,
      tp,
      "EMA13x48 SELL"
   );
}

int CountPositions(ENUM_POSITION_TYPE type)
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == type)
         count++;
   }

   return count;
}

void ClosePositionsByType(ENUM_POSITION_TYPE type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type)
         continue;

      trade.PositionClose(ticket);
   }
}

void ManagePositions()
{
   double atr = GetATR();

   if(atr <= 0)
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);

      if(type == POSITION_TYPE_BUY)
      {
         double profitDistance = bid - openPrice;

         if(EnableBreakEven && profitDistance >= atr * BreakEvenATR)
         {
            double newSL = openPrice + atr * BreakEvenOffsetATR;

            if(currentSL == 0.0 || newSL > currentSL)
            {
               newSL = NormalizePrice(newSL);

               if(newSL < bid)
                  trade.PositionModify(ticket, newSL, currentTP);
            }
         }

         if(EnableTrailing && profitDistance >= atr * BreakEvenATR)
         {
            double trailingSL = bid - atr * TrailingATR;

            if(currentSL == 0.0 || trailingSL > currentSL)
            {
               trailingSL = NormalizePrice(trailingSL);

               if(trailingSL < bid)
                  trade.PositionModify(ticket, trailingSL, currentTP);
            }
         }
      }

      if(type == POSITION_TYPE_SELL)
      {
         double profitDistance = openPrice - ask;

         if(EnableBreakEven && profitDistance >= atr * BreakEvenATR)
         {
            double newSL = openPrice - atr * BreakEvenOffsetATR;

            if(currentSL == 0.0 || newSL < currentSL)
            {
               newSL = NormalizePrice(newSL);

               if(newSL > ask)
                  trade.PositionModify(ticket, newSL, currentTP);
            }
         }

         if(EnableTrailing && profitDistance >= atr * BreakEvenATR)
         {
            double trailingSL = ask + atr * TrailingATR;

            if(currentSL == 0.0 || trailingSL < currentSL)
            {
               trailingSL = NormalizePrice(trailingSL);

               if(trailingSL > ask)
                  trade.PositionModify(ticket, trailingSL, currentTP);
            }
         }
      }
   }
}

double GetTodayClosedProfit()
{
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);

   tm.hour = 0;
   tm.min = 0;
   tm.sec = 0;

   datetime startTime = StructToTime(tm);

   if(!HistorySelect(startTime, TimeCurrent()))
      return 0.0;

   double result = 0.0;

   int total = HistoryDealsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);

      if(ticket == 0)
         continue;

      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol)
         continue;

      if((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != MagicNumber)
         continue;

      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);

      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT)
         continue;

      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      double swap = HistoryDealGetDouble(ticket, DEAL_SWAP);
      double commission = HistoryDealGetDouble(ticket, DEAL_COMMISSION);

      result += profit + swap + commission;
   }

   return result;
}

bool IsDailyTargetReached()
{
   double profit = GetTodayClosedProfit();

   return profit >= DailyProfitTarget;
}

bool IsDailyLossReached()
{
   double profit = GetTodayClosedProfit();

   return profit <= -DailyLossLimit;
}
